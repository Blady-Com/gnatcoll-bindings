-----------------------------------------------------------------------
--                               G P S                               --
--                                                                   --
--                  Copyright (C) 2002-2010, AdaCore                 --
--                                                                   --
-- GPS is free  software;  you can redistribute it and/or modify  it --
-- under the terms of the GNU General Public License as published by --
-- the Free Software Foundation; either version 2 of the License, or --
-- (at your option) any later version.                               --
--                                                                   --
-- This program is  distributed in the hope that it will be  useful, --
-- but  WITHOUT ANY WARRANTY;  without even the  implied warranty of --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU --
-- General Public License for more details. You should have received --
-- a copy of the GNU General Public License along with this program; --
-- if not,  write to the  Free Software Foundation, Inc.,  59 Temple --
-- Place - Suite 330, Boston, MA 02111-1307, USA.                    --
-----------------------------------------------------------------------

with Ada.Calendar;               use Ada.Calendar;
with Ada.Characters.Handling;    use Ada.Characters.Handling;
with Ada.Containers.Doubly_Linked_Lists;
with Ada.Containers.Hashed_Sets;
with Ada.Directories;
with Ada.Strings;                use Ada.Strings;
with Ada.Strings.Fixed;          use Ada.Strings.Fixed;
with Ada.Strings.Hash_Case_Insensitive;
with Ada.Strings.Maps;           use Ada.Strings.Maps;
with Ada.Text_IO;                use Ada.Text_IO;
with GNAT.Case_Util;             use GNAT.Case_Util;
with GNAT.Directory_Operations;  use GNAT.Directory_Operations;
with GNAT.OS_Lib;                use GNAT.OS_Lib;
with GNATCOLL.Projects.Normalize; use GNATCOLL.Projects.Normalize;
with GNATCOLL.Traces;            use GNATCOLL.Traces;
with GNATCOLL.Utils;             use GNATCOLL.Utils;
with GNATCOLL.VFS;               use GNATCOLL.VFS;
with GNATCOLL.VFS_Utils;         use GNATCOLL.VFS_Utils;
with Casing;                     use Casing;
with Csets;
with Namet;                      use Namet;
with Osint;
with Opt;
with Output;
with Prj.Attr;                   use Prj.Attr;
with Prj.Com;
with Prj.Conf;                   use Prj.Conf;
with Prj.Env;                    use Prj, Prj.Env;
with Prj.Err;
with Prj.Ext;
with Prj.Part;
with Prj.PP;                     use Prj.PP;
with Prj.Tree;                   use Prj.Tree;
with Prj.Util;                   use Prj.Util;
with Sinput.P;
with Snames;                     use Snames;
with Types;                      use Types;

