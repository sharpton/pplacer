(* mokaphy v0.3. Copyright (C) 2010  Frederick A Matsen.
 * This file is part of mokaphy. mokaphy is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. pplacer is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with pplacer. If not, see <http://www.gnu.org/licenses/>.
 *
 * to get significance values using eigenvalues of the common ancestry matrix.
 *
 * mtilde = \int_u G_i(u) G_j(u) \lambda(du)
 *)

let tol = 1e-5
let max_iter = 100

module BA1 = Bigarray.Array1
module BA2 = Bigarray.Array2

(* could be made faster by improving the way the matrices are accessed *)
let build_mtilde weighting criterion pr1 pr2 = 
  let t = Placerun.get_same_tree pr1 pr2 in
  let both = 
    Array.of_list
    ((Placerun.get_pqueries pr1)@(Placerun.get_pqueries pr2)) in
  let n = Array.length both
  and ca_info = Camat.build_ca_info t
  in
  let mt = Gsl_matrix.create ~init:0. n n in
  (* set mt[i][j] symmetrically *)
  let mt_set i j x =
    let set_one i j = BA2.unsafe_set mt i j x in
    set_one i j;
    if i <> j then set_one j i
  in
  let () = match weighting with
  | Mass_map.Weighted -> 
    for i=0 to n-1 do
      for j=i to n-1 do
        let total = ref 0. in
        Base.list_iter_over_pairs_of_two 
          (fun p1 p2 ->
            total := !total +.
              ((criterion p1) *. (criterion p2) *.
                ((Camat.find_ca_dist ca_info
                  (Placement.location p1, Placement.distal_bl p1)
                  (Placement.location p2, Placement.distal_bl p2)))))
          (Pquery.place_list both.(i))
          (Pquery.place_list both.(j));
        mt_set i j (!total)
      done
    done;
  | Mass_map.Unweighted -> 
    for i=0 to n-1 do
      for j=i to n-1 do
        let p1 = Pquery.best_place criterion both.(i)
        and p2 = Pquery.best_place criterion both.(j)
        in
        mt_set i j 
          ((Camat.find_ca_dist ca_info
              (Placement.location p1, Placement.distal_bl p1)
              (Placement.location p2, Placement.distal_bl p2)))
      done
    done;
  in
  Gsl_matrix.scale mt (1. /. (Gtree.tree_length t));
  mt

let vec_tot = Fam_vector.fold_left (+.) 0.

(* the average of each of the rows *)
let row_avg m = 
  let (_, n_cols) = Gsl_matrix.dims m
  and ra = Fam_matrix.map_rows_to_vector vec_tot m in
  Gsl_vector.scale ra (1. /. (float_of_int n_cols));
  ra

(* if m is mtilde then convert it to an m. n1 and n2 are the number of pqueries
 * in pr1 and pr2 *)
let m_of_mtilde m n1 n2 = 
  (* it's mtilde so far *)
  let (n,_) = Gsl_matrix.dims m in
  assert(n = n1+n2);
  let ra = row_avg m in
  let avg = (vec_tot ra) /. (float_of_int n) in
  let coeff = 1. /. (float_of_int (n1*n2)) in
  for i=0 to n-1 do
    for j=0 to n-1 do
      BA2.unsafe_set m i j
        (coeff *.
          ((BA2.unsafe_get m i j) 
          -. (BA1.unsafe_get ra i)
          -. (BA1.unsafe_get ra j)
          +. avg))
    done
  done

let rooted_qform m v = sqrt(Fam_matrix.qform m v)

(* get expectation of w within some tolerance *)
let w_expectation rng tol m = 
  let n = Fam_matrix.dim_asserting_square m in
  let v = Gsl_vector.create n in
  let n_samples = ref 0
  and sample_total = ref 0.
  in
  let next_expectation () = 
    for i=0 to n-1 do 
      v.{i} <- Gsl_randist.gaussian rng ~sigma:1.
    done;
    incr n_samples;
    sample_total := !sample_total +. rooted_qform m v;
    (!sample_total) /. (float_of_int (!n_samples))
  in
  (* make sure we get at least 10 (one more below) *)
  for i=1 to 10 do let _ = next_expectation () in () done;
  (* continue until the expectation changes less than tol *)
  let rec get_expectation prev = 
    let ew = next_expectation () in
    if abs_float (ew -. prev) > tol then get_expectation ew
    else ew
  in
  get_expectation (next_expectation ())

let dist_and_p weighting criterion rng pr1 pr2 = 
  let n1 = Placerun.n_pqueries pr1 
  and n2 = Placerun.n_pqueries pr2 in
  let inv_n1 = 1. /. (float_of_int n1)
  and neg_inv_n2 = -. 1. /. (float_of_int n2) in
  let indicator = 
    Fam_vector.init 
      (n1+n2)
      (fun i -> if i < n1 then inv_n1 else neg_inv_n2)
  in
  let m = build_mtilde weighting criterion pr1 pr2 in
    (* first m is mtilde *)
  let w = rooted_qform m indicator in
  (* then it actually becomes mtilde *)
  m_of_mtilde m n1 n2;
  let ew = w_expectation rng tol m in
  Printf.printf "W: %g\t E[W]: %g\n" w ew;
  let t = w -. ew in
  (w,
  2. *. exp ( -. t *. t /. (2. *. (Top_eig.top_eig m tol max_iter))))

