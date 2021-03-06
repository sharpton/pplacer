(* mokaphy v1.0. Copyright (C) 2010  Frederick A Matsen.
 * This file is part of mokaphy. mokaphy is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. pplacer is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with pplacer. If not, see <http://www.gnu.org/licenses/>.
 *
 * Here we do pdfrac. 
 *
 *)

open MapsSets
open Fam_batteries

let of_induceds t ind1 ind2 = 
  let isect = Induced.intersect t ind1 ind2
  and union = Induced.union t ind1 ind2
  in
  (* to play it safe for a while *)
  List.iter (Induced.check t) [ind1; ind2; isect; union;];
  (Pd.of_induced t isect) /. (Pd.of_induced t union)
