(* pplacer v0.3. Copyright (C) 2009  Frederick A Matsen.
 * This file is part of pplacer. pplacer is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. pplacer is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with pplacer. If not, see <http://www.gnu.org/licenses/>.
 *
 * here we actually do the work.
*)

open Fam_batteries
open MapsSets
open Prefs

let max_iter = 100
let prof_prefix_req = 1
let prof_length = 5 

type prior = Uniform_prior | Exponential_prior of float

(* pplacer_core :
  * actually try the placements, etc. return placement records *)
let pplacer_core 
      prefs query_fname prior model ref_align gtree 
      ~darr ~parr ~halfd ~halfp locs = 
  let seq_type = Model.seq_type model in
  let max_bytes = Memory.bytes_of_gb (max_memory prefs) 
  and max_usage = ref 0 in
  let update_usage () = 
    let cb = Memory.curr_bytes () in
    if cb > !max_usage then max_usage := cb
  in
  let prior_fun =
    match prior with
    | Uniform_prior -> (fun _ -> 1.)
    | Exponential_prior mean ->
        fun pend -> Gsl_randist.exponential_pdf ~mu:mean pend
  in
  let query_channel = Fasta_channel.of_fname query_fname in
  (* cycle through queries *)
  let num_queries = 
    Fasta_channel.size_checking_for_duplicate_names query_channel in
  let ref_length = Alignment.length ref_align in
  let result_arr = 
    Array.make num_queries
    (Pquery.make Placement.ml_ratio ~name:"" ~seq:"" []) in
  let prof_trie = ref Ltrie.empty in
  let fantasy_mat = 
    if fantasy prefs then
      Fantasy.make_fantasy_matrix 
        ~max_strike_box:(int_of_float (strike_box prefs))
        ~max_strikes:(max_strikes prefs)
    else [||]
  in
  (* the main query loop *)
  let process_query query_num (query_name, pre_query_seq) = 
    let query_seq = String.uppercase pre_query_seq in
    update_usage ();
    if Memory.ceiling_collection max_bytes then 
      if (verb_level prefs) >= 1 then begin
        print_endline "performed garbage collection";
        Memory.check_ceiling max_bytes;
      end;
    if String.length query_seq <> ref_length then
      failwith ("query '"^query_name^"' is not the same length as the ref alignment");
    if (verb_level prefs) >= 1 then begin
      Printf.printf "running '%s' %d / %d ...\n" query_name (query_num+1) num_queries; 
      flush_all ()
    end;
    (* prepare the query glv *)
    let query_arr = StringFuns.to_char_array query_seq in
    let mask_arr = 
      Array.map (fun c -> c <> '?' && c <> '-') query_arr in
    let query_like = 
      match seq_type with
      | Alignment.Nucleotide_seq -> Array.map Nuc_models.lv_of_nuc query_arr
      | Alignment.Protein_seq -> Array.map Prot_models.lv_of_aa query_arr
    in
    let query_glv = 
      Glv.lv_list_to_constant_rate_glv 
        (Model.n_rates model) 
        (Base.mask_to_list mask_arr query_like)
    in
    (* make a masked alignment with just the given query sequence and the
     * reference seqs *)
    if (write_masked prefs) then
      Alignment.toFasta
        (Alignment.mask_align mask_arr
          (Alignment.stack [|query_name, query_seq|] ref_align))
        (query_name^".mask.fasta");
   (* mask *) 
    let curr_time = Sys.time () in
    let darr_masked = Glv_arr.mask mask_arr darr 
    and parr_masked = Glv_arr.mask mask_arr parr 
    and halfd_maskd = Glv_arr.mask mask_arr halfd 
    and halfp_maskd = Glv_arr.mask mask_arr halfp 
    in
    if (verb_level prefs) >= 2 then Printf.printf "masking took\t%g\n" ((Sys.time ()) -. curr_time);
    (* make our edges.
     * start them all with query as a place holder.
     * we are breaking interface by naming them and changing them later, but
     * it would be silly to have setting functions for each edge.  *)
    let dist_edge = Glv_edge.make model query_glv (start_pend prefs)
    and prox_edge = Glv_edge.make model query_glv (start_pend prefs)
    and query_edge = Glv_edge.make model query_glv (start_pend prefs)
    in
    (* get the results from the h_map *)
    let q_evolved = Glv_edge.get_evolv query_edge in
    (* the h_r ranks the locations according to the h criterion. we use
     * this as an ordering for the slower computation *)
    let curr_time = Sys.time () in
    let h_r = 
      List.sort
        (fun (_,l1) (_,l2) -> - compare l1 l2)
        (List.map
          (fun loc ->
            (loc,
            Glv.log_like3_statd model 
              q_evolved 
              (Glv_arr.get halfd_maskd loc) 
              (Glv_arr.get halfp_maskd loc)))
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
        ~dist:dist_edge ~prox:prox_edge ~query:query_edge
    in
    (* finding a friend *)
    let friend =
      if prof_length = 0 then None (* profiling turned off *)
      else begin
        let prof = Ltrie.list_first_n h_ranking prof_length in
        let friend_result = 
          if Ltrie.prefix_mem prof prof_prefix_req !prof_trie then 
            (* we pass the prefix test *)
            begin
              let f_index = Ltrie.int_approx_find prof !prof_trie in
              if (verb_level prefs) >= 2 then
                Printf.printf "found friend in %d\n" f_index;
              assert(f_index < query_num);
              Some (result_arr.(f_index))
            end
          else None
        in
        prof_trie := Ltrie.add prof query_num !prof_trie;
        friend_result
      end
    in
    let get_friend_place loc = 
      match friend with
      | None -> None
      | Some f -> Pquery.opt_place_by_location f loc
    in 
    (* prepare_tt: set tt up for loc. side effect! *)
    let prepare_tt loc = 
      let cut_bl = Gtree.get_bl gtree loc in
      (* this is just to factor out setting up the prox and dist edges *)
      let set_edge edge glv_arr len = 
        Glv_edge.set_orig_and_bl 
          model
          edge
          (Glv_arr.get glv_arr loc) 
          len
      in
    (* set up branch lengths, using a friend's branch lengths if we have them *)
      match get_friend_place loc with
      | None -> (* set to usual defaults *)
        (* set the query edge to the default *)
        Glv_edge.set_bl model query_edge (start_pend prefs);
        (* set the distal and proximal edges to half of the cut one *)
        set_edge dist_edge darr_masked (cut_bl /. 2.);
        set_edge prox_edge parr_masked (cut_bl /. 2.)
      | Some f -> (* use a friend's branch lengths *)
        Glv_edge.set_bl model query_edge (Placement.pendant_bl f);
        (* set the distal and proximal edges to half of the cut one *)
        let distal = Placement.distal_bl f in
        set_edge dist_edge darr_masked distal;
        set_edge prox_edge parr_masked (cut_bl -. distal)
    in
    let ml_evaluate_location loc = 
      prepare_tt loc;
      (* optimize *)
      let () = 
        try
          let n_like_calls = 
            Three_tax.optimize (tolerance prefs) (max_pend prefs) max_iter tt
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
    let gsl_warn loc query_name = 
      Printf.printf "Warning: GSL had a problem with location %d for query %s; it was skipped.\n" loc query_name;
    in
    let (t_max_pitches, t_max_strikes) = 
      if max_strikes prefs = 0 then 
    (* we have disabled ball playing, and evaluate every location *)
        (max_int, max_int)
      else if fantasy prefs then
    (* in fantasy mode we evaluate the first max_pitches locations *)
        (max_pitches prefs, max_int)
      else
    (* usual ball playing *)
        (max_pitches prefs, max_strikes prefs)
    in
    (* in play_ball we go down the h_ranking list and wait until we get
     * strike_limit strikes, i.e. placements that are strike_box below the
     * best one so far. *)
    let rec play_ball like_record n_strikes results = function
      | loc::rest -> begin
          try 
            let (like,_,_) as result = 
              ml_evaluate_location loc in
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
          | Gsl_error.Gsl_exn(_,_) ->
              gsl_warn loc query_name;
              play_ball like_record n_strikes results rest
         end
      | [] -> results
    in
    let ml_results = 
 (* important to reverse for fantasy baseball. also should save time on sorting *)
      List.rev (play_ball (-. infinity) 0 [] h_ranking) 
    in
    if (verb_level prefs) >= 2 then Printf.printf "ML calc took\t%g\n" ((Sys.time ()) -. curr_time);
    if fantasy prefs then
      Fantasy.add_to_fantasy_matrix ml_results fantasy_mat;
    (* calc ml weight ratios. these tuples are ugly but that way we don't need
     * to make a special type for ml results. *)
    let ml_ratios = 
      Base.ll_normalized_prob 
        (List.map 
          (fun (_, (like, _, _)) -> like) 
          ml_results) 
    in
    let ml_sorted_results = 
      Placement.sort_placecoll 
        Placement.ml_ratio
        (List.map2 
          (fun ml_ratio (loc, (log_like, pend_bl, dist_bl)) -> 
            Placement.make_ml 
              loc ~ml_ratio ~log_like ~pend_bl ~dist_bl)
          ml_ratios ml_results)
    in
    let above_cutoff, below_cutoff = 
      List.partition 
        (fun p -> Placement.ml_ratio p >= (ratio_cutoff prefs))
        ml_sorted_results
    in
  (* the tricky thing here is that we want to keep the optimized branch lengths
   * for all of the pqueries that we try so that we can use them later as
   * friends. however, we don't want to calculate pp for all of them, and we
   * don't want to return them for writing either *)
    result_arr.(query_num) <-
      Pquery.make_ml_sorted
        ~name:query_name 
        ~seq:query_seq
        (if (calc_pp prefs) then begin
          (* pp calculation *)
          let curr_time = Sys.time () in
          (* calculate marginal likes for those placements whose ml ratio is
           * above cutoff *)
          let marginal_probs = 
            List.map 
              (fun placement ->
                prepare_tt (Placement.location placement);
                Three_tax.calc_marg_prob 
                  prior_fun (pp_rel_err prefs) (max_pend prefs) tt)
              above_cutoff
          in
          (* just add pp to those above cutoff *)
          if (verb_level prefs) >= 2 then Printf.printf "PP calc took\t%g\n" ((Sys.time ()) -. curr_time);
            ((ListFuns.map3 
              (fun placement marginal_prob post_prob ->
                Placement.add_pp placement ~marginal_prob ~post_prob)
              above_cutoff
              marginal_probs
              (Base.ll_normalized_prob marginal_probs))
          (* keep the ones below cutoff, but don't calc pp *)
              @ below_cutoff)
        end
        else ml_sorted_results)
  in
  Fasta_channel.named_seq_iteri process_query query_channel;
  if fantasy prefs then
    Fantasy.results_to_file 
      (Filename.basename (Filename.chop_extension query_fname))
      fantasy_mat num_queries;
(* here we actually apply the ratio cutoff so that we don't write them to file *)
  let results = 
    Array.map (Pquery.apply_cutoff (ratio_cutoff prefs)) result_arr
  in
  update_usage ();
  if (verb_level prefs) >= 1 then 
    Printf.printf "maximal memory usage for %s: %d bytes\n" 
                  query_fname (!max_usage);
  results

