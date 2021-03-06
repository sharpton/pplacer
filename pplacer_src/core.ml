(* pplacer v1.0. Copyright (C) 2009-2010  Frederick A Matsen.
 * This file is part of pplacer. pplacer is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. pplacer is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with pplacer. If not, see <http://www.gnu.org/licenses/>.
 *
 * here we actually do the work.
*)

open Fam_batteries
open MapsSets
open Prefs

let max_iter = 200
(* the most number of placements we keep *)
let keep_at_most = 7
(* we throw away anything that has ml_ratio below keep_factor times (best ml_ratio) *)
let keep_factor = 0.01
let log_keep_factor = log keep_factor

(* the second stage tolerance for branch length optimization. modify in online
 * help if changed here. *)
let final_tolerance = 1e-5

type prior = Uniform_prior | Exponential_prior of float

(* pplacer_core :
  * actually try the placements, etc. return placement records *)
let pplacer_core prefs query_fname prior model ref_align gtree 
      ~darr ~parr ~snodes locs = 
  let seq_type = Model.seq_type model
  and prior_fun =
    match prior with
    | Uniform_prior -> (fun _ -> 1.)
    | Exponential_prior mean ->
        fun pend -> Gsl_randist.exponential_pdf ~mu:mean pend
  and query_channel = Fasta_channel.of_fname query_fname 
  and ref_length = Alignment.length ref_align
  and fantasy_mat = 
    if fantasy prefs <> 0. then
      Fantasy.make_fantasy_matrix 
        ~max_strike_box:(int_of_float (strike_box prefs))
        ~max_strikes:(max_strikes prefs)
    else [||]
  and fantasy_mod = Base.round (100. *. (fantasy_frac prefs))
  and n_fantasies = ref 0
  in
  (* we turn off friend finding in fantasy mode *)
  let friendly_run = friendly prefs && (fantasy prefs = 0.) in
  (* make the friend profile if required *)
  let friend_prof = 
    if friendly_run then begin
      print_string "Finding friends. ";
      flush_all();
      let a = Alignment.read_fasta query_fname in
      print_string "Read alignment. ";
      flush_all();
      let flen = float_of_int (Alignment.n_seqs a) in
      if (verb_level prefs) >= 1 then begin
        Printf.printf
          "This will require around %.4g sequence comparisons... "
          (flen *. (flen -. 1.) /. 2.);
        flush_all();
      end;
      let fp = Friendly.prev_pairing_of_alignment a in
      print_endline "done.";
      fp
    end
    else [||]
  in
  (* set up the number of pitches and strikes according to the prefs *)
  let (t_max_pitches, t_max_strikes) = 
    if fantasy prefs <> 0. then
  (* in fantasy mode we evaluate the first max_pitches locations *)
      (max_pitches prefs, max_int)
    else if max_strikes prefs = 0 then 
  (* we have disabled ball playing, and evaluate every location *)
      (max_int, max_int)
    else
  (* usual ball playing *)
      (max_pitches prefs, max_strikes prefs)
  and num_queries = 
    Fasta_channel.size_checking_for_duplicate_names query_channel
  in
  (* making glvs which are appropriate for query side of the first placement
   * stage. in contrast to the second stage query glv, this guy is full length. *)
  let full_query_orig = 
    Glv.make ~n_rates:(Model.n_rates model) 
             ~n_sites:ref_length
             ~n_states:(Model.n_states model)
  in
  let full_query_evolv = Glv.mimic full_query_orig in
  (* our result array *)
  let result_arr = 
    Array.make num_queries
    (Pquery.make Placement.ml_ratio ~name:"" ~seq:"" [])
  in
  (* *** the main query loop *** *)
  let process_query query_num (query_name, pre_query_seq) = 
    if fantasy prefs = 0. || query_num mod fantasy_mod = 0 then begin
    (* we only proceed if fantasy baseball is turned off or if this is one of
     * the sequences used for the fantasy baseball procedure *)
    let query_seq = String.uppercase pre_query_seq in
    if String.length query_seq <> ref_length then
      failwith ("query '"^query_name^"' is not the same length as the ref alignment");
    if (verb_level prefs) >= 1 then begin
      Printf.printf "running '%s' %d / %d ...\n" query_name (query_num+1) num_queries; 
      flush_all ()
    end;
    (* pull out the friend *)
    let friend = 
      if friendly_run then friend_prof.(query_num) 
      else Friendly.Friendless
    in
    (* if we have an identical friend, then we can use that friend's info *)
    match friend with
    | Friendly.Identical j ->
        result_arr.(query_num) <-
          Pquery.set_name result_arr.(j) query_name
    (* otherwise, start the evaluation *)
    | _ -> begin
    (* prepare the query glv *)
    let query_arr = StringFuns.to_char_array query_seq in
    (* the mask array shows true if it's included *)
    let informative c = c <> '?' && c <> '-' in
    let mask_arr = Array.map informative query_arr in
    let masked_query_arr = 
      Alignment.array_filteri (fun _ c -> informative c) query_arr in
    if masked_query_arr = [||] then
      failwith (query_name^" has no informative sites.");
    let first_informative = Base.array_first informative query_arr
    and last_informative = Base.array_last informative query_arr in
    let lv_arr_of_char_arr a = 
      match seq_type with
      | Alignment.Nucleotide_seq -> Array.map Nuc_models.lv_of_nuc a
      | Alignment.Protein_seq -> Array.map Prot_models.lv_of_aa a
    in
    (* the query glv, which has been masked *)
    let query_glv = 
      Glv.lv_arr_to_constant_rate_glv 
        (Model.n_rates model) 
        (lv_arr_of_char_arr masked_query_arr)
    in
    (* the full one, which will be used for the first stage only *)
    Glv.prep_constant_rate_glv_from_lv_arr
      full_query_orig 
      (lv_arr_of_char_arr query_arr);
    Glv.evolve_into 
      model 
      ~dst:full_query_evolv 
      ~src:full_query_orig
      (start_pend prefs);
    (* make a masked alignment with just the given query sequence and the
     * reference seqs *)
    if write_masked prefs then
      Alignment.toFasta
        (Alignment.mask_align mask_arr
          (Alignment.stack [|query_name, query_seq|] ref_align))
        (query_name^".mask.fasta");
    (* make our edges. we are breaking interface by making them then changing
     * them later, but it would be silly to have setting functions for each
     * edge. *)
    let dist_edge = Glv_edge.make model (Glv.mimic query_glv) (start_pend prefs)
    and prox_edge = Glv_edge.make model (Glv.mimic query_glv) (start_pend prefs)
    and pend_edge = Glv_edge.make model query_glv (start_pend prefs)
    in
    (* the h_r ranks the locations according to the h criterion. we use
     * this as an ordering for the slower computation *)
    let curr_time = Sys.time () in
    let h_r = 
      List.sort
        (fun (_,l1) (_,l2) -> - compare l1 l2)
        (List.map
          (fun loc ->
            (loc,
            Glv.bounded_logdot model full_query_evolv 
              (Glv_arr.get snodes loc) first_informative last_informative))
          locs)
    in
    if (verb_level prefs) >= 2 then Printf.printf "ranking took\t%g\n" ((Sys.time ()) -. curr_time);
    let h_ranking = List.map fst h_r in
    (* first get the results from ML *)
    let curr_time = Sys.time () in
    (* make our three taxon tree. we can't move this higher because the cached
     * calculation on the edges needs to be the right size for the length of
     * the query sequence. *)
    let tt = 
      Three_tax.make 
        model
        ~dist:dist_edge ~prox:prox_edge ~pend:pend_edge
    in
    (* set up the function which gives placements by location *)
    let get_friend_place = 
      match friend with
      (* no friend *)
      | Friendly.Friendless -> fun _ -> None
      (* if identical, should have skipped optimization *)
      | Friendly.Identical _ -> assert(false)
      (* set up the function *)
      | Friendly.Friend friend_num -> begin
          let f = result_arr.(friend_num) in
          fun loc -> Pquery.opt_place_by_location f loc
      end
    in 
(* set tt edges to be for location loc with given pendant and distal branch lengths *)
    let set_tt_edges loc ~pendant ~distal = 
      let cut_bl = Gtree.get_bl gtree loc in
      let set_edge edge glv_arr len = 
        Glv.mask_into 
          mask_arr
          ~src:(Glv_arr.get glv_arr loc) 
          ~dst:(Glv_edge.get_orig edge);
        Glv_edge.set_bl model edge len
      in
      (* still the same glv for query, but have to set branch length *)
      Glv_edge.set_bl model pend_edge pendant;
      (* need to set the glv and branch length for dist and prox *)
      set_edge dist_edge darr distal;
      set_edge prox_edge parr (cut_bl -. distal)
    in
    let tt_edges_default loc =
      let cut_bl = Gtree.get_bl gtree loc in
      set_tt_edges loc 
      ~pendant:(start_pend prefs)
      ~distal:(cut_bl /. 2.) 
    in
    let tt_edges_from_placement p = 
      let loc = Placement.location p in
      set_tt_edges loc 
        ~pendant:(Placement.pendant_bl p)
        ~distal:(Placement.distal_bl p)
    in
    (* prepare_tt: set tt up for loc. side effect! *)
    let prepare_tt loc = 
    (* set up branch lengths, using a friend's branch lengths if we have them *)
      match get_friend_place loc with
      | None -> (* set to usual defaults *)
          tt_edges_default loc
      | Some f -> (* use a friend's branch lengths *)
          tt_edges_from_placement f
    in
    (* evaluate the location wrt ML *)
    let ml_optimize_location mlo_tolerance loc = 
      let () = 
        try
          let n_like_calls = 
            Three_tax.optimize mlo_tolerance (max_pend prefs) max_iter tt
          in
          if 2 < verb_level prefs then
            Printf.printf "\tlocation %d: %d likelihood function calls\n" loc n_like_calls;
        with
        | Minimization.ExceededMaxIter ->
            Printf.printf 
              "optimization for %s at %d exceeded maximum number of iterations.\n"
              query_name
              loc;
      in
      (* get the results *)
      Three_tax.get_results tt
    in
    let safe_ml_optimize_location tol loc = 
      try ml_optimize_location tol loc with
      | Gsl_error.Gsl_exn(_,_) -> begin
        (* try again starting with default branch lengths *)
        tt_edges_default loc;
        ml_optimize_location tol loc
      end
    in
    (* in play_ball we go down the h_ranking list and wait until we get
     * strike_limit strikes, i.e. placements that are strike_box below the
     * best one so far. *)
    let rec play_ball like_record n_strikes results = function
      | loc::rest -> begin
          try 
            prepare_tt loc;
            let (like,_,_) as result = 
              safe_ml_optimize_location (initial_tolerance prefs) loc in
            let new_results = (loc, result)::results in
            if List.length results >= t_max_pitches then
              new_results
            else if like > like_record then
              (* we have a new best likelihood *)
              play_ball like n_strikes new_results rest
            else if like < like_record-.(strike_box prefs) then
              (* we have a strike *)
              if n_strikes+1 >= t_max_strikes then new_results
              else play_ball like_record (n_strikes+1) new_results rest
            else
              (* not a strike, just keep on accumulating results *)
              play_ball like_record n_strikes new_results rest
          with
(* we need to handle the exception here so that we continue the baseball recursion *)
          | Gsl_error.Gsl_exn(_,warn_str) ->
              Printf.printf "Warning: GSL problem with location %d for query %s; Skipped with warning \"%s\".\n" loc query_name warn_str;
              play_ball like_record n_strikes results rest
         end
      | [] -> results
    in
    let ml_results = 
 (* important to reverse for fantasy baseball. also should save time on sorting *)
      List.rev (play_ball (-. infinity) 0 [] h_ranking) 
    in
    if ml_results = [] then
      failwith 
        (Printf.sprintf "empty results for %s, query number %d!\n"
                        query_name query_num);
    if (verb_level prefs) >= 2 then Printf.printf "ML calc took\t%g\n" ((Sys.time ()) -. curr_time);
    if fantasy prefs <> 0. then begin
      Fantasy.add_to_fantasy_matrix ml_results fantasy_mat;
      incr n_fantasies;
    end;
    (* these tuples are ugly but that way we don't need
     * to make a special type for ml results. *)
    let get_like (_, (like, _, _)) = like in
    let decreasing_cmp_likes r1 r2 = 
      - compare (get_like r1) (get_like r2) in
    let sorted_ml_results = 
      List.sort decreasing_cmp_likes ml_results in
    assert(sorted_ml_results <> []);
    let best_like = get_like (List.hd sorted_ml_results) in
    let keep_results, _ = 
      ListFuns.partitioni 
        (fun i r -> 
          ((i < keep_at_most) &&
          (get_like r >= log_keep_factor +. best_like)))
        sorted_ml_results
    in
    (* do final refinement of branch lengths *)
    let refined_results = 
      List.map
        (fun initial ->
          let (loc, (_, pendant, distal)) = initial in
          set_tt_edges loc ~pendant ~distal;
          try
            (loc, safe_ml_optimize_location final_tolerance loc)
          with
          | Gsl_error.Gsl_exn(_,warn_str) ->
              Printf.printf "Warning: GSL problem with final branch length optimization for location %d. %s\n" loc warn_str;
              initial)
        keep_results
    in
    let sorted_ml_placements = 
      List.map2 
        (fun ml_ratio (loc, (log_like, pend_bl, dist_bl)) -> 
          Placement.make_ml 
            loc ~ml_ratio ~log_like ~pend_bl ~dist_bl)
         (Base.ll_normalized_prob (List.map get_like refined_results))
         refined_results
    in
    result_arr.(query_num) <-
      Pquery.make_ml_sorted
        ~name:query_name 
        ~seq:query_seq
        (if (calc_pp prefs) then begin
          (* pp calculation *)
          let curr_time = Sys.time () in
        (* calculate marginal likes for those placements we will keep *)
          let marginal_probs = 
            List.map 
              (fun placement ->
                tt_edges_from_placement placement;
                Three_tax.calc_marg_prob 
                  prior_fun (pp_rel_err prefs) (max_pend prefs) tt)
              sorted_ml_placements
          in
          (* add pp *)
          if (verb_level prefs) >= 2 then Printf.printf "PP calc took\t%g\n" ((Sys.time ()) -. curr_time);
            ((ListFuns.map3 
              (fun placement marginal_prob post_prob ->
                Placement.add_pp placement ~marginal_prob ~post_prob)
              sorted_ml_placements
              marginal_probs
              (Base.ll_normalized_prob marginal_probs)))
        end
        else sorted_ml_placements)
  end
  end
  in
  Fasta_channel.named_seq_iteri process_query query_channel;
  if fantasy prefs <> 0. then begin
    Fantasy.results_to_file 
      (Filename.basename (Filename.chop_extension query_fname))
      fantasy_mat (!n_fantasies);
      Fantasy.print_optimum fantasy_mat (fantasy prefs) (!n_fantasies);
  end;
  result_arr

