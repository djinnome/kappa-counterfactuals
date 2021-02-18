(******************************************************************************)
(*  _  __ * The Kappa Language                                                *)
(* | |/ / * Copyright 2010-2017 CNRS - Harvard Medical School - INRIA - IRIF  *)
(* | ' /  *********************************************************************)
(* | . \  * This file is distributed under the terms of the                   *)
(* |_|\_\ * GNU Lesser General Public License Version 3                       *)
(******************************************************************************)
(*                                                                            *)
(*  Author / Maintainer: Jonathan Laurent (jonathan.laurent@cs.cmu.edu)       *)
(*                                                                            *)
(******************************************************************************)

(** Resimulation algorithm that serves as a basis for
    counterfactual reasoning. *)

open Kappa_terms
open Kappa_runtime
open Kappa_mixtures
open Kappa_generic_toolset

module Algos = struct

  (*  This function solves the following problem:
      Given `n` boxes containing white and black balls, pick one ball
      from each box conditionned to the fact that at least one ball has
      to be black.

      Input: [prob] is an array of size `n` whose ith element
      is the probability to draw a black ball from the ith box.Agent

      Returns: an array of `n` booleans, [true] representing a black ball
      and [false] a white ball. *)

  let draw_at_least_one random_state probs =

      let draw_exp p =
          if p = 0. then max_int
          else if p = 1. then 1
          else
            let x = Random.State.float random_state 1.0 in
            int_of_float (ceil (log1p (-. x) /. log1p (-. p))) in

      let array_min t =
          Array.fold_left min t.(0) t in

      let r = Array.map draw_exp probs in
      let m = array_min r in
      Array.map (fun e -> e = m) r

  (* Alternate implementation *)
  let draw_at_least_one' random_state probs =
      let draw p = (Random.State.float random_state 1.0) <= p in
      let f p1 lst = p1 /. (1. -. (List.fold_left (fun acc e -> acc*.(1. -. e)) 1. (p1::lst))) in
      let rec _draw_at_least_one probs =
      match probs with
      | [] -> []
      | hd::tl when draw (f hd tl) -> true::(List.map draw tl)
      | _hd::tl -> false::(_draw_at_least_one tl)
      in Array.of_list (_draw_at_least_one (Array.to_list probs))

end

module Util = struct

  let array_zip_with f t t' =
    let n = min (Array.length t) (Array.length t') in
    Array.init n (fun i -> f t.(i) t'.(i))

  let array_product = Array.fold_left ( * ) 1

  let array_eq p p' =
    let exception Different_arrays in
    let n = Array.length p in
      Array.length p' = n &&
      begin
        try
          p |> Array.iteri (fun i v ->
            if p'.(i) <> v then raise Different_arrays) ;
          true
        with Different_arrays -> false
      end

  let partition_int_collection f col =
    let n = IntCollection.size col in
    let true_c = IntCollection.create n in
    let false_c = IntCollection.create n in
    IntCollection.fold (fun i () ->
      if f i then IntCollection.add i true_c
      else IntCollection.add i false_c
    ) col () ;
    (true_c, false_c)

  let int_collection_singleton i =
    let c = IntCollection.create 1 in
    IntCollection.add i c ;
    c

  exception Found

  let inefficient_int_collection_mem i c =
    try
      IntCollection.fold (fun j () ->
        if i = j then raise Found
      ) c () ; false
    with Found -> true

  let rec range a b = if a > b then [] else a :: range (a+1) b

  let rec map_filter f = function
    | [] -> []
    | x::xs ->
      match f x with
      | Some y -> y :: map_filter f xs
      | None -> map_filter f xs

  module Int = struct type t = int let compare = compare end
  module IntMap = Map.Make(Int)
  module IntSet = Set.Make(Int)

  let identity x = x

  let const x _ = x

  let const2 x _ _ = x

end

open Util

(******************************************************************************)
(* INTERVENTIONS                                                              *)
(******************************************************************************)

type event_properties = {
  rule_instance: int option ;
  actions: (Instantiation.concrete Instantiation.action) list ;
  tests: (Instantiation.concrete Instantiation.test) list ;
  factual_event_id: int option ;
}

type event_predicate = Model.t -> event_properties -> bool

type partial_event =
  { pe_rule_instance: int ;
    pe_pat: Pattern.id ;
    pe_root: int }

type partial_event_predicate =
  Model.t -> Edges.t -> partial_event -> bool

type intervention_id = int

type intervention = {
  block: event_predicate ;
  block_partial: partial_event_predicate ;
  rules_to_monitor: int list ;
}

let merge_interventions interventions =
  let interventions =
    IntMap.bindings interventions
    |> List.map (fun (_, i) -> i) in

  let rules_to_monitor =
    interventions
    |> List.map (fun i -> i.rules_to_monitor)
    |> List.concat
    |> List.sort_uniq compare in

  let block model e =
    List.exists (fun i -> i.block model e) interventions in

  let block_partial model graph pe =
    List.exists (fun i -> i.block_partial model graph pe) interventions in

  { rules_to_monitor ; block ; block_partial }


(******************************************************************************)
(* DIVERGENT INSTANCES                                                        *)
(******************************************************************************)

type div_instances_message =
    | New_cur_mixture of Edges.t
    (** This message is sent when the current mixture is updated.
        A reference to the current mixture is needed by `is_divergent` *)

    | New_reference_state of Edges.t * (Pattern.id * Agent.t) list
    (** This message is sent when the reference graph is updated.
        It contains:
         + The new reference graph
         + A list of observables whose status (convergent or divergent)
           might have changed *)
    | Flush_roots_buffer
    (** Calls to [Divergent_instances.update_roots] are put in a cache
        and executed when this message is received *)

    | Set_intervention of bool * intervention
    (** This message is sent when a new intervention is set.
        The boolean is true iff specialized instances should be used. *)


type mod_ccs_cache = (int, unit) Hashtbl.t

type divergent_instances = {
  conv_roots : Roots.t ;
  div_roots  : Roots.t ;

  reference_mixture : Edges.t ;
  current_mixture : Edges.t ;
  (* Has to be updated at each event loop using `send_message` *)

  precomputed_unary_patterns : Pattern.Set.t ;
  (* Useful to call `update_roots` in *)

  domain : Pattern.Env.t ;
  (* The domain has to be stored in [t] because of
      the `is_divergent` function. *)

  roots_buffer : (bool * mod_ccs_cache * Pattern.id * int) Queue.t
  (* Calls to [Divergent_instances.update_roots] are put in this cache
      and executed when the message [Flush_roots_buffer] is received *)
}

module type DIVERGENT_INSTANCES =
  Instances_sig.S with type message = div_instances_message

module type DIVERGENT_INSTANCES_TRANSPARENT =
  DIVERGENT_INSTANCES with type t = divergent_instances

module Divergent_instances : DIVERGENT_INSTANCES_TRANSPARENT =
struct

  type t = divergent_instances

  let break_apart_cc insts graph ?mod_connectivity_store ccs =
    Roots.break_apart_cc insts.conv_roots graph ?mod_connectivity_store ccs;
    Roots.break_apart_cc insts.div_roots graph ?mod_connectivity_store ccs

  let merge_cc insts ?mod_connectivity_store ccs =
    Roots.merge_cc ?mod_connectivity_store insts.conv_roots ccs;
    Roots.merge_cc ?mod_connectivity_store insts.div_roots ccs

  let empty model =
    { reference_mixture = Edges.empty ~with_connected_components:true ;
      current_mixture = Edges.empty ~with_connected_components:true ;
      domain = Model.domain model ;
      precomputed_unary_patterns = Model.unary_patterns model ;
      conv_roots = Roots.empty model ;
      div_roots = Roots.empty model ;
      roots_buffer = Queue.create () }

  let debug_print fmt insts =
    Format.fprintf fmt "[CONVERGENT]:@;%a@.@.[DIVERGENT]:%a@."
      Roots.debug_print insts.conv_roots
      Roots.debug_print insts.div_roots

  exception Divergent

  (* [root] must be the root of an embedding of [pat_id] in [graph]  *)
  let is_divergent domain ref_graph graph pat_id root =
    let nav = Pattern.Env.to_navigation domain pat_id in
    let ag = (root, Edges.get_sort root graph) in
    match Navigation.concretize ~debugMode:false ag graph nav with
    | None -> false
    (* Means the observable is outdated and so it will
        be removed soon, so we can give any answer *)
    | Some nav ->

    let compare_step ((ag, s), arr) =
      match arr with
      | Navigation.ToNode (ag', s') ->
        begin
          assert (Edges.link_exists ag s ag' s' graph) ;
          if not (Edges.link_exists ag s ag' s' ref_graph) then raise Divergent
        end
      | Navigation.ToNothing ->
        begin
          assert (Edges.is_free ag s graph) ;
          if not (Edges.is_free ag s ref_graph) then raise Divergent
        end
      | Navigation.ToInternal st ->
        begin
          assert (Edges.is_internal st ag s graph) ;
          if not (Edges.is_internal st ag s ref_graph) then raise Divergent
        end in

    try begin List.iter compare_step nav ; (false) end
    with Divergent -> (true)

  let update_roots insts is_positive_update _unary_pats _graph cache id root =
    Queue.push (is_positive_update, cache, id, root) insts.roots_buffer

  let update_roots_now insts is_positive_update unary_pats graph cache id root =
    let update is =
      Roots.update_roots is is_positive_update unary_pats graph cache id root in
    if not is_positive_update then
    begin
      update insts.div_roots ;
      update insts.conv_roots
    end
    else if is_divergent insts.domain insts.reference_mixture graph id root then
      update insts.div_roots
    else
      update insts.conv_roots

  (* Checking validity *)

  let is_valid inst patid i = assert false

  (* Update the status of an observable (convergent or divergent) *)
  let update_obs_status insts pat_id root =
    let dummy_cache = Hashtbl.create 10 in
    let ups = insts.precomputed_unary_patterns in
    let graph = insts.current_mixture in
    update_roots_now insts false ups graph dummy_cache pat_id root ;
    update_roots_now insts true ups graph dummy_cache pat_id root


  let incorporate_extra_pattern st pat_id roots =
    let is_divergent = is_divergent st.domain
      st.reference_mixture st.current_mixture pat_id in
    let div_roots, conv_roots =
      Util.partition_int_collection is_divergent roots in
    Roots.incorporate_extra_pattern st.div_roots pat_id div_roots ;
    Roots.incorporate_extra_pattern st.conv_roots pat_id conv_roots


  type message = div_instances_message

  let receive_message msg st =
      match msg with
      | New_cur_mixture edges -> { st with current_mixture = edges }
      | New_reference_state (edges, obs) ->
        begin
          let st = { st with reference_mixture = edges } in
          obs |> List.iter (fun (pat_id, (root, _root_ty)) ->
            update_obs_status st pat_id root
          ) ; st
        end
      | Flush_roots_buffer ->
        begin
          Queue.iter (fun (is_pos, cache, pat_id, root) ->
            update_roots_now st is_pos st.precomputed_unary_patterns
              st.current_mixture cache pat_id root
          ) st.roots_buffer ;
          Queue.clear st.roots_buffer ;
          st
        end
      | Set_intervention _ -> st

  let get_unary_maps st (pat1, pat2) =
    let map1_conv = Roots.of_unary_pattern pat1 st.conv_roots in
    let map2_conv = Roots.of_unary_pattern pat2 st.conv_roots in
    let map1_div  = Roots.of_unary_pattern pat1 st.div_roots  in
    let map2_div  = Roots.of_unary_pattern pat2 st.div_roots  in
    map1_conv, map2_conv, map1_div, map2_div


  (** {6 Counting instances } *)

  let number_of_instances ?rule_id:_ insts pats =
    let cc_counts xs =
      Array.map (fun pat -> Roots.number xs pat) pats in
    let convs = cc_counts insts.conv_roots in
    let divs = cc_counts insts.div_roots in
    array_product (array_zip_with (+) convs divs) - array_product convs


  let number_of_unary_instances_in_cc ?rule_id:_ st (pat1, pat2) =
    let map1_conv, map2_conv, map1_div, map2_div =
        get_unary_maps st (pat1, pat2) in
    fun cc ->
      let size_cc m = Mods.IntSet.size
        (Mods.IntMap.find_default Mods.IntSet.empty cc m) in
      let n1_conv = size_cc map1_conv in
      let n2_conv = size_cc map2_conv in
      let n1_div  = size_cc map1_div  in
      let n2_div  = size_cc map2_div  in
      (n1_conv + n1_div) * (n2_conv + n2_div) - n1_conv * n2_conv


  (** {6 Picking instances } *)

  module type INT_SET = sig
    type t
    val size : t -> int
    val random : Random.State.t -> t -> int option
    val fold : (int -> 'a -> 'a) -> t -> 'a -> 'a
  end

  let pick (type set) (module S : INT_SET with type t = set)
    random_state (conv_sets : set array) (div_sets : set array) =

    let n  = Array.length conv_sets in
    let n' = Array.length div_sets  in
    assert (n = n') ;
    let probs = Array.init n (fun i ->
      let nc = S.size conv_sets.(i) in
      let nd = S.size div_sets.(i) in
      float_of_int nd /. float_of_int (nc + nd)
    ) in
    let is_div = Algos.draw_at_least_one random_state probs in
    Array.init n (fun i ->
      if is_div.(i)
      then S.random random_state div_sets.(i)
      else S.random random_state conv_sets.(i)
    )
    |> Array.map (Option_util.unsome (-1))


  let pick_unary_instance_in_cc ?rule_id:_ st random_state (pat1, pat2) =
    let map1_conv, map2_conv, map1_div, map2_div =
      get_unary_maps st (pat1, pat2) in
    fun cc ->
      let rts m =
        (Mods.IntMap.find_default Mods.IntSet.empty cc m) in
      let roots = pick (module Mods.IntSet) random_state
        [| rts map1_conv ; rts map2_conv |]
        [| rts map1_div ; rts map2_div |] in
      roots.(0), roots.(1)


  let fold_picked_instance ?rule_id:_ st random_state pats ~init f =
    let conv_sets =
      Array.map (fun pat_id -> Roots.of_pattern pat_id st.conv_roots) pats in
    let div_sets =
      Array.map (fun pat_id -> Roots.of_pattern pat_id st.div_roots) pats in
    let roots = pick (module IntCollection) random_state conv_sets div_sets in

    let rec aux i acc =
      if i >= Array.length pats then acc else
      match acc with
        | None -> None
        | Some acc ->
          begin
            let root = roots.(i) in
            assert (root <> (-1)) ;
            let acc = f i pats.(i) root acc in
            aux (i+1) acc
          end
    in aux 0 (Some init)


  (** {6 Enumerating instances } *)

  module Pat = struct
    type t = int array
    let equal = array_eq
    let hash p = Hashtbl.hash (Array.to_list p)
  end
  module PatHashtbl = Hashtbl.Make(Pat)

  let fold_combinations (type set) (module S : INT_SET with type t = set)
    conv_sets div_sets ~init f =

    let n  = Array.length conv_sets in
    let n' = Array.length div_sets  in
    assert (n = n') ;

    let size =
        array_product (array_zip_with (+)
          (Array.map S.size conv_sets) (Array.map S.size div_sets))
        - array_product (Array.map S.size conv_sets) in

    let closed_list = PatHashtbl.create size in

    let call l acc =
      if PatHashtbl.mem closed_list l then acc
      else begin
        let acc = f l acc in
        PatHashtbl.add closed_list (Array.copy l) () ;
        acc
      end in

    let take_div_at_i i acc =
      let tab = Array.make n (-1) in
      let rec aux j acc =
        let take_root r acc = begin tab.(j) <- r ; aux (j+1) acc end in
        if j >= n then call tab acc
        else
          let acc = S.fold take_root div_sets.(j) acc in
          if (j = i) then acc
          else S.fold take_root conv_sets.(j) acc
      in aux 0 acc in

    let acc = List.fold_right take_div_at_i (Util.range 0 (n-1)) init in
    assert (PatHashtbl.length closed_list = size) ;
    acc


  module List_as_set : INT_SET with type t = int list = struct
    type t = int list
    let size = List.length
    let random st l = Some (List_util.random st l)
    let fold = List.fold_right
  end

  let _test_fold_combinations () =
    let conv_sets = [| [11; 12]; [11]; [11; 12] |] in
    let div_sets = [| [21]; [21]; [21; 22] |] in
    fold_combinations (module List_as_set) conv_sets div_sets ~init:()
      (fun l () ->
        l |> Array.iter (fun i ->
          Printf.printf "%d " i
        ) ;
        print_newline ()
      )

  let process_excp pats set = function
  | None -> ()
  | Some (pat, root) ->
      pats
      |> Array.to_list
      |> List.mapi (fun i x -> (i, x))
      |> List.filter (fun (_, pat') -> Pattern.is_equal_canonicals pat pat')
      |> List.map fst
      |> List.iter (fun i ->
        (* [i] must be sent ro [root] *)
        if inefficient_int_collection_mem root set.(i)
        then set.(i) <- int_collection_singleton root
        else set.(i) <- IntCollection.create 0
      )

  let fold_instances ?rule_id:_ ?excp st pats ~init f =
    let conv_sets =
      Array.map (fun pat_id -> Roots.of_pattern pat_id st.conv_roots) pats in
    let div_sets =
      Array.map (fun pat_id -> Roots.of_pattern pat_id st.div_roots) pats in
    process_excp pats conv_sets excp ;
    process_excp pats div_sets excp ;
    fold_combinations (module IntCollection) conv_sets div_sets ~init f


  let map_fold4 ~def map1 map2 map3 map4 ~init f =
    let keys m = List.map fst (Mods.IntMap.bindings m) in
    let all_keys = List.sort_uniq compare
      (keys map1 @ keys map2 @ keys map3 @ keys map4) in
    List.fold_left (fun acc key ->
      let v1 = Mods.IntMap.find_default def key map1 in
      let v2 = Mods.IntMap.find_default def key map2 in
      let v3 = Mods.IntMap.find_default def key map3 in
      let v4 = Mods.IntMap.find_default def key map4 in
      f key v1 v2 v3 v4 acc
    ) init all_keys


  let fold_unary_instances ?rule_id:_ st (pat1, pat2) ~init f =
     let map1_conv, map2_conv, map1_div, map2_div = get_unary_maps st (pat1, pat2) in
     map_fold4 ~def:Mods.IntSet.empty map1_conv map2_conv map1_div map2_div ~init
      (fun _ rts1_conv rts2_conv rts1_div rts2_div acc ->
        fold_combinations (module Mods.IntSet)
          [| rts1_conv ; rts2_conv |] [| rts1_div ; rts2_div |] ~init:acc (fun c acc ->
          assert (Array.length c = 2) ;
          f (c.(0), c.(1)) acc
        )
      )

end


(******************************************************************************)
(* PER-RULE DIVERGENT INSTANCES                                               *)
(******************************************************************************)

module type RULE_PATS = sig
  type t
  val init : Model.t -> t
  val reset : t -> t
  val follow_rule : int -> t -> t
  val fold_rules : pat:Pattern.id -> init:'a -> (int -> 'a -> 'a) -> t -> 'a
  val fold_pats : rule_id:int -> init:'a -> (Pattern.id -> 'a -> 'a) -> t -> 'a
  val iter_rules : pat:Pattern.id -> (int -> unit) -> t -> unit
  val iter_pats : rule_id:int -> (Pattern.id -> unit) -> t -> unit
end

module Rule_pats : RULE_PATS =
struct

  module PSet = Pattern.Set
  module PMap = Pattern.Map

  type t = {
    rule_to_pats : PSet.t array ;
    pat_to_rules : IntSet.t PMap.t ;
  }

  let init model =
    let pats_set rule =
      Array.fold_left (fun acc pat_id ->
        PSet.add pat_id acc
      ) PSet.empty rule.Primitives.connected_components in
    let rule_to_pats = Array.map pats_set (Model.get_rules model) in
    { rule_to_pats ; pat_to_rules = PMap.empty }

  let reset t = { t with pat_to_rules = PMap.empty }

  let follow_rule r t =
    let pats = t.rule_to_pats.(r) in
    let pat_to_rules =
      PSet.fold (fun pat_id pat_to_rules ->
        let rs = PMap.find_default IntSet.empty pat_id pat_to_rules in
        let rs = IntSet.add r rs in
        PMap.add pat_id rs pat_to_rules
      ) pats t.pat_to_rules in
    { t with pat_to_rules }

  let fold_rules ~pat ~init f t =
    match PMap.find_option pat t.pat_to_rules with
    | None -> init
    | Some rs -> IntSet.fold f rs init

  let fold_pats ~rule_id ~init f t =
    PSet.fold f (t.rule_to_pats.(rule_id)) init

  let iter_rules ~pat f t =
    fold_rules ~pat ~init:() (fun r () -> f r) t

  let iter_pats ~rule_id f t =
    fold_pats ~rule_id ~init:() (fun p () -> f p) t

end


module Per_rule (Div : DIVERGENT_INSTANCES_TRANSPARENT) : DIVERGENT_INSTANCES =
struct

  type t =
    { def : Div.t ;
      rule : Div.t IntMap.t ;
      rule_pats : Rule_pats.t ;
      model : Model.t ;
      block_insts : partial_event_predicate }

  type message = div_instances_message

  let debug_print _f _t = assert false (* TODO *)

  let block_nothing _ _ _ = false

  let update_all f t =
    { t with def = f t.def ; rule = IntMap.map f t.rule }

  let apply_all f t =
    f t.def;
    IntMap.iter (fun _ v -> f v) t.rule

  let empty model =
    { def = Div.empty model ;
      rule = IntMap.empty ;
      rule_pats = Rule_pats.init model ;
      model ;
      block_insts = block_nothing }

  (* Copy a divergent instance *)
  let empty_copy model insts =
    { reference_mixture = insts.reference_mixture ;
      current_mixture = insts.current_mixture ;
      domain = insts.domain ;
      precomputed_unary_patterns = insts.precomputed_unary_patterns ;
      roots_buffer = Queue.copy insts.roots_buffer ;
      div_roots = Roots.empty model ;
      conv_roots = Roots.empty model }



  let initialize_specialized_instances ~model ~rule_id src dest pat_id blocked =
    let graph = src.current_mixture in
    let pre = src.precomputed_unary_patterns in
    let cache = Hashtbl.create 10 in

    let maybe_add root =
      let pe =
        { pe_rule_instance = rule_id ;
          pe_pat = pat_id ;
          pe_root = root } in
      if not (blocked model graph pe) then
        Div.update_roots dest true pre graph cache pat_id root in

    (* Patterns *)
    let conv_roots = Roots.of_pattern pat_id src.conv_roots in
    let div_roots = Roots.of_pattern pat_id src.div_roots in
    let process_roots roots =
      IntCollection.fold (fun root _ ->
      maybe_add root
      ) roots () in
    process_roots conv_roots ;
    process_roots div_roots ;

    (* Unary patterns *)
    let conv_roots = Roots.of_unary_pattern pat_id src.conv_roots in
    let div_roots = Roots.of_unary_pattern pat_id src.div_roots in
    let process_ccs_roots ccs_roots =
      ccs_roots |> Mods.IntMap.iter (fun _ roots ->
        roots |> Mods.IntSet.iter (fun root ->
          maybe_add root
        )
      ) in
    process_ccs_roots conv_roots ;
    process_ccs_roots div_roots


  let set_intervention ~use_specialized_instances intervention t =

    if use_specialized_instances then

      let block_insts = intervention.block_partial in

      let rule_pats =
        intervention.rules_to_monitor |> List.fold_left (fun rule_pats r ->
          Rule_pats.follow_rule r rule_pats
        ) (Rule_pats.reset t.rule_pats) in

      let rule =
        intervention.rules_to_monitor |> List.fold_left (fun rule rule_id ->
          let insts = empty_copy t.model t.def in
          t.rule_pats |> Rule_pats.iter_pats ~rule_id (fun pat_id ->
            initialize_specialized_instances
              ~model:t.model ~rule_id t.def insts pat_id block_insts
          ) ;
          IntMap.add rule_id insts rule
        ) IntMap.empty in

      { t with rule ; rule_pats ; block_insts }

    else

      { t with
        rule = IntMap.empty ;
        rule_pats = Rule_pats.reset t.rule_pats ;
        block_insts = block_nothing }



  let incorporate_extra_pattern _ _ _ = assert false (* TODO *)

  let break_apart_cc t graph ?mod_connectivity_store ccs =
    apply_all (fun t -> Div.break_apart_cc t graph ?mod_connectivity_store ccs) t

  let merge_cc t ?mod_connectivity_store ccs =
    apply_all (fun t -> Div.merge_cc t ?mod_connectivity_store ccs) t

  let update_roots t is_positive_update unary_pats graph cache id root =
    Div.update_roots t.def is_positive_update unary_pats graph cache id root ;
    t.rule_pats |> Rule_pats.iter_rules ~pat:id (fun rule ->
      (* For each affected rule:
           + if positive update: transmit if not blocked
           + otherwise, transmit *)
      match IntMap.find_opt rule t.rule with
      | None -> ()
      | Some insts ->
        let pe =
          { pe_rule_instance = rule ;
            pe_pat = id ;
            pe_root = root } in
        if not (is_positive_update && t.block_insts t.model graph pe) then
          Div.update_roots
            insts is_positive_update unary_pats graph cache id root
    )

  let is_valid inst patid i = assert false

  let query ?rule_id f t =
    match rule_id with
    | None -> f t.def
    | Some r ->
      begin match IntMap.find_opt r t.rule with
      | None -> f t.def
      | Some insts -> f insts
      end

  let number_of_instances ?rule_id t pats =
    t |> query ?rule_id (fun t -> Div.number_of_instances ?rule_id t pats)

  let number_of_unary_instances_in_cc ?rule_id t (pat1, pat2) =
    t |> query ?rule_id (fun t ->
      Div.number_of_unary_instances_in_cc ?rule_id t (pat1, pat2))

  let pick_unary_instance_in_cc ?rule_id t random_state (pat1, pat2) =
    t |> query ?rule_id (fun t ->
      Div.pick_unary_instance_in_cc ?rule_id t random_state (pat1, pat2))

  let fold_picked_instance ?rule_id t random_state pats ~init f =
    t |> query ?rule_id (fun t ->
      Div.fold_picked_instance ?rule_id t random_state pats ~init f)

  let fold_instances ?rule_id ?excp t pats ~init f =
    t |> query ?rule_id (fun t ->
      Div.fold_instances ?rule_id ?excp t pats ~init f)

  let fold_unary_instances ?rule_id t (pat1, pat2) ~init f =
    t |> query ?rule_id (fun t ->
      Div.fold_unary_instances ?rule_id t (pat1, pat2) ~init f)

  let receive_message msg state =
    match msg with
    | Set_intervention (use_specialized_instances, intervention) ->
      set_intervention ~use_specialized_instances intervention state
    | New_cur_mixture _ | Flush_roots_buffer ->
      update_all (Div.receive_message msg) state
    | New_reference_state (edges, obs) as msg ->
      (* Transmit the message as-is to `def` *)
      let def = state.def |> Div.receive_message msg in
      (* We have to filter the observables depending on the rule *)
      let rule = state.rule |> IntMap.mapi (fun pe_rule_instance inst ->
        let obs =
          obs |> List.filter (fun (pe_pat, (pe_root, _root_ty)) ->
            let pe = { pe_rule_instance ; pe_pat ; pe_root } in
            not (state.block_insts state.model state.def.current_mixture pe)
          ) in
        let msg = New_reference_state (edges, obs) in
        inst |> Div.receive_message msg
      ) in
      { state with def ; rule }

end

(******************************************************************************)
(* RESIMULATION TYPES AND HELPERS                                             *)
(******************************************************************************)

(* module Instances = Divergent_instances *)

module Instances = Per_rule(Divergent_instances)

module Modified_rule_interpreter =
  Generic_rule_interpreter.Make(Instances)

module Mri = Modified_rule_interpreter

type state = {
  graph : Modified_rule_interpreter.t ;
  ref_state : Replay.state ;
  counter : Counter.t ;
  model : Model.t ;
  max_consecutive_null : int option ;
  specialized_instances : bool ;

  special_steps : (float * (state -> state)) list ;
  (* TODO: implement special steps *)
  interventions : intervention IntMap.t ;
  next_intervention_id : int ;
}

type step =
  | Factual_happened of Trace.step
  | Factual_did_not_happen of (intervention_id list) * Trace.step
  | Counterfactual_happened of Trace.step

let tested_agents tests =
  let open Instantiation in
  tests
  |> List.map (function
    | Is_Here ag -> [Agent.id ag]
    | Has_Internal _ -> []
    | Is_Free _ -> []
    | Is_Bound _ -> []
    | Has_Binding_type _ -> []
    | Is_Bound_to _ -> []
  )
  |> List.concat
  |> List.sort_uniq compare

let pp_comma f = Format.fprintf f ", "

let debug_print_tstep env f step =

  let tests = Trace.tests_of_step step in
  let ags = tested_agents tests in

  let open Format in
  match step with
  | Trace.Init _  -> fprintf f "init"
  | Trace.Dummy _ -> fprintf f "dummy"
  | Trace.Pert _  -> fprintf f "pert"
  | Trace.Subs _  -> fprintf f "subs"

  | Trace.Rule (r, _, _)  ->
    fprintf f "%a\t(%a)"
      (Model.print_rule ~noCounters:true ~env) r
      (Pp.list pp_comma Format.pp_print_int) ags
  | Trace.Obs (s, _, _)   ->
    fprintf f "%s\t(%a)" s
      (Pp.list pp_comma Format.pp_print_int) ags


let debug_print_resimulation_step env f =
  let open Format in
  let pp_step = debug_print_tstep env in
  function
    | Factual_happened step ->
      fprintf f "[F] %a" pp_step step
    | Factual_did_not_happen (blocked, step) ->
      if blocked = [] then fprintf f "[.] %a" pp_step step
      else fprintf f "[X] %a" pp_step step
    | Counterfactual_happened step -> fprintf f "[C] %a" pp_step step

let actions_of_step = function
  | Trace.Subs _ -> ([],[])
  | Trace.Rule (_,e,_) | Trace.Pert (_,e,_) ->
    (e.Instantiation.actions,e.Instantiation.side_effects_dst)
  | Trace.Init y -> (y,[])
  | Trace.Obs (_,_,_) -> ([],[])
  | Trace.Dummy _ -> ([],[])

let time_of_step ~def step =
  match Trace.simulation_info_of_step step with
  | None -> def
  | Some infos -> infos.Trace.Simulation_info.story_time

let event_id_of_step step =
  match Trace.simulation_info_of_step step with
  | None -> None
  | Some infos -> Some infos.Trace.Simulation_info.story_event

let event_properties_of_tstep tstep =
  let rule_instance =
    match tstep with
    | Trace.Rule (rid, _, _) -> Some rid
    | _ -> None in
  let actions = fst (actions_of_step tstep) in
  let tests = Trace.tests_of_step tstep in
  let factual_event_id = event_id_of_step tstep in
  {rule_instance ; actions ; tests ; factual_event_id}

let step_is_blocked_by_predicate (pred : event_predicate) model step =
  pred model (event_properties_of_tstep step)

(* Returns [(blocked, blocking)] where [blocked] is true iff the step is
   blocked, in which case [blocking] gives the list of blocking
   interventions. *)
let step_is_blocked state step =
  let blocking =
    IntMap.fold (fun id intervention bs ->
      if step_is_blocked_by_predicate intervention.block state.model step
      then id :: bs else bs) state.interventions [] in
  (blocking <> []), blocking


(** {6 Compute observables to update after a factual step } *)

let valid_positive_transformation_on_same_sites edges =
  let open Primitives.Transformation in
  let handle_link (ag, s) =
    if not (Edges.is_agent ag edges) then [] else
    match Edges.link_destination (Agent.id ag) s edges with
    | None -> [Freed (ag, s)]
    | Some (ag', s') -> [Linked ((ag, s), (ag', s'))] in

  function
  | Agent ag -> if Edges.is_agent ag edges then [Agent ag] else []
  | Freed q -> handle_link q
  | Linked (q, q') -> handle_link q @ handle_link q'
  | NegativeWhatEver _ | NegativeInternalized _ -> assert false
  | PositiveInternalized (ag, s, _) ->
    if Edges.is_agent ag edges then
      let st = Edges.get_internal (Agent.id ag) s edges in
      [PositiveInternalized (ag, s, st)]
    else []

let valid_positive_transformations_on_same_sites edges trans =
  List.concat (List.map (valid_positive_transformation_on_same_sites edges) trans)

let observables_to_update state step =
  let actions, side_effects_dst = actions_of_step step in
  let trans = Primitives.Transformation.positive_transformations_of_actions
    (Model.signatures state.model) side_effects_dst actions in
  let mod_trans = valid_positive_transformations_on_same_sites (Mri.get_edges state.graph) trans in
  let obs, deps = Mri.obs_from_transformations ~debugMode:false (Model.domain state.model) (Mri.get_edges state.graph) mod_trans in
  obs, deps


(** Small helper functions *)

let time st = Counter.current_time st.counter

let update_outdated_activities st =
  let graph, _ =
      Mri.update_outdated_activities ~debugMode:false (fun _ _ _ -> ())
        st.model st.counter st.graph [] in
      (* Note: I added the last [] because an aegument was added to this function
       * and I have no idea why. Is it related to counters? *)
  { st with graph }

let debug_print_obs_updates model (obs, deps) =
  let pp_obs_list fmt l =
    l |> List.iter (fun (pat, (root, _)) ->
      let domain = Model.domain model in
      Format.fprintf fmt "({@[<h>%a@]}, %d)@."
        (Pattern.print ~noCounters:true ~domain ~with_id:true) pat root)
  in
  Format.printf "@.%a@.@.%d@." pp_obs_list obs (Operator.DepSet.size deps)


(** {6 Add and remove interventions } *)

(* TODO: the fun part happens here... *)
let interventions_updated state =
  let pred =
    if IntMap.is_empty state.interventions then None
    else Some (fun rule_instance _matching tests actions ->
      IntMap.exists (fun _ intervention ->
        intervention.block state.model
          { rule_instance ; tests ; actions ; factual_event_id = None }
      ) state.interventions ) in
  let intervention = merge_interventions state.interventions in
  let specialized_instances = state.specialized_instances in
  let graph =
    state.graph
    |> Mri.set_events_to_block pred
    |> Mri.send_instances_message
      (Set_intervention (specialized_instances, intervention)) in
  { state with graph }

let clear_interventions state =
  { state with
    interventions = IntMap.empty }
  |> interventions_updated
  (* You should not reset [next_intervention_id] (because of [special_steps]) *)

let remove_intervention id state =
  { state with interventions = IntMap.remove id state.interventions }
  |> interventions_updated

let rec insert_special_step (t, f) = function
  | [] -> [(t, f)]
  | (t', f') :: steps ->
    if t <= t' then
      (t, f) :: (t', f') :: steps
    else
      (t', f') :: insert_special_step (t, f) steps

let add_intervention ?timeout intervention state =
  let id = state.next_intervention_id in
  let next_intervention_id = id + 1 in
  let interventions = IntMap.add id intervention state.interventions in

  let special_steps =
    match timeout with
    | None -> state.special_steps
    | Some t ->
      insert_special_step (t, remove_intervention id) state.special_steps in

  let state =
    { state with next_intervention_id ; interventions  ; special_steps}
    |> interventions_updated in

  (id, state)

let model state = state.model

let set_max_consecutive_null n state =
  { state with max_consecutive_null = n }

let set_use_specialized_instances use state =
  { state with specialized_instances = use}


(******************************************************************************)
(* RESIMULATION                                                               *)
(******************************************************************************)

let init model random_state =
  let counter = Counter.create ~plot_period:(Configuration.DT 1.0)
    ?max_event:None ?max_time:None ?init_t:None ?init_e:None ~nb_rules:(Model.nb_rules model) in
  { counter ;
    (* New argument outputs: not sure what to do with it *)
    graph = Mri.empty ~outputs:(fun _ -> ()) ~with_trace:true random_state model counter ;
    ref_state = Replay.init_state ~with_connected_components:true ;
    model ;
    max_consecutive_null = None ;
    specialized_instances = true ;
    special_steps = [] ;
    interventions = IntMap.empty ;
    next_intervention_id = 0 ;
  }


let do_factual_step step st =
  let ref_state, _ =
      Replay.do_step (Model.signatures st.model) st.ref_state step in
  let time' = ref_state.Replay.time in
  let st = { st with ref_state } in
  (* TODO: why does this return bool *)
  let _:bool = Counter.one_time_advance st.counter (time' -. time st) in
  let obs, deps = observables_to_update st step in
  (* debug_print_obs_updates st.model (obs, deps) *)
  let graph = Mri.add_outdated_dependencies deps st.graph in
  let graph = Mri.send_instances_message
    (New_reference_state (ref_state.Replay.graph, obs)) graph in
  let st = { st with graph ; ref_state } in

  let blocked, blocking = step_is_blocked st step in

  if not blocked &&
     Replay.is_step_triggerable_on_edges (Mri.get_edges st.graph) step

  then begin
    let graph = Mri.update_edges_from_actions ~debugMode:false ~outputs:(fun _ -> ())
      (Model.signatures st.model) st.counter (Model.domain st.model)
      st.graph (actions_of_step step) in
    (* This function makes calls to Instances.update_roots.
       We want to defer these calls to the moment where the
       edges are fully updated, so that we can know which
       sites are divergent and which sites are not.
       This is why we use the [Flush_roots_buffer] trick. *)
    let graph = Mri.send_instances_message
        (New_cur_mixture (Mri.get_edges graph)) graph in
    let graph = Mri.send_instances_message Flush_roots_buffer graph in
    Some (Factual_happened step) ,
    update_outdated_activities { st with graph }
  end else begin
    Some (Factual_did_not_happen (blocking, step)) ,
    update_outdated_activities st
  end



let do_counterfactual_step dt st =
  let gen_step = ref None in
  let receive_step = function
    | Data.TraceStep step -> gen_step := Some (Counterfactual_happened step)
    | _ -> () in
  (* Note (Feb 2021): this is the biggest update I've made:
   * I have replaced a call to [Mri.apply_rule] by [Mri.pick_instance]
   * followed by [Mri.apply_instance] *)
  let instance = Mri.pick_an_instance ~debugMode:false st.model st.graph in
  let applied_rule, _, graph =
    Mri.apply_instance
      ~debugMode:false
      ~outputs:receive_step
      ~maxConsecutiveClash:3
      ?maxConsecutiveBlocked:st.max_consecutive_null
      st.model st.counter st.graph instance in
  let graph = Mri.send_instances_message
    (New_cur_mixture (Mri.get_edges graph)) graph in
  let graph = Mri.send_instances_message Flush_roots_buffer graph in
  let st = { st with graph } in
  (* TODO: why does this thing return bool? *)
  let _:bool = Counter.one_time_advance st.counter dt in
  if applied_rule = None then (* null_event *)
    (* No need to register the null event: this is done by [Mri.apply_rule] *)
    !gen_step, st
  else begin
    !gen_step, update_outdated_activities st
  end



type next_step_kind =
  | Next_is_factual
  | Next_is_counterfactual

exception End_of_resimulation

let do_step
  ?(do_before_factual = const identity)
  next_fstep_opt st =

  let get_next_fstep, next_fstep_time =
    match next_fstep_opt with
    | None -> (fun () -> assert false), infinity
    | Some s ->
      let t = time_of_step ~def:(st.ref_state.Replay.time) s in
      (fun () -> s), t in

  let div_activity = Mri.activity st.graph in
  let rd = Random.State.float (Mri.get_random_state st.graph) 1.0 in
  let dt = abs_float (log rd /. div_activity) in
  let next_div_step_time = time st +. dt in

  let time', next_step_kind =
    if next_fstep_time <= next_div_step_time
    then next_fstep_time, Next_is_factual
    else next_div_step_time, Next_is_counterfactual in

  if time' = infinity then raise End_of_resimulation
  else
    match next_step_kind with
    | Next_is_counterfactual ->
      let step, st = do_counterfactual_step dt st in
      false, step, st
    | Next_is_factual ->
      let next_fstep = get_next_fstep () in
      let st = do_before_factual next_fstep st in
      let step, st = do_factual_step next_fstep st in
      true, step, st



(* TODO: continue after the factual trace is consumed. *)
let resimulate
  ?(do_init = identity)
  ?(do_before_factual = const identity)
  ?(do_after_step = const identity)
  ?(handle_null_event = const ())
  ?(handle_step = const2 ())
  ?(stop_after = const2 false)
  trace_file =

  let state model =
    init model (Random.get_state ()) |> do_init in

  let rec until_factual_consumed next_fstep_opt state =
    let consumed, ostep, state =
      do_step ~do_before_factual next_fstep_opt state in
    let state =
      match ostep with
      | None ->
        handle_null_event () ;
        state
      | Some step ->
        handle_step state.model step ;
        let state = do_after_step step state in
        if stop_after state.model step then raise End_of_resimulation
        else state in
    if consumed then state
    else until_factual_consumed next_fstep_opt state in

  try
    trace_file |> Trace.fold_trace_file (fun _ st step ->
      until_factual_consumed (Some step) st
    ) state
    |> ignore
  with End_of_resimulation -> ()

