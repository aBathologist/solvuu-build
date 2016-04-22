module List = Util.List

type name = string

type condition = [
  | `Pkgs_installed
]

type pkg = string

type app = {
  name : name;
  internal_deps : t list;
  findlib_deps : pkg list;
  build_if : condition list;
}

and lib = {
  name : name;
  internal_deps : t list;
  findlib_deps : pkg list;
  build_if : condition list;
}

and t = Lib of lib | App of app

type typ = [`Lib | `App]

let lib ?(internal_deps=[]) ?(findlib_deps=[]) ?(build_if=[]) name =
  Lib {name;internal_deps;findlib_deps;build_if}

let app ?(internal_deps=[]) ?(findlib_deps=[]) ?(build_if=[]) name =
  App {name;internal_deps;findlib_deps;build_if}

let typ = function Lib _ -> `Lib | App _ -> `App
let name = function Lib x -> x.name | App x -> x.name

let hash t = Hashtbl.hash (typ t, name t)

let compare t u =
  match compare (typ t) (typ u) with
  | -1 -> -1
  | 1 -> 1
  | 0 -> String.compare (name t) (name u)
  | _ -> assert false

let equal t u = compare t u = 0

let internal_deps = function
  | Lib x -> x.internal_deps | App x -> x.internal_deps

let findlib_deps = function
  | Lib x -> x.findlib_deps | App x -> x.findlib_deps

let build_if = function Lib x -> x.build_if | App x -> x.build_if

let internal_deps_all t =
  let count = ref 0 in
  let rec loop t =
    incr count;
    if !count > 10000 then
      failwith "max recursion count exceeded, likely cycle in internal_deps"
    else
      let direct = internal_deps t in
      let further =
        List.map direct ~f:loop
        |> List.flatten
      in
      List.sort_uniq compare (direct@further)
  in
  loop t

let findlib_deps_all t =
  let count = ref 0 in
  let rec loop t =
    incr count;
    if !count > 10000 then
      failwith "max recursion count exceeded, likely cycle in internal_deps"
    else
      let direct = findlib_deps t in
      let further =
        List.map (internal_deps t) ~f:loop
        |> List.flatten
      in
      List.sort_uniq String.compare (direct@further)
  in
  loop t

let is_lib = function Lib _ -> true | App _ -> false
let is_app = function App _ -> true | Lib _ -> false

let typ_to_string = function `Lib -> "lib" | `App -> "app"

(******************************************************************************)
(** {2 Graph Operations} *)
(******************************************************************************)
module T = struct
  type nonrec t = t
  let compare = compare
  let hash = hash
  let equal = equal
end

module Graph = struct
  include Graph.Persistent.Digraph.Concrete(T)

  module Dfs = Graph.Traverse.Dfs(
    Graph.Persistent.Digraph.Concrete(T)
  )

  module Topological = Graph.Topological.Make(
    Graph.Persistent.Digraph.Concrete(T)
  )

  let of_list items =
    if not (List.is_uniq ~cmp:compare items) then
      failwith "multiple libraries or apps have an identical name"
    else
      let g = List.fold_left items ~init:empty ~f:(fun g x ->
        match internal_deps x with
        | [] -> add_vertex g x
        | _ ->
          List.fold_left (internal_deps x) ~init:g ~f:(fun g y ->
            add_edge g x y
          )
      )
      in
      if Dfs.has_cycle g then
        failwith "internal dependencies form a cycle"
      else
        g

end
