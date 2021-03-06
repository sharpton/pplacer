(* pplacer v1.0. Copyright (C) 2009-2010  Frederick A Matsen.
 * This file is part of pplacer. pplacer is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. pplacer is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with pplacer.  If not, see <http://www.gnu.org/licenses/>.
 *
 * bark for trees that have newick + a list of Decor decorations.
*)

open Fam_batteries
open MapsSets


class decor_bark arg = 
  let (bl, name, boot, decor) = 
    match arg with
    | `Empty -> (None, None, None, [])
    | `Of_newick_bark nb -> 
        (nb#get_bl_opt, nb#get_name_opt, nb#get_boot_opt, [])
    | `Of_bl_name_boot_dlist (bl, name, boot, dlist) -> 
        (bl, name, boot, dlist) 
  in
  object (* (self) *)
    val decor = decor
    inherit Newick_bark.newick_bark 
      (`Of_bl_name_boot (bl, name, boot))
      as super

    method get_decor = decor

    method ppr ff = 
      Format.fprintf ff "@[{%a decor = %a;}@]" 
        (fun ff () -> super#ppr_inners ff) ()
        (Ppr.ppr_list Decor.ppr) decor

    method write_xml ch = 
      super#write_xml ch;
      (* sort so tags are in proper order *)
      List.iter (Decor.write_xml ch) (List.sort compare decor)

    method append_decor decor_list = 
      {< decor = decor @ decor_list >}

  end

let compare b1 b2 = 
  try 
    Base.raise_if_different Newick_bark.compare b1 b2;
    Base.raise_if_different compare b1#get_decor b2#get_decor;
    0
  with
  | Base.Different c -> c

let of_newick_bark nb = new decor_bark (`Of_newick_bark nb)
let to_newick_bark db = 
  new Newick_bark.newick_bark 
        (`Of_bl_name_boot (db#get_bl_opt, db#get_name_opt, db#get_boot_opt))
