(* pplacer v1.0 Copyright (C) 2009 -2010 Frederick A Matsen.
 * This file is part of pplacer. pplacer is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. pplacer is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with pplacer. If not, see <http://www.gnu.org/licenses/>.
 *
 * could be called newick_gtree.
 *)

open MapsSets
open Fam_batteries

type t = Newick_bark.newick_bark Gtree.gtree

(* use *)

let compare t1 t2 = Gtree.compare Newick_bark.compare t1 t2

let to_numbered t = 
  Gtree.mapi_bark_map (fun i x -> x#to_numbered i) t

let make_boot_id t =
  Gtree.mapi_bark_map (fun i x -> x#set_boot (float_of_int i)) t

(* output *)

let string_of_bark t id = 
    match Gtree.get_bark_opt t id with
    | Some b -> b#to_newick_string
    | None -> ""

let to_string_gen f t = 
    (Gtree.recur
      (fun id below ->
        "("^(String.concat "," below)^")"^(f t id))
      (f t)
      t)^";"

let to_string t = to_string_gen string_of_bark t

let write ch t = Printf.fprintf ch "%s\n" (to_string t)

let tree_list_to_file trees fname = 
  let ch = open_out fname in
  List.iter (write ch) trees;
  close_out ch

let to_file t fname = tree_list_to_file [t] fname

let ppr ff t = 
  let ppr_bark ff id = 
    Format.pp_print_string ff (string_of_bark t id) in 
  let rec aux ff = function
    | Stree.Node(id, tL) ->
      Format.fprintf ff "@[(%a)%a@]"
        (Ppr.ppr_gen_list_inners "," aux) tL 
        ppr_bark id
    | Stree.Leaf(id) ->
        ppr_bark ff id
  in
  Format.fprintf ff "%a;" aux (Gtree.get_stree t)



(* input *)

(* count the number of occurrences of char c in str *)
let count_n_occurrences c str = 
  let count = ref 0 in
  String.iter (fun d -> if c = d then incr count) str;
  !count

let check_string s = 
  let n_open = count_n_occurrences '(' s 
  and n_closed = count_n_occurrences ')' s in
  if n_open <> n_closed then
    Printf.printf "warning: %d open parens and %d closed parens\n" n_open n_closed;
  ()

let of_lexbuf lexbuf = 
  try
    Newick_parser.tree Newick_lexer.token lexbuf
  with 
  | Parsing.Parse_error -> failwith "couldn't parse tree!"

let of_string s = 
  check_string s;
  try
    of_lexbuf 
    (Lexing.from_string (Str.replace_first (Str.regexp ");") "):0.;" s))
  with
  | Failure s -> failwith("problem parsing tree: "^s)

let of_file fname = 
  match
    List.filter 
      (fun line -> 
        not (Str.string_match (Str.regexp "^[ \t]*$") line 0)) 
      (File_parsing.string_list_of_file fname)
  with
    | [] -> failwith ("empty file in "^fname)
    | [s] -> of_string s
    | _ -> failwith ("expected a single tree on a single line in "^fname)

let list_of_file fname =
  List.map of_string (File_parsing.string_list_of_file fname)
