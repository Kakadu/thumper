(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

type shift = { estimate : float; lower : float; upper : float }

type reason =
  | Wide_interval
  | Non_positive
  | Baseline_unstable
  | Environment
  | Unconfirmed
  | Exactness_lost
  | Batch_drifted
  | Candidate_unstable
  | Candidate_drifted

type strong =
  | Exact_change of { baseline : int; candidate : int }
  | Confirmed of {
      first : shift;
      confirmation : shift;
      pooled : float array;
      k : int;
    }

type relation =
  | Improved of strong
  | Regressed of strong
  | Equivalent of shift option
  | Within_budget of shift
  | Inconclusive of { reason : reason; shift : shift option }

type metric_verdict = Proposed | Judged of relation

type metric_report = {
  metric : Metric.t;
  verdict : metric_verdict;
  budget : Budget.t option;
}

type case_report = {
  id : string;
  full_name : string;
  trial : Run.Trial.t;
  reports : metric_report list;
  warnings : string list;
}

type staleness = Ocaml_mismatch of { section : string; current : string }
type comparison = No_baseline | Stale of staleness | Compared

(* Constants. The band cap and default budget live in [Budget]; the
   drift level (α = 0.01) is measurement-time and lives with the flags. *)

(* Initial rank-test level, 0.005 per side. *)
let alpha_initial = 0.005

(* Confirmation-pass level, 0.05 per side. *)
let alpha_confirmation = 0.05

(* A shift within 2e of zero is bias-comparable after recalibration. *)
let bias_comparability_factor = 2.0

(* Judgment parameters for metrics with no relative contract: the default
   budget's shape (r = 5%, derived band), used for reporting only. *)
let default_params =
  ( min Budget.band_cap (Budget.default_max_regression /. 2.),
    Budget.default_max_regression )

(* Internal representation *)

type pending = {
  p_dir : [ `Improved | `Regressed ];
  p_first : shift;
  p_first_sorted : float array;
      (* first-pass candidate samples; never mutated *)
  p_first_k : int; (* their batch size, which the confirmation must match *)
  p_baseline_log : float array;
  p_e : float;
  p_r : float;
}

type m_state = Settled of metric_verdict | Pending of pending

type pcase = {
  c_id : string;
  c_full_name : string;
  c_trial : Run.Trial.t;
  c_warnings : string list;
  c_states : (Metric.t * m_state * Budget.t option) list;
}

type core = {
  cr_identity : Baseline.identity;
  cr_suite : string;
  cr_file : Baseline.t; (* the baseline judged against; the ratchet's input *)
  cr_selection : [ `Full | `Partial ];
  cr_comparison : comparison;
  cr_warnings : string list;
}

type provisional = { p_core : core; p_cases : pcase list }
type t = { core : core; v_load : Env.load; v_cases : case_report list }

(* Small helpers *)

let invalid fmt = Printf.ksprintf invalid_arg fmt

(* An inconclusive relation keeps the first-pass shift iff the rank test ran:
   the estimate and interval are reported whatever the relation. *)
let inconclusive ?shift reason = Inconclusive { reason; shift }
let log_all a = Array.map log a
let all_positive a = Array.for_all (fun x -> x > 0.) a

(* [expm1] is increasing, so comparing the mapped bounds with a budget [r] and
   a band [e] decides the same relation as comparing the log-space bounds with
   [log1p r] and [log1p (-e)]: the table reads budgets as exact fractions. *)
let fractional_of_stats (s : Stats.shift) =
  {
    estimate = expm1 s.Stats.estimate;
    lower = expm1 s.Stats.interval.Stats.lower;
    upper = expm1 s.Stats.interval.Stats.upper;
  }

let bias_comparable ~e (sh : shift) =
  Float.abs sh.estimate <= bias_comparability_factor *. e

let is_loaded = function Env.Loaded _ -> true | Env.Quiet -> false

(* One reading for both sides, from the sorted vector alone: a stored
   baseline row and a trial are unstable by the same test. A negative
   sample is never unstable here; it is [Non_positive] evidence. A baseline
   row gets no drift test: drift is read from the samples in collection order,
   which a stored row no longer has, and it was tested when the row's trial
   was measured, though a drifted trial can still be recorded. *)
let unstable samples =
  Array.length samples >= 3
  && samples.(0) >= 0.
  && Stats.severe_outlier_inflation_sorted samples

(* Budget resolution (per case): the case's per-metric merge wins, other
   metrics fall through to the run's list, budgets on metrics the case does
   not collect are dropped, and a case left with none gets [Budget.defaults]
   (bench.mli module doc). The default comes after the drop: chosen before
   it, a wall_time-only case under an alloc-only suite would drop the alloc
   budget and end with no budget at all. *)

let budget_for budgets metric =
  List.find_opt (fun b -> Metric.equal (Budget.metric b) metric) budgets

let effective_budgets ~run_budgets ~collected case =
  let case_b = Option.value ~default:[] (Bench.budgets case) in
  let inherited =
    List.filter
      (fun b -> budget_for case_b (Budget.metric b) = None)
      run_budgets
  in
  let binding budgets =
    List.filter
      (fun b -> List.exists (Metric.equal (Budget.metric b)) collected)
      budgets
  in
  match binding (case_b @ inherited) with
  | [] -> binding Budget.defaults
  | l -> l

let relative_params budget =
  match Option.map Budget.contract budget with
  | Some (Budget.Relative { max_regression; band }) -> (band, max_regression)
  | Some (Budget.Absolute_max _) | None -> default_params

(* A zero-tolerance relative budget on a downgraded exact-capable
   metric is never a rank test at r = 0. *)
let zero_tolerance_downgrade metric budget =
  Metric.is_counter metric
  &&
  match Option.map Budget.contract budget with
  | Some (Budget.Relative { max_regression = 0.; _ }) -> true
  | _ -> false

(* The relation table over the fractional bounds [l <= u]. Every metric is
   lower-is-better, so a positive bound is worse. The r = 0 chain keeps the
   table total at a degenerate band (e = 0 whenever r = 0: Budget enforces
   band <= max_regression). *)

type raw =
  | Strong of [ `Improved | `Regressed ]
  | Demonstrated (* within budget: a demonstrated direction *)
  | Tame of relation (* equivalent or inconclusive: no direction claimed *)

let table ~e ~r sh =
  let l = sh.lower and u = sh.upper in
  if r = 0. then
    if u < 0. then Strong `Improved
    else if l > 0. then Strong `Regressed
    else if u <= 0. then Demonstrated
    else Tame (inconclusive ~shift:sh Wide_interval)
  else if u < -.e then Strong `Improved
  else if l > r then Strong `Regressed
  else if -.e <= l && u <= e then Tame (Equivalent (Some sh))
  else if l > e && u <= r then Demonstrated
  else Tame (inconclusive ~shift:sh Wide_interval)

(* First-pass judgment of one sampled comparison. *)
let judge_sampled ~load ~budget ~row_k ~baseline ~cand ~trial_k =
  let e, r = relative_params budget in
  if
    (* A zero sample breaks the log-space comparison, and no amount of
       re-measurement prices it: its own reason, with an honest remedy. A
       quiet host would not fix it either, so it is tested before the load. *)
    (not (all_positive baseline)) || not (all_positive cand.Run.sorted)
  then Settled (Judged (inconclusive Non_positive))
  else if is_loaded load then Settled (Judged (inconclusive Environment))
  else if
    (* Load explains drift, so drift is only read on a quiet host. *)
    cand.Run.drifted
  then Settled (Judged (inconclusive Candidate_drifted))
  else if
    (* Defensive: public constructors require n >= 3. *)
    Array.length baseline < 3
  then Settled (Judged (inconclusive Wide_interval))
  else
    let baseline_log = log_all baseline in
    let sh =
      fractional_of_stats
        (Stats.shift ~alpha_per_side:alpha_initial ~baseline:baseline_log
           ~candidate:(log_all cand.Run.sorted))
    in
    let k_moved = row_k <> trial_k in
    if k_moved && bias_comparable ~e sh then
      (* After recalibration only a bias-comparable shift degrades; a
         large shift is a verdict, not a calibration event. *)
      Settled (Judged (inconclusive ~shift:sh Batch_drifted))
    else
      (* Instability undermines a demonstrated direction within 2e: there,
         unstable trials support equivalent or inconclusive only. A shift
         beyond 2e is judged as on a stable row — the batch-drift test above;
         one outlier barely moves a rank interval, and at the derived band
         (where r >= 2e) a strong regression must not hide behind a heavy
         tail. *)
      let unless_unstable state =
        if not (bias_comparable ~e sh) then state
        else if unstable baseline then
          Settled (Judged (inconclusive ~shift:sh Baseline_unstable))
        else if unstable cand.Run.sorted then
          Settled (Judged (inconclusive ~shift:sh Candidate_unstable))
        else state
      in
      match table ~e ~r sh with
      | Tame rel -> Settled (Judged rel)
      | Demonstrated -> unless_unstable (Settled (Judged (Within_budget sh)))
      | Strong dir ->
          unless_unstable
            (Pending
               {
                 p_dir = dir;
                 p_first = sh;
                 p_first_sorted = cand.Run.sorted;
                 p_first_k = trial_k;
                 p_baseline_log = baseline_log;
                 p_e = e;
                 p_r = r;
               })

(* Whether a proven-exact count exceeds its budget's absolute cap. The cap
   is on the measured value itself, so it is judged on this run's count
   alone, whatever the baseline holds or lacks. *)
let over_cap budget c =
  match Option.map Budget.contract budget with
  | Some (Budget.Absolute_max cap) -> float_of_int c > cap
  | Some (Budget.Relative _) | None -> false

(* First-pass judgment of one exact (integer) comparison. *)
let judge_exact ~budget ~case_k ~trial_k ~b ~c =
  let k_moved = match case_k with Some kb -> kb <> trial_k | None -> false in
  let strong = Exact_change { baseline = b; candidate = c } in
  (* A moved batch size explains a changed count, never one over the cap. *)
  if over_cap budget c then Regressed strong
  else if k_moved && b <> c then
    (* Amortized allocators can be k-phase-dependent. *)
    inconclusive Batch_drifted
  else
    let better = c < b in
    (* Degradation as a fraction of the baseline; [None] when b = 0 (a change
       from zero has no relative size and exceeds any relative budget). *)
    let degradation =
      if b = 0 then None
      else Some ((float_of_int c -. float_of_int b) /. float_of_int b)
    in
    let budgeted_increase () =
      (* The [None] arm is live only via [Absolute_max] at b = 0 under the
         cap: growth from nothing has no relative size, rendered +inf% in a
         terminal cell and null in JSON. *)
      let point = match degradation with Some d -> d | None -> infinity in
      Within_budget { estimate = point; lower = point; upper = point }
    in
    match Option.map Budget.contract budget with
    | Some (Budget.Absolute_max _) ->
        (* Under the cap: the change is reported, never gated. *)
        if c = b then Equivalent None
        else if better then Improved strong
        else budgeted_increase ()
    | (Some (Budget.Relative _) | None) as contract ->
        let r =
          match contract with
          | Some (Budget.Relative { max_regression; _ }) -> max_regression
          | _ -> snd default_params
        in
        if c = b then Equivalent None
        else if better then Improved strong
        else
          let over = match degradation with Some d -> d > r | None -> true in
          if over then Regressed strong else budgeted_increase ()

(* Judging *)

let check_distinct ~what ~ids =
  let tbl = Hashtbl.create 16 in
  List.iter
    (fun id ->
      if Hashtbl.mem tbl id then invalid "Verdict: duplicate %s %S" what id
      else Hashtbl.add tbl id ())
    ids

let classify_comparison identity section =
  match section with
  | None -> No_baseline
  | Some s ->
      (* The section is derived from the judged file by this machine's key,
         so a foreign section is unrepresentable here. *)
      let recorded = Baseline.ocaml_of s in
      if String.equal recorded identity.Baseline.ocaml then Compared
      else
        Stale
          (Ocaml_mismatch
             { section = recorded; current = identity.Baseline.ocaml })

let compared_section ~identity file =
  let section = Baseline.section file identity.Baseline.machine in
  match classify_comparison identity section with
  | Compared -> section
  | No_baseline | Stale _ -> None

let judge_metric ~load section ~id ~trial metric measurement budget =
  match Baseline.find_row section ~id ~metric:(Metric.id metric) with
  | None -> Settled Proposed
  | Some row -> (
      let trial_k = Run.Trial.k trial in
      match (Baseline.row_evidence row, measurement) with
      | Baseline.Exact_int b, Run.Exact c ->
          let case_k = Baseline.case_frozen_k section ~id in
          Settled (Judged (judge_exact ~budget ~case_k ~trial_k ~b ~c))
      | Baseline.Exact_int _, Run.Samples _ | Baseline.Sampled _, Run.Exact _ ->
          Settled (Judged (inconclusive Exactness_lost))
      | Baseline.Sampled { k = row_k; samples }, Run.Samples cand ->
          if zero_tolerance_downgrade metric budget then
            Settled (Judged (inconclusive Exactness_lost))
          else
            judge_sampled ~load ~budget ~row_k ~baseline:samples ~cand ~trial_k)

let absent_ids s ~case_ids =
  List.sort_uniq String.compare
    (List.filter_map
       (fun row ->
         let id = Baseline.row_id row in
         if List.mem id case_ids then None else Some id)
       (Baseline.rows s))

(* A stale section is replaced wholesale from the selected cases alone, by
   check's candidate and by bless alike: under a partial selection the
   unselected cases' rows are dropped, and the acceptance prompt is the only
   later tell. Both say so, in these words (a silent partial re-record reads
   as data loss after the fact). *)
let stale_partial_notice ~selection ~comparison ~section ~case_ids =
  match (selection, comparison, section) with
  | `Partial, Stale _, Some s ->
      let dropped = absent_ids s ~case_ids in
      let n = List.length dropped in
      if n = 0 then []
      else
        [
          Printf.sprintf
            "partial selection on a stale section — the corrected file \
             re-records this machine's whole section and drops the rows of the \
             %d unselected case%s"
            n
            (if n = 1 then "" else "s");
        ]
  | _ -> []

let prune_notices ~selection ~comparison ~section ~case_ids =
  match (selection, comparison, section) with
  | `Full, Compared, Some s ->
      List.map
        (Printf.sprintf
           "case %s no longer exists in this binary; its rows will be pruned \
            from the corrected file")
        (absent_ids s ~case_ids)
  | _ -> []

let judge ~identity ~suite ~load ~selection ~budgets ~file ~cases =
  let case_ids = List.map (fun (c, _) -> Bench.id c) cases in
  check_distinct ~what:"case id" ~ids:case_ids;
  let section = Baseline.section file identity.Baseline.machine in
  let comparison = classify_comparison identity section in
  let comparable =
    match comparison with Compared -> section | No_baseline | Stale _ -> None
  in
  let p_cases =
    List.map
      (fun (bench_case, trial) ->
        let id = Bench.id bench_case in
        let measured = Run.Trial.measurements trial in
        let effective =
          effective_budgets ~run_budgets:budgets
            ~collected:(List.map fst measured) bench_case
        in
        let states =
          List.map
            (fun (metric, measurement) ->
              let budget = budget_for effective metric in
              let state =
                match comparable with
                | None -> Settled Proposed
                | Some s ->
                    judge_metric ~load s ~id ~trial metric measurement budget
              in
              (metric, state, budget))
            measured
        in
        {
          c_id = id;
          c_full_name = Bench.full_name bench_case;
          c_trial = trial;
          c_warnings = Run.Trial.warnings trial;
          c_states = states;
        })
      cases
  in
  let cr_warnings =
    prune_notices ~selection ~comparison ~section ~case_ids
    @ stale_partial_notice ~selection ~comparison ~section ~case_ids
  in
  {
    p_core =
      {
        cr_identity = identity;
        cr_suite = suite;
        cr_file = file;
        cr_selection = selection;
        cr_comparison = comparison;
        cr_warnings;
      };
    p_cases;
  }

let has_pending pc =
  List.exists
    (fun (_, st, _) -> match st with Pending _ -> true | _ -> false)
    pc.c_states

let confirmations p =
  List.filter_map
    (fun pc -> if has_pending pc then Some pc.c_id else None)
    p.p_cases

(* Deciding *)

let resolve_pending ~load ~conf metric pd =
  let first = pd.p_first in
  if is_loaded load then inconclusive ~shift:first Environment
  else
    match conf with
    | None -> inconclusive ~shift:first Unconfirmed
    | Some trial -> (
        (* A confirmation that recalibrated measured at another batch size:
           two batch sizes are never pooled into one row. *)
        match Run.Trial.measurement trial metric with
        | Some (Run.Samples s)
          when (not s.Run.drifted) && all_positive s.Run.sorted
               && Run.Trial.k trial = pd.p_first_k -> (
            let confirmation =
              fractional_of_stats
                (Stats.shift ~alpha_per_side:alpha_confirmation
                   ~baseline:pd.p_baseline_log ~candidate:(log_all s.Run.sorted))
            in
            let reproduced =
              match pd.p_dir with
              | `Improved -> confirmation.upper < -.pd.p_e
              | `Regressed -> confirmation.lower > pd.p_r
            in
            (* An unstable confirmation counts only beyond 2e, as on the
               first pass. *)
            if
              (not reproduced)
              || unstable s.Run.sorted
                 && bias_comparable ~e:pd.p_e confirmation
            then inconclusive ~shift:first Unconfirmed
            else
              (* Pool both passes for the ratchet; [Array.append] is a fresh
                 array, so neither trial's evidence is sorted in place. *)
              let pooled = Array.append pd.p_first_sorted s.Run.sorted in
              let () = Array.sort Float.compare pooled in
              let strong =
                Confirmed
                  {
                    first = pd.p_first;
                    confirmation;
                    pooled;
                    k = Run.Trial.k trial;
                  }
              in
              match pd.p_dir with
              | `Improved -> Improved strong
              | `Regressed -> Regressed strong)
        | Some (Run.Samples _) | Some (Run.Exact _) | None ->
            inconclusive ~shift:first Unconfirmed)

let decide ~load ~confirmations:confs p =
  let queue = confirmations p in
  check_distinct ~what:"confirmation id" ~ids:(List.map fst confs);
  List.iter
    (fun (id, _) ->
      if not (List.mem id queue) then
        invalid "Verdict.decide: confirmation for %S was not requested" id)
    confs;
  let v_cases =
    List.map
      (fun pc ->
        let conf = List.assoc_opt pc.c_id confs in
        let reports =
          List.map
            (fun (metric, state, budget) ->
              let verdict =
                match state with
                | Settled v -> v
                | Pending pd -> Judged (resolve_pending ~load ~conf metric pd)
              in
              { metric; verdict; budget })
            pc.c_states
        in
        (* The confirmation's samples are judged and pooled, so its
           warnings are the case's too; one the first trial raised already
           is not repeated. *)
        let conf_warnings =
          match conf with
          | None -> []
          | Some trial ->
              List.filter
                (fun w -> not (List.mem w pc.c_warnings))
                (Run.Trial.warnings trial)
        in
        {
          id = pc.c_id;
          full_name = pc.c_full_name;
          trial = pc.c_trial;
          reports;
          warnings = pc.c_warnings @ conf_warnings;
        })
      p.p_cases
  in
  { core = p.p_core; v_load = load; v_cases }

(* Observers *)

let comparison t = t.core.cr_comparison
let cases t = t.v_cases
let warnings t = t.core.cr_warnings
let suite t = t.core.cr_suite
let identity t = t.core.cr_identity
let load t = t.v_load

let exact_evidence case_report metric =
  match Run.Trial.measurement case_report.trial metric with
  | Some (Run.Exact _) -> true
  | Some (Run.Samples _) | None -> false

(* Whether a report fails its case: a regression beyond a relative budget,
   or a proven-exact count over an absolute cap — on any run, with or
   without a baseline row. A statistical estimate crossing an absolute line
   is not an earned verdict, so a sampled count never gates a cap. *)
let report_fails case_report report =
  match Option.map Budget.contract report.budget with
  | Some (Budget.Relative _) -> (
      match report.verdict with Judged (Regressed _) -> true | _ -> false)
  | Some (Budget.Absolute_max _) -> (
      match Run.Trial.measurement case_report.trial report.metric with
      | Some (Run.Exact c) -> over_cap report.budget c
      | Some (Run.Samples _) | None -> false)
  | None -> false

let report_inconclusive report =
  match report.verdict with Judged (Inconclusive _) -> true | _ -> false

let case_overall case_report =
  if List.exists (report_fails case_report) case_report.reports then `Fail
  else if
    List.exists
      (fun r -> r.budget <> None && report_inconclusive r)
      case_report.reports
  then `Inconclusive
  else `Pass

let overall t =
  let outcomes = List.map case_overall t.v_cases in
  if List.mem `Fail outcomes then `Fail
  else if List.mem `Inconclusive outcomes then `Inconclusive
  else `Pass

let has_proposed t =
  List.exists
    (fun c ->
      List.exists
        (fun r -> match r.verdict with Proposed -> true | Judged _ -> false)
        c.reports)
    t.v_cases

let exit_code ?(strict = false) t =
  match overall t with
  | `Fail -> 1
  | `Inconclusive -> if strict then 1 else 0
  | `Pass ->
      let non_compared =
        match t.core.cr_comparison with
        | Compared -> false
        | No_baseline | Stale _ -> true
      in
      if strict && (non_compared || has_proposed t) then 1 else 0

(* JSON (v1 field names and escaping) *)

(* v1 string escaping: backslash forms for the two JSON metacharacters
   and the three named C0 controls, [\u00XX] for the rest of C0; everything
   else — UTF-8 sequences included — passes through byte-verbatim. *)
let json_string buf s =
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' | '\\' ->
          Buffer.add_char buf '\\';
          Buffer.add_char buf c
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | '\x00' .. '\x1f' -> Printf.bprintf buf "\\u%04x" (Char.code c)
      | _ -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"'

(* Floats print [%.17g] (v1) — enough digits to round-trip a double. An
   absent or non-finite value is [null]: JSON has no spelling for NaN or the
   infinities. *)
let json_float buf f =
  match f with
  | Some f when Float.is_finite f -> Printf.bprintf buf "%.17g" f
  | Some _ | None -> Buffer.add_string buf "null"

let json_overall = function
  | `Pass -> "pass"
  | `Fail -> "fail"
  | `Inconclusive -> "inconclusive"

let wire_reason = function
  | Wide_interval -> "wide_interval"
  | Non_positive -> "non_positive"
  | Baseline_unstable -> "baseline_unstable"
  | Environment -> "environment"
  | Unconfirmed -> "unconfirmed"
  | Exactness_lost -> "exactness_lost"
  | Batch_drifted -> "batch_drifted"
  | Candidate_unstable -> "unstable"
  | Candidate_drifted -> "drifted"

let wire_relation = function
  | Improved _ -> "improved"
  | Regressed _ -> "regressed"
  | Equivalent _ -> "equivalent"
  | Within_budget _ -> "changed_within_budget"
  | Inconclusive _ -> "inconclusive"

let strong_estimate = function
  | Confirmed { first; _ } -> Some first.estimate
  | Exact_change { baseline; candidate } ->
      if baseline = 0 then None
      else
        Some
          ((float_of_int candidate -. float_of_int baseline)
          /. float_of_int baseline)

(* The reported deltas: the first-pass shift for confirmed strongs, the
   relation's shift otherwise (an inconclusive row's first-pass shift when its
   rank test ran); exact evidence has no interval bounds. *)
let deltas_of_verdict ~exact = function
  | Proposed -> (None, None, None)
  | Judged (Inconclusive { shift = None; _ }) -> (None, None, None)
  | Judged (Equivalent None) -> (Some 0.0, None, None)
  | Judged (Equivalent (Some sh))
  | Judged (Within_budget sh)
  | Judged (Inconclusive { shift = Some sh; _ }) ->
      if exact then (Some sh.estimate, None, None)
      else (Some sh.estimate, Some sh.lower, Some sh.upper)
  | Judged (Improved (Confirmed { first; _ }))
  | Judged (Regressed (Confirmed { first; _ })) ->
      (Some first.estimate, Some first.lower, Some first.upper)
  | Judged (Improved (Exact_change _ as s))
  | Judged (Regressed (Exact_change _ as s)) ->
      (strong_estimate s, None, None)

let json_metric buf case_report report =
  let status =
    if report_fails case_report report then `Fail
    else if report_inconclusive report then `Inconclusive
    else `Pass
  in
  Buffer.add_string buf "{\"metric\":";
  json_string buf (Metric.id report.metric);
  Buffer.add_string buf ",\"relation\":";
  (match report.verdict with
  | Proposed -> Buffer.add_string buf "null"
  | Judged rel -> json_string buf (wire_relation rel));
  Buffer.add_string buf ",\"status\":";
  json_string buf (json_overall status);
  Buffer.add_string buf ",\"reason\":";
  (match report.verdict with
  | Proposed -> json_string buf "missing_baseline"
  | Judged (Inconclusive { reason; _ }) -> json_string buf (wire_reason reason)
  | Judged _ -> Buffer.add_string buf "null");
  (match report.verdict with
  | Judged _ -> (
      match Run.Trial.measurement case_report.trial report.metric with
      | Some (Run.Exact _) -> Buffer.add_string buf ",\"exact\":true"
      | Some (Run.Samples s) ->
          let confirmed =
            match report.verdict with
            | Judged (Improved _ | Regressed _) -> true
            | _ -> false
          in
          Buffer.add_string buf
            (Printf.sprintf ",\"confirmed\":%b,\"n\":%d" confirmed
               (Array.length s.Run.sorted))
      | None -> ())
  | Proposed -> ());
  let delta, lower, upper =
    deltas_of_verdict
      ~exact:(exact_evidence case_report report.metric)
      report.verdict
  in
  Buffer.add_string buf ",\"delta\":";
  json_float buf delta;
  Buffer.add_string buf ",\"lower_delta\":";
  json_float buf lower;
  Buffer.add_string buf ",\"upper_delta\":";
  json_float buf upper;
  Buffer.add_char buf '}'

(* The per-case ratio a report contributes to the geomean, v1's guard: only
   finite, strictly positive ratios participate. *)
let ratio_of_verdict = function
  | Proposed | Judged (Inconclusive { shift = None; _ }) -> None
  | Judged (Equivalent None) -> Some 1.0
  | ( Judged (Equivalent (Some _))
    | Judged (Within_budget _)
    | Judged (Inconclusive { shift = Some _; _ })
    | Judged (Improved _)
    | Judged (Regressed _) ) as v -> (
      (* Only the point delta matters; the [exact] flag shapes bounds only. *)
      match deltas_of_verdict ~exact:false v with
      | Some d, _, _ ->
          let ratio = 1.0 +. d in
          if Float.is_finite ratio && ratio > 0.0 then Some ratio else None
      | None, _, _ -> None)

(* Summary metrics in first-appearance order across the cases' reports —
   v1's ordering, inherited by the frozen schema. A run measures a handful
   of metrics; the quadratic dedup is nothing. *)
let summary_metrics t =
  let add order r =
    if List.exists (Metric.equal r.metric) order then order
    else r.metric :: order
  in
  List.rev
    (List.fold_left
       (fun order c -> List.fold_left add order c.reports)
       [] t.v_cases)

let json_summary buf t =
  Buffer.add_char buf '{';
  List.iteri
    (fun i metric ->
      if i > 0 then Buffer.add_char buf ',';
      let reports =
        List.concat_map
          (fun c ->
            List.filter (fun r -> Metric.equal r.metric metric) c.reports)
          t.v_cases
      in
      let count pred = List.length (List.filter pred reports) in
      let n_improved =
        count (fun r ->
            match r.verdict with Judged (Improved _) -> true | _ -> false)
      in
      let n_regressed =
        count (fun r ->
            match r.verdict with Judged (Regressed _) -> true | _ -> false)
      in
      let n_equivalent =
        count (fun r ->
            match r.verdict with
            | Judged (Equivalent _ | Within_budget _) -> true
            | _ -> false)
      in
      let n_inconclusive =
        count (fun r ->
            match r.verdict with
            | Proposed | Judged (Inconclusive _) -> true
            | _ -> false)
      in
      let ratios =
        List.filter_map (fun r -> ratio_of_verdict r.verdict) reports
      in
      let geomean_delta =
        match ratios with
        | [] -> None
        | _ -> Some (Stats.geometric_mean (Array.of_list ratios) -. 1.0)
      in
      json_string buf (Metric.id metric);
      Buffer.add_string buf
        (Printf.sprintf
           ":{\"n_improved\":%d,\"n_regressed\":%d,\"n_equivalent\":%d,\"n_inconclusive\":%d,\"geomean_delta\":"
           n_improved n_regressed n_equivalent n_inconclusive);
      json_float buf geomean_delta;
      Buffer.add_char buf '}')
    (summary_metrics t);
  Buffer.add_char buf '}'

let to_json t =
  let buf = Buffer.create 1024 in
  Buffer.add_string buf "{\"overall\":";
  json_string buf (json_overall (overall t));
  Buffer.add_string buf ",\"machine\":";
  json_string buf t.core.cr_identity.Baseline.machine;
  Buffer.add_string buf ",\"summary\":";
  json_summary buf t;
  Buffer.add_string buf ",\"cases\":[";
  List.iteri
    (fun i c ->
      if i > 0 then Buffer.add_char buf ',';
      Buffer.add_string buf "{\"id\":";
      json_string buf c.id;
      Buffer.add_string buf ",\"full_name\":";
      json_string buf c.full_name;
      Buffer.add_string buf ",\"overall\":";
      json_string buf (json_overall (case_overall c));
      Buffer.add_string buf ",\"metrics\":[";
      List.iteri
        (fun j r ->
          if j > 0 then Buffer.add_char buf ',';
          json_metric buf c r)
        c.reports;
      Buffer.add_string buf "]}")
    t.v_cases;
  Buffer.add_string buf "]}";
  Buffer.contents buf

(* The write path: the single-rule ratchet *)

let row_of_measurement ~id ~k metric measurement =
  match measurement with
  | Run.Exact n -> Baseline.exact_row ~id ~metric:(Metric.id metric) n
  | Run.Samples s ->
      Baseline.sampled_row ~id ~metric:(Metric.id metric) ~k
        ~samples:s.Run.sorted

let rows_of_trial id trial =
  List.map
    (fun (metric, measurement) ->
      row_of_measurement ~id ~k:(Run.Trial.k trial) metric measurement)
    (Run.Trial.measurements trial)

let with_suite_header ~suite file =
  match Baseline.suite file with
  | None -> Baseline.empty ~suite
  | Some _ -> file

let corrected t =
  let file = t.core.cr_file in
  let machine = t.core.cr_identity.Baseline.machine in
  let result =
    match t.core.cr_comparison with
    | No_baseline | Stale _ ->
        (* Missing or stale section: propose it wholesale from this run's
           evidence. *)
        let rows =
          List.concat_map (fun c -> rows_of_trial c.id c.trial) t.v_cases
        in
        Baseline.set_section
          (with_suite_header ~suite:t.core.cr_suite file)
          t.core.cr_identity rows
    | Compared ->
        let advance =
          List.concat_map
            (fun c ->
              List.filter_map
                (fun r ->
                  match r.verdict with
                  | Judged (Improved (Confirmed { pooled; k; _ })) ->
                      Some
                        (Baseline.sampled_row ~id:c.id
                           ~metric:(Metric.id r.metric) ~k ~samples:pooled)
                  | Judged (Improved (Exact_change { candidate = value; _ })) ->
                      Some
                        (Baseline.exact_row ~id:c.id
                           ~metric:(Metric.id r.metric) value)
                  | Proposed ->
                      Option.map
                        (row_of_measurement ~id:c.id ~k:(Run.Trial.k c.trial)
                           r.metric)
                        (Run.Trial.measurement c.trial r.metric)
                  | Judged
                      ( Regressed _ | Equivalent _ | Within_budget _
                      | Inconclusive _ ) ->
                      None)
                c.reports)
            t.v_cases
        in
        let prune =
          match t.core.cr_selection with
          | `Partial -> []
          | `Full -> (
              match Baseline.section file machine with
              | None -> []
              | Some s ->
                  let live = List.map (fun c -> c.id) t.v_cases in
                  List.filter_map
                    (fun row ->
                      let id = Baseline.row_id row in
                      if List.mem id live then None
                      else Some (id, Baseline.row_metric row))
                    (Baseline.rows s))
        in
        if advance = [] && prune = [] then file
        else Baseline.update_rows file ~machine ~advance ~prune
  in
  if String.equal (Baseline.to_string result) (Baseline.to_string file) then
    None
  else Some result

let bless ?(annotations = []) ~identity ~suite ~selection ~run file =
  let trials = Run.trials run in
  let ids = List.map fst trials in
  let rows =
    List.concat_map (fun (id, trial) -> rows_of_trial id trial) trials
  in
  let machine = identity.Baseline.machine in
  let section = Baseline.section file machine in
  let comparison = classify_comparison identity section in
  match (selection, comparison, section) with
  | `Partial, Compared, Some s ->
      (* A current section keeps its header and every unselected row. The
         selected cases' rows are replaced by case id: a metric a selected
         case no longer collects loses its row too. *)
      let key r = (Baseline.row_id r, Baseline.row_metric r) in
      let recorded = List.map key rows in
      let prune =
        List.filter_map
          (fun row ->
            let k = key row in
            if List.mem (fst k) ids && not (List.mem k recorded) then Some k
            else None)
          (Baseline.rows s)
      in
      (Baseline.update_rows ~annotations file ~machine ~advance:rows ~prune, [])
  | _ ->
      (* A full selection, or a missing or stale section: the section is
         re-recorded whole, and a partial one says what it drops. *)
      ( Baseline.set_section ~annotations
          (with_suite_header ~suite file)
          identity rows,
        stale_partial_notice ~selection ~comparison ~section ~case_ids:ids )
