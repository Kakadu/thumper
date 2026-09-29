(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let strf = Printf.sprintf

let err_duplicate fname what id =
  strf "%s: duplicate %s %s" fname what (Baseline.quote id)

let err_unrequested id =
  strf "Verdict.decide: confirmation for %s was not requested"
    (Baseline.quote id)

type shift = { estimate : float; lower : float; upper : float }

type reason =
  | Wide_interval
  | Non_positive
  | Environment
  | Unconfirmed
  | Exactness_lost
  | Batch_drifted
  | Candidate_drifted

type strong =
  | Exact_change of { baseline : int; candidate : int }
  | Confirmed of { first : shift; confirmation : shift }

type relation =
  | Improved of strong
  | Regressed of strong
  | Equivalent of shift option
  | Changed_within_budget of shift
  | Within_budget of shift
  | Inconclusive of { reason : reason; shift : shift option }

type metric_verdict = Proposed | Judged of relation

type metric_report = {
  metric : Metric.t;
  verdict : metric_verdict;
  budget : Budget.t;
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

(* Constants. The drift level is [Measure]'s, read when the trial is
   measured. *)

(* Initial rank-test level, 0.005 per side. *)
let alpha_initial = 0.005

(* Confirmation-pass level, 0.05 per side. *)
let alpha_confirmation = 0.05

(* A shift within 2e of zero is bias-comparable after recalibration. *)
let bias_comparability_factor = 2.0

(* The equivalence band of a budget [r] is at most half of it, so that
   [2e <= r], and at most [band_cap]. *)
let band_cap = 0.025
let band r = Float.min band_cap (r /. 2.)

(* Internal representation. Judging takes two passes: [judge] settles each
   metric or leaves it [Pending] with what its confirmation is compared
   against; [confirmations] lists the cases with a [Pending] metric; [decide]
   resolves each [Pending] into a relation, so a [t] holds none. *)

type pending = {
  p_dir : [ `Improved | `Regressed ];
  p_first : shift;
  p_first_k : int;
      (* the first trial's batch size, which the confirmation must match *)
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
  c_states : (Metric.t * m_state * Budget.t) list;
}

type core = {
  cr_identity : Baseline.identity;
  cr_suite : string;
  cr_comparison : comparison;
}

type provisional = { p_core : core; p_cases : pcase list }
type t = { core : core; v_load : Env.load; v_cases : case_report list }

(* Small helpers *)

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

(* Budget resolution, per collected metric: the case's per-metric merge
   wins, then the run's list, then [Budget.default] (bench.mli module doc).
   A budget on a metric the case does not collect is never looked up. *)
let budget_for ~run_budgets case metric =
  let own = Option.value ~default:[] (Bench.budgets case) in
  match
    List.find_opt
      (fun b -> Metric.equal (Budget.metric b) metric)
      (own @ run_budgets)
  with
  | Some b -> b
  | None -> Budget.default metric

(* The relation table over the fractional bounds [l <= u]. Every metric is
   lower-is-better, so a positive bound is worse. The r = 0 chain keeps the
   table total at a degenerate band ([band 0.] is [0.]). *)

type raw =
  | Strong of [ `Improved | `Regressed ]
  | Demonstrated (* changed within budget: a demonstrated direction *)
  | Tame of relation (* no direction claimed *)

let table ~e ~r sh =
  let l = sh.lower and u = sh.upper in
  if r = 0. then
    if u < 0. then Strong `Improved
    else if l > 0. then Strong `Regressed
    else if u <= 0. then Tame (Within_budget sh)
    else Tame (inconclusive ~shift:sh Wide_interval)
  else if u < -.e then Strong `Improved
  else if l > r then Strong `Regressed
  else if -.e <= l && u <= e then Tame (Equivalent (Some sh))
  else if l > e && u <= r then Demonstrated
  else if u <= r then Tame (Within_budget sh)
  else Tame (inconclusive ~shift:sh Wide_interval)

(* First-pass judgment of one sampled comparison. *)
let judge_sampled ~load ~r ~row_k ~baseline ~cand ~trial_k =
  let e = band r in
  if
    (* A non-positive sample breaks the logarithmic comparison, and a quiet
       host would not fix it, so it is tested before the load. *)
    (not (all_positive baseline)) || not (all_positive cand.Run.sorted)
  then Settled (Judged (inconclusive Non_positive))
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
    if is_loaded load then
      (* The shift is information only: a loaded host judges nothing. *)
      Settled (Judged (inconclusive ~shift:sh Environment))
    else if
      (* Load explains drift, so drift is only read on a quiet host. Like
         instability, it undermines only a shift within 2e. *)
      cand.Run.drifted && bias_comparable ~e sh
    then Settled (Judged (inconclusive ~shift:sh Candidate_drifted))
    else if k_moved && bias_comparable ~e sh then
      (* After recalibration only a bias-comparable shift degrades; a
         large shift is a verdict, not a calibration event. *)
      Settled (Judged (inconclusive ~shift:sh Batch_drifted))
    else
      (* Instability undermines a direction only within 2e, the batch-drift
         threshold: one outlier barely moves a rank interval, and a strong
         regression must not hide behind a heavy tail. Since [2e <= r], a
         direction within 2e is an improvement or a change within budget, and
         its interval ends within the budget. *)
      let vetoed () =
        bias_comparable ~e sh && (unstable baseline || unstable cand.Run.sorted)
      in
      match table ~e ~r sh with
      | Tame rel -> Settled (Judged rel)
      | (Demonstrated | Strong _) when vetoed () ->
          Settled (Judged (Within_budget sh))
      | Demonstrated -> Settled (Judged (Changed_within_budget sh))
      | Strong dir ->
          Pending
            {
              p_dir = dir;
              p_first = sh;
              p_first_k = trial_k;
              p_baseline_log = baseline_log;
              p_e = e;
              p_r = r;
            }

(* The cap is on the measured value itself, baseline-independent. *)
let over_cap budget c =
  match Budget.contract budget with
  | Budget.Absolute_max cap -> float_of_int c > cap
  | Budget.Relative _ -> false

(* The relative size of an exact change from [baseline] to [candidate], and
   [None] for growth from zero, which has none. *)
let exact_estimate ~baseline ~candidate =
  if baseline = 0 then None
  else
    Some
      ((float_of_int candidate -. float_of_int baseline)
      /. float_of_int baseline)

(* First-pass judgment of one exact (integer) comparison. The count was
   probed at [Measure.probe_k], the case's frozen k unless this trial's k is
   more than 16 times smaller. *)
let judge_exact ~budget ~case_k ~trial_k ~b ~c =
  let k_moved =
    match case_k with
    | Some kb -> Measure.probe_k ~frozen_k:case_k ~k:trial_k <> kb
    | None -> false
  in
  let strong = Exact_change { baseline = b; candidate = c } in
  (* A moved batch size explains a changed count, never one over the cap. *)
  if over_cap budget c then Regressed strong
  else if k_moved && b <> c then
    (* Amortized allocators can be k-phase-dependent. *)
    inconclusive Batch_drifted
  else if c = b then Equivalent None
  else if c < b then Improved strong
  else
    (* [None] for growth from zero, which has no relative size: it exceeds
       any relative budget, and under a cap it is the point [infinity]. *)
    let growth = exact_estimate ~baseline:b ~candidate:c in
    let within =
      let point = Option.value growth ~default:infinity in
      Changed_within_budget { estimate = point; lower = point; upper = point }
    in
    match Budget.contract budget with
    | Budget.Absolute_max _ -> within
    | Budget.Relative r ->
        let over = match growth with Some g -> g > r | None -> true in
        if over then Regressed strong else within

(* Judging *)

let check_distinct ~fname ~what ~ids =
  let tbl = Hashtbl.create 16 in
  List.iter
    (fun id ->
      if Hashtbl.mem tbl id then invalid_arg (err_duplicate fname what id)
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

let judge_metric ~load ~section ~id ~trial ~budget metric measurement =
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
      | Baseline.Sampled { k = row_k; samples }, Run.Samples cand -> (
          (* A cap, or a zero budget on a counter metric, judges exact counts
             only, which no rank test gives. *)
          match Budget.contract budget with
          | Budget.Absolute_max _ ->
              Settled (Judged (inconclusive Exactness_lost))
          | Budget.Relative 0. when Metric.is_counter metric ->
              Settled (Judged (inconclusive Exactness_lost))
          | Budget.Relative r ->
              judge_sampled ~load ~r ~row_k ~baseline:samples ~cand ~trial_k))

let judge ~identity ~suite ~load ~budgets ~file ~cases =
  check_distinct ~fname:"Verdict.judge" ~what:"case id"
    ~ids:(List.map (fun (c, _) -> Bench.id c) cases);
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
        let states =
          List.map
            (fun (metric, measurement) ->
              let budget = budget_for ~run_budgets:budgets bench_case metric in
              let state =
                match comparable with
                | None -> Settled Proposed
                | Some s ->
                    judge_metric ~load ~section:s ~id ~trial ~budget metric
                      measurement
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
  {
    p_core =
      { cr_identity = identity; cr_suite = suite; cr_comparison = comparison };
    p_cases;
  }

let has_pending pc =
  List.exists
    (fun (_, st, _) -> match st with Pending _ -> true | Settled _ -> false)
    pc.c_states

let confirmations p =
  List.filter_map
    (fun pc -> if has_pending pc then Some pc.c_id else None)
    p.p_cases

(* Deciding *)

(* An unconfirmed improvement is within budget, since its [U < -e] is within
   any budget; an unconfirmed regression has [U >= L > r]. *)
let unconfirmed pd =
  match pd.p_dir with
  | `Improved -> Within_budget pd.p_first
  | `Regressed -> inconclusive ~shift:pd.p_first Unconfirmed

let resolve_pending ~load ~conf metric pd =
  let first = pd.p_first in
  if is_loaded load then inconclusive ~shift:first Environment
  else
    match conf with
    | None -> unconfirmed pd
    | Some trial -> (
        (* A confirmation that recalibrated measured at another batch size,
           which the first trial's shift does not describe. *)
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
            then unconfirmed pd
            else
              let strong = Confirmed { first = pd.p_first; confirmation } in
              match pd.p_dir with
              | `Improved -> Improved strong
              | `Regressed -> Regressed strong)
        | Some (Run.Samples _) | Some (Run.Exact _) | None -> unconfirmed pd)

let decide ~load ~confirmations:confs p =
  let queue = confirmations p in
  check_distinct ~fname:"Verdict.decide" ~what:"confirmation id"
    ~ids:(List.map fst confs);
  List.iter
    (fun (id, _) ->
      if not (List.mem id queue) then invalid_arg (err_unrequested id))
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
        (* The confirmation's samples are judged, so its warnings are the
           case's too; one the first trial raised already is not repeated. *)
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
let suite t = t.core.cr_suite
let identity t = t.core.cr_identity
let load t = t.v_load

let exact_evidence case_report metric =
  match Run.Trial.measurement case_report.trial metric with
  | Some (Run.Exact _) -> true
  | Some (Run.Samples _) | None -> false

(* A statistical estimate crossing an absolute line is not an earned
   verdict, so only an exact count fails a cap. *)
let report_fails case_report report =
  match Budget.contract report.budget with
  | Budget.Relative _ -> (
      match report.verdict with
      | Judged (Regressed _) -> true
      | Proposed
      | Judged
          ( Improved _ | Equivalent _ | Changed_within_budget _
          | Within_budget _ | Inconclusive _ ) ->
          false)
  | Budget.Absolute_max _ -> (
      match Run.Trial.measurement case_report.trial report.metric with
      | Some (Run.Exact c) -> over_cap report.budget c
      | Some (Run.Samples _) | None -> false)

let report_inconclusive report =
  match report.verdict with
  | Judged (Inconclusive _) -> true
  | Judged
      ( Improved _ | Regressed _ | Equivalent _ | Changed_within_budget _
      | Within_budget _ ) ->
      false
  | Proposed -> false

let case_overall case_report =
  if List.exists (report_fails case_report) case_report.reports then `Fail
  else if List.exists report_inconclusive case_report.reports then `Inconclusive
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
  | `Inconclusive | `Pass -> if strict && has_proposed t then 1 else 0

(* JSON *)

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

(* [%.17g] round-trips a double; JSON has no spelling for NaN or the
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
  | Environment -> "environment"
  | Unconfirmed -> "unconfirmed"
  | Exactness_lost -> "exactness_lost"
  | Batch_drifted -> "batch_drifted"
  | Candidate_drifted -> "drifted"

let wire_relation = function
  | Improved _ -> "improved"
  | Regressed _ -> "regressed"
  | Equivalent _ -> "equivalent"
  | Changed_within_budget _ -> "changed_within_budget"
  | Within_budget _ -> "within_budget"
  | Inconclusive _ -> "inconclusive"

(* The reported deltas: the first-pass shift for confirmed strongs, the
   relation's shift otherwise (an inconclusive row's first-pass shift when its
   rank test ran); exact evidence has no interval bounds. *)
let deltas_of_verdict ~exact = function
  | Proposed -> (None, None, None)
  | Judged (Inconclusive { shift = None; _ }) -> (None, None, None)
  | Judged (Equivalent None) -> (Some 0.0, None, None)
  | Judged (Equivalent (Some sh))
  | Judged (Changed_within_budget sh)
  | Judged (Within_budget sh)
  | Judged (Inconclusive { shift = Some sh; _ }) ->
      if exact then (Some sh.estimate, None, None)
      else (Some sh.estimate, Some sh.lower, Some sh.upper)
  | Judged (Improved (Confirmed { first; _ }))
  | Judged (Regressed (Confirmed { first; _ })) ->
      (Some first.estimate, Some first.lower, Some first.upper)
  | Judged (Improved (Exact_change { baseline; candidate }))
  | Judged (Regressed (Exact_change { baseline; candidate })) ->
      (exact_estimate ~baseline ~candidate, None, None)

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
  | Judged rel -> (
      match Run.Trial.measurement case_report.trial report.metric with
      | Some (Run.Exact _) -> Buffer.add_string buf ",\"exact\":true"
      | Some (Run.Samples s) ->
          let confirmed =
            match rel with
            | Improved _ | Regressed _ -> true
            | Equivalent _ | Changed_within_budget _ | Within_budget _
            | Inconclusive _ ->
                false
          in
          Printf.bprintf buf ",\"confirmed\":%b,\"n\":%d" confirmed
            (Array.length s.Run.sorted)
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

let ratio_of_verdict v =
  (* Only the point delta matters; the [exact] flag shapes bounds only. *)
  match deltas_of_verdict ~exact:false v with
  | Some d, _, _ ->
      let ratio = 1.0 +. d in
      if Float.is_finite ratio && ratio > 0.0 then Some ratio else None
  | None, _, _ -> None

(* A run measures a handful of metrics; the quadratic dedup is nothing. *)
let summary_metrics t =
  let add order r =
    if List.exists (Metric.equal r.metric) order then order
    else r.metric :: order
  in
  List.rev
    (List.fold_left
       (fun order c -> List.fold_left add order c.reports)
       [] t.v_cases)

let counted_as r =
  match r.verdict with
  | Judged (Improved _) -> `Improved
  | Judged (Regressed _) -> `Regressed
  | Judged (Equivalent _ | Changed_within_budget _ | Within_budget _) ->
      `Equivalent
  | Proposed | Judged (Inconclusive _) -> `Inconclusive

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
      let counts = List.map counted_as reports in
      let count c = List.length (List.filter (( = ) c) counts) in
      let ratios =
        List.filter_map (fun r -> ratio_of_verdict r.verdict) reports
      in
      let geomean_delta =
        match ratios with
        | [] -> None
        | _ -> Some (Stats.geometric_mean (Array.of_list ratios) -. 1.0)
      in
      json_string buf (Metric.id metric);
      Printf.bprintf buf
        ":{\"n_improved\":%d,\"n_regressed\":%d,\"n_equivalent\":%d,\"n_inconclusive\":%d,\"geomean_delta\":"
        (count `Improved) (count `Regressed) (count `Equivalent)
        (count `Inconclusive);
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
