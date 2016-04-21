(** Build system. *)
open Printf
let failwithf fmt = ksprintf (fun s () -> failwith s) fmt
let (/) = Ocamlbuild_plugin.(/)

module String = struct
  include String
  let hash = Hashtbl.hash
  let equal = ( = )
end

module List0 = struct
  include List
  include ListLabels

  let diff a b =
    filter a ~f:(fun x -> not (mem x b))

  let is_uniq ~cmp (l : 'a list) : bool =
    let m = length l in
    let n = length (sort_uniq cmp l) in
    m = n
end
module List = List0

module Util = struct

  let readdir dir : string list =
    match Sys.file_exists dir && Sys.is_directory dir with
    | false -> []
    | true -> (Sys.readdir dir |> Array.to_list)

  let modules_of_file filename : string list =
    List.fold_left [".ml"; ".mli"; ".ml.m4"; ".mll"; ".mly"; ".atd"]
      ~init:[] ~f:(fun accum suffix ->
        let new_items = match suffix with
          | ".atd" -> (
            if Filename.check_suffix filename suffix then (
              Filename.chop_suffix filename suffix
              |> fun x -> [x^"_j"; x^"_t"]
            )
            else
              []
            )
          | _ -> (
            if Filename.check_suffix filename suffix then
              [Filename.chop_suffix filename suffix]
            else
              []
            )
        in
        new_items@accum
      )
    |> List.map ~f:String.capitalize

  let modules_of_dir dir : string list =
    readdir dir
    |> List.map ~f:modules_of_file
    |> List.concat
    |> List.sort_uniq compare

  let c_units_of_dir dir : string list =
    readdir dir
    |> List.filter ~f:(fun p -> Filename.check_suffix p ".c")
    |> List.map ~f:Filename.chop_extension

  let h_files_of_dir dir : string list =
    readdir dir
    |> List.filter ~f:(fun p -> Filename.check_suffix p ".h")

  let mlpack_file dir : string list =
    if not (Sys.file_exists dir && Sys.is_directory dir) then
      failwithf "cannot create mlpack file for dir %s" dir ()
    else (
      modules_of_dir dir
      |> List.map ~f:(fun x -> dir/x)
    )

  let clib_file dir lib =
    let path = dir / lib in
    match c_units_of_dir path with
    | [] -> None
    | xs ->
      Some (List.map xs ~f:(fun x -> lib ^ "/" ^ x ^ ".o"))

end

module Findlib = struct
  type pkg = string

  (* This is necessary to query findlib *)
  let () = Findlib.init ()

  let all_packages =
    Fl_package_base.list_packages ()

  let installed x = List.mem x ~set:all_packages

end

module Item = struct
  type typ = [`Lib | `App]

  type name = string

  type condition = [
    | `Pkgs_installed
  ]

  type t = {
    typ : typ;
    name : name;
    libs : t list;
    pkgs : Findlib.pkg list;
    build_if : condition list;
  }

  let hash t = Hashtbl.hash (t.typ, t.name)

  let compare t u =
    match compare t.typ u.typ with
    | -1 -> -1
    | 1 -> 1
    | 0 -> String.compare t.name u.name
    | _ -> assert false

  let equal t u = compare t u = 0

  let name x = x.name

  let is_lib x = match x.typ with `Lib -> true | `App -> false
  let is_app x = match x.typ with `App -> true | `Lib -> false

  let typ_to_string = function `Lib -> "lib" | `App -> "app"
end

module Graph = struct
  module G = Graph.Persistent.Digraph.Concrete(Item)
  include G

  module Dfs = Graph.Traverse.Dfs(G)
  module Topological = Graph.Topological.Make(G)
end

module Items = struct
  type t = Item.t list

  let graph_of_list items =
    if not (List.is_uniq ~cmp:Item.compare items) then
      failwith "multiple libraries or apps have an identical name"
    else
      let g = List.fold_left items ~init:Graph.empty ~f:(fun g x ->
        match x.Item.libs with
        | [] -> Graph.add_vertex g x
        | _ ->
          List.fold_left x.Item.libs ~init:g ~f:(fun g y ->
            Graph.add_edge g x y
          )
      )
      in
      if Graph.Dfs.has_cycle g then
        failwith "internal dependencies form a cycle"
      else
        g

  let of_list items =
    ignore (graph_of_list items);
    items

  let get t typ name =
    try List.find t ~f:(fun x -> x.Item.typ = typ && x.Item.name = name)
    with Not_found ->
      failwithf "unknown %s %s " (Item.typ_to_string typ) name ()

  let lib_deps t typ name =
    (get t typ name).Item.libs

  let rec lib_deps_all t typ name =
    let item = get t typ name in
    item.Item.libs
    @(
      List.map item.Item.libs ~f:(fun x ->
        lib_deps_all t x.Item.typ x.Item.name
      )
      |> List.flatten
    )
    |> List.sort_uniq Item.compare

  let pkgs_deps t typ name =
    (get t typ name).Item.pkgs

  let rec pkgs_deps_all t typ name =
    let item = get t typ name in
    item.Item.pkgs
    @(
      List.map item.Item.libs ~f:(fun x ->
        pkgs_deps_all t x.Item.typ x.Item.name
      )
      |> List.flatten
    )
    |> List.sort_uniq String.compare

  let all_findlib_pkgs t =
    List.map t ~f:(fun x -> x.Item.pkgs)
    |> List.flatten
    |> List.sort_uniq String.compare

  let rec should_build items i =
    List.for_all i.Item.build_if ~f:(function
      | `Pkgs_installed ->
        List.for_all i.Item.pkgs ~f:Findlib.installed
    )
    &&
    List.for_all i.Item.libs ~f:(fun x ->
      should_build items (get items x.Item.typ x.Item.name)
    )

  let topologically_sorted t =
    Graph.Topological.fold
      (fun x t -> x::t)
      (graph_of_list t)
      []

end

module type PROJECT = sig
  val name : string
  val version : string
  val items : Items.t
  val ocamlinit_postfix : string list
end

module Make(Project:PROJECT) = struct
  open Ocamlbuild_plugin

  (* override the one from Ocamlbuild_plugin *)
  module List = List0

  (* Union of Project, and Items module with Project.items assumed as
     argument to most functions. *)
  module Project = struct
    include Project

    (** All libs to build. *)
    let libs : Item.t list =
      List.filter items ~f:Item.is_lib |>
      List.filter ~f:(Items.should_build items)

    (** All apps that should be built. *)
    let apps : Item.t list =
      List.filter items ~f:Item.is_app |>
      List.filter ~f:(Items.should_build items)

    let libs_names = List.map libs ~f:Item.name
    let apps_names = List.map apps ~f:Item.name

    let get = Items.get items
    let lib_deps = Items.lib_deps items
    let lib_deps_all = Items.lib_deps_all items
    let pkgs_deps = Items.pkgs_deps items
    let pkgs_deps_all = Items.pkgs_deps_all items
    let all_findlib_pkgs = Items.all_findlib_pkgs items
    let should_build = Items.should_build items
    let topologically_sorted = Items.topologically_sorted items
  end
  module Items = struct end

  let git_commit =
    if Sys.file_exists ".git" then
      sprintf "Some \"%s\""
        (
          Ocamlbuild_pack.My_unix.run_and_read "git rev-parse HEAD"
          |> fun x -> String.sub x 0 (String.length x - 1)
        )
    else
      "None"

  let tags_lines : string list =
    [
      "true: thread, bin_annot, annot, short_paths, safe_string, debug";
      "true: warn(A-4-33-41-42-44-45-48)";
      "true: use_menhir";
      "\"lib\": include";
    ]
    (* === for-pack tags *)
    @(
      List.map Project.libs_names ~f:(fun x ->
          sprintf
            "<lib/%s/*.cmx>: for-pack(%s_%s)"
            x (String.capitalize Project.name) x )
    )
    (* === use_foo for libs *)
    @(
      List.map Project.libs ~f:(fun lib ->
        lib.Item.name,
        Project.lib_deps `Lib lib.Item.name |>
        List.filter ~f:Item.is_lib |>
        List.map ~f:Item.name
      )
      |> List.filter ~f:(function (_,[]) -> false | (_,_) -> true)
      |> List.map ~f:(fun (name,libs) ->
          sprintf "<lib/%s/*>: %s"
            name
            (String.concat ", " (List.map libs ~f:(sprintf "use_%s_%s" Project.name)))
        )
    )
    (* === use_foo_stub tags for cm{a,xa,xs} *)
    @(
      Project.libs
      |> List.map ~f:Item.name
      |> List.filter ~f:(fun x ->
          Util.c_units_of_dir ("lib"/x) <> []
        )
      |> List.map ~f:(fun x ->
          sprintf "<lib/%s_%s.{cma,cmxa,cmxs}>: use_%s_%s_stub"
            Project.name x Project.name x
        )
    )
    (* === package tags for libs *)
    @(
      List.map Project.libs ~f:(fun lib ->
        lib.Item.name, Project.pkgs_deps_all `Lib lib.Item.name
      )
      |> List.filter ~f:(function (_,[]) -> false | (_,_) -> true)
      |> List.map ~f:(fun (name,pkgs) ->
        sprintf "<lib/%s/*>: %s"
          name
          (String.concat ", " (List.map pkgs ~f:(sprintf "package(%s)")))
      )
    )
    (* === use_foo for apps *)
    @(
      List.map Project.apps ~f:(fun app ->
        app.Item.name,
        Project.lib_deps_all `App app.Item.name |>
        List.filter ~f:Item.is_lib |>
        List.map ~f:(fun x -> x.Item.name)
      )
      |> List.filter ~f:(function (_,[]) -> false | (_,_) -> true)
      |> List.map ~f:(fun (name,libs) ->
          sprintf "<app/%s.*>: %s"
            name
            (String.concat ", " (List.map libs ~f:(sprintf "use_%s_%s" Project.name)))
        )
    )
    (* === package tags for apps *)
    @(
      List.map Project.apps ~f:(fun app ->
        app.Item.name, Project.pkgs_deps_all `App app.Item.name )
      |> List.filter ~f:(function (_,[]) -> false | (_,_) -> true)
      |> List.map ~f:(fun (name,pkgs) ->
        sprintf "<app/%s.*>: %s"
          name
          (String.concat "," (List.map pkgs ~f:(sprintf "package(%s)")))
      )
    )
    (* === use_foo_stub for apps *)
    @(
      List.map Project.apps ~f:(fun app ->
        app.Item.name,
        Project.lib_deps_all `App app.Item.name |>
        List.filter ~f:Item.is_lib |>
        List.map ~f:(fun x -> x.Item.name)
      )
      |> List.filter ~f:(function (_,[]) -> false | (_,_) -> true)
      |> List.map ~f:(fun (name,libs) ->
        sprintf "<app/%s.*>: %s"
          name
          (String.concat
             ","
             (List.map libs ~f:(sprintf "use_%s_%s" Project.name)))
      )
    )

  let mllib_file dir lib : string list =
    let path = dir / lib in
    if not (Sys.file_exists path && Sys.is_directory path) then
      failwithf "cannot create mllib file for dir %s" path ()
    else [ dir / String.capitalize (Project.name ^ "_" ^ lib) ]

  let merlin_file : string list =
    [
      "S ./lib/**";
      "S ./app/**";
      "B ./_build/lib";
      "B ./_build/lib/**";
      "B ./_build/app/**";
      "B +threads";
      "PKG solvuu_build";
    ]
    @(
      List.map Project.all_findlib_pkgs ~f:(fun x -> sprintf "PKG %s" x)
    )

  let meta_file : string list =
    List.map Project.libs_names ~f:(fun x ->
        let lib_name = sprintf "%s_%s" Project.name x in
        let requires : string list =
          (Project.pkgs_deps_all `Lib x)
          @(List.map
              (Project.lib_deps `Lib x |> List.map ~f:Item.name)
              ~f:(sprintf "%s.%s" Project.name)
           )
        in
        [
          sprintf "package \"%s\" (" x;
          sprintf "  directory = \"%s\"" x;
          sprintf "  version = \"%s\"" Project.version;
          sprintf "  archive(byte) = \"%s.cma\"" lib_name;
          sprintf "  archive(native) = \"%s.cmxa\"" lib_name;
          sprintf "  requires = \"%s\"" (String.concat " " requires);
          sprintf "  exists_if = \"%s.cma\"" lib_name;
          sprintf ")";
        ]
      )
    |> List.flatten
    |> List.filter ~f:((<>) "")

  let install_file : string list =
    let suffixes = [
      "a";"annot";"cma";"cmi";"cmo";"cmt";"cmti";"cmx";"cmxa";
      "cmxs";"dll";"o"]
    in
    (
      List.map Project.libs_names ~f:(fun lib ->
          List.map suffixes ~f:(fun suffix ->
              sprintf "  \"?_build/lib/%s_%s.%s\" { \"%s/%s_%s.%s\" }"
                Project.name lib suffix
                lib Project.name lib suffix
            )
        )
      |> List.flatten
      |> fun l -> "  \"_build/META\""::l
                  |> fun l -> ["lib: ["]@l@["]"]
    )
    @(
      let lines =
        List.map Project.libs_names ~f:(fun lib ->
            sprintf "  \"?_build/lib/dll%s_%s_stub.so\"" Project.name lib
          )
      in
      "stublibs: [" :: lines @ ["]"]
    )
    @(
      List.map Project.apps_names ~f:(fun app ->
          List.map ["byte"; "native"] ~f:(fun suffix ->
              sprintf "  \"?_build/app/%s.%s\" {\"%s\"}" app suffix app
            )
        )
      |> List.flatten
      |> function
      | [] -> []
      | l -> ["bin: ["]@l@["]"]
    )

  let ocamlinit_file =
    [
      "let () =" ;
      "  try Topdirs.dir_directory (Sys.getenv \"OCAML_TOPLEVEL_PATH\")" ;
      "  with Not_found -> ()" ;
      ";;" ;
      "" ;
      "#use \"topfind\";;" ;
      "#thread;;" ;
      sprintf "#require \"%s\";;" (String.concat " " Project.all_findlib_pkgs);
      "" ;
      "(* Load each lib provided by this project. *)" ;
      "#directory \"_build/lib\";;" ;
    ]
    @(
      Project.topologically_sorted |>
      List.filter ~f:Item.is_lib |>
      List.map ~f:(fun x ->
        sprintf "#load \"%s_%s.cma\";;" Project.name x.Item.name )
    )
    @ Project.ocamlinit_postfix

  let makefile_rules_file : string list =
    let map_name xs = List.map xs ~f:(sprintf "%s_%s" Project.name) in
    let native =
      List.concat [
        map_name Project.libs_names |> List.map ~f:(sprintf "lib/%s.cmxa") ;
        map_name Project.apps_names |> List.map ~f:(sprintf "lib/%s.cmxs") ;
        List.map Project.apps_names ~f:(sprintf "app/%s.native") ;
      ]
      |> String.concat " "
      |> sprintf "native: %s"
    in
    let byte =
      List.concat [
        map_name Project.libs_names |> List.map ~f:(sprintf "lib/%s.cma") ;
        List.map Project.apps_names ~f:(sprintf "app/%s.byte") ;
      ]
      |> String.concat " "
      |> sprintf "byte: %s"
    in
    let static = [
      "default: byte project_files.stamp";

      "%.cma %.cmxa %.cmxs %.native %.byte lib/%.mlpack:";
      "\t$(OCAMLBUILD) $@";

      "project_files.stamp META:";
      "\t$(OCAMLBUILD) $@";

      sprintf ".merlin %s.install .ocamlinit:" Project.name;
      "\t$(OCAMLBUILD) $@ && ln -s _build/$@ $@";

      "clean:";
      "\t$(OCAMLBUILD) -clean";

      ".PHONY: default native byte clean";
    ]
    in
    static@[native ; byte]

  let make_static_file path contents =
    let contents = List.map contents ~f:(sprintf "%s\n") in
    rule path ~prod:path (fun _ _ ->
        Seq [
          Cmd (Sh (sprintf "mkdir -p %s" (Filename.dirname path)));
          Echo (contents,path);
        ]
      )

  let plugin = function
    | Before_options -> (
        Options.use_ocamlfind := true;
        List.iter tags_lines ~f:Ocamlbuild_pack.Configuration.parse_string
      )
    | After_rules -> (
        rule "m4: ml.m4 -> ml"
          ~prod:"%.ml"
          ~dep:"%.ml.m4"
          (fun env _ ->
             let ml_m4 = env "%.ml.m4" in
             Cmd (S [
                 A "m4";
                 A "-D"; A ("VERSION=" ^ Project.version);
                 A "-D"; A ("GIT_COMMIT=" ^ git_commit);
                 P ml_m4;
                 Sh ">";
                 P (env "%.ml");
               ]) )
        ;

        rule "atd: .atd -> _t.ml, _t.mli"
          ~dep:"%.atd"
          ~prods:["%_t.ml"; "%_t.mli"]
          (fun env _ ->
             Cmd (S [A "atdgen"; A "-t"; A "-j-std"; P (env "%.atd")])
          )
        ;

        rule "atd: .atd -> _j.ml, _j.mli"
          ~dep:"%.atd"
          ~prods:["%_j.ml"; "%_j.mli"]
          (fun env _ ->
             Cmd (S [A "atdgen"; A "-j"; A "-j-std"; P (env "%.atd")])
          )
        ;

        List.iter Project.libs_names ~f:(fun lib ->
            make_static_file
              (sprintf "lib/%s_%s.mlpack" Project.name lib)
              (Util.mlpack_file ("lib"/lib))
          );

        List.iter Project.libs_names ~f:(fun lib ->
            make_static_file
              (sprintf "lib/%s_%s.mllib" Project.name lib)
              (mllib_file "lib" lib)
          );

        List.iter Project.libs_names ~f:(fun lib ->
            let lib_name = sprintf "%s_%s" Project.name lib in
            let lib_tag = sprintf "use_%s_%s" Project.name lib in
            flag ["link";"ocaml";lib_tag] (S[A"-I"; P "lib"]);
            ocaml_lib ~tag_name:lib_tag ~dir:"lib" ("lib/" ^ lib_name) ;
            dep ["ocaml";"byte";lib_tag] [sprintf "lib/%s.cma" lib_name] ;
            dep ["ocaml";"native";lib_tag] [sprintf "lib/%s.cmxa" lib_name]
          );

        List.iter Project.libs_names ~f:(fun lib ->
            match Util.clib_file "lib" lib with
            | None -> ()
            | Some file ->
              let cstub = sprintf "%s_%s_stub" Project.name lib in
              let stub_tag = "use_"^cstub in
              let headers =
                Util.h_files_of_dir ("lib"/lib)
                |> List.map ~f:(fun x -> "lib"/lib/x)
              in
              dep ["c" ; "compile"] headers ;
              dep ["link";"ocaml";stub_tag] [
                sprintf "lib/lib%s.a" cstub ;
              ] ;
              flag
                ["link";"ocaml";"byte";stub_tag]
                (S[A"-dllib";A("-l"^cstub);A"-cclib";A("-l"^cstub)]) ;
              flag
                ["link";"ocaml";"native";stub_tag]
                (S[A"-cclib";A("-l"^cstub)]) ;
              make_static_file
                (sprintf "lib/lib%s.clib" cstub)
                file
          ) ;

        make_static_file ".merlin" merlin_file;
        make_static_file "META" meta_file;
        make_static_file (sprintf "%s.install" Project.name) install_file;
        make_static_file ".ocamlinit" ocamlinit_file;
        make_static_file "Makefile.rules" makefile_rules_file ;

        rule "project files"
          ~stamp:"project_files.stamp"
          (fun _ build ->
             let project_files = [
                 [".merlin"];
                 [".ocamlinit"];
               ]
             in
             List.map (build project_files) ~f:Outcome.good
             |> List.map ~f:(fun result ->
                 Cmd (S [A "ln"; A "-sf";
                         P ((Filename.basename !Options.build_dir)/result);
                         P Pathname.pwd] )
               )
             |> fun l -> Seq l
          )
      )
    | _ -> ()

  let dispatch () = dispatch plugin

end
