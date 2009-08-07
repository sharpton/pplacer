(* pplacer v0.2. Copyright (C) 2009  Frederick A Matsen.
 * This file is part of pplacer. pplacer is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. pplacer is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with pplacer. If not, see <http://www.gnu.org/licenses/>.
 *)

open Fam_batteries
open MapsSets
open Placement

let version_str = "v0.2"

let verbose = ref false
and out_fname = ref ""

let parse_args () =
  let files  = ref [] in
  let verbose_opt = "-v", Arg.Set verbose,
   "verbose running."
 and out_fname_opt = "-o", Arg.Set_string out_fname,
   "Set the filename to write to. Otherwise write to stdout."
  in
  let usage =
    "panda "^version_str^"\npanda ex1.place ex2.place...\n"
  and anon_arg arg =
    files := arg :: !files in
  let args = [verbose_opt; out_fname_opt; ] in
  Arg.parse args anon_arg usage;
  List.rev !files

     
    (* note return code of 0 is OK *)
let () =
  if not !Sys.interactive then begin
    let fnames = parse_args () in
    let parsed = 
      List.map 
        (fun fname -> Placement_io.parse_place_file version_str fname)
        fnames
    in
    if parsed = [] then exit 0;
    let ref_tree = 
      Base.complete_fold_left
        (fun prev_ref a_ref ->
          if prev_ref <> a_ref then
            failwith "Reference trees not all the same!";
          prev_ref)
        (List.map fst parsed)
    in
    let out_ch = 
      if !out_fname = "" then stdout
      else open_out !out_fname
    in
    Panda_core.core
      !verbose
      Placement.compare_ml_place 
      out_ch
      ref_tree
      (Array.of_list
        (List.combine
          (List.map Filename.chop_extension fnames)
          (List.map snd parsed)));
      if !out_fname <> "" then close_out out_ch
  end
