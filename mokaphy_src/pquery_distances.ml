(* mokaphy v0.3. Copyright (C) 2010  Frederick A Matsen.
 * This file is part of mokaphy. mokaphy is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. pplacer is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with pplacer. If not, see <http://www.gnu.org/licenses/>.
 *
 * This builds a matrix of distances between pqueries. 
 * In fact, it does the following. 
 * Say pquery x has placements x_i, with weights P(x_i).
 * Say pquery y has placements y_i, with weights P(y_i).
 * Assume we have a distance metric d on the tree.
 * In the weighted case this computes
 *   \sum_{ij} d(x_i, x_j) P(x_i) P(x_j)
 * and in the unweighted case it's simply the distance between the placements
 * with the highest P's.
 *
 * Build the ca_info to avoid tree traversal in the main loop.
 *)

module BA1 = Bigarray.Array1
module BA2 = Bigarray.Array2


let exponentiate_function exponent f = 
  if exponent = 1. then f
  else (fun crit cai a b -> (f crit cai a b) ** exponent)

(* take the weighted average over placements of the pquery *)
let weighted_pquery_dist criterion ca_info pqa pqb = 
  let total = ref 0. in
  Base.list_iter_over_pairs_of_two 
    (fun p1 p2 ->
      total := !total +.
        ((criterion p1) *. (criterion p2) *.
          ((Edge_rdist.find_ca_dist ca_info
            (Placement.location p1, Placement.distal_bl p1)
            (Placement.location p2, Placement.distal_bl p2)))))
    (Pquery.place_list pqa)
    (Pquery.place_list pqb);
  !total

(* distance between the best placements *)
let unweighted_pquery_dist criterion ca_info pqa pqb = 
  let p1 = Pquery.best_place criterion pqa
  and p2 = Pquery.best_place criterion pqb
  in
  Edge_rdist.find_ca_dist ca_info
    (Placement.location p1, Placement.distal_bl p1)
    (Placement.location p2, Placement.distal_bl p2)

let dist_fun_of_expon_weight exponent weighting = 
  exponentiate_function 
    exponent
    (match weighting with
    | Mass_map.Weighted -> weighted_pquery_dist
    | Mass_map.Unweighted -> unweighted_pquery_dist)