package body GNATCOLL.Projects is

   Me    : constant Trace_Handle := Create ("Projects");
   Debug : constant Trace_Handle := Create ("Projects.Debug", Default => Off);
   Me_Gnat : constant Trace_Handle :=
               Create ("Projects.GNAT", GNATCOLL.Traces.Off);
   Exception_Handle : constant Trace_Handle :=
     Create ("UNEXPECTED_EXCEPTION", Default => On);

   Dummy_Suffix : constant String := "<no suffix defined>";
   --  A dummy suffixes that is used for languages that have either no spec or
   --  no implementation suffix defined.

   package Virtual_File_List is new Ada.Containers.Doubly_Linked_Lists
     (Element_Type => Virtual_File);

   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (Scenario_Variable_Array, Scenario_Variable_Array_Access);

   package Project_Htables is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,   --  project name
      Element_Type    => Project_Type,
      Hash            => Ada.Strings.Hash_Case_Insensitive,
      Equivalent_Keys => GNATCOLL.Utils.Case_Insensitive_Equal);
   --  maps project names (casing insensitive) to project types
   --  ??? This would not be needed if we could, in the prj* sources, associate
   --  user data with project nodes.

   type Source_File_Data is record
      Project   : Project_Type;
      File      : GNATCOLL.VFS.Virtual_File;
      Lang      : Namet.Name_Id;
      Source    : Prj.Source_Id;
   end record;
   --   In some case, Lang might be set to Unknown_Language, if the file was
   --   set in the project (for instance through the Source_Files attribute),
   --   but no matching language was found.

   function Hash
     (File : GNATCOLL.VFS.Filesystem_String) return Ada.Containers.Hash_Type;
   function Equal (F1, F2 : GNATCOLL.VFS.Filesystem_String) return Boolean;
   pragma Inline (Hash, Equal);
   --  Either case sensitive or not, depending on the system

   package Names_Files is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => GNATCOLL.VFS.Filesystem_String,   --  file base name
      Element_Type    => Source_File_Data,
      Hash            => Hash,
      Equivalent_Keys => Equal);
   --  maps for file base names to info about the file

   function Hash (Node : Project_Node_Id) return Ada.Containers.Hash_Type;
   pragma Inline (Hash);

   package Project_Sets is new Ada.Containers.Hashed_Sets
     (Element_Type        => Project_Node_Id,
      Hash                => Hash,
      Equivalent_Elements => "=");

   type Directory_Dependency is (Direct, As_Parent);
   --  The way a directory belongs to the project: either as a direct
   --  dependency, or because one of its subdirs belong to the project, or
   --  doesn't belong at all.

   package Directory_Statuses is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => GNATCOLL.VFS.Filesystem_String,   --  Directory path
      Element_Type    => Directory_Dependency,
      Hash            => Hash,
      Equivalent_Keys => Equal);
   --  Whether a directory belongs to a project

   use Project_Htables, Extensions_Languages, Names_Files;
   use Directory_Statuses;

   type Project_Status is (From_File, Default);
   --  How the project was created: either read from a file, automatically
   --  created from a directory, automatically created from an executable
   --  (debugger case), or default empty project. An actual project file exists
   --  on disk only in the From_File or Default cases.
   --  When loading a new project, and if the previous project had status
   --  Default, it is removed from the disk.

   type Project_Tree_Data is record
      Env       : Project_Environment_Access;

      Tree      : Prj.Tree.Project_Node_Tree_Ref;
      View      : Prj.Project_Tree_Ref;
      --  The description of the trees

      Status  : Project_Status := From_File;

      Root    : Project_Type := No_Project;
      --  The root of the project hierarchy.

      Sources : Names_Files.Map;
      --  Index on base source file names, returns information about the file

      Directories : Directory_Statuses.Map;
      --  Index on directory name
      --  CHANGE: might not be needed anymore, using the hash tables already
      --  in prj.*

      Projects : Project_Htables.Map;
      --  Index on project names. This table is filled when the project is
      --  loaded.

      Scenario_Variables : Scenario_Variable_Array_Access;
      --  Cached value of the scenario variables. This should be accessed only
      --  through the function Scenario_Variables, since it needs to be
      --  initialized first.

      Timestamp : Ada.Calendar.Time := GNATCOLL.Utils.No_Time;
      --  Time when we last parsed the project from the disk
   end record;

   function Get_View (Project : Project_Type) return Prj.Project_Id;
   function Get_View
     (Tree : Prj.Project_Tree_Ref; Name : Name_Id) return Prj.Project_Id;
   --  Return the project view for the project Name

   type External_Variable_Callback is access function
     (Variable : Project_Node_Id; Prj : Project_Node_Id) return Boolean;
   --  Called for a typed variable declaration that references an external
   --  variable in Prj.
   --  Stops iterating if this subprogram returns False.

   procedure For_Each_Project_Node
     (Tree     : Project_Node_Tree_Ref;
      Root     : Project_Node_Id;
      Callback : access procedure
        (Tree : Project_Node_Tree_Ref; Node : Project_Node_Id));
   --  Iterate over all projects in the tree.
   --  They are each returned once, the root project first and then all its
   --  imported projects.
   --  As opposed to For_Every_Project_Imported, this iteration in based on the
   --  project tree, and therefore can be used before the project view has been
   --  computed.

   procedure For_Each_External_Variable_Declaration
     (Project   : Project_Type;
      Recursive : Boolean;
      Callback  : External_Variable_Callback);
   --  Iterate other all the typed variable declarations that reference
   --  external variables in Project (or one of its imported projects if
   --  Recursive is true).
   --  Callback is called for each of them.

   procedure Reset
     (Tree : in out Project_Tree'Class;
      Env  : Project_Environment_Access);
   --  Make sure the Tree data has been created and initialized.

   function Substitute_Dot
     (Unit_Name : String; Dot_Replacement : String) return String;
   --  Replace the '.' in unit_name with Dot_Replacement

   procedure Compute_Importing_Projects (Project : Project_Type'Class);
   --  Compute the list of all projects that import, possibly indirectly,
   --  Project.

   function String_Elements
     (Data : Project_Tree_Data_Access)
      return Prj.String_Element_Table.Table_Ptr;
   pragma Inline (String_Elements);
   --  Return access to the various tables that contain information about the
   --  project

   function Get_String (Id : Namet.File_Name_Type) return String;
   function Get_String (Id : Namet.Path_Name_Type) return String;
   pragma Inline (Get_String);
   --  Return the string in Name
   --  Same as Namet.Get_Name_String, but return "" in case of
   --  failure, instead of raising Assert_Failure.

   function Create_Flags
     (On_Error        : Prj.Error_Handler;
      Require_Sources : Boolean := True) return Prj.Processing_Flags;
   --  Return the flags to pass to the project manager in the context of GPS.
   --  Require_Sources indicates whether each language must have sources
   --  attached to it.

   function Length
     (Tree : Prj.Project_Tree_Ref; List : Prj.String_List_Id) return Natural;
   --  Return the number of elements in the list

   function Attribute_Value
     (Project      : Project_Type;
      Attribute    : String;
      Index        : String := "";
      Use_Extended : Boolean := False) return Variable_Value;
   --  Internal version of Attribute_Value

   function Has_Attribute
     (Project   : Project_Type;
      Attribute : String;
      Index     : String := "") return Boolean;
   --  Internal version of Has_Attribute

   function Attribute_Indexes
     (Project      : Project_Type;
      Attribute    : String;
      Use_Extended : Boolean := False) return GNAT.Strings.String_List;
   --  Internal version of Attribute_Indexes

   procedure Reset_View (Self : in out Project_Data'Class);
   --  Reset and free the internal data of the project view.

   procedure Compute_Scenario_Variables (Tree : Project_Tree_Data_Access);
   --  Compute (and cache) the whole list of scenario variables for the
   --  project tree.
   --  This also ensures that each external reference actually exists

   procedure Compute_Imported_Projects (Project : Project_Type'Class);
   --  Compute and cache the list of projects imported by Project.
   --  Nothing is done if this is already known.

   function Delete_File_Suffix
     (Filename : GNATCOLL.VFS.Filesystem_String;
      Project  : Project_Type) return Natural;
   --  Return the last index in Filename before the beginning of the file
   --  suffix. Suffixes are searched independently from the language.
   --  If not matching suffix is found in project, the returned value will
   --  simply be Filename'Last.

   procedure Internal_Load
     (Tree              : in out Project_Tree'Class;
      Root_Project_Path : GNATCOLL.VFS.Virtual_File;
      Errors            : Projects.Error_Report;
      Project           : out Project_Node_Id;
      Recompute_View    : Boolean := True);
   --  Internal implementation of load. This doesn't reset the tree at all,
   --  but will properly setup the GNAT project manager so that error messages
   --  are redirected and fatal errors do not kill GPS

   procedure Parse_Source_Files (Self : in out Project_Tree);
   --  Find all the source files for the project, and cache them.
   --  At the same time, check that the gnatls attribute is coherent between
   --  all projects and subprojects, and memorize the sources in the
   --  hash-table.

   function Tree_View
     (P : Project_Type'Class) return Prj.Project_Tree_Ref;
   function Tree_Tree
     (P : Project_Type'Class) return Prj.Tree.Project_Node_Tree_Ref;
   pragma Inline (Tree_View, Tree_Tree);
   --  Access to the project tree

   function Info
     (Tree : Project_Tree_Data_Access;
      File : GNATCOLL.VFS.Virtual_File) return File_Info;
   --  Internal version of Info

   procedure Create_Project_Instances
     (Self : in out Project_Tree'Class; With_View : Boolean);
   function Instance_From_Node
     (Self : Project_Tree'Class;
      Node : Project_Node_Id) return Project_Type;
   --  Create all instances of Project_Type for the loaded projects.
   --  This also resets the internal data for the view.

   function Handle_Subdir
     (Project : Project_Type;
      Id      : Namet.Path_Name_Type;
      Xref_Dirs : Boolean) return Filesystem_String;
   --  Adds the object subdirectory to Id if one is defined.

   -----------
   -- Lists --
   -----------

   type String_List_Iterator is record
      Current : Project_Node_Id;
      --  pointer to N_Literal_String or N_Expression
   end record;

   function Done (Iter : String_List_Iterator) return Boolean;
   --  Return True if Iter is past the end of the list of strings

   function Next
     (Tree : Prj.Tree.Project_Node_Tree_Ref;
      Iter : String_List_Iterator) return String_List_Iterator;
   --  Return the next item in the list

   function Data
     (Tree : Prj.Tree.Project_Node_Tree_Ref;
      Iter : String_List_Iterator) return Namet.Name_Id;
   --  Return the value pointed to by Iter.
   --  This could be either a N_String_Literal or a N_Expression node in the
   --  first case.
   --  The second case only works if Iter points to N_String_Literal.

   function Value_Of
     (Tree : Project_Node_Tree_Ref;
      Var  : Scenario_Variable) return String_List_Iterator;
   --  Return an iterator over the possible values of the variable

   ------------
   -- Errors --
   ------------

   generic
      Tree : Project_Tree'Class;
   procedure Mark_Project_Error (Project : Project_Id; Is_Warning : Boolean);
   --  Handler called when the project parser finds an error.
   --  Mark_Project_Incomplete should be true if any error should prevent the
   --  edition of project properties graphically.

   ------------------------
   -- Mark_Project_Error --
   ------------------------

   procedure Mark_Project_Error (Project : Project_Id; Is_Warning : Boolean) is
      P : Project_Type;
   begin
      if not Is_Warning then
         if Project = Prj.No_Project then
            if Tree.Root_Project /= No_Project then
               declare
                  Iter : Project_Iterator := Start (Tree.Root_Project);
               begin
                  while Current (Iter) /= No_Project loop
                     Current (Iter).Data.View_Is_Complete := False;
                     Next (Iter);
                  end loop;
               end;
            end if;

         else
            P := Project_Type (Project_From_Name (Tree.Data, Project.Name));
            P.Data.View_Is_Complete := False;
         end if;
      end if;
   end Mark_Project_Error;

   ---------------
   -- Tree_View --
   ---------------

   function Tree_View (P : Project_Type'Class) return Prj.Project_Tree_Ref is
   begin
      return P.Data.Tree.View;
   end Tree_View;

   ---------------
   -- Tree_Tree --
   ---------------

   function Tree_Tree
     (P : Project_Type'Class) return Prj.Tree.Project_Node_Tree_Ref
   is
   begin
      return P.Data.Tree.Tree;
   end Tree_Tree;

   ---------------------
   -- String_Elements --
   ---------------------

   function String_Elements
     (Data : Project_Tree_Data_Access)
      return Prj.String_Element_Table.Table_Ptr is
   begin
      return Data.View.String_Elements.Table;
   end String_Elements;

   ------------
   -- Length --
   ------------

   function Length
     (Tree : Prj.Project_Tree_Ref; List : Prj.String_List_Id) return Natural
   is
      L     : String_List_Id := List;
      Count : Natural        := 0;
   begin
      while L /= Nil_String loop
         Count := Count + 1;
         L := Tree.String_Elements.Table (L).Next;
      end loop;
      return Count;
   end Length;

   ----------------
   -- Get_String --
   ----------------

   function Get_String (Id : Namet.File_Name_Type) return String is
   begin
      if Id = Namet.No_File then
         return "";
      end if;

      return Get_Name_String (Id);
   exception
      when E : others =>
         Trace (Exception_Handle, E);
         return "";
   end Get_String;

   function Get_String (Id : Namet.Path_Name_Type) return String is
   begin
      if Id = Namet.No_Path then
         return "";
      end if;

      return Get_Name_String (Id);

   exception
      when E : others =>
         Trace (Exception_Handle, E);
         return "";
   end Get_String;

   ----------
   -- Name --
   ----------

   function Name (Project : Project_Type) return String is
   begin
      if Project.Data = null then
         return "default";

      elsif Get_View (Project) /= Prj.No_Project then
         return Get_String (Get_View (Project).Display_Name);

      else
         return Get_String
           (Prj.Tree.Name_Of (Project.Data.Node, Project.Tree_Tree));
      end if;
   end Name;

   ------------------
   -- Project_Path --
   ------------------

   function Project_Path
     (Project : Project_Type;
      Host    : String := Local_Host) return GNATCOLL.VFS.Virtual_File
   is
      View : constant Prj.Project_Id := Get_View (Project);
   begin
      if Project.Data.Node = Empty_Node then
         return GNATCOLL.VFS.No_File;

      elsif View = Prj.No_Project then
         --  View=Prj.No_Project case needed for the project wizard

         return To_Remote
           (Create (+Get_String (Path_Name_Of
            (Project.Data.Node, Project.Tree_Tree))),
            Host);

      else
         return To_Remote
           (Create (+Get_String (View.Path.Display_Name)), Host);
      end if;
   end Project_Path;

   -----------------
   -- Source_Dirs --
   -----------------

   function Source_Dirs
     (Project   : Project_Type;
      Recursive : Boolean := False) return GNATCOLL.VFS.File_Array
   is
      Current_Dir : constant Filesystem_String := Get_Current_Dir;
      Iter        : Project_Iterator := Start (Project, Recursive);
      Count       : Natural := 0;
      P           : Project_Type;
      View        : Project_Id;
      Src         : String_List_Id;
   begin
      loop
         P := Current (Iter);
         exit when P = No_Project;

         View := Get_View (P);
         exit when View = Prj.No_Project;

         Count := Count + Length (Project.Tree_View, View.Source_Dirs);
         Next (Iter);
      end loop;

      declare
         Sources : File_Array (1 .. Count);
         Index   : Natural := Sources'First;
      begin
         Iter := Start (Project, Recursive);

         loop
            P := Current (Iter);
            exit when P = No_Project;

            View := Get_View (P);
            exit when View = Prj.No_Project;

            Src := View.Source_Dirs;

            while Src /= Nil_String loop
               Sources (Index) := Create
                 (Normalize_Pathname
                    (+Get_String
                       (String_Elements (P.Data.Tree) (Src).Display_Value),
                     Current_Dir,
                     Resolve_Links => False));
               Ensure_Directory (Sources (Index));
               Index := Index + 1;
               Src   := String_Elements (P.Data.Tree) (Src).Next;
            end loop;

            Next (Iter);
         end loop;

         return Sources (1 .. Index - 1);
      end;
   end Source_Dirs;

   -------------------
   -- Handle_Subdir --
   -------------------

   function Handle_Subdir
     (Project   : Project_Type;
      Id        : Namet.Path_Name_Type;
      Xref_Dirs : Boolean) return Filesystem_String
   is
      View : constant Project_Id := Get_View (Project);
      Env  : constant Project_Environment_Access := Project.Data.Tree.Env;
      Path : constant Filesystem_String :=
        Name_As_Directory (+Get_String (Id));
   begin
      if not Xref_Dirs or else Xrefs_Subdir (Env.all)'Length = 0 then
         return Path;
      elsif View.Externally_Built then
         return Path;
      elsif Prj.Subdirs /= null then
         return Name_As_Directory
           (Path (Path'First .. Path'Last - Prj.Subdirs.all'Length - 1) &
            Xrefs_Subdir (Env.all));
      else
         return Name_As_Directory (Xrefs_Subdir (Env.all));
      end if;
   end Handle_Subdir;

   ----------------
   -- Object_Dir --
   ----------------

   function Object_Dir
     (Project : Project_Type) return GNATCOLL.VFS.Virtual_File
   is
      View : constant Project_Id := Get_View (Project);
   begin
      if View.Object_Directory /= No_Path_Information then
         return
           Create
             (Handle_Subdir
                  (Project, View.Object_Directory.Display_Name, False));
      else
         return GNATCOLL.VFS.No_File;
      end if;
   end Object_Dir;

   -----------------
   -- Object_Path --
   -----------------

   function Object_Path
     (Project             : Project_Type;
      Recursive           : Boolean := False;
      Including_Libraries : Boolean := False;
      Xrefs_Dirs          : Boolean := False) return File_Array
   is
      View : constant Project_Id := Get_View (Project);

   begin
      if View = Prj.No_Project then
         return (1 .. 0 => <>);

      elsif Recursive then
         return From_Path
           (+Prj.Env.Ada_Objects_Path (View, Including_Libraries).all);

      elsif Including_Libraries
        and then View.Library
        and then View.Library_ALI_Dir /= No_Path_Information
      then
         if View.Object_Directory = No_Path_Information then
            return (1 => Create (Handle_Subdir (Project,
                                                View.Library_ALI_Dir.Name,
                                                Xrefs_Dirs)));
         else
            return
              (Create (Handle_Subdir
                         (Project, View.Object_Directory.Display_Name,
                          Xrefs_Dirs)),
               Create (Handle_Subdir
                         (Project, View.Library_ALI_Dir.Name,
                          Xrefs_Dirs)));
         end if;

      elsif View.Object_Directory /= No_Path_Information then
         return
           (1 => Create (Handle_Subdir
                           (Project, View.Object_Directory.Display_Name,
                            Xrefs_Dirs)));
      else
         return (1 .. 0 => <>);
      end if;
   end Object_Path;

   --------------------------
   -- Direct_Sources_Count --
   --------------------------

   function Direct_Sources_Count (Project : Project_Type) return Natural is
   begin
      --  ??? Should directly use the size of Source_Files, since this is now
      --  precomputed when the project is loaded
      if Get_View (Project) = Prj.No_Project then
         return 0;

      else
         return Project.Data.Files'Length;
      end if;
   end Direct_Sources_Count;

   ------------
   -- Create --
   ------------

   function Create
     (Self            : Project_Tree;
      Name            : Filesystem_String;
      Project         : Project_Type'Class := No_Project;
      Use_Source_Path : Boolean := True;
      Use_Object_Path : Boolean := True) return GNATCOLL.VFS.Virtual_File
   is
      Base          : constant Filesystem_String := Base_Name (Name);
      Project2      : Project_Type;
      Path          : Virtual_File := GNATCOLL.VFS.No_File;
      Iterator      : Project_Iterator;
      Info_Cursor   : Names_Files.Cursor;
      Info          : Source_File_Data;
      In_Predefined : Boolean := False;

   begin
      if Self.Data = null then
         --  No view computed, we do not even know the source dirs
         return GNATCOLL.VFS.No_File;
      end if;

      if Is_Absolute_Path (Name) then
         return Create (Normalize_Pathname (Name, Resolve_Links => False));
      end if;

      --  Is the file already in the cache ?
      --  This cache is automatically filled initially when the project is
      --  loaded, so we know that all source files of the project are in the
      --  cache and will be returned efficiently

      if Project.Data = null then
         Info_Cursor := Self.Data.Sources.Find (Base);

         if Has_Element (Info_Cursor) then
            return Element (Info_Cursor).File;
         end if;
      end if;

      --  When looking for a project file, check among those that are loaded.
      --  This means we might be looking outside of the source and obj dirs.

      if Equal (File_Extension (Name), Project_File_Extension) then
         Iterator := Self.Root_Project.Start;
         loop
            Project2 := Current (Iterator);
            exit when Project2 = No_Project;

            if Case_Insensitive_Equal
              (Project2.Name & (+Project_File_Extension), +Base)
            then
               return Project2.Project_Path;
            end if;

            Next (Iterator);
         end loop;
      end if;

      --  We have to search in one or more projects

      if Project.Data /= null then
         Iterator := Project.Start (Recursive => False);
      else
         Iterator := Self.Root_Project.Start (Recursive => True);
      end if;

      while Path = GNATCOLL.VFS.No_File loop
         Project2 := Current (Iterator);
         exit when Project2 = No_Project;

         if Use_Source_Path then
            Path := Locate_Regular_File
              (Name, Project2.Source_Dirs (Recursive => False));
         end if;

         if Use_Object_Path and then Path = GNATCOLL.VFS.No_File then
            Path := Locate_Regular_File
              (Name, Project2.Object_Path
                 (Recursive => False, Including_Libraries => True));
         end if;

         Next (Iterator);
      end loop;

      --  Only search in the predefined directories if the user did not
      --  specify an explicit project

      if Path = GNATCOLL.VFS.No_File and then Project.Data = null then
         if Use_Source_Path then
            Path := Locate_Regular_File
              (Name, Self.Data.Env.Predefined_Source_Path.all);
         end if;

         if Use_Object_Path and then Path = GNATCOLL.VFS.No_File then
            Path := Locate_Regular_File
              (Name, Self.Data.Env.Predefined_Object_Path.all);
         end if;

         In_Predefined := Path /= GNATCOLL.VFS.No_File;
      end if;

      --  If still not found, search in the current directory

      if Path = GNATCOLL.VFS.No_File then
         Path := Locate_Regular_File (Name, (1 => Get_Current_Dir));
      end if;

      --  If found, cache the result for future usage.
      --  We do not cache anything if the project was forced, however
      --  since this wouldn't work with extended projects were sources
      --  can be duplicated.
      --  Do not cache either files found in the current directory, since that
      --  could change.
      --
      --  ??? There is a potential issue if for instance we found the file in
      --  a source dir but the next call specifies Use_Source_Path=>False. But
      --  that's an unlikely scenario because the user knows where to expect a
      --  file in general.

      if Path /= GNATCOLL.VFS.No_File
        and then Project.Data = null
        and then (Project2 /= No_Project   --  found in a specific project
                  or else In_Predefined)   --  or in the runtime
      then
         --  Language and Source are always unknown: if we had a source file,
         --  it would have been set in the cache while loading the project.
         --  However, for runtime files we do compute the language since these
         --  are likely to be source files

         Info := Source_File_Data'
           (Project => Project2,
            File    => Path,
            Lang    => No_Name,
            Source  => null);

         if In_Predefined then
            Info.Lang := Get_String (Language (Self.Info (Path)));
         end if;

         Self.Data.Sources.Include (Base, Info);
      end if;

      return Path;
   end Create;

   ------------------
   -- Source_Files --
   ------------------

   function Source_Files
     (Project   : Project_Type;
      Recursive : Boolean := False) return GNATCOLL.VFS.File_Array_Access
   is
      Count   : Natural;
      Index   : Natural := 1;
      P       : Project_Type;
      Sources : File_Array_Access;
      Ret     : File_Array_Access;

   begin
      if not Recursive then
         if Project.Data.Files = null then
            return new File_Array (1 .. 0);
         else
            return new File_Array'(Project.Data.Files.all);
         end if;
      end if;

      declare
         Iter : Project_Iterator := Start (Project, Recursive);
      begin
         Count := 0;

         --  Count files

         loop
            P := Current (Iter);
            exit when P = No_Project;

            --  Files may be null in case of a parse error

            if P.Data.Files /= null then
               Count := Count + P.Data.Files'Length;
            end if;

            Next (Iter);
         end loop;

         Sources := new File_Array (1 .. Count);
         Iter    := Start (Project, Recursive);

         --  Now add files to the Sources array

         loop
            P := Current (Iter);
            exit when P = No_Project;

            if P.Data.Files /= null then
               for S in P.Data.Files'Range loop
                  Sources (Index) := P.Data.Files (S);
                  Index := Index + 1;
               end loop;
            end if;

            Next (Iter);
         end loop;

         Ret := new File_Array'(Sources (Sources'First .. Index - 1));
         Unchecked_Free (Sources);
         return Ret;
      end;
   end Source_Files;

   ---------------
   -- Unit_Part --
   ---------------

   function Unit_Part (Info : File_Info'Class) return Unit_Parts is
   begin
      return Info.Part;
   end Unit_Part;

   ---------------
   -- Unit_Name --
   ---------------

   function Unit_Name (Info : File_Info'Class) return String is
   begin
      if Info.Name = No_Name then
         return "";
      else
         return Get_String (Info.Name);
      end if;
   end Unit_Name;

   --------------
   -- Language --
   --------------

   function Language (Info : File_Info'Class) return String is
   begin
      if Info.Lang = No_Name then
         return "";
      else
         return Get_String (Info.Lang);
      end if;
   end Language;

   -------------
   -- Project --
   -------------

   function Project
     (Info              : File_Info'Class;
      Root_If_Not_Found : Boolean := False) return Project_Type
   is
   begin
      if Root_If_Not_Found and then Info.Project = No_Project then
         return Info.Root_Project;
      else
         return Info.Project;
      end if;
   end Project;

   ----------
   -- Info --
   ----------

   function Info
     (Tree : Project_Tree_Data_Access;
      File : GNATCOLL.VFS.Virtual_File) return File_Info
   is
      Part : Unit_Parts;
      Id   : Source_Id;
      Full : String := String
        (File.Full_Name
           (Normalize     => True,
            Resolve_Links => Opt.Follow_Links_For_Files).all);
      Path : Path_Name_Type;
      Lang : Name_Id;

   begin
      --  Lookup in the project's Source_Paths_HT, rather than in
      --  Registry.Data.Sources, since the latter does not support duplicate
      --  base names. In Prj.Nmsc, names have been converted to lower case on
      --  case-insensitive file systems, so we need to do the same here.
      --  (Insertion is done in Check_File, where the Path passed in parameter
      --  comes from a call to Normalize_Pathname with the following args:
      --      Resolve_Links  => Opt.Follow_Links_For_Files
      --      Case_Sensitive => True
      --  So we use the normalized name in the above call to Full_Name for
      --  full compatibility between GPS and the project manager

      Osint.Canonical_Case_File_Name (Full);
      Path := Path_Name_Type (Name_Id'(Get_String (Full)));
      Id := Source_Paths_Htable.Get (Tree.View.Source_Paths_HT, Path);

      if Id /= No_Source then
         case Id.Kind is
            when Spec => Part := Unit_Spec;
            when Impl => Part := Unit_Body;
            when Sep  => Part := Unit_Separate;
         end case;

         if Id.Unit /= null then
            return File_Info'
              (Project      => Project_Type
                 (Project_From_Name (Tree, Id.Project.Name)),
               Root_Project => Tree.Root,
               Part         => Part,
               Name         => Id.Unit.Name,
               Lang         => Id.Language.Name);
         else
            return File_Info'
              (Project      => Project_Type
                 (Project_From_Name (Tree, Id.Project.Name)),
               Root_Project => Tree.Root,
               Part         => Part,
               Name         => No_Name,
               Lang         => Id.Language.Name);
         end if;
      end if;

      --  Either the file was not cached, or there is no Source info. In both
      --  cases, that means the file is not a source file (although it might be
      --  a predefined source file), so we just use the default naming scheme.

      declare
         Ext    : constant Filesystem_String :=
           File.File_Extension (Normalize => True);
         Cursor : Extensions_Languages.Cursor;
         NS     : Naming_Scheme_Access;
      begin
         if Ext = ".ads" then
            --  Do not compute the unit names, which requires parsing the file
            --  or the ALI file, since the GNAT runtime uses krunched names
            return File_Info'
              (Project      => No_Project,
               Root_Project => Tree.Root,
               Part         => Unit_Spec,
               Name         => Namet.No_Name,
               Lang         => Name_Ada);

         elsif Ext = ".adb" then
            return File_Info'
              (Project      => No_Project,
               Root_Project => Tree.Root,
               Part         => Unit_Body,
               Name         => Namet.No_Name,
               Lang         => Name_Ada);
         end if;

         --  Try and guess the language from the registered extensions

         if Ext = "" then
            --  This is a file without extension like Makefile or
            --  ChangeLog for example. Use the filename to get the proper
            --  language for this file.

            Cursor := Tree.Env.Extensions.Find (Base_Name (Full));

         else
            Cursor := Tree.Env.Extensions.Find (+Ext);
         end if;

         if Has_Element (Cursor) then
            Lang := Extensions_Languages.Element (Cursor);
         else
            Lang := Namet.No_Name;
            NS := Tree.Env.Naming_Schemes;
            while NS /= null loop
               if +Ext = NS.Default_Spec_Suffix.all
                 or else +Ext = NS.Default_Body_Suffix.all
               then
                  Lang := Get_String (NS.Language.all);
                  exit;
               end if;

               NS := NS.Next;
            end loop;
         end if;
      end;

      return
        (No_Project, Tree.Root, Unit_Separate, Namet.No_Name, Lang => Lang);
   end Info;

   ----------
   -- Info --
   ----------

   function Info
     (Self : Project_Tree'Class; File : GNATCOLL.VFS.Virtual_File)
      return File_Info is
   begin
      return Info (Self.Data, File);
   end Info;

   --------------------
   -- Substitute_Dot --
   --------------------

   function Substitute_Dot
     (Unit_Name       : String;
      Dot_Replacement : String) return String
   is
      Dot_Count : Natural := 0;
   begin
      for U in Unit_Name'Range loop
         if Unit_Name (U) = '.' then
            Dot_Count := Dot_Count + 1;
         end if;
      end loop;

      declare
         Uname : String
           (1 .. Unit_Name'Length + Dot_Count * (Dot_Replacement'Length - 1));
         Index : Natural := Uname'First;
      begin
         for U in Unit_Name'Range loop
            if Unit_Name (U) = '.' then
               Uname (Index .. Index + Dot_Replacement'Length - 1) :=
                 Dot_Replacement;
               Index := Index + Dot_Replacement'Length;
            else
               Uname (Index) := Unit_Name (U);
               Index := Index + 1;
            end if;
         end loop;
         return Uname;
      end;
   end Substitute_Dot;

   --------------------
   -- File_From_Unit --
   --------------------

   function File_From_Unit
     (Project                  : Project_Type;
      Unit_Name                : String;
      Part                     : Unit_Parts;
      Language                 : String;
      Check_Predefined_Library : Boolean := False;
      File_Must_Exist          : Boolean := True) return Filesystem_String
   is
      function Has_Predefined_Prefix (S : String) return Boolean;
      --  Return True is S has a name that starts like a predefined unit
      --  (e.g. a.b, which should be replaced by a~b)

      ---------------------------
      -- Has_Predefined_Prefix --
      ---------------------------

      function Has_Predefined_Prefix (S : String) return Boolean is
         C : constant Character := S (S'First);
      begin
         return S (S'First + 1) = '-'
           and then (C = 'a' or else C = 'g' or else C = 'i' or else C = 's');
      end Has_Predefined_Prefix;

      Unit    : Name_Id;
      UIndex  : Unit_Index;
      Lang    : Language_Ptr;
   begin
      --  Standard GNAT naming scheme
      --  ??? This isn't language independent, what if other languages have
      --  similar requirements. Should use configuration files as gprbuild does

      if Project = No_Project
        or else (Check_Predefined_Library
                 and then Case_Insensitive_Equal (Language, "ada"))
      then
         case Part is
            when Unit_Body =>
               return +Substitute_Dot (Unit_Name, "-") & ".adb";
            when Unit_Spec =>
               return +Substitute_Dot (Unit_Name, "-") & ".ads";
            when others =>
               Assert (Me, False, "Unexpected Unit_Part");
               return "";
         end case;

      --  The project naming scheme
      else
         Name_Len := Unit_Name'Length;
         Name_Buffer (1 .. Name_Len) := Unit_Name;
         Unit := Name_Find;

         --  Take advantage of computation done by the project manager when we
         --  looked for source files

         UIndex := Units_Htable.Get (Project.Tree_View.Units_HT, Unit);
         if UIndex /= No_Unit_Index then
            case Part is
               when Unit_Body | Unit_Separate =>
                  if UIndex.File_Names (Impl) /= null then
                     return +Get_String (UIndex.File_Names (Impl).File);
                  end if;

               when Unit_Spec =>
                  if UIndex.File_Names (Spec) /= null then
                     return +Get_String (UIndex.File_Names (Spec).File);
                  end if;
            end case;
         end if;

         --  The unit does not exist yet. Perhaps we are creating a new file
         --  and trying to guess the correct file name

         if File_Must_Exist then
            return "";
         end if;

         --  We can only perform guesses if the language is a valid for the
         --  project.

         Lang := Get_Language_From_Name (Get_View (Project), Language);

         if Lang = null then
            return "";
         end if;

         declare
            Dot_Replacement : constant String := Get_String
              (Name_Id (Lang.Config.Naming_Data.Dot_Replacement));
            Uname           : String := Substitute_Dot
              (Unit_Name, Dot_Replacement);

         begin
            case Lang.Config.Naming_Data.Casing is
               when All_Lower_Case => To_Lower (Uname);
               when All_Upper_Case => To_Upper (Uname);
               when others => null;
            end case;

            --  Handle properly special naming such as a.b -> a~b

            if Case_Insensitive_Equal (Language, "ada")
              and then Uname'Length > 2
              and then Has_Predefined_Prefix (Uname)
            then
               Uname (Uname'First + 1) := '~';
            end if;

            case Part is
               when Unit_Body =>
                  return +(Uname
                           & Get_Name_String
                             (Name_Id (Lang.Config.Naming_Data.Body_Suffix)));

               when Unit_Spec =>
                  return +(Uname
                           & Get_Name_String
                             (Name_Id (Lang.Config.Naming_Data.Spec_Suffix)));

               when others =>
                  return "";
            end case;
         end;
      end if;
   end File_From_Unit;

   ----------------
   -- Other_File --
   ----------------

   function Other_File
     (Self : Project_Tree;
      File : GNATCOLL.VFS.Virtual_File) return GNATCOLL.VFS.Virtual_File
   is
      Info : constant File_Info := Self.Info (File);
      Part : Unit_Parts;
   begin
      case Info.Part is
         when Unit_Spec                 => Part := Unit_Body;
         when Unit_Body | Unit_Separate => Part := Unit_Spec;
      end case;

      declare
         Base : constant Filesystem_String := File_From_Unit
           (Project (Info), Unit_Name (Info), Part,
            Language => Info.Language);
      begin
         if Base'Length > 0 then
            return Self.Create (Base, Use_Object_Path => False);

         elsif Case_Insensitive_Equal (Info.Language, "ada") then
            --  Default to the GNAT naming scheme (for runtime files)
            declare
               Base2 : constant Filesystem_String := File_From_Unit
                 (Project (Info), Unit_Name (Info), Part,
                  Check_Predefined_Library => True,
                  Language => Info.Language);
            begin
               if Base2'Length > 0 then
                  return Self.Create (Base2, Use_Object_Path => False);
               end if;
            end;
         end if;

         return File;
      end;
   end Other_File;

   ---------------------
   -- Attribute_Value --
   ---------------------

   function Attribute_Value
     (Project      : Project_Type;
      Attribute    : String;
      Index        : String := "";
      Use_Extended : Boolean := False) return Variable_Value
   is
      Sep            : constant Natural :=
        Ada.Strings.Fixed.Index (Attribute, "#");
      Attribute_Name : constant String :=
                         String (Attribute (Sep + 1 .. Attribute'Last));
      Pkg_Name       : constant String :=
                         String (Attribute (Attribute'First .. Sep - 1));
      Project_View   : constant Project_Id := Get_View (Project);
      Pkg            : Package_Id := No_Package;
      Value          : Variable_Value := Nil_Variable_Value;
      Var            : Variable_Id;
      Arr            : Array_Id;
      Elem           : Array_Element_Id;
      N              : Name_Id;
   begin
      if Project_View = Prj.No_Project then
         return Nil_Variable_Value;
      end if;

      if Pkg_Name /= "" then
         Pkg := Value_Of
           (Get_String (Pkg_Name),
            In_Packages => Project_View.Decl.Packages,
            In_Tree     => Project.Tree_View);

         if Pkg = No_Package then
            if Use_Extended
              and then Extended_Project (Project) /= No_Project
            then
               return Attribute_Value
                 (Extended_Project (Project), Attribute, Index, Use_Extended);
            else
               return Nil_Variable_Value;
            end if;
         end if;

         Var := Project.Tree_View.Packages.Table (Pkg).Decl.Attributes;
         Arr := Project.Tree_View.Packages.Table (Pkg).Decl.Arrays;

      else
         Var := Project_View.Decl.Attributes;
         Arr := Project_View.Decl.Arrays;
      end if;

      N := Get_String (Attribute_Name);

      if Index /= "" then
         Elem := Value_Of
           (N, In_Arrays => Arr, In_Tree => Project.Tree_View);
         if Elem /= No_Array_Element then
            Value := Value_Of (Index => Get_String (Index), In_Array => Elem,
                               In_Tree => Project.Tree_View);
         end if;
      else
         Value := Value_Of (N, Var, In_Tree => Project.Tree_View);
      end if;

      if Value = Nil_Variable_Value
        and then Use_Extended
        and then Extended_Project (Project) /= No_Project
      then
         return Attribute_Value
           (Extended_Project (Project), Attribute, Index, Use_Extended);
      else
         return Value;
      end if;
   end Attribute_Value;

   ---------------------
   -- Attribute_Value --
   ---------------------

   function Attribute_Value
     (Project      : Project_Type;
      Attribute    : Attribute_Pkg_String;
      Default      : String := "";
      Index        : String := "";
      Use_Extended : Boolean := False) return String
   is
      View  : constant Project_Id := Get_View (Project);
      Value : Variable_Value;
      Lang  : Language_Ptr;
      Unit  : Unit_Index;
   begin
      if Project = No_Project or else View = Prj.No_Project then
         return Default;
      end if;

      --  Special case for the naming scheme, since we need to get access to
      --  the default registered values for foreign languages

      if Attribute = Spec_Suffix_Attribute
        or else Attribute = Specification_Suffix_Attribute
      then
         Lang := Get_Language_From_Name (View, Index);
         if Lang /= null then
            return Get_String (Lang.Config.Naming_Data.Spec_Suffix);
         else
            return "";
         end if;

      elsif Attribute = Impl_Suffix_Attribute
        or else Attribute = Implementation_Suffix_Attribute
      then
         Lang := Get_Language_From_Name (View, Index);
         if Lang /= null then
            return Get_String (Lang.Config.Naming_Data.Body_Suffix);
         else
            return "";
         end if;

      elsif Attribute = Separate_Suffix_Attribute then
         Lang := Get_Language_From_Name (View, "ada");
         if Lang /= null then
            return Get_String (Lang.Config.Naming_Data.Separate_Suffix);
         else
            return "";
         end if;

      elsif Attribute = Casing_Attribute then
         Lang := Get_Language_From_Name (View, "ada");
         if Lang /= null then
            return Prj.Image (Lang.Config.Naming_Data.Casing);
         else
            return "";
         end if;

      elsif Attribute = Dot_Replacement_Attribute then
         Lang := Get_Language_From_Name (View, "ada");
         if Lang /= null then
            return Get_String (Lang.Config.Naming_Data.Dot_Replacement);
         else
            return "";
         end if;

      elsif Attribute = Old_Implementation_Attribute
        or else Attribute = Implementation_Attribute
      then
         --  Index is a unit name
         Unit := Units_Htable.Get
           (Project.Tree_View.Units_HT,
            Get_String (Index));
         if Unit /= No_Unit_Index
           and then Unit.File_Names (Impl) /= null
         then
            return Get_String (Unit.File_Names (Impl).Display_File);
         else
            return "";
         end if;

      elsif Attribute = Old_Specification_Attribute
        or else Attribute = Specification_Attribute
      then
         --  Index is a unit name
         Unit := Units_Htable.Get
           (Project.Tree_View.Units_HT, Get_String (Index));
         if Unit /= No_Unit_Index
           and then Unit.File_Names (Spec) /= null
         then
            return Get_String (Unit.File_Names (Spec).Display_File);
         else
            return "";
         end if;

      else
         Value := Attribute_Value
           (Project, String (Attribute), Index, Use_Extended);
      end if;

      case Value.Kind is
         when Undefined => return Default;
         when Single    => return Value_Of (Value, Default);
         when List      =>
            Trace (Me, "Attribute " & String (Attribute)
                   & " is not a single string");
            return Default;
      end case;
   end Attribute_Value;

   ---------------------
   -- Attribute_Value --
   ---------------------

   function Attribute_Value
     (Project      : Project_Type;
      Attribute    : Attribute_Pkg_List;
      Index        : String := "";
      Use_Extended : Boolean := False) return GNAT.Strings.String_List_Access
   is
      Value : constant Variable_Value := Attribute_Value
        (Project, String (Attribute), Index, Use_Extended);
      V     : String_List_Id;
      S     : String_List_Access;
   begin
      case Value.Kind is
         when Undefined =>
            return null;

         when Single =>
            --  ??? Should we really convert to a list
            return new String_List'
              (1 .. 1 => new String'(Get_Name_String (Value.Value)));

         when List =>
            S := new String_List
              (1 .. Length (Project.Tree_View, Value.Values));
            V := Value.Values;

            for J in S'Range loop
               Get_Name_String
                 (Project.Tree_View.String_Elements.Table (V).Value);
               S (J) := new String'(Name_Buffer (1 .. Name_Len));
               V := Project.Tree_View.String_Elements.Table (V).Next;
            end loop;
            return S;

      end case;
   end Attribute_Value;

   -------------------
   -- Has_Attribute --
   -------------------

   function Has_Attribute
     (Project   : Project_Type;
      Attribute : String;
      Index     : String := "") return Boolean
   is
      Sep            : constant Natural :=
        Ada.Strings.Fixed.Index (Attribute, "#");
      Attribute_Name : constant String :=
                         String (Attribute (Sep + 1 .. Attribute'Last));
      Pkg_Name       : constant String :=
                         String (Attribute (Attribute'First .. Sep - 1));
      Project_View   : constant Project_Id := Get_View (Project);
      Pkg            : Package_Id := No_Package;
      Var            : Variable_Id;
      Arr            : Array_Id;
      N              : Name_Id;
   begin
      if Project_View = Prj.No_Project then
         return False;
      end if;

      if Pkg_Name /= "" then
         Pkg := Value_Of
           (Get_String (Pkg_Name),
            In_Packages => Project_View.Decl.Packages,
            In_Tree     => Project.Tree_View);

         if Pkg = No_Package then
            return False;
         end if;

         Var := Project.Tree_View.Packages.Table (Pkg).Decl.Attributes;
         Arr := Project.Tree_View.Packages.Table (Pkg).Decl.Arrays;

      else
         Var := Project_View.Decl.Attributes;
         Arr := Project_View.Decl.Arrays;
      end if;

      N := Get_String (Attribute_Name);

      if Index /= "" then
         --  ??? That seems incorrect, we are not testing for the specific
         --  index
         return Value_Of (N, In_Arrays => Arr,
                          In_Tree => Project.Tree_View)
           /= No_Array_Element;
      else
         return not Value_Of (N, Var, Project.Tree_View).Default;
      end if;
   end Has_Attribute;

   function Has_Attribute
     (Project   : Project_Type;
      Attribute : Attribute_Pkg_String;
      Index     : String := "") return Boolean is
   begin
      return Has_Attribute (Project, String (Attribute), Index);
   end Has_Attribute;

   function Has_Attribute
     (Project   : Project_Type;
      Attribute : Attribute_Pkg_List;
      Index     : String := "") return Boolean is
   begin
      return Has_Attribute (Project, String (Attribute), Index);
   end Has_Attribute;

   -----------------------
   -- Attribute_Indexes --
   -----------------------

   function Attribute_Indexes
     (Project      : Project_Type;
      Attribute    : String;
      Use_Extended : Boolean := False) return GNAT.Strings.String_List
   is
      Sep            : constant Natural :=
        Ada.Strings.Fixed.Index (Attribute, "#");
      Attribute_Name : constant String :=
                         String (Attribute (Sep + 1 .. Attribute'Last));
      Pkg_Name       : constant String :=
                         String (Attribute (Attribute'First .. Sep - 1));
      Project_View   : constant Project_Id := Get_View (Project);
      Packages       : Prj.Package_Table.Table_Ptr;
      Array_Elements : Prj.Array_Element_Table.Table_Ptr;
      Pkg            : Package_Id := No_Package;
      Arr            : Array_Id;
      Elem, Elem2    : Array_Element_Id;
      N              : Name_Id;
      Count          : Natural := 0;

   begin
      if Project_View = Prj.No_Project then
         return (1 .. 0 => null);
      end if;

      Packages       := Project.Data.Tree.View.Packages.Table;
      Array_Elements := Project.Data.Tree.View.Array_Elements.Table;

      if Pkg_Name /= "" then
         Pkg := Value_Of
           (Get_String (Pkg_Name),
            In_Packages => Project_View.Decl.Packages,
            In_Tree     => Project.Data.Tree.View);

         if Pkg = No_Package then
            if Use_Extended
              and then Extended_Project (Project) /= No_Project
            then
               return Attribute_Indexes
                 (Extended_Project (Project), Attribute, Use_Extended);
            else
               return (1 .. 0 => null);
            end if;
         end if;

         Arr := Packages (Pkg).Decl.Arrays;

      else
         Arr := Project_View.Decl.Arrays;
      end if;

      N := Get_String (Attribute_Name);
      Elem := Value_Of (N,
                        In_Arrays => Arr,
                        In_Tree   => Project.Data.Tree.View);
      if Elem = No_Array_Element
        and then Use_Extended
        and then Extended_Project (Project) /= No_Project
      then
         return Attribute_Indexes
           (Extended_Project (Project), Attribute, Use_Extended);
      end if;

      Elem2 := Elem;
      while Elem2 /= No_Array_Element loop
         Count := Count + 1;
         Elem2 := Array_Elements (Elem2).Next;
      end loop;

      declare
         Result : String_List (1 .. Count);
      begin
         Count := Result'First;

         while Elem /= No_Array_Element loop
            Result (Count) := new String'
              (Get_String (Array_Elements (Elem).Index));
            Count := Count + 1;
            Elem := Array_Elements (Elem).Next;
         end loop;

         return Result;
      end;
   end Attribute_Indexes;

   function Attribute_Indexes
     (Project      : Project_Type;
      Attribute    : Attribute_Pkg_String;
      Use_Extended : Boolean := False) return GNAT.Strings.String_List is
   begin
      return Attribute_Indexes (Project, String (Attribute), Use_Extended);
   end Attribute_Indexes;

   function Attribute_Indexes
     (Project      : Project_Type;
      Attribute    : Attribute_Pkg_List;
      Use_Extended : Boolean := False) return GNAT.Strings.String_List is
   begin
      return Attribute_Indexes (Project, String (Attribute), Use_Extended);
   end Attribute_Indexes;

   ---------------
   -- Languages --
   ---------------

   function Languages
     (Project : Project_Type; Recursive : Boolean := False) return String_List
   is
      Iter          : Project_Iterator := Start (Project, Recursive);
      Num_Languages : Natural := 0;
      Val           : Variable_Value;
      P             : Project_Type;

      procedure Add_Language
        (Lang : in out String_List; Index : in out Natural; Str : String);
      --  Add a new language in the list, if not already there

      ------------------
      -- Add_Language --
      ------------------

      procedure Add_Language
        (Lang : in out String_List; Index : in out Natural; Str : String) is
      begin
         for L in Lang'First .. Index - 1 loop
            if Lang (L).all = Str then
               return;
            end if;
         end loop;

         Lang (Index) := new String'(Str);
         Index := Index + 1;
      end Add_Language;

   begin
      if Get_View (Project) = Prj.No_Project then
         return GNAT.OS_Lib.Argument_List'(1 .. 1 => new String'("ada"));
      end if;

      loop
         P := Current (Iter);
         exit when P = No_Project;

         Val := Attribute_Value (P, String (Languages_Attribute));
         case Val.Kind is
            when Undefined => null;
            when Single    => Num_Languages := Num_Languages + 1;
            when List      =>
               Num_Languages :=
                 Num_Languages + Length (P.Tree_View, Val.Values);
         end case;

         Next (Iter);
      end loop;

      Iter := Start (Project, Recursive);

      declare
         --  If no project defines the language attribute, then they have
         --  Ada as an implicit language. Save space for it.
         Lang  : Argument_List (1 .. Num_Languages + 1);
         Index : Natural := Lang'First;
         Value : String_List_Id;
      begin
         loop
            P := Current (Iter);
            exit when P = No_Project;

            if not P.Has_Attribute (Languages_Attribute) then
               Add_Language (Lang, Index, "ada");

            else
               Val := Attribute_Value (P, String (Languages_Attribute));
               case Val.Kind is
                  when Undefined => null;
                  when Single    =>
                     Add_Language (Lang, Index, Get_Name_String (Val.Value));
                  when List      =>
                     Value := Val.Values;
                     while Value /= Nil_String loop
                        Add_Language
                          (Lang, Index,
                           Get_String
                             (String_Elements (P.Data.Tree)(Value).Value));
                        Value := String_Elements (P.Data.Tree)(Value).Next;
                     end loop;
               end case;
            end if;

            Next (Iter);
         end loop;

         return Lang (Lang'First .. Index - 1);
      end;
   end Languages;

   ------------------
   -- Has_Language --
   ------------------

   function Has_Language
     (Project : Project_Type; Language : String) return Boolean
   is
      Normalized_Lang : constant Name_Id := Get_String (To_Lower (Language));
      P               : constant Project_Id := Get_View (Project);
      Lang            : Language_Ptr;
   begin
      if P /= Prj.No_Project then
         Lang := P.Languages;
         while Lang /= null loop
            if Lang.Name = Normalized_Lang then
               return True;
            end if;

            Lang := Lang.Next;
         end loop;

      end if;
      return False;
   end Has_Language;

   ------------------
   -- Is_Main_File --
   ------------------

   function Is_Main_File
     (Project        : Project_Type;
      File           : GNATCOLL.VFS.Filesystem_String;
      Case_Sensitive : Boolean := True) return Boolean
   is
      Value : String_List_Access := Project.Attribute_Value (Main_Attribute);
   begin
      for V in Value'Range loop
         if Equal (Value (V).all, +File, Case_Sensitive => Case_Sensitive) then
            Free (Value);
            return True;
         end if;
      end loop;

      Free (Value);
      return False;
   end Is_Main_File;

   ---------------------------
   -- Executables_Directory --
   ---------------------------

   function Executables_Directory
     (Project : Project_Type) return Virtual_File
   is
   begin
      if Project = No_Project or else Get_View (Project) = Prj.No_Project then
         return GNATCOLL.VFS.No_File;

      else
         declare
            Exec : constant Filesystem_String := +Get_String
              (Name_Id (Get_View (Project).Exec_Directory.Display_Name));

         begin
            if Exec'Length > 0 then
               return Create (Name_As_Directory (Exec));
            else
               --  ??? Can't we simply access Object_Dir in the view ?

               declare
                  Path : constant File_Array := Project.Object_Path;
               begin
                  if Path'Length /= 0 then
                     return Path (Path'First);
                  else
                     return GNATCOLL.VFS.No_File;
                  end if;
               end;
            end if;
         end;
      end if;
   end Executables_Directory;

   ---------------------------
   -- For_Each_Project_Node --
   ---------------------------

   procedure For_Each_Project_Node
     (Tree     : Project_Node_Tree_Ref;
      Root     : Project_Node_Id;
      Callback : access procedure
        (Tree : Project_Node_Tree_Ref; Node : Project_Node_Id))
   is
      use Project_Sets;
      Seen : Project_Sets.Set;

      procedure Process_Project (Proj : Project_Node_Id);

      procedure Process_Project (Proj : Project_Node_Id) is
         With_Clause : Project_Node_Id := First_With_Clause_Of (Proj, Tree);
         Extended    : Project_Node_Id;
      begin
         if Seen.Find (Proj) = Project_Sets.No_Element then
            Seen.Include (Proj);

            Callback (Tree, Proj);

            while With_Clause /= Empty_Node loop
               --  We have to ignore links back to the root project,
               --  which could only happen with "limited with", since
               --  otherwise the root project would not appear first in
               --  the topological sort, and then Start returns invalid
               --  results at least when its Recursive parameters is set
               --  to False.
               if Project_Node_Of (With_Clause, Tree) /= Root
                 and then not Is_Virtual_Extending
                   (Tree, Project_Node_Of (With_Clause, Tree))
               then
                  Process_Project (Project_Node_Of (With_Clause, Tree));
               end if;
               With_Clause := Next_With_Clause_Of (With_Clause, Tree);
            end loop;

            --  Is this an extending project ?

            Extended := Extended_Project_Of
              (Project_Declaration_Of (Proj, Tree), Tree);
            if Extended /= Empty_Node then
               Process_Project (Extended);
            end if;

         end if;
      end Process_Project;

   begin
      Process_Project (Root);
   end For_Each_Project_Node;

   -------------------------------
   -- Compute_Imported_Projects --
   -------------------------------

   procedure Compute_Imported_Projects (Project : Project_Type'Class) is
      Count : Natural := 0;

      procedure Do_Count (Tree : Project_Node_Tree_Ref;
                          Node : Project_Node_Id);

      procedure Do_Count (Tree : Project_Node_Tree_Ref;
                          Node : Project_Node_Id)
      is
         pragma Unreferenced (Tree, Node);
      begin
         Count := Count + 1;
      end Do_Count;

   begin
      if Project.Data.Imported_Projects = null then
         For_Each_Project_Node
           (Project.Data.Tree.Tree, Project.Data.Node,
            Do_Count'Unrestricted_Access);

         declare
            Imports : Name_Id_Array (1 .. Count);
            Index   : Integer := Imports'First;

            procedure Do_Add (T : Project_Node_Tree_Ref; P : Project_Node_Id);
            procedure Do_Add
              (T : Project_Node_Tree_Ref; P : Project_Node_Id) is
            begin
               Imports (Index) := Prj.Tree.Name_Of (P, T);
               Index := Index + 1;
            end Do_Add;

         begin
            For_Each_Project_Node
              (Project.Data.Tree.Tree, Project.Data.Node,
               Do_Add'Unrestricted_Access);
            Project.Data.Imported_Projects := new Name_Id_Array'
              (Imports (Imports'First .. Index - 1));
         end;
      end if;
   end Compute_Imported_Projects;

   -----------
   -- Start --
   -----------

   function Start
     (Root_Project     : Project_Type;
      Recursive        : Boolean := True;
      Direct_Only      : Boolean := False;
      Include_Extended : Boolean := True) return Project_Iterator
   is
      Iter : Project_Iterator;
   begin
      Assert (Me, Root_Project.Data /= null,
              "Start: Uninitialized project passed as argument");

      Compute_Imported_Projects (Root_Project);

      if Recursive then
         Iter := Project_Iterator'
           (Root             => Root_Project,
            Direct_Only      => Direct_Only,
            Importing        => False,
            Include_Extended => Include_Extended,
            Current          => Root_Project.Data.Imported_Projects'Last + 1);
         Next (Iter);
         return Iter;
      else
         return Project_Iterator'
           (Root             => Root_Project,
            Direct_Only      => Direct_Only,
            Importing        => False,
            Include_Extended => Include_Extended,
            Current          => Root_Project.Data.Imported_Projects'First);
      end if;
   end Start;

   ---------------------
   -- Project_Imports --
   ---------------------

   procedure Project_Imports
     (Parent           : Project_Type;
      Child            : Project_Type;
      Include_Extended : Boolean := False;
      Imports          : out Boolean;
      Is_Limited_With  : out Boolean)
   is
      With_Clause : Project_Node_Id;
      Extended    : Project_Node_Id;
   begin
      Assert (Me, Child /= No_Project, "Project_Imports: no child provided");

      if Parent = No_Project then
         Imports := True;
         Is_Limited_With := False;
         return;
      end if;

      With_Clause := First_With_Clause_Of
        (Parent.Data.Node, Parent.Tree_Tree);

      while With_Clause /= Empty_Node loop
         if Project_Node_Of
           (With_Clause, Parent.Tree_Tree) = Child.Data.Node
         then
            Imports         := True;
            Is_Limited_With :=
              Non_Limited_Project_Node_Of (With_Clause, Parent.Tree_Tree)
              = Empty_Node;
            return;
         end if;

         With_Clause := Next_With_Clause_Of (With_Clause, Parent.Tree_Tree);
      end loop;

      --  Handling for extending projects ?

      if Include_Extended then
         Extended := Extended_Project_Of
           (Project_Declaration_Of (Parent.Data.Node, Parent.Tree_Tree),
            Parent.Tree_Tree);
         if Extended = Child.Data.Node then
            Imports := True;
            Is_Limited_With := False;
            return;
         end if;
      end if;

      Imports := False;
      Is_Limited_With := False;
   end Project_Imports;

   --------------------------------
   -- Compute_Importing_Projects --
   --------------------------------

   procedure Compute_Importing_Projects (Project : Project_Type'Class) is
      type Boolean_Array is array (Positive range <>) of Boolean;

      Root_Project : constant Project_Type := Project.Data.Tree.Root;
      Tree : constant Prj.Tree.Project_Node_Tree_Ref :=
        Root_Project.Tree_Tree;
      All_Prj   : Name_Id_Array_Access := Root_Project.Data.Imported_Projects;
      Importing : Name_Id_Array_Access;
      Current   : Project_Type;
      Start     : Project_Type;
      Index     : Integer;
      Parent    : Project_Type;
      Decl, N   : Project_Node_Id;
      Imports, Is_Limited_With : Boolean;

      procedure Merge_Project (P : Project_Type; Inc : in out Boolean_Array);
      --  Merge the imported projects of P with the ones for Project

      -------------------
      -- Merge_Project --
      -------------------

      procedure Merge_Project
        (P : Project_Type; Inc : in out Boolean_Array)
      is
         Index2 : Integer;
      begin
         for J in P.Data.Importing_Projects'Range loop
            Index2 := All_Prj'First;
            while All_Prj (Index2) /= P.Data.Importing_Projects (J) loop
               Index2 := Index2 + 1;
            end loop;

            Inc (Index2) := True;
         end loop;
      end Merge_Project;

   begin
      if Project.Data.Importing_Projects /= null then
         return;
      end if;

      if All_Prj = null then
         Compute_Imported_Projects (Root_Project);
         All_Prj := Root_Project.Data.Imported_Projects;
      end if;

      --  Process all extending and extended projects as a single one: they
      --  will all have the same list of importing projects.

      N := Project.Data.Node;
      loop
         Decl := Project_Declaration_Of (N, Tree);
         exit when Extending_Project_Of (Decl, Tree) = Empty_Node;
         N := Extending_Project_Of (Decl, Tree);
      end loop;

      Current := Project_Type
        (Project_From_Name (Project.Data.Tree, Prj.Tree.Name_Of (N, Tree)));
      Start := Current;

      declare
         Include   : Boolean_Array (All_Prj'Range) := (others => False);

      begin
         while Current /= No_Project loop
            for Index in All_Prj'Range loop
               Parent := Project_Type
                 (Project_From_Name (Project.Data.Tree, All_Prj (Index)));

               --  Avoid processing a project twice

               if not Include (Index) then
                  if Parent /= Current then
                     Project_Imports
                       (Parent, Child => Current, Include_Extended => False,
                        Imports         => Imports,
                        Is_Limited_With => Is_Limited_With);

                     if Imports then
                        Include (Index) := True;
                        Compute_Importing_Projects (Parent);
                        Merge_Project (Parent, Include);
                     end if;
                  end if;
               end if;
            end loop;

            Current := Extended_Project (Current);
         end loop;

         --  Done processing everything

         Index := 0;
         for Inc in Include'Range loop
            if Include (Inc) then
               Index := Index + 1;
            end if;
         end loop;

         --  Keep the last place for the project itself

         Importing := new Name_Id_Array (1 .. Index + 1);

         Index := Importing'First;
         for Inc in Include'Range loop
            if Include (Inc) then
               Importing (Index) := All_Prj (Inc);
               Index := Index + 1;
            end if;
         end loop;
      end;

      Importing (Importing'Last) := Prj.Tree.Name_Of
        (Project.Data.Node, Project.Data.Tree.Tree);

      Start := Project_Type (Project);
      while Start /= No_Project loop
         if Start.Data = Project.Data then
            Start.Data.Importing_Projects := Importing;
         else
            Start.Data.Importing_Projects := new Name_Id_Array'(Importing.all);
         end if;

         Start := Start.Extending_Project;
      end loop;

      --  The code below is used for debugging sessions

      if Active (Debug) then
         Trace (Debug, "Find_All_Projects_Importing: " & Project.Name);
         for J in Project.Data.Importing_Projects'Range loop
            Trace (Debug, Get_String (Project.Data.Importing_Projects (J)));
         end loop;
      end if;

   exception
      when E : others =>
         Trace (Exception_Handle, E);
   end Compute_Importing_Projects;

   ---------------------------------
   -- Find_All_Projects_Importing --
   ---------------------------------

   function Find_All_Projects_Importing
     (Project      : Project_Type;
      Include_Self : Boolean := False;
      Direct_Only  : Boolean := False) return Project_Iterator
   is
      Root_Project : constant Project_Type := Project.Data.Tree.Root;
      Iter         : Project_Iterator;
   begin
      if Project = No_Project then
         return Start (Root_Project, Recursive => True);
      end if;

      if Project.Data.Importing_Projects = null then
         Compute_Imported_Projects (Root_Project);
         Compute_Importing_Projects (Project);
      end if;

      Iter := Project_Iterator'
        (Root             => Project,
         Direct_Only      => Direct_Only,
         Importing        => True,
         Include_Extended => True,   --  ??? Should this be configurable
         Current          => Project.Data.Importing_Projects'Last + 1);

      --  The project iself is always at index 'Last
      if not Include_Self then
         Iter.Current := Iter.Current - 1;
      end if;

      Next (Iter);
      return Iter;
   end Find_All_Projects_Importing;

   -------------
   -- Current --
   -------------

   function Current
     (Iterator : Project_Iterator) return Project_Type
   is
      P : Project_Type;
   begin
      if Iterator.Importing then
         if Iterator.Current >=
           Iterator.Root.Data.Importing_Projects'First
         then
            return Project_Type
              (Project_From_Name
                 (Iterator.Root.Data.Tree,
                  Iterator.Root.Data.Importing_Projects (Iterator.Current)));
         end if;

      elsif Iterator.Current > Iterator.Root.Data.Imported_Projects'Last then
         return No_Project;

      elsif Iterator.Current >= Iterator.Root.Data.Imported_Projects'First then
         P := Project_Type
           (Project_From_Name
              (Iterator.Root.Data.Tree,
               Iterator.Root.Data.Imported_Projects (Iterator.Current)));
         Assert (Me, P.Data /= null,
                 "Current: project not found: "
                 & Get_String (Iterator.Root.Data.Imported_Projects
                               (Iterator.Current)));
         return P;
      end if;

      return No_Project;
   end Current;

   ---------------------
   -- Is_Limited_With --
   ---------------------

   function Is_Limited_With
     (Iterator : Project_Iterator) return Boolean
   is
      Imports, Is_Limited_With : Boolean;
   begin
      if Iterator.Importing then
         Project_Imports
           (Current (Iterator), Iterator.Root,
            Include_Extended => False,
            Imports          => Imports,
            Is_Limited_With  => Is_Limited_With);

      else
         Project_Imports
           (Iterator.Root, Current (Iterator),
            Include_Extended => False,
            Imports          => Imports,
            Is_Limited_With  => Is_Limited_With);
      end if;

      return Imports and Is_Limited_With;
   end Is_Limited_With;

   ----------
   -- Next --
   ----------

   procedure Next (Iterator : in out Project_Iterator) is
      Imports, Is_Limited_With : Boolean;
   begin
      Iterator.Current := Iterator.Current - 1;

      if Iterator.Direct_Only then
         if Iterator.Importing then
            while Iterator.Current >=
              Iterator.Root.Data.Importing_Projects'First
            loop
               Project_Imports
                 (Current (Iterator), Iterator.Root, Iterator.Include_Extended,
                  Imports => Imports, Is_Limited_With => Is_Limited_With);
               exit when Imports;
               Iterator.Current := Iterator.Current - 1;
            end loop;

         else
            while Iterator.Current >=
              Iterator.Root.Data.Imported_Projects'First
            loop
               Project_Imports
                 (Iterator.Root, Current (Iterator), Iterator.Include_Extended,
                  Imports => Imports, Is_Limited_With => Is_Limited_With);
               exit when Imports;
               Iterator.Current := Iterator.Current - 1;
            end loop;
         end if;
      end if;
   end Next;

   --------------------------------
   -- Compute_Scenario_Variables --
   --------------------------------

   procedure Compute_Scenario_Variables (Tree : Project_Tree_Data_Access) is
      T     : constant Project_Node_Tree_Ref := Tree.Tree;
      List  : Scenario_Variable_Array_Access;
      Curr  : Positive;

      function Count_Vars return Natural;
      --  Return the number of scenario variables in tree

      function Register_Var
        (Variable : Project_Node_Id; Proj : Project_Node_Id) return Boolean;
      --  Add the variable to the list of scenario variables, if not there yet
      --  (see the documentation for Scenario_Variables for the exact rules
      --  used to detect aliases).

      function External_Default (Var : Project_Node_Id) return Name_Id;
      --  Return the default value for the variable. Var must be a variable
      --  declaration or a variable reference. This routine supports only
      --  single expressions (no composite values).

      ----------------
      -- Count_Vars --
      ----------------

      function Count_Vars return Natural is
         Count : Natural := 0;

         function Cb
           (Variable : Project_Node_Id; Prj : Project_Node_Id) return Boolean;
         --  Increment the total number of variables

         --------
         -- Cb --
         --------

         function Cb
           (Variable : Project_Node_Id; Prj : Project_Node_Id) return Boolean
         is
            pragma Unreferenced (Variable, Prj);
         begin
            Count := Count + 1;
            return True;
         end Cb;

      begin
         For_Each_External_Variable_Declaration
           (Tree.Root, Recursive => True, Callback => Cb'Unrestricted_Access);
         return Count;
      end Count_Vars;

      ----------------------
      -- External_Default --
      ----------------------

      function External_Default (Var : Project_Node_Id) return Name_Id is
         Proj : Project_Type    := Tree.Root;
         Expr : Project_Node_Id := Expression_Of (Var, T);
      begin
         Expr := First_Term   (Expr, T);
         Expr := Current_Term (Expr, T);

         if Kind_Of (Expr, T) = N_External_Value then
            Expr := External_Default_Of (Expr, T);

            if Expr = Empty_Node then
               return No_Name;
            end if;

            if Kind_Of (Expr, T) /= N_Literal_String then
               Expr := First_Term (Expr, T);
               Assert (Me, Next_Term (Expr, T) = Empty_Node,
                       "Default value cannot be a concatenation");

               Expr := Current_Term (Expr, T);

               if Kind_Of (Expr, T) = N_Variable_Reference then
                  --  A variable reference, look for the corresponding string
                  --  literal.

                  declare
                     Var    : constant Name_Id :=
                                Prj.Tree.Name_Of (Expr, T);
                     In_Prj : constant Project_Node_Id :=
                                Project_Node_Of (Expr, T);
                     Decl   : Project_Node_Id;
                  begin
                     if In_Prj /= Empty_Node then
                        --  This variable is defined in another project, get
                        --  project reference.
                        Proj := Project_Type
                          (Project_From_Name
                             (Tree, Prj.Tree.Name_Of (In_Prj, T)));
                     end if;

                     --  Look for Var declaration into the project

                     Decl := First_Declarative_Item_Of
                       (Project_Declaration_Of (Proj.Data.Node, T), T);

                     while Decl /= Empty_Node loop
                        Expr := Current_Item_Node (Decl, T);

                        if Prj.Tree.Name_Of (Expr, T) = Var then
                           Expr := Expression_Of (Expr, T);
                           Expr := First_Term (Expr, T);
                           --  Get expression and corresponding term

                           --  Check now that this is not a composite value

                           Assert
                             (Me, Next_Term (Expr, T) = Empty_Node,
                              "Default value cannot be a concatenation");

                           --  Get the string literal

                           Expr := Current_Term (Expr, T);
                           exit;
                        end if;
                        Decl := Next_Declarative_Item (Decl, T);
                     end loop;
                  end;
               end if;

               if Kind_Of (Expr, T) /= N_Literal_String then
                  Trace (Me, "Default value can only be literal string");
                  Proj.Data.Uses_Variables := True; --  prevent edition
                  return No_Name;
               end if;
            end if;

            return String_Value_Of (Expr, T);

         else
            return No_Name;
         end if;
      end External_Default;

      ------------------
      -- Register_Var --
      ------------------

      function Register_Var
        (Variable : Project_Node_Id; Proj : Project_Node_Id) return Boolean
      is
         pragma Unreferenced (Proj);
         V : constant Name_Id := External_Reference_Of (Variable, T);
         N : constant String := Get_String (V);
         Var : Scenario_Variable;
      begin
         for Index in 1 .. Curr - 1 loop
            if External_Name (List (Index)) = N then
               --  Nothing to do
               return True;
            end if;
         end loop;

         Var := Scenario_Variable'
           (Name        => V,
            Default     => External_Default (Variable),
            String_Type => String_Type_Of (Variable, T),
            Value       => Prj.Ext.Value_Of
              (Tree.Tree, V, With_Default => External_Default (Variable)));

         List (Curr) := Var;

         --  Ensure the external reference actually exists

         if Prj.Ext.Value_Of (T, Var.Name) = No_Name then
            if Var.Default /= No_Name then
               Prj.Ext.Add (T, N, Get_Name_String (Var.Default));
            else
               Get_Name_String
                 (String_Value_Of
                    (First_Literal_String
                       (Var.String_Type, T), T));
               Prj.Ext.Add
                 (T, N, Name_Buffer (Name_Buffer'First .. Name_Len));
            end if;
         end if;

         Curr := Curr + 1;
         return True;
      end Register_Var;

   begin
      Trace (Me, "Compute the list of scenario variables");
      Unchecked_Free (Tree.Scenario_Variables);
      List :=  new Scenario_Variable_Array (1 .. Count_Vars);
      Curr := List'First;

      For_Each_External_Variable_Declaration
        (Tree.Root, Recursive => True,
         Callback => Register_Var'Unrestricted_Access);

      if Curr > List'Last then
         Tree.Scenario_Variables := List;
      else
         Tree.Scenario_Variables :=
           new Scenario_Variable_Array'(List (1 .. Curr - 1));
         Unchecked_Free (List);
      end if;
   end Compute_Scenario_Variables;

   ------------------------
   -- Scenario_Variables --
   ------------------------

   function Scenario_Variables
     (Self : Project_Tree) return Scenario_Variable_Array is
   begin
      return Scenario_Variables (Self.Data);
   end Scenario_Variables;

   ------------------------
   -- Scenario_Variables --
   ------------------------

   function Scenario_Variables
     (Tree : Project_Tree_Data_Access) return Scenario_Variable_Array is
   begin
      if Tree.Scenario_Variables = null then
         Compute_Scenario_Variables (Tree);
      end if;

      for V in Tree.Scenario_Variables'Range loop
         Tree.Scenario_Variables (V).Value :=
           Prj.Ext.Value_Of
             (Tree.Tree, Tree.Scenario_Variables (V).Name,
              With_Default => Tree.Scenario_Variables (V).Default);
      end loop;

      return Tree.Scenario_Variables.all;
   end Scenario_Variables;

   ------------------------
   -- Scenario_Variables --
   ------------------------

   function Scenario_Variables
     (Self : Project_Tree; External_Name : String)
      return Scenario_Variable
   is
      Ext  : constant Name_Id := Get_String (External_Name);
      List : Scenario_Variable_Array_Access;
      Var  : Scenario_Variable;
   begin
      if Self.Data.Scenario_Variables = null then
         Compute_Scenario_Variables (Self.Data);
      end if;

      for V in Self.Data.Scenario_Variables'Range loop
         if Self.Data.Scenario_Variables (V).Name = Ext then
            return Self.Data.Scenario_Variables (V);
         end if;
      end loop;

      Var := Scenario_Variable'
        (Name        => Ext,
         Default     => No_Name,
         String_Type => Empty_Node,
         Value       => No_Name);

      List := Self.Data.Scenario_Variables;
      Self.Data.Scenario_Variables :=
        new Scenario_Variable_Array'
          (Self.Data.Scenario_Variables.all & Var);
      Unchecked_Free (List);

      return Var;
   end Scenario_Variables;

   -------------------
   -- External_Name --
   -------------------

   function External_Name (Var : Scenario_Variable) return String is
   begin
      return Get_String (Var.Name);
   end External_Name;

   ----------------------
   -- External_Default --
   ----------------------

   function External_Default (Var : Scenario_Variable) return String is
   begin
      return Get_String (Var.Default);
   end External_Default;

   ---------------
   -- Set_Value --
   ---------------

   procedure Set_Value
     (Var   : in out Scenario_Variable;
      Value : String)
   is
   begin
      Var.Value := Get_String (Value);
   end Set_Value;

   ------------------------
   -- Change_Environment --
   ------------------------

   procedure Change_Environment
     (Self  : Project_Tree;
      Vars  : Scenario_Variable_Array) is
   begin
      for V in Vars'Range loop
         Prj.Ext.Add
           (Self.Data.Tree,
            Get_String (Vars (V).Name),
            Get_String (Vars (V).Value));
      end loop;
   end Change_Environment;

   -----------
   -- Value --
   -----------

   function Value (Var : Scenario_Variable) return String is
   begin
      return Get_String (Var.Value);
   end Value;

   --------------
   -- Get_View --
   --------------

   function Get_View
     (Tree : Prj.Project_Tree_Ref; Name : Name_Id) return Prj.Project_Id
   is
      Proj : Project_List := Tree.Projects;
   begin
      while Proj /= null loop
         if Proj.Project.Name = Name
           and then Proj.Project.Qualifier /= Configuration
         then
            return Proj.Project;
         end if;

         Proj := Proj.Next;
      end loop;

      return Prj.No_Project;
   end Get_View;

   --------------
   -- Get_View --
   --------------

   function Get_View (Project : Project_Type) return Prj.Project_Id is
   begin
      if Project.Data = null or else Project.Data.Node = Empty_Node then
         return Prj.No_Project;

      elsif Project.Data.View = Prj.No_Project then
         Project.Data.View :=
           Get_View
             (Project.Tree_View,
              Prj.Tree.Name_Of (Project.Data.Node, Project.Tree_Tree));
      end if;

      return Project.Data.View;
   end Get_View;

   --------------------------------------------
   -- For_Each_External_Variable_Declaration --
   --------------------------------------------

   procedure For_Each_External_Variable_Declaration
     (Project   : Project_Type;
      Recursive : Boolean;
      Callback  : External_Variable_Callback)
   is
      Tree     : constant Prj.Tree.Project_Node_Tree_Ref := Project.Tree_Tree;
      Iterator : Project_Iterator := Start (Project, Recursive);
      P        : Project_Type;

      procedure Process_Prj (Prj : Project_Node_Id);
      --  Process all the declarations in a single project

      -----------------
      -- Process_Prj --
      -----------------

      procedure Process_Prj (Prj : Project_Node_Id) is
         Pkg : Project_Node_Id := Prj;
         Var : Project_Node_Id;
      begin
         --  For all the packages and the common section
         while Pkg /= Empty_Node loop
            Var := First_Variable_Of (Pkg, Tree);

            while Var /= Empty_Node loop
               if Kind_Of (Var, Tree) = N_Typed_Variable_Declaration
                 and then Is_External_Variable (Var, Tree)
                 and then not Callback (Var, Prj)
               then
                  exit;

               elsif Kind_Of (Var, Tree) = N_Variable_Declaration
                 or else
                   (Kind_Of (Var, Tree) = N_Typed_Variable_Declaration
                    and then not Is_External_Variable (Var, Tree))
               then
                  if Active (Debug) then
                     Trace (Me, "Uses variable in " & P.Name);
                     Pretty_Print
                       (Var, Tree, Backward_Compatibility => False);
                  end if;
                  P.Data.Uses_Variables := True;
               end if;

               Var := Next_Variable (Var, Tree);
            end loop;

            if Pkg = Prj then
               Pkg := First_Package_Of (Prj, Tree);
            else
               Pkg := Next_Package_In_Project (Pkg, Tree);
            end if;
         end loop;
      end Process_Prj;

   begin
      loop
         P := Current (Iterator);
         exit when P.Data = null;

         P.Data.Uses_Variables := False;
         Process_Prj (P.Data.Node);
         Next (Iterator);
      end loop;
   end For_Each_External_Variable_Declaration;

   --------------
   -- Switches --
   --------------

   procedure Switches
     (Project          : Project_Type;
      In_Pkg           : String;
      File             : GNATCOLL.VFS.Virtual_File;
      Language         : String;
      Value            : out GNAT.Strings.String_List_Access;
      Is_Default_Value : out Boolean)
   is
   begin
      Value := null;
      Is_Default_Value := True;

      --  Do we have some file-specific switches ?
      if Project /= No_Project and then File /= GNATCOLL.VFS.No_File then
         Value := Project.Attribute_Value
           (Attribute      =>
              Build (In_Pkg, Get_Name_String (Name_Switches)),
            Index          => +Base_Name (File));

         Is_Default_Value := Value = null;
      end if;

      --  Search if the user has defined default switches for that tool
      if Project /= No_Project and then Value = null then
         Value := Project.Attribute_Value
           (Attribute      =>
              Build (In_Pkg, Get_String (Name_Default_Switches)),
            Index          => Language);

         if Value = null then
            Value := Project.Attribute_Value
              (Attribute      =>
                 Build (In_Pkg, Get_String (Name_Switches)),
               Index          => Language);
         end if;

         Is_Default_Value := True;
      end if;
   end Switches;

   --------------
   -- Value_Of --
   --------------

   function Value_Of
     (Tree : Project_Node_Tree_Ref;
      Var  : Scenario_Variable) return String_List_Iterator
   is
      V, Expr : Project_Node_Id;
   begin
      case Kind_Of (Var.String_Type, Tree) is
         when N_String_Type_Declaration =>
            return (Current => First_Literal_String (Var.String_Type, Tree));

         when N_Attribute_Declaration
           |  N_Typed_Variable_Declaration
           |  N_Variable_Declaration =>

            V := Expression_Of (Var.String_Type, Tree);

            case Kind_Of (V, Tree) is
               when N_Expression =>
                  Expr := First_Term (V, Tree);
                  pragma Assert (Kind_Of (Expr, Tree) = N_Term);
                  Expr := Current_Term (Expr, Tree);

                  case Kind_Of (Expr, Tree) is
                     when N_Literal_String_List =>
                        return
                          (Current => First_Expression_In_List (Expr, Tree));

                     when N_External_Value =>
                        return
                          (Current => External_Default_Of (Expr, Tree));

                     when others =>
                        return (Current => V);
                  end case;

               when others =>
                  raise Program_Error;
            end case;

         when others =>
            raise Program_Error;
      end case;
   end Value_Of;

   ----------
   -- Done --
   ----------

   function Done (Iter : String_List_Iterator) return Boolean is
   begin
      return Iter.Current = Empty_Node;
   end Done;

   ----------
   -- Next --
   ----------

   function Next
     (Tree : Project_Node_Tree_Ref;
      Iter : String_List_Iterator) return String_List_Iterator is
   begin
      pragma Assert (Iter.Current /= Empty_Node);

      case Kind_Of (Iter.Current, Tree) is
         when N_Literal_String =>
            return (Current => Next_Literal_String (Iter.Current, Tree));

         when N_Expression =>
            return (Current => Next_Expression_In_List (Iter.Current, Tree));

         when others =>
            raise Program_Error;
      end case;
   end Next;

   ----------
   -- Data --
   ----------

   function Data
     (Tree : Prj.Tree.Project_Node_Tree_Ref;
      Iter : String_List_Iterator) return Namet.Name_Id is
   begin
      pragma Assert (Kind_Of (Iter.Current, Tree) = N_Literal_String);
      return String_Value_Of (Iter.Current, Tree);
   end Data;

   ------------------------
   -- Possible_Values_Of --
   ------------------------

   function Possible_Values_Of
     (Self : Project_Tree; Var : Scenario_Variable) return String_List
   is
      Tree   : constant Prj.Tree.Project_Node_Tree_Ref := Self.Data.Tree;
      Count  : Natural := 0;
      Iter   : String_List_Iterator := Value_Of (Tree, Var);
   begin
      while not Done (Iter) loop
         Count := Count + 1;
         Iter := Next (Tree, Iter);
      end loop;

      declare
         Values : String_List (1 .. Count);
      begin
         Count := Values'First;

         Iter := Value_Of (Tree, Var);
         while not Done (Iter) loop
            Values (Count) := new String'
              (Get_Name_String (Data (Tree, Iter)));
            Count := Count + 1;
            Iter := Next (Tree, Iter);
         end loop;

         return Values;
      end;
   end Possible_Values_Of;

   ---------------------------
   -- Has_Imported_Projects --
   ---------------------------

   function Has_Imported_Projects (Project : Project_Type) return Boolean is
      Iter : constant Project_Iterator := Start
        (Project, Recursive => True, Direct_Only => True);
   begin
      return Current (Iter) /= No_Project;
   end Has_Imported_Projects;

   ---------
   -- "=" --
   ---------

   function "=" (Prj1, Prj2 : Project_Type) return Boolean is
   begin
      if Prj1.Data = null then
         return Prj2.Data = null;
      elsif Prj2.Data = null then
         return False;
      else
         return Prj1.Data.Node = Prj2.Data.Node;
      end if;
   end "=";

   ----------------------
   -- Extended_Project --
   ----------------------

   function Extended_Project
     (Project : Project_Type) return Project_Type
   is
      Tree     : constant Project_Node_Tree_Ref := Project.Tree_Tree;
      Extended : constant Project_Node_Id := Extended_Project_Of
        (Project_Declaration_Of (Project.Data.Node, Tree), Tree);
   begin
      if Extended = Empty_Node then
         return No_Project;
      else
         return Project_Type
           (Project_From_Name
              (Project.Data.Tree, Prj.Tree.Name_Of (Extended, Tree)));
      end if;
   end Extended_Project;

   -----------------------
   -- Extending_Project --
   -----------------------

   function Extending_Project
     (Project : Project_Type; Recurse : Boolean := False) return Project_Type
   is
      Tree   : constant Project_Node_Tree_Ref := Project.Tree_Tree;
      Extend : Project_Node_Id;
   begin
      if Recurse then
         Extend := Project.Data.Node;

         while Extending_Project_Of
           (Project_Declaration_Of (Extend, Tree), Tree) /= Empty_Node
         loop
            Extend := Extending_Project_Of
              (Project_Declaration_Of (Extend, Tree), Tree);
         end loop;

      else
         Extend := Extending_Project_Of
           (Project_Declaration_Of (Project.Data.Node, Tree), Tree);
      end if;

      if Extend = Empty_Node then
         return No_Project;
      else
         return Project_Type
           (Project_From_Name
              (Project.Data.Tree, Prj.Tree.Name_Of (Extend, Tree)));
      end if;
   end Extending_Project;

   -----------
   -- Build --
   -----------

   function Build
     (Package_Name, Attribute_Name : String) return Attribute_Pkg_String is
   begin
      return Attribute_Pkg_String
        (To_Lower (Package_Name) & '#' & To_Lower (Attribute_Name));
   end Build;

   function Build
     (Package_Name, Attribute_Name : String) return Attribute_Pkg_List is
   begin
      return Attribute_Pkg_List
        (To_Lower (Package_Name) & '#' & To_Lower (Attribute_Name));
   end Build;

   ------------------------
   -- Delete_File_Suffix --
   ------------------------

   function Delete_File_Suffix
     (Filename : Filesystem_String; Project : Project_Type) return Natural
   is
      View  : constant Project_Id := Get_View (Project);
      Lang  : Language_Ptr;
      Suffix : Name_Id;
   begin
      --  View will be null when called from the project wizard

      if View /= Prj.No_Project then
         Lang := View.Languages;
         while Lang /= null loop
            Suffix := Name_Id (Lang.Config.Naming_Data.Spec_Suffix);
            if Suffix /= No_Name
              and then Ends_With (+Filename, Get_Name_String (Suffix))
            then
               return Filename'Last - Natural (Length_Of_Name (Suffix));
            end if;

            Suffix := Name_Id (Lang.Config.Naming_Data.Body_Suffix);
            if Suffix /= No_Name
              and then Ends_With (+Filename, Get_Name_String (Suffix))
            then
               return Filename'Last - Natural (Length_Of_Name (Suffix));
            end if;

            Lang := Lang.Next;
         end loop;
      end if;

      --  Check the default naming scheme as well ? Otherwise, it might happen
      --  that a project has its own naming scheme, but still references files
      --  in the runtime with the default naming scheme.

      declare
         Ext : constant String :=
           GNAT.Directory_Operations.File_Extension (+Filename);
      begin
         if  Ext = ".ads" or else Ext = ".adb" then
            return Filename'Last - 4;
         end if;
      end;

      return Filename'Last;
   end Delete_File_Suffix;

   ---------------------
   -- Executable_Name --
   ---------------------

   function Executable_Name
     (Project : Project_Type;
      File    : Filesystem_String) return Filesystem_String
   is
      Base         : constant Filesystem_String := Base_Name (File);
      Default_Exec : constant Filesystem_String := Base
        (Base'First .. Delete_File_Suffix (Base, Project));

   begin
      if Project = No_Project then
         --  Simply remove the current extension, since we don't have any
         --  information on the file itself.
         return Default_Exec;

      else
         declare
            From_Project : constant String := Project.Attribute_Value
              (Executable_Attribute,
               Index => String (Base), Default => "");
            Result       : File_Info;
         begin
            if From_Project = "" then
               --  Check whether the file is a special naming scheme for an
               --  Ada unit. If this is the case, the name of the unit is the
               --  name of the executable

               Result := Info (Project.Data.Tree, Create (File));
               if Result.Name /= No_Name then
                  return +Get_String (Result.Name);
               end if;

               --  Else use the default
               return Default_Exec;
            end if;

            return +From_Project;
         end;
      end if;
   end Executable_Name;

   ------------------
   -- Create_Flags --
   ------------------

   function Create_Flags
     (On_Error        : Prj.Error_Handler;
      Require_Sources : Boolean := True) return Processing_Flags is
   begin
      if Require_Sources then
         return Create_Flags
           (Report_Error               => On_Error,
            When_No_Sources            => Warning,
            Require_Sources_Other_Lang => True,
            Compiler_Driver_Mandatory  => False,
            Allow_Duplicate_Basenames  => True,
            Require_Obj_Dirs           => Warning,
            Allow_Invalid_External     => Warning,
            Missing_Source_Files       => Warning);
      else
         return Create_Flags
           (Report_Error               => On_Error,
            When_No_Sources            => Silent,
            Require_Sources_Other_Lang => False,
            Compiler_Driver_Mandatory  => False,
            Allow_Duplicate_Basenames  => True,
            Require_Obj_Dirs           => Warning,
            Allow_Invalid_External     => Silent,
            Missing_Source_Files       => Warning);
      end if;
   end Create_Flags;

   ----------------------------
   -- Has_Multi_Unit_Sources --
   ----------------------------

   function Has_Multi_Unit_Sources (Project : Project_Type) return Boolean is
      View : constant Project_Id := Get_View (Project);
   begin
      if View /= Prj.No_Project then
         return View.Has_Multi_Unit_Sources;
      end if;
      return False;
   end Has_Multi_Unit_Sources;

   -----------------------
   -- Project_From_Name --
   -----------------------

   function Project_From_Name
     (Tree : Project_Tree_Data_Access;
      Name : Namet.Name_Id) return Project_Type'Class
   is
      P_Cursor : Project_Htables.Cursor;
   begin
      if Tree = null or else Tree.Tree = null then
         Trace (Me, "Project_From_Name: Registry not initialized");
         return No_Project;

      else
         Get_Name_String (Name);
         P_Cursor := Tree.Projects.Find (Name_Buffer (1 .. Name_Len));

         if Has_Element (P_Cursor) then
            return Element (P_Cursor);
         else
            Trace (Me, "Get_Project_From_Name: "
                   & Get_String (Name) & " wasn't found");
            return No_Project;
         end if;
      end if;
   end Project_From_Name;

   -----------------------
   -- Project_From_Name --
   -----------------------

   function Project_From_Name
     (Self : Project_Tree'Class; Name : String) return Project_Type is
   begin
      return Project_Type (Project_From_Name (Self.Data, Get_String (Name)));
   end Project_From_Name;

   ----------------------
   -- Set_Trusted_Mode --
   ----------------------

   procedure Set_Trusted_Mode
     (Self : in out Project_Environment; Trusted : Boolean := True)
   is
   begin
      Self.Trusted_Mode := Trusted;
   end Set_Trusted_Mode;

   ------------------
   -- Trusted_Mode --
   ------------------

   function Trusted_Mode (Self : Project_Environment) return Boolean is
   begin
      return Self.Trusted_Mode;
   end Trusted_Mode;

   --------------------------------
   -- Set_Predefined_Source_Path --
   --------------------------------

   procedure Set_Predefined_Source_Path
     (Self : in out Project_Environment; Path : GNATCOLL.VFS.File_Array) is
   begin
      Unchecked_Free (Self.Predefined_Source_Files);
      Unchecked_Free (Self.Predefined_Source_Path);
      Self.Predefined_Source_Path := new File_Array'(Path);
   end Set_Predefined_Source_Path;

   procedure Set_Predefined_Object_Path
     (Self : in out Project_Environment; Path : GNATCOLL.VFS.File_Array) is
   begin
      Unchecked_Free (Self.Predefined_Object_Path);
      Self.Predefined_Object_Path := new File_Array'(Path);
   end Set_Predefined_Object_Path;

   procedure Set_Predefined_Project_Path
     (Self : in out Project_Environment; Path : GNATCOLL.VFS.File_Array) is
   begin
      Unchecked_Free (Self.Predefined_Project_Path);
      Self.Predefined_Project_Path := new File_Array'(Path);
   end Set_Predefined_Project_Path;

   ----------------------------
   -- Predefined_Source_Path --
   ----------------------------

   function Predefined_Source_Path
     (Self : Project_Environment) return GNATCOLL.VFS.File_Array is
   begin
      if Self.Predefined_Source_Path = null then
         return (1 .. 0 => GNATCOLL.VFS.No_File);
      else
         return Self.Predefined_Source_Path.all;
      end if;
   end Predefined_Source_Path;

   function Predefined_Object_Path
     (Self : Project_Environment) return GNATCOLL.VFS.File_Array is
   begin
      if Self.Predefined_Object_Path = null then
         return (1 .. 0 => GNATCOLL.VFS.No_File);
      else
         return Self.Predefined_Object_Path.all;
      end if;
   end Predefined_Object_Path;

   function Predefined_Project_Path
     (Self : Project_Environment) return GNATCOLL.VFS.File_Array
   is
      Current : Virtual_File;
   begin
      if Self.Predefined_Project_Path = null then
         Current := Create (Get_Current_Dir);
         return (1 .. 1 => Current);
      else
         return Self.Predefined_Project_Path.all;
      end if;
   end Predefined_Project_Path;

   -----------------------
   -- Set_Object_Subdir --
   -----------------------

   procedure Set_Object_Subdir
     (Self   : in out Project_Environment;
      Subdir : GNATCOLL.VFS.Filesystem_String) is
   begin
      Free (Self.Object_Subdir);
      Self.Object_Subdir := new String'(+Subdir);
   end Set_Object_Subdir;

   -------------------
   -- Object_Subdir --
   -------------------

   function Object_Subdir
     (Self   : Project_Environment) return GNATCOLL.VFS.Filesystem_String is
   begin
      if Self.Object_Subdir = null then
         return "";
      else
         return +Self.Object_Subdir.all;
      end if;
   end Object_Subdir;

   ----------------------
   -- Set_Xrefs_Subdir --
   ----------------------

   procedure Set_Xrefs_Subdir
     (Self   : in out Project_Environment;
      Subdir : GNATCOLL.VFS.Filesystem_String) is
   begin
      Free (Self.Xrefs_Subdir);
      Self.Xrefs_Subdir := new String'(+Subdir);
   end Set_Xrefs_Subdir;

   function Xrefs_Subdir
     (Self   : Project_Environment) return GNATCOLL.VFS.Filesystem_String is
   begin
      if Self.Xrefs_Subdir = null then
         return "";
      else
         return +Self.Xrefs_Subdir.all;
      end if;
   end Xrefs_Subdir;

   -----------------------------
   -- Predefined_Source_Files --
   -----------------------------

   function Predefined_Source_Files
     (Self : access Project_Environment) return GNATCOLL.VFS.File_Array is
   begin
      --  ??? A nicer way would be to implement this with a predefined project,
      --  and rely on the project parser to return the source
      --  files. Unfortunately, this doesn't work with the current
      --  implementation of this parser, since one cannot have two separate
      --  project hierarchies at the same time.

      if Self.Predefined_Source_Files = null
        and then Self.Predefined_Source_Path /= null
      then
         Self.Predefined_Source_Files := Read_Files_From_Dirs
           (Self.Predefined_Source_Path.all);
      end if;

      if Self.Predefined_Source_Files = null then
         return Empty_File_Array;
      else
         return Self.Predefined_Source_Files.all;
      end if;
   end Predefined_Source_Files;

   ------------------
   -- Data_Factory --
   ------------------

   function Data_Factory (Self : Project_Tree) return Project_Data_Access is
      pragma Unreferenced (Self);
   begin
      return new Project_Data;
   end Data_Factory;

   ----------
   -- Data --
   ----------

   function Data (Project : Project_Type) return Project_Data_Access is
   begin
      return Project.Data;
   end Data;

   -------------
   -- On_Free --
   -------------

   procedure On_Free (Self : in out Project_Data) is
   begin
      Unchecked_Free (Self.Imported_Projects);
      Unchecked_Free (Self.Importing_Projects);
      Reset_View (Self);
   end On_Free;

   ----------------
   -- Reset_View --
   ----------------

   procedure Reset_View (Self : in out Project_Data'Class) is
   begin
      Self.View := Prj.No_Project;
      --  No need to reset Self.Imported_Projects, since this doesn't
      --  change when the view changes.

      Unchecked_Free (Self.Non_Recursive_Include_Path);
      Unchecked_Free (Self.Files);

      Self.View_Is_Complete := True;
   end Reset_View;

   ------------
   -- Adjust --
   ------------

   overriding procedure Adjust (Self : in out Project_Type) is
   begin
      if Self.Data /= null then
         Self.Data.Refcount := Self.Data.Refcount + 1;
      end if;
   end Adjust;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Self : in out Project_Type) is
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (Project_Data'Class, Project_Data_Access);
   begin
      --  We never finalize unless Tree is null: the tree is set to null when
      --  the project_tree is unloaded. That means user cares about memory
      --  management. If we try to finalize when unload hasn't been called, and
      --  because the tree owns references to the project, this means Finalize
      --  is called by GNAT as part of processing the finalization_lists. In
      --  that case, it seems we always end up in a case where we access
      --  already deallocated memory.

      if Self.Data /= null then
         Self.Data.Refcount := Self.Data.Refcount - 1;
         if Self.Data.Refcount = 0
           and then Self.Data.Tree = null
         then
            On_Free (Self.Data.all);
            Unchecked_Free (Self.Data);
         end if;
      end if;
   end Finalize;

   ----------------------------
   -- Add_Language_Extension --
   ----------------------------

   procedure Add_Language_Extension
     (Self          : in out Project_Environment;
      Language_Name : String;
      Extension     : String)
   is
      Ext  : String := Extension;
   begin
      Osint.Canonical_Case_File_Name (Ext);
      Self.Extensions.Include (Ext, Get_String (To_Lower (Language_Name)));
   end Add_Language_Extension;

   -----------------------------------------
   -- Register_Default_Language_Extension --
   -----------------------------------------

   procedure Register_Default_Language_Extension
     (Self                : in out Project_Environment;
      Language_Name       : String;
      Default_Spec_Suffix : String;
      Default_Body_Suffix : String)
   is
      Spec, Impl : String_Access;
      Spec_Suff  : String := Default_Spec_Suffix;
      Impl_Suff  : String := Default_Body_Suffix;
   begin
      --  GNAT doesn't allow empty suffixes, and will display an error when
      --  the view is recomputed, in that case. Therefore we substitute dummy
      --  empty suffixes instead

      if Default_Spec_Suffix = "" then
         Spec := new String'(Dummy_Suffix);
      else
         Osint.Canonical_Case_File_Name (Spec_Suff);
         Spec := new String'(Spec_Suff);
      end if;

      if Default_Body_Suffix = "" then
         Impl := new String'(Dummy_Suffix);
      else
         Osint.Canonical_Case_File_Name (Impl_Suff);
         Impl := new String'(Impl_Suff);
      end if;

      Self.Naming_Schemes := new Naming_Scheme_Record'
        (Language            => new String'(To_Lower (Language_Name)),
         Default_Spec_Suffix => Spec,
         Default_Body_Suffix => Impl,
         Next                => Self.Naming_Schemes);
   end Register_Default_Language_Extension;

   ---------------------------
   -- Registered_Extensions --
   ---------------------------

   function Registered_Extensions
     (Self          : Project_Environment;
      Language_Name : String) return GNAT.Strings.String_List
   is
      Lang    : constant String := To_Lower (Language_Name);
      Lang_Id : constant Name_Id := Get_String (Lang);
      Iter    : Extensions_Languages.Cursor := Self.Extensions.First;
      Count   : Natural := 0;
   begin
      while Has_Element (Iter) loop
         if Element (Iter) = Lang_Id then
            Count := Count + 1;
         end if;

         Next (Iter);
      end loop;

      declare
         Args : String_List (1 .. Count);
      begin
         Count := Args'First;
         Iter := Self.Extensions.First;
         while Has_Element (Iter) loop
            if Element (Iter) = Lang_Id then
               Args (Count) := new String'(Key (Iter));
               Count := Count + 1;
            end if;

            Next (Iter);
         end loop;

         return Args;
      end;
   end Registered_Extensions;

   ------------------
   -- Root_Project --
   ------------------

   function Root_Project (Self : Project_Tree'Class) return Project_Type is
   begin
      return Self.Data.Root;
   end Root_Project;

   ----------------------------------
   -- Directory_Belongs_To_Project --
   ----------------------------------

   function Directory_Belongs_To_Project
     (Self        : Project_Tree;
      Directory   : GNATCOLL.VFS.Filesystem_String;
      Direct_Only : Boolean := True) return Boolean
   is
      Curs : constant Directory_Statuses.Cursor :=
        Self.Data.Directories.Find (Name_As_Directory (Directory));
      Belong : Directory_Dependency;
   begin
      if Has_Element (Curs) then
         Belong := Element (Curs);
         return Belong = Direct
           or else (not Direct_Only and then Belong = As_Parent);
      else
         return False;
      end if;
   end Directory_Belongs_To_Project;

   ----------
   -- Hash --
   ----------

   function Hash
     (File : GNATCOLL.VFS.Filesystem_String) return Ada.Containers.Hash_Type is
   begin
      if GNATCOLL.VFS_Utils.Local_Host_Is_Case_Sensitive then
         return Ada.Strings.Hash (+File);
      else
         return Ada.Strings.Hash_Case_Insensitive (+File);
      end if;
   end Hash;

   function Hash (Node : Project_Node_Id) return Ada.Containers.Hash_Type is
   begin
      return Ada.Containers.Hash_Type (Prj.Tree.Hash (Node));
   end Hash;

   -----------
   -- Equal --
   -----------

   function Equal (F1, F2 : GNATCOLL.VFS.Filesystem_String) return Boolean is
   begin
      --  ??? In GPS, we used to take into account the sensitive of the build
      --  host. However, this wasn't correct either, because it was computed
      --  at elaboration time, so always with local_host. Ideally, we should
      --  have access to a Project_Environment to find this out.
      return Equal
        (+F1, +F2,
         Case_Sensitive => GNATCOLL.VFS_Utils.Local_Host_Is_Case_Sensitive);
   end Equal;

   ----------------------
   -- Reload_If_Needed --
   ----------------------

   procedure Reload_If_Needed
     (Self     : in out Project_Tree;
      Reloaded : out Boolean;
      Errors   : Error_Report := null)
   is
      Iter               : Project_Iterator;
   begin
      Iter     := Start (Self.Root_Project);
      Reloaded := False;

      while Current (Iter) /= No_Project loop
         if File_Time_Stamp (Project_Path (Current (Iter))) >
           Self.Data.Timestamp
         then
            Trace (Me, "Reload_If_Needed: timestamp has changed for "
                   & Current (Iter).Name);
            Reloaded := True;
            exit;
         end if;

         Next (Iter);
      end loop;

      if Reloaded then
         Self.Load
           (Env                => Self.Data.Env,
            Root_Project_Path  => Project_Path (Self.Root_Project),
            Errors             => Errors);
      else
         Trace (Me, "Reload_If_Needed: nothing to do, timestamp unchanged");
      end if;
   end Reload_If_Needed;

   ----------
   -- Load --
   ----------

   procedure Load
     (Self               : in out Project_Tree;
      Root_Project_Path  : GNATCOLL.VFS.Virtual_File;
      Env                : Project_Environment_Access := null;
      Errors             : Error_Report := null;
      Recompute_View     : Boolean := True)
   is
      Previous_Project : Virtual_File;
      Previous_Status  : Project_Status;
      Success          : Boolean;
      Project          : Project_Node_Id;

   begin
      Trace (Me, "Load project " & Root_Project_Path.Display_Full_Name);

      if Active (Me_Gnat) then
         Prj.Current_Verbosity := Prj.High;
      end if;

      if Self.Data /= null and then Self.Data.Root /= No_Project then
         Previous_Project := Self.Root_Project.Project_Path;
         Previous_Status  := Self.Data.Status;

      else
         Previous_Project := GNATCOLL.VFS.No_File;
         Previous_Status  := Default;
      end if;

      if not Is_Regular_File (Root_Project_Path) then
         Trace (Me, "Load: " & Display_Full_Name (Root_Project_Path)
                & " is not a regular file");

         if Errors /= null then
            Errors (Display_Full_Name (Root_Project_Path)
                    & " is not a regular file");
         end if;

         raise Invalid_Project;
      end if;

      Self.Unload;

      if Self.Data = null then
         Self.Data := new Project_Tree_Data;

         if Env = null then
            Self.Data.Env := new Project_Environment;
         else
            Self.Data.Env := Env;
         end if;
      end if;

      --  Force a recomputation of the timestamp the next time Recompute_View
      --  is called.
      Self.Data.Timestamp := GNATCOLL.Utils.No_Time;

      Internal_Load (Self, Root_Project_Path, Errors, Project, Recompute_View);

      if Project = Empty_Node then
         --  Reset the list of error messages
         Prj.Err.Initialize;
         Self.Load_Empty_Project (Env => Self.Data.Env);
         raise Invalid_Project;
      end if;

      if Previous_Status = Default then
         Trace (Me, "Remove default project on disk, no longer used");
         Delete (Previous_Project, Success);
      end if;

      Trace (Me, "End of Load project");
   end Load;

   -----------
   -- Reset --
   -----------

   procedure Reset
     (Tree : in out Project_Tree'Class;
      Env  : Project_Environment_Access) is
   begin
      if Tree.Data = null then
         Tree.Data := new Project_Tree_Data;

         if Env = null then
            Tree.Data.Env := new Project_Environment;
         else
            Tree.Data.Env := Env;
         end if;
      end if;

      if Tree.Data.Tree = null then
         Tree.Data.Tree := new Project_Node_Tree_Data;
      end if;

      Prj.Tree.Initialize (Tree.Data.Tree);

      if Tree.Data.View = null then
         Tree.Data.View := new Prj.Project_Tree_Data;
      end if;

      Prj.Initialize (Tree.Data.View);
   end Reset;

   -------------------
   -- Internal_Load --
   -------------------

   procedure Internal_Load
     (Tree              : in out Project_Tree'Class;
      Root_Project_Path : GNATCOLL.VFS.Virtual_File;
      Errors            : Projects.Error_Report;
      Project           : out Project_Node_Id;
      Recompute_View    : Boolean := True)
   is
      procedure On_Error is new Mark_Project_Error (Tree);
      --  Any error while parsing the project marks it as incomplete, and
      --  prevents direct edition of the project.

      procedure Fail (S : String);
      --  Replaces Osint.Fail

      ----------
      -- Fail --
      ----------

      procedure Fail (S : String) is
      begin
         if Errors /= null then
            Errors (S);
         end if;
      end Fail;

      Predefined_Path : constant String :=
        +To_Path (Predefined_Project_Path (Tree.Data.Env.all));
   begin
      Traces.Assert (Me, Tree.Data /= null, "Tree data initialized");

      Reset (Tree, Tree.Data.Env);

      Trace (Me, "Set project path to " & Predefined_Path);
      Prj.Ext.Set_Project_Path (Tree.Data.Tree, Predefined_Path);

      Project := Empty_Node;

      --  Make sure errors are reinitialized before load
      Prj.Err.Initialize;

      Output.Set_Special_Output (Output.Output_Proc (Errors));
      Prj.Com.Fail := Fail'Unrestricted_Access;

      Tree.Data.Root := No_Project;

      Sinput.P.Clear_Source_File_Table;
      Sinput.P.Reset_First;
      Prj.Part.Parse
        (Tree.Data.Tree, Project,
         +Root_Project_Path.Full_Name,
         True,
         Store_Comments    => True,
         Is_Config_File    => False,
         Flags             => Create_Flags (On_Error'Unrestricted_Access),
         Current_Directory => Get_Current_Dir);

      if Project /= Empty_Node then
         Tree.Data.Root := Tree.Instance_From_Node (Project);

         --  Create the project instances, so that we can use the
         --  project_iterator (otherwise Current cannot return a project_type).
         --  These instances, for now, will have now view associated

         Create_Project_Instances (Tree, With_View => False);

         Tree.Data.Status := From_File;

         Prj.Com.Fail := null;
         Output.Cancel_Special_Output;

         if Recompute_View then
            Tree.Recompute_View (Errors => Errors);
         end if;
      end if;

   exception
      when Invalid_Project =>
         Prj.Com.Fail := null;
         Output.Cancel_Special_Output;
         raise;

      when E : others =>
         Trace (Exception_Handle, E);
         Prj.Com.Fail := null;
         Output.Cancel_Special_Output;
         raise;
   end Internal_Load;

   --------------------
   -- Recompute_View --
   --------------------

   procedure Recompute_View
     (Self   : in out Project_Tree;
      Errors : Projects.Error_Report := null)
   is
      procedure Add_GPS_Naming_Schemes_To_Config_File
        (Config_File  : in out Project_Node_Id;
         Project_Tree : Project_Node_Tree_Ref);
      --  Add the naming schemes defined in GPS's configuration files to the
      --  configuration file (.cgpr) used to parse the project.

      procedure On_Error is new Mark_Project_Error (Self);
      --  Any error while processing the project marks it as incomplete, and
      --  prevents direct edition of the project.

      -------------------------------------------
      -- Add_GPS_Naming_Schemes_To_Config_File --
      -------------------------------------------

      procedure Add_GPS_Naming_Schemes_To_Config_File
        (Config_File  : in out Project_Node_Id;
         Project_Tree : Project_Node_Tree_Ref)
      is
         NS   : Naming_Scheme_Access := Self.Data.Env.Naming_Schemes;
         Attr : Project_Node_Id;
         pragma Unreferenced (Attr);
      begin
         if Config_File = Empty_Node then
            --  Create a dummy config file is none was found. In that case we
            --  need to provide the Ada naming scheme as well

            Trace (Me, "Creating dummy configuration file");

            Add_Default_GNAT_Naming_Scheme
              (Config_File, Project_Tree);

            --  Pretend we support shared and static libs. Since we are not
            --  trying to build anyway, this isn't dangerous, and allows
            --  loading some libraries projects which otherwise we could not
            --  load.

            Attr := Create_Attribute
              (Tree       => Project_Tree,
               Prj_Or_Pkg => Config_File,
               Name       => Get_String ("library_support"),
               Kind       => Single,
               Value      => Create_Literal_String
                 (Tree => Project_Tree,
                  Str  => Get_String ("full")));
         end if;

         while NS /= null loop
            if NS.Default_Spec_Suffix.all /= Dummy_Suffix then
               Attr := Create_Attribute
                 (Tree               => Project_Tree,
                  Prj_Or_Pkg         => Create_Package
                    (Tree    => Project_Tree,
                     Project => Config_File,
                     Pkg     => "naming"),
                  Kind               => Single,
                  Name               => Get_String ("spec_suffix"),
                  Index_Name         => Get_String (NS.Language.all),
                  Value              => Create_Literal_String
                    (Tree  => Project_Tree,
                     Str   => Get_String (NS.Default_Spec_Suffix.all)));
            end if;

            if NS.Default_Body_Suffix.all /= Dummy_Suffix then
               Attr := Create_Attribute
                 (Tree               => Project_Tree,
                  Prj_Or_Pkg         => Create_Package
                    (Tree    => Project_Tree,
                     Project => Config_File,
                     Pkg     => "naming"),
                  Kind               => Single,
                  Name               => Get_String ("body_suffix"),
                  Index_Name         => Get_String (NS.Language.all),
                  Value              => Create_Literal_String
                    (Tree  => Project_Tree,
                     Str   => Get_String (NS.Default_Body_Suffix.all)));
            end if;

            NS := NS.Next;
         end loop;
      end Add_GPS_Naming_Schemes_To_Config_File;

      View                    : Project_Id;
      Automatically_Generated : Boolean;
      Config_File_Path        : String_Access;
      Flags                   : Processing_Flags;
      Iter                    : Project_Iterator;
      Timestamp               : Time;

   begin
      Trace (Me, "Recomputing project view");
      Output.Set_Special_Output (Output.Output_Proc (Errors));

      --  Compute the list of scenario variables. This also ensures that
      --  the variables do exist in the environment, and therefore that
      --  we can correctly load the project.

      Compute_Scenario_Variables (Self.Data);

      begin
         Flags := Create_Flags
           (On_Error'Unrestricted_Access, Require_Sources => False);

         --  Make sure errors are reinitialized before load
         Prj.Err.Initialize;

         Process_Project_And_Apply_Config
           (Main_Project               => View,
            User_Project_Node          => Self.Root_Project.Data.Node,
            Config_File_Name           => "",
            Autoconf_Specified         => False,
            Project_Tree               => Self.Data.View,
            Project_Node_Tree          => Self.Data.Tree,
            Packages_To_Check          => null,
            Allow_Automatic_Generation => False,
            Automatically_Generated    => Automatically_Generated,
            Config_File_Path           => Config_File_Path,
            Flags                      => Flags,
            Normalized_Hostname        => "",
            On_Load_Config             =>
              Add_GPS_Naming_Schemes_To_Config_File'Unrestricted_Access);
      exception
         when Invalid_Config =>
            --  Error message was already reported via Prj.Err
            null;
      end;

      if View = null then
         raise Invalid_Project;
      end if;

      Trace (Me, "View has been recomputed");

      --  Now that we have the view, we can create the project instances

      Self.Data.Root.Data.View := View;
      Create_Project_Instances (Self, With_View => True);

      Parse_Source_Files (Self);

      --  If the timestamp have not been computed yet (ie we are loading a new
      --  project), do it now.
      --  We cannot simply use Clock here, since this returns local time,
      --  and the file timestamps will be returned in GMT, therefore we
      --  won't be able to compare.

      if Self.Data.Timestamp = GNATCOLL.Utils.No_Time
        and then Self.Data.Status = From_File
      then
         Iter := Start (Self.Root_Project);

         while Current (Iter) /= No_Project loop
            Timestamp := File_Time_Stamp (Project_Path (Current (Iter)));

            if Timestamp > Self.Data.Timestamp then
               Self.Data.Timestamp := Timestamp;
            end if;

            Next (Iter);
         end loop;
      end if;

      --  ??? Should not be needed since all errors are reported through the
      --  callback already. This avoids duplicate error messages in the console

      Prj.Err.Finalize;
      Output.Cancel_Special_Output;

   exception
      --  We can get an unexpected exception (actually Directory_Error) if the
      --  project file's path is invalid, for instance because it was
      --  modified by the user.

      when Invalid_Project =>
         Trace (Me, "Could not compute project view");
         Prj.Err.Finalize;
         Output.Cancel_Special_Output;
         raise;

      when E : others =>
         Trace (Exception_Handle, E);
         Prj.Err.Finalize;
         Output.Cancel_Special_Output;
   end Recompute_View;

   ------------------------
   -- Instance_From_Node --
   ------------------------

   function Instance_From_Node
     (Self : Project_Tree'Class;
      Node : Project_Node_Id) return Project_Type
   is
      Name : constant String :=
        Get_String (Prj.Tree.Name_Of (Node, Self.Data.Tree));
      Data : constant Project_Data_Access := Self.Data_Factory;
      P    : Project_Type;
   begin
      Data.Tree := Self.Data;
      Data.Node := Node;
      P := Project_Type'(Ada.Finalization.Controlled with Data => Data);
      Self.Data.Projects.Include (Name, P);
      return P;
   end Instance_From_Node;

   ------------------------------
   -- Create_Project_Instances --
   ------------------------------

   procedure Create_Project_Instances
     (Self : in out Project_Tree'Class; With_View : Boolean)
   is
      procedure Do_Project (Proj : Project_Id; S : in out Integer);
      procedure Do_Project (Proj : Project_Id; S : in out Integer) is
         pragma Unreferenced (S);
         Name : constant String := Get_String (Proj.Name);
         Iter : Project_Htables.Cursor;
         P    : Project_Type;

      begin
         --  The project will always exist, since we have already called
         --  Create_Project_Instances once before to create them
         Iter := Self.Data.Projects.Find (Name);
         Assert (Me, Has_Element (Iter),
                 "Create_Project_Instances must be called"
                 & " to create project_type");
         P := Element (Iter);
         Reset_View (P.Data.all);
         P.Data.View := Proj;
      end Do_Project;

      procedure Do_Project2 (T : Project_Node_Tree_Ref; P : Project_Node_Id);
      procedure Do_Project2 (T : Project_Node_Tree_Ref; P : Project_Node_Id) is
         Name : constant String := Get_String (Prj.Tree.Name_Of (P, T));
         Proj : Project_Type;
         Iter : Project_Htables.Cursor;
         pragma Unreferenced (Proj);
      begin
         Iter := Self.Data.Projects.Find (Name);
         if not Has_Element (Iter) then
            Proj := Self.Instance_From_Node (P);
         end if;
      end Do_Project2;

      procedure For_All_Projects is new For_Every_Project_Imported
        (Integer, Do_Project);

      S : Integer := 0;
   begin
      if With_View then
         Assert (Me, Self.Data.Root.Data.View /= null,
                 "Create_Project_Instances: Project not parsed");
         For_All_Projects (Self.Data.Root.Data.View, S);

      else
         For_Each_Project_Node
           (Self.Data.Tree, Self.Data.Root.Data.Node,
            Do_Project2'Unrestricted_Access);
      end if;
   end Create_Project_Instances;

   ------------------------
   -- Load_Empty_Project --
   ------------------------

   procedure Load_Empty_Project
     (Self : in out Project_Tree;
      Env  : Project_Environment_Access := null;
      Name : String := "empty";
      Recompute_View : Boolean := True)
   is
      D : constant Filesystem_String :=
            Name_As_Directory (Get_Current_Dir)
            & (+Name) & Project_File_Extension;
      Node : Project_Node_Id;
   begin
      Self.Unload;
      Reset (Self, Env);

      Node := Prj.Tree.Create_Project
        (In_Tree        => Self.Data.Tree,
         Name           => Get_String (Name),
         Full_Path      => Path_Name_Type (Get_String (+D)),
         Is_Config_File => False);

      Self.Data.Root := Self.Instance_From_Node (Node);

      --  No language known for empty project

      Self.Data.Root.Set_Attribute (Languages_Attribute, (1 .. 0 => null));

      Self.Data.Root.Data.Modified := False;

      Create_Project_Instances (Self, With_View => False);

      if Recompute_View then
         Project_Tree'Class (Self).Recompute_View;
      end if;
   end Load_Empty_Project;

   ------------------------
   -- Parse_Source_Files --
   ------------------------

   procedure Parse_Source_Files (Self : in out Project_Tree) is
      procedure Register_Directory (Directory : Filesystem_String);
      --  Register Directory as belonging to Project.
      --  The parent directories are also registered.

      ------------------------
      -- Register_Directory --
      ------------------------

      procedure Register_Directory (Directory : Filesystem_String) is
         Dir  : constant Filesystem_String := Name_As_Directory (Directory);
         Last : Integer := Dir'Last - 1;
         Curs : Directory_Statuses.Cursor;
      begin
         Self.Data.Directories.Include (Dir, Direct);

         loop
            while Last >= Dir'First
              and then Dir (Last) /= Directory_Separator
              and then Dir (Last) /= '/'
            loop
               Last := Last - 1;
            end loop;

            Last := Last - 1;

            exit when Last <= Dir'First;

            --  Register the name with a trailing directory separator

            Curs := Self.Data.Directories.Find (Dir (Dir'First .. Last + 1));
            if not Has_Element (Curs) or else Element (Curs) /= Direct then
               Self.Data.Directories.Include
                 (Dir (Dir'First .. Last + 1), As_Parent);
            end if;
         end loop;
      end Register_Directory;

      use Virtual_File_List;

      Gnatls           : constant String :=
        Self.Root_Project.Attribute_Value (Gnatlist_Attribute);
      Iter             : Project_Iterator;
      Sources          : String_List_Id;
      P                : Project_Type;
      Source_Iter      : Source_Iterator;
      Source           : Source_Id;
      Source_File_List : Virtual_File_List.List;

   begin
      Trace (Me, "Parse source files");

      Iter := Self.Root_Project.Start (Recursive => True);

      loop
         P := Current (Iter);
         exit when P = No_Project;

         declare
            Ls : constant String := P.Attribute_Value (Gnatlist_Attribute);
         begin
            if Ls /= "" and then Ls /= Gnatls then
               --  We do not want to mark the project as incomplete for this
               --  warning, so we do not need to pass an actual Error_Handler
               Prj.Err.Error_Msg
                 (Flags => Create_Flags (null),
                  Msg   =>
                   "?the project attribute IDE.gnatlist doesn't have"
                  & " the same value as in the root project."
                  & " The value """ & Gnatls & """ will be used",
                  Project => Get_View (P));
            end if;
         end;

         --  Reset the list of source files for this project. We must not
         --  Free it, since it is now stored in the previous project's instance

         Source_File_List := Virtual_File_List.Empty_List;

         --  Add the directories

         Sources := Get_View (P).Source_Dirs;
         while Sources /= Nil_String loop
            Register_Directory
              (+Get_String (String_Elements (Self.Data)(Sources).Value));
            Sources := String_Elements (Self.Data)(Sources).Next;
         end loop;

         Register_Directory (+Get_String (Get_View (P).Object_Directory.Name));
         Register_Directory (+Get_String (Get_View (P).Exec_Directory.Name));

         --  Add the sources that are already in the project.
         --  Convert the names to UTF8 for proper handling in GPS

         Source_Iter := For_Each_Source (Self.Data.View, Get_View (P));
         loop
            Source := Element (Source_Iter);
            exit when Source = No_Source;

            --  Get the absolute path name for this source
            Get_Name_String (Source.Path.Display_Name);

            declare
               File : constant Virtual_File :=
                        Create (+Name_Buffer (1 .. Name_Len));
            begin
               Self.Data.Sources.Include
                 (Base_Name (File),
                  (P, File, Source.Language.Name, Source));

               --  The project manager duplicates files that contain several
               --  units. Only add them once in the project sources (and thus
               --  only when the Index is 0 (single unit) or 1 (first of
               --  multiple units)
               --  For source-based languages, we allow duplicate sources

               if Source.Unit = null or else Source.Index <= 1 then
                  Prepend (Source_File_List, File);
               end if;
            end;

            Next (Source_Iter);
         end loop;

         --  Register the sources in our own caches

         declare
            Count   : constant Ada.Containers.Count_Type :=
                        Virtual_File_List.Length (Source_File_List);
            Files   : constant File_Array_Access :=
                        new File_Array (1 .. Natural (Count));
            Current : Virtual_File_List.Cursor := First (Source_File_List);
            J       : Natural := Files'First;
         begin
            while Has_Element (Current) loop
               Files (J) := Element (Current);
               Next (Current);
               J := J + 1;
            end loop;

            Unchecked_Free (P.Data.Files);
            P.Data.Files := Files;
         end;

         Next (Iter);
      end loop;
   end Parse_Source_Files;

   ------------
   -- Unload --
   ------------

   procedure Unload (Self : in out Project_Tree) is
      Iter : Project_Htables.Cursor;
      Data : Project_Data_Access;

   begin
      if Self.Data = null then
         return;
      end if;

      Iter := Self.Data.Projects.First;

      --  Since we are going to free the tree, removing any reference to it in
      --  the projects that the user might keep around

      while Has_Element (Iter) loop
         Data := Element (Iter).Data;
         Data.Tree := null;
         Data.View := null;
         Data.Node := Empty_Node;
         Next (Iter);
      end loop;

      --  We should not reset the environment variables, which might have
      --  been set by the user already.
      --  Prj.Ext.Reset (Registry.Data.Tree);

      if Self.Data.View /= null then
         Reset (Self.Data.View);
      end if;

      Prj.Tree.Tree_Private_Part.Projects_Htable.Reset
        (Self.Data.Tree.Projects_HT);
      Sinput.P.Clear_Source_File_Table;
      Sinput.P.Reset_First;

      Self.Data.Sources.Clear;
      Self.Data.Directories.Clear;
      Unchecked_Free (Self.Data.Scenario_Variables);

      --  Free all projects. This will decrease the refcounting for their data
      --  and possibly free the memory

      Self.Data.Projects.Clear;

      --  Do not reset the tree node, since it also contains the environment
      --  variables, which we want to preserve in case the user has changed
      --  them before loading the project.

      Initialize (Self.Data.Tree);
      Free (Self.Data.View);
   end Unload;

   -----------------
   -- Is_Editable --
   -----------------

   function Is_Editable (Project : Project_Type) return Boolean is
   begin
      return not Project.Data.Uses_Variables
        and then Project.Data.View_Is_Complete;
   end Is_Editable;

   --------------
   -- Finalize --
   --------------

   procedure Finalize is
   begin
      Namet.Finalize;
   end Finalize;

   ---------
   -- Put --
   ---------

   procedure Put (Self : in out Pretty_Printer; C : Character) is
      pragma Unreferenced (Self);
   begin
      Ada.Text_IO.Put (C);
   end Put;

   ---------
   -- Put --
   ---------

   procedure Put (Self : in out Pretty_Printer; S : String) is
   begin
      for C in S'Range loop
         Put (Pretty_Printer'Class (Self), S (C));
      end loop;
   end Put;

   --------------
   -- New_Line --
   --------------

   procedure New_Line (Self : in out Pretty_Printer) is
   begin
      Put (Pretty_Printer'Class (Self), ASCII.LF);
   end New_Line;

   ---------
   -- Put --
   ---------

   procedure Put
     (Self                 : in out Pretty_Printer;
      Project              : Project_Type'Class;
      Increment            : Positive              := 3;
      Eliminate_Empty_Case_Constructions : Boolean := False)
   is
      procedure W_Char (C : Character);
      procedure W_Eol;
      procedure W_Str  (S : String);

      procedure W_Char (C : Character) is
      begin
         Put (Pretty_Printer'Class (Self), C);
      end W_Char;

      procedure W_Eol is
      begin
         New_Line (Pretty_Printer'Class (Self));
      end W_Eol;

      procedure W_Str (S : String) is
      begin
         Put (Pretty_Printer'Class (Self), S);
      end W_Str;

   begin
      Prj.PP.Pretty_Print
        (Project                            => Project.Data.Node,
         In_Tree                            => Project.Data.Tree.Tree,
         Increment                          => Increment,
         Eliminate_Empty_Case_Constructions =>
           Eliminate_Empty_Case_Constructions,
         Minimize_Empty_Lines               => False,
         W_Char                             => W_Char'Unrestricted_Access,
         W_Eol                              => W_Eol'Unrestricted_Access,
         W_Str                              => W_Str'Unrestricted_Access,
         Backward_Compatibility             => False,
         Id                                 => Project.Data.View);
   end Put;

   ----------
   -- Node --
   ----------

   function Node
     (Project : Project_Type'Class) return Prj.Tree.Project_Node_Id is
   begin
      return Project.Data.Node;
   end Node;

   ----------
   -- Tree --
   ----------

   function Tree
     (Data : Project_Tree_Data_Access) return Prj.Tree.Project_Node_Tree_Ref is
   begin
      return Data.Tree;
   end Tree;

   -------------------
   -- Set_Attribute --
   -------------------

   procedure Set_Attribute
     (Self      : Project_Type;
      Attribute : Attribute_Pkg_List;
      Values    : GNAT.Strings.String_List;
      Scenario  : Scenario_Variable_Array := All_Scenarios;
      Index     : String := "";
      Prepend   : Boolean := False) is
   begin
      GNATCOLL.Projects.Normalize.Set_Attribute
        (Self.Data.Tree, Self, Attribute, Values, Scenario, Index, Prepend);
   end Set_Attribute;

   procedure Set_Attribute
     (Self      : Project_Type;
      Attribute : Attribute_Pkg_String;
      Value     : String;
      Scenario  : Scenario_Variable_Array := All_Scenarios;
      Index     : String := "") is
   begin
      GNATCOLL.Projects.Normalize.Set_Attribute
        (Self.Data.Tree, Self, Attribute, Value, Scenario, Index);
   end Set_Attribute;

   ----------------------
   -- Delete_Attribute --
   ----------------------

   procedure Delete_Attribute
     (Self      : Project_Type;
      Attribute : Attribute_Pkg_String;
      Scenario  : Scenario_Variable_Array := All_Scenarios;
      Index     : String := "") is
   begin
      GNATCOLL.Projects.Normalize.Delete_Attribute
        (Self.Data.Tree, Self, String (Attribute), Scenario, Index);
   end Delete_Attribute;

   procedure Delete_Attribute
     (Self      : Project_Type;
      Attribute : Attribute_Pkg_List;
      Scenario  : Scenario_Variable_Array := All_Scenarios;
      Index     : String := "") is
   begin
      GNATCOLL.Projects.Normalize.Delete_Attribute
        (Self.Data.Tree, Self, String (Attribute), Scenario, Index);
   end Delete_Attribute;

   ---------------------
   -- Rename_And_Move --
   ---------------------

   procedure Rename_And_Move
     (Self      : Project_Type;
      New_Name  : String;
      Directory : GNATCOLL.VFS.Virtual_File;
      Errors    : Error_Report := null) is
   begin
      GNATCOLL.Projects.Normalize.Rename_And_Move
        (Self.Data.Tree, Self, New_Name, Directory, Errors);

      Self.Data.Tree.Projects.Delete  (Self.Name);
      Self.Data.Tree.Projects.Include (New_Name, Self);

      if Self.Data.View /= Prj.No_Project then
         Self.Data.View.Display_Name := Get_String (New_Name);
      end if;

      --  This is no longer the default project, since it was
      --  renamed. Otherwise, Project_Path would still return "" when saving
      --  the default project.

      Self.Data.Tree.Status := From_File;

      Reset_All_Caches (Self.Data.Tree);
   end Rename_And_Move;

   ----------------------------
   -- Register_New_Attribute --
   ----------------------------

   function Register_New_Attribute
     (Name    : String;
      Pkg     : String;
      Is_List : Boolean := False;
      Indexed : Boolean := False;
      Case_Sensitive_Index : Boolean := False) return String
   is
      Pkg_Id             : Package_Node_Id := Empty_Package;
      Attr_Id            : Attribute_Node_Id;
      Attr_Kind          : Defined_Attribute_Kind;
      Var_Kind           : Defined_Variable_Kind;
   begin
      if Pkg /= "" then
         Pkg_Id := Package_Node_Id_Of (Get_String (Pkg));
         if Pkg_Id = Empty_Package then
            Trace (Me, "Register_New_Package (" & Pkg & ")");
            Register_New_Package (Name  => Pkg, Id => Pkg_Id);
         end if;
      end if;

      if Pkg_Id = Empty_Package then
         Attr_Id := Attribute_Node_Id_Of
           (Name        => Get_String (Name),
            Starting_At => Prj.Attr.Attribute_First);
      else
         Attr_Id := Attribute_Node_Id_Of
           (Name        => Get_String (Name),
            Starting_At => First_Attribute_Of (Pkg_Id));
      end if;

      if Is_List then
         Var_Kind := Prj.List;
      else
         Var_Kind := Prj.Single;
      end if;

      if Indexed then
         if Case_Sensitive_Index then
            Attr_Kind := Prj.Attr.Associative_Array;
         else
            Attr_Kind := Prj.Attr.Case_Insensitive_Associative_Array;
         end if;

         --  Priority is given to the registered type
         if Attr_Id /= Empty_Attribute then
            Attr_Kind := Attribute_Kind_Of (Attr_Id);
            if Attr_Kind = Attribute_Kind'(Single) then
               Attr_Kind := Prj.Attr.Associative_Array;
            end if;
         end if;
      else
         Attr_Kind := Attribute_Kind'(Single);
      end if;

      if Attr_Id = Empty_Attribute then
         if Pkg = "" then
            return "Project attributes cannot be added at the top level of"
              & " project files, only in packages";

         else
            if Active (Me) then
               Trace (Me, "Register_New_Attribute (" & Name
                      & ", " & Pkg & ", " & Attr_Kind'Img & ", "
                      & Var_Kind'Img & ")");
            end if;

            Register_New_Attribute
              (Name               => Name,
               In_Package         => Pkg_Id,
               Attr_Kind          => Attr_Kind,
               Var_Kind           => Var_Kind,
               Index_Is_File_Name => False,
               Opt_Index          => False);
         end if;

      else
         if Attribute_Kind_Of (Attr_Id) /= Attr_Kind
           or else Variable_Kind_Of (Attr_Id) /= Var_Kind
         then
            return Name
              & ": attributes was already defined but with a"
              & " different type";
         end if;
      end if;

      return "";
   end Register_New_Attribute;

   ----------
   -- Save --
   ----------

   function Save
     (Project : Project_Type;
      Force   : Boolean := False;
      Errors  : Error_Report := null) return Boolean
   is
      File     : Ada.Text_IO.File_Type;

      type File_Pretty_Printer is new Pretty_Printer with null record;
      overriding procedure Put
        (Self : in out File_Pretty_Printer; C : Character);
      overriding procedure Put (Self : in out File_Pretty_Printer; S : String);

      overriding procedure Put
        (Self : in out File_Pretty_Printer; C : Character)
      is
         pragma Unreferenced (Self);
      begin
         Put (File, C);
      end Put;

      overriding procedure Put
        (Self : in out File_Pretty_Printer; S : String)
      is
         pragma Unreferenced (Self);
      begin
         Put (File, S);
      end Put;

      PP : File_Pretty_Printer;

   begin
      if not Is_Regular_File (Project.Project_Path)
        or else Project.Data.Modified
        or else Force
      then
         if Is_Regular_File (Project_Path (Project))
           and then not Is_Writable (Project_Path (Project))
         then
            if Errors /= null then
               Errors
                 ("The file " & Display_Full_Name (Project_Path (Project))
                  & " is not writable. Project not saved");
            end if;
            Trace (Me, "Project file not writable: "
                   & Project_Path (Project).Display_Full_Name);
            return False;
         end if;

         declare
            Filename : constant Virtual_File := Project_Path (Project);
            Dirname  : Virtual_File renames Dir (Filename);
         begin
            Trace (Me, "Save_Project: Creating new file "
                   & Filename.Display_Full_Name);

            begin
               Ada.Directories.Create_Path (Dirname.Display_Full_Name);
            exception
               when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
                  Trace (Me, "Couldn't create directory " &
                         Dirname.Display_Full_Name);

                  if Errors /= null then
                     Errors
                       ("Couldn't create directory " &
                        Dirname.Display_Full_Name);
                  end if;

                  return False;
            end;

            Normalize_Cases (Project.Data.Tree.Tree, Project);

            Create (File, Mode => Out_File, Name => +Full_Name (Filename));
            PP.Put (Project => Project);
            Close (File);

            Project.Data.Modified := False;
            Project.Data.Tree.Status := From_File;
            return True;

         exception
            when Ada.Text_IO.Name_Error =>
               Trace (Me, "Couldn't create " & Filename.Display_Full_Name);

               if Errors /= null then
                  Errors
                    ("Couldn't create file " & Filename.Display_Full_Name);
               end if;

               return False;
         end;
      end if;
      return False;
   end Save;

   --------------
   -- Modified --
   --------------

   function Modified
     (Project   : Project_Type;
      Recursive : Boolean := False) return Boolean
   is
      Iter : Project_Iterator := Start (Project, Recursive);
      P    : Project_Type;
   begin
      loop
         P := Current (Iter);
         exit when P = GNATCOLL.Projects.No_Project;

         if P.Data.Modified then
            return True;
         end if;
         Next (Iter);
      end loop;

      return False;
   end Modified;

   ------------------
   -- Set_Modified --
   ------------------

   procedure Set_Modified (Project : Project_Type; Modified : Boolean) is
   begin
      Project.Data.Modified := Modified;
   end Set_Modified;

   -----------------------------
   -- Remove_Imported_Project --
   -----------------------------

   procedure Remove_Imported_Project
     (Project          : Project_Type;
      Imported_Project : Project_Type)
   is
      Tree        : constant Project_Node_Tree_Ref := Project.Data.Tree.Tree;
      With_Clause : Project_Node_Id :=
                      First_With_Clause_Of (Project.Node, Tree);
      Next        : Project_Node_Id;
   begin
      --  ??? When the project is no longer found in the hierarchy, it should
      --  also be removed from the htable in Prj.Tree, so that another
      --  project by that name can be loaded.

      if With_Clause /= Empty_Node
        and then Prj.Tree.Name_Of (With_Clause, Tree) =
        Prj.Tree.Name_Of (Imported_Project.Node, Tree)
      then
         Set_First_With_Clause_Of
           (Project.Node, Tree, Next_With_Clause_Of (With_Clause, Tree));
      else
         loop
            Next := Next_With_Clause_Of (With_Clause, Tree);
            exit when Next = Empty_Node;

            if Prj.Tree.Name_Of (Next, Tree) =
              Prj.Tree.Name_Of (Imported_Project.Node, Tree)
            then
               Set_Next_With_Clause_Of
                 (With_Clause, Tree, Next_With_Clause_Of (Next, Tree));
            end if;

            With_Clause := Next;
         end loop;
      end if;

      Project.Data.Modified := True;

      --  Need to reset all the caches, since the caches contain the indirect
      --  dependencies as well.
      Reset_All_Caches (Project.Data.Tree);
   end Remove_Imported_Project;

   ----------------------
   -- Reset_All_Caches --
   ----------------------

   procedure Reset_All_Caches (Tree : Project_Tree_Data_Access) is
      Cursor : Project_Htables.Cursor := Tree.Projects.First;
   begin
      while Has_Element (Cursor) loop
         Unchecked_Free (Element (Cursor).Data.Imported_Projects);
         Unchecked_Free (Element (Cursor).Data.Importing_Projects);
         Next (Cursor);
      end loop;
   end Reset_All_Caches;

   --------------------------
   -- Add_Imported_Project --
   --------------------------

   function Add_Imported_Project
     (Tree                      : Project_Tree;
      Project                   : Project_Type'Class;
      Imported_Project_Location : GNATCOLL.VFS.Virtual_File;
      Errors                    : Error_Report := null;
      Use_Relative_Path         : Boolean := True;
      Use_Base_Name             : Boolean := False;
      Limited_With              : Boolean := False)
      return Import_Project_Error
   is
      Tree_Node : constant Project_Node_Tree_Ref := Project.Data.Tree.Tree;
      use Prj.Tree.Tree_Private_Part;

      procedure Fail (S : String);
      procedure Fail (S : String) is
      begin
         if Errors /= null then
            Errors (S);
         end if;
      end Fail;

      Basename         : constant Filesystem_String := Base_Name
        (Imported_Project_Location, Project_File_Extension);
      Imported_Project : Project_Node_Id := Empty_Node;
      Dep_ID           : Name_Id;
      Dep_Name         : Prj.Tree.Tree_Private_Part.Project_Name_And_Node;

   begin
      Output.Set_Special_Output (Fail'Unrestricted_Access);
      Prj.Com.Fail := Fail'Unrestricted_Access;

      Dep_ID := Get_String (+Basename);

      Dep_Name := Tree_Private_Part.Projects_Htable.Get
        (Tree_Node.Projects_HT, Dep_ID);

      if Dep_Name /= No_Project_Name_And_Node then
         --  ??? We used to compare on the build server, but that might not be
         --  necessary (and we do not have access to this information in
         --  GNATCOLL in any case).
         if not File_Equal
           (Format_Pathname
              (+Get_String (Path_Name_Of (Dep_Name.Node, Tree_Node))),
            Imported_Project_Location.Full_Name,
            Local_Host)
         then
            Fail
              ("A different project with the same name"
               & " already exists in the project tree.");
            Output.Cancel_Special_Output;
            Prj.Com.Fail := null;
            return Project_Already_Exists;
         else
            Imported_Project := Dep_Name.Node;
         end if;

      else
         Prj.Part.Parse
           (Tree_Node, Imported_Project,
            +Full_Name (Imported_Project_Location),
            Is_Config_File         => False,
            Current_Directory      => Get_Current_Dir,
            Flags                  => Create_Flags (null, False),
            Always_Errout_Finalize => True);

         Prj.Err.Finalize;
      end if;

      if Imported_Project = Empty_Node then
         Trace (Me, "Add_Imported_Project: imported project not found ("
                & Imported_Project_Location.Display_Full_Name & ")");
         Output.Cancel_Special_Output;
         Prj.Com.Fail := null;
         return Imported_Project_Not_Found;
      end if;

      Compute_Importing_Projects (Project);
      return Add_Imported_Project
        (Tree                      => Project.Data.Tree,
         Project                   => Project,
         Imported_Project          =>
           Tree.Instance_From_Node (Imported_Project),
         Errors                    => Errors,
         Use_Relative_Path         => Use_Relative_Path,
         Use_Base_Name             => Use_Base_Name,
         Limited_With              => Limited_With);
   end Add_Imported_Project;

   --------------------------
   -- Add_Imported_Project --
   --------------------------

   function Add_Imported_Project
     (Project           : Project_Type;
      Imported_Project  : Project_Type;
      Errors            : Error_Report := null;
      Use_Relative_Path : Boolean := True;
      Use_Base_Name     : Boolean := False;
      Limited_With      : Boolean := False) return Import_Project_Error is
   begin
      Compute_Importing_Projects (Project);
      return GNATCOLL.Projects.Normalize.Add_Imported_Project
        (Tree                      => Project.Data.Tree,
         Project                   => Project,
         Imported_Project          => Imported_Project,
         Errors                    => Errors,
         Use_Relative_Path         => Use_Relative_Path,
         Use_Base_Name             => Use_Base_Name,
         Limited_With              => Limited_With);
   end Add_Imported_Project;

   ------------------------------
   -- Delete_Scenario_Variable --
   ------------------------------

   procedure Delete_Scenario_Variable
     (Tree                     : Project_Tree'Class;
      External_Name            : String;
      Keep_Choice              : String;
      Delete_Direct_References : Boolean := True) is
   begin
      if not Tree.Root_Project.Is_Editable then
         Trace (Me, "Project is not editable");
         return;
      end if;

      GNATCOLL.Projects.Normalize.Delete_Scenario_Variable
        (Tree.Data, Tree.Root_Project,
         External_Name, Keep_Choice, Delete_Direct_References);

      --  Mark all projects in the hierarchy as modified, since they are
      --  potentially all impacted.

      declare
         Cursor : Project_Htables.Cursor := Tree.Data.Projects.First;
      begin
         while Has_Element (Cursor) loop
            Element (Cursor).Set_Modified (True);
            Next (Cursor);
         end loop;
      end;
   end Delete_Scenario_Variable;

   -----------------
   -- Rename_Path --
   -----------------

   function Rename_Path
     (Self               : Project_Type;
      Old_Path           : GNATCOLL.VFS.Virtual_File;
      New_Path           : GNATCOLL.VFS.Virtual_File;
      Use_Relative_Paths : Boolean) return Boolean
   is
   begin
      return GNATCOLL.Projects.Normalize.Rename_Path
        (Self.Data.Tree, Self, Old_Path, New_Path, Use_Relative_Paths);
   end Rename_Path;

   --------------------
   -- Create_Project --
   --------------------

   function Create_Project
     (Tree     : Project_Tree'Class;
      Name     : String;
      Path     : GNATCOLL.VFS.Virtual_File) return Project_Type
   is
      D : constant Filesystem_String :=
            Name_As_Directory (Path.Full_Name)
            & (+Translate (To_Lower (Name), To_Mapping (".", "-")))
            & GNATCOLL.Projects.Project_File_Extension;
      Project   : constant Project_Node_Id :=
        Prj.Tree.Create_Project
          (In_Tree        => Tree.Data.Tree,
           Name           => Get_String (Name),
           Full_Path      => Path_Name_Type (Get_String (+D)),
           Is_Config_File => False);

      P       : Project_Type;
   begin
      P := Tree.Instance_From_Node (Project);
      P.Set_Modified (True);
      return P;
   end Create_Project;

   --------------------------
   -- Set_Extended_Project --
   --------------------------

   procedure Set_Extended_Project
     (Self               : GNATCOLL.Projects.Project_Type;
      Extended           : GNATCOLL.Projects.Project_Type;
      Extend_All         : Boolean := False;
      Use_Relative_Paths : Boolean := False)
   is
   begin
      if Use_Relative_Paths then
         declare
            Path : constant Filesystem_String :=
                     Relative_Path (Extended.Project_Path,
                                    Self.Project_Path);
         begin
            Set_Extended_Project_Path_Of
              (Self.Data.Node,
               Self.Data.Tree.Tree,
               To => Path_Name_Type (Get_String (+Path)));
         end;
      else
         Set_Extended_Project_Path_Of
           (Self.Data.Node,
            Self.Data.Tree.Tree,
            To => Path_Name_Type
              (Get_String (+Extended.Project_Path.Full_Name)));
      end if;

      Set_Extended_Project_Of
        (Project_Declaration_Of (Self.Data.Node, Self.Data.Tree.Tree),
         Self.Data.Tree.Tree,
         To => Extended.Node);

      if Extend_All then
         Set_Is_Extending_All (Self.Data.Node, Self.Data.Tree.Tree);
      end if;
   end Set_Extended_Project;

   ------------------------------
   -- Create_Scenario_Variable --
   ------------------------------

   function Create_Scenario_Variable
     (Project       : Project_Type;
      Name          : String;
      Type_Name     : String;
      External_Name : String) return Scenario_Variable
   is
      Tree_Node     : constant Project_Node_Tree_Ref := Project.Data.Tree.Tree;
      Typ, Var : Project_Node_Id;
   begin
      if not Project.Is_Editable then
         Trace (Me, "Project is not editable");
         return GNATCOLL.Projects.No_Variable;
      end if;

      GNATCOLL.Projects.Normalize.Normalize (Project.Data.Tree, Project);
      Typ := Create_Type (Tree_Node, Project.Data.Node, Type_Name);
      Var := Create_Typed_Variable
        (Tree_Node, Project.Data.Node, Name, Typ,
         Add_Before_First_Case_Or_Pkg => True);
      Set_Value_As_External (Tree_Node, Var, External_Name);

      Project.Set_Modified (True);

      Unchecked_Free (Project.Data.Tree.Scenario_Variables);

      return (Name        => Get_String (External_Name),
              Default     => No_Name,
              Value       => No_Name,
              String_Type => Typ);
   end Create_Scenario_Variable;

   --------------------------
   -- Change_External_Name --
   --------------------------

   procedure Change_External_Name
     (Tree     : Project_Tree'Class;
      Variable : in out Scenario_Variable;
      New_Name : String)
   is
      Tree_Node : constant Project_Node_Tree_Ref := Tree.Data.Tree;

      procedure Callback (Project, Parent, Node, Choice : Project_Node_Id);
      --  Called for each mtching node for the env. variable

      --------------
      -- Callback --
      --------------

      procedure Callback (Project, Parent, Node, Choice : Project_Node_Id) is
         pragma Unreferenced (Project, Parent, Choice);
      begin
         if Kind_Of (Node, Tree_Node) = N_External_Value then
            Set_String_Value_Of
              (External_Reference_Of (Node, Tree_Node), Tree_Node,
               Get_String (New_Name));
         end if;
      end Callback;

      Ext_Ref : constant Name_Id := Get_String (External_Name (Variable));
   begin
      if not Tree.Root_Project.Is_Editable then
         Trace (Me, "Project is not editable");
         return;
      end if;

      GNATCOLL.Projects.Normalize.Normalize (Tree.Data, Tree.Root_Project);
      For_Each_Environment_Variable
        (Tree.Data.Tree,
         Tree.Root_Project,
         Ext_Ref, No_Name, Callback'Unrestricted_Access);

      Tree.Root_Project.Set_Modified (True);

      --  Create the new variable, to avoid errors when computing the view of
      --  the project.
      Variable.Name := Get_String (New_Name);

      Tree.Change_Environment ((1 => Variable));
   end Change_External_Name;

   -----------------------
   -- Set_Default_Value --
   -----------------------

   procedure Set_Default_Value
     (Tree          : Project_Tree'Class;
      External_Name : String;
      Default       : String)
   is
      Tree_Node : constant Project_Node_Tree_Ref := Tree.Data.Tree;

      procedure Callback (Project, Parent, Node, Choice : Project_Node_Id);
      --  Called for each mtching node for the env. variable

      --------------
      -- Callback --
      --------------

      procedure Callback (Project, Parent, Node, Choice : Project_Node_Id) is
         pragma Unreferenced (Project, Parent, Choice);
      begin
         if Kind_Of (Node, Tree_Node) = N_Typed_Variable_Declaration then
            Set_External_Default_Of
              (Current_Term
                 (First_Term (Expression_Of (Node, Tree_Node), Tree_Node),
                  Tree_Node),
               Tree_Node,
               Enclose_In_Expression
                 (Create_Literal_String (Get_String (Default), Tree_Node),
                  Tree_Node));
         end if;
      end Callback;

   begin
      if not Tree.Root_Project.Is_Editable then
         Trace (Me, "Project is not editable");
         return;
      end if;

      For_Each_Environment_Variable
        (Tree.Data.Tree, Tree.Root_Project,
         Get_String (External_Name), No_Name,
         Callback'Unrestricted_Access);
      Tree.Root_Project.Set_Modified (True);
   end Set_Default_Value;

   ------------------
   -- Rename_Value --
   ------------------

   procedure Rename_Value
     (Tree          : Project_Tree'Class;
      External_Name : String;
      Old_Value     : String;
      New_Value     : String)
   is
      Tree_N : constant Project_Node_Tree_Ref := Tree.Data.Tree;
      Old_V  : constant Name_Id := Get_String (Old_Value);
      New_V  : constant Name_Id := Get_String (New_Value);
      N      : constant Name_Id := Get_String (External_Name);

      procedure Callback (Project, Parent, Node, Choice : Project_Node_Id);
      --  Called for each mtching node for the env. variable

      --------------
      -- Callback --
      --------------

      procedure Callback (Project, Parent, Node, Choice : Project_Node_Id) is
         pragma Unreferenced (Project, Parent);
         C : Project_Node_Id;
      begin
         case Kind_Of (Node, Tree_N) is
            when N_External_Value =>
               if External_Default_Of (Node, Tree_N) /= Empty_Node
                 and then Expression_As_String
                   (Tree_N, External_Default_Of (Node, Tree_N)) = Old_V
               then
                  if Kind_Of (External_Default_Of (Node, Tree_N), Tree_N) =
                    N_Literal_String
                  then
                     Set_String_Value_Of
                       (External_Default_Of (Node, Tree_N), Tree_N, New_V);
                  else
                     Set_External_Default_Of
                       (Node, Tree_N, Create_Literal_String (New_V, Tree_N));
                  end if;
               end if;

            when N_String_Type_Declaration =>
               C := First_Literal_String (Node, Tree_N);
               while C /= Empty_Node loop
                  if String_Value_Of (C, Tree_N) = Old_V then
                     Set_String_Value_Of (C, Tree_N, New_V);
                     exit;
                  end if;
                  C := Next_Literal_String (C, Tree_N);
               end loop;

            when N_Case_Item =>
               Set_String_Value_Of (Choice, Tree_N, New_V);

            when others =>
               null;
         end case;
      end Callback;

   begin
      if not Tree.Root_Project.Is_Editable then
         Trace (Me, "Project is not editable");
         return;
      end if;

      GNATCOLL.Projects.Normalize.Normalize (Tree.Data, Tree.Root_Project);
      For_Each_Environment_Variable
        (Tree.Data.Tree, Tree.Root_Project,
         N, Old_V, Callback'Unrestricted_Access);

      if Prj.Ext.Value_Of (Tree_N, N) /= No_Name
        and then Prj.Ext.Value_Of (Tree_N, N) = Old_V
      then
         Prj.Ext.Add (Tree_N, External_Name, New_Value);
      end if;

      Tree.Root_Project.Set_Modified (True);
   end Rename_Value;

   ------------------
   -- Remove_Value --
   ------------------

   procedure Remove_Value
     (Tree          : Project_Tree'Class;
      External_Name : String;
      Value         : String)
   is
      Tree_N          : constant Project_Node_Tree_Ref := Tree.Data.Tree;
      Delete_Variable : exception;
      Type_Decl       : Project_Node_Id := Empty_Node;
      V_Name          : constant Name_Id := Get_String (Value);
      Ext_Var         : constant Name_Id := Get_String (External_Name);

      procedure Callback (Project, Parent, Node, Choice : Project_Node_Id);
      --  Called for each matching node for the env. variable

      --------------
      -- Callback --
      --------------

      procedure Callback (Project, Parent, Node, Choice : Project_Node_Id) is
         pragma Unreferenced (Project, Choice);
         C, C2 : Project_Node_Id;
      begin
         case Kind_Of (Node, Tree_N) is
            when N_String_Type_Declaration =>
               Type_Decl := Node;

               C := First_Literal_String (Node, Tree_N);

               if Next_Literal_String (C, Tree_N) = Empty_Node then
                  raise Delete_Variable;
               end if;

               if String_Value_Of (C, Tree_N) = V_Name then
                  Set_First_Literal_String
                    (Node, Tree_N, Next_Literal_String (C, Tree_N));
                  return;
               end if;

               loop
                  C2 := Next_Literal_String (C, Tree_N);
                  exit when C2 = Empty_Node;

                  if String_Value_Of (C2, Tree_N) = V_Name then
                     Set_Next_Literal_String
                       (C, Tree_N, Next_Literal_String (C2, Tree_N));
                     exit;
                  end if;
                  C := C2;
               end loop;

            when N_External_Value =>
               if External_Default_Of (Node, Tree_N) /= Empty_Node
                 and then String_Value_Of
                   (External_Default_Of (Node, Tree_N), Tree_N) = V_Name
               then
                  Set_External_Default_Of (Node, Tree_N, Empty_Node);
               end if;

            when N_Case_Item =>
               C := First_Case_Item_Of
                 (Current_Item_Node (Parent, Tree_N), Tree_N);
               if C = Node then
                  Set_First_Case_Item_Of
                    (Current_Item_Node (Parent, Tree_N), Tree_N,
                     Next_Case_Item (C, Tree_N));
                  return;
               end if;

               loop
                  C2 := Next_Case_Item (C, Tree_N);
                  exit when C2 = Empty_Node;

                  if C2 = Node then
                     Set_Next_Case_Item
                       (C, Tree_N, Next_Case_Item (C2, Tree_N));
                  end if;

                  C := C2;
               end loop;

            when others =>
               null;
         end case;
      end Callback;

   begin
      if not Tree.Root_Project.Is_Editable then
         Trace (Me, "Project is not editable");
         return;
      end if;

      GNATCOLL.Projects.Normalize.Normalize (Tree.Data, Tree.Root_Project);
      For_Each_Environment_Variable
        (Tree.Data.Tree, Tree.Root_Project, Ext_Var,
         Get_String (Value), Callback'Unrestricted_Access);

      --  Reset the value of the external variable if needed

      if Prj.Ext.Value_Of (Tree_N, Ext_Var) = V_Name then
         if Type_Decl /= Empty_Node then
            Prj.Ext.Add (Tree_N,
                 External_Name,
                 Get_String (String_Value_Of
                               (First_Literal_String (Type_Decl, Tree_N),
                                Tree_N)));
         else
            Prj.Ext.Add (Tree_N, External_Name, "");
         end if;
      end if;

      Tree.Root_Project.Set_Modified (True);

   exception
      when Delete_Variable =>
         Tree.Delete_Scenario_Variable
           (External_Name            => External_Name,
            Keep_Choice              => Value,
            Delete_Direct_References => False);
   end Remove_Value;

   ----------------
   -- Add_Values --
   ----------------

   procedure Add_Values
     (Tree     : Project_Tree'Class;
      Variable : Scenario_Variable;
      Values   : GNAT.Strings.String_List)
   is
      Tree_N         : constant Project_Node_Tree_Ref := Tree.Data.Tree;
      Type_Node, Var : Project_Node_Id;
      Iter           : Project_Iterator := Tree.Root_Project.Start;
      P              : Project_Type;
   begin
      loop
         P := Current (Iter);
         exit when P = No_Project;

         if not P.Is_Editable then
            Trace (Me, "Project is not editable: " & P.Name);
            return;
         end if;

         GNATCOLL.Projects.Normalize.Normalize (Tree.Data, P);
         Var := Find_Scenario_Variable (Tree_N, P, External_Name (Variable));

         --  If variable is defined in the current project, then modify the
         --  type to Values.

         if Var /= Empty_Node then
            Type_Node := String_Type_Of (Var, Tree_N);
            pragma Assert (Type_Node /= Empty_Node);
            --  Set_First_Literal_String (Type_Node, Empty_Node);

            for J in Values'Range loop
               Add_Possible_Value (Tree_N, Type_Node, Values (J).all);
            end loop;

            P.Set_Modified (True);
         end if;

         Next (Iter);
      end loop;
   end Add_Values;

   ----------
   -- Free --
   ----------

   procedure Free (Self : in out Project_Environment_Access) is
      procedure Internal is new Ada.Unchecked_Deallocation
        (Project_Environment'Class, Project_Environment_Access);
   begin
      Internal (Self);
   end Free;

   procedure Free (Self : in out Project_Tree_Access) is
      procedure Internal is new Ada.Unchecked_Deallocation
        (Project_Tree'Class, Project_Tree_Access);
   begin
      Internal (Self);
   end Free;

begin
   Namet.Initialize;
   Csets.Initialize;
   Snames.Initialize;

   --  Disable verbose messages from project manager, not useful in GPS
   Opt.Quiet_Output := True;
end GNATCOLL.Projects;