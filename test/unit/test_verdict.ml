(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Every verdict here is judged from hand-built trials against hand-built
   rows, so no test measures. Tied samples pin a shift's interval to a
   point, and two-valued ones pin it to their two values: against a row of
   1s, a trial of [v]s has [L = U = v - 1] up to an ulp. The values 0.5, 1,
   2 and 4 make every such bound exact, which the JSON documents need to
   print the same digits on any libm. *)

open Windtrap
module Baseline = Thumper.Private.Baseline
module Bench = Thumper.Private.Bench
module Budget = Thumper.Private.Budget
module Env = Thumper.Private.Env
module Metric = Thumper.Private.Metric
module Run = Thumper.Private.Run
module Stats = Thumper.Private.Stats
module Verdict = Thumper.Private.Verdict

let strf = Printf.sprintf

(* Evidence *)

let ident =
  {
    Baseline.machine = "testmachine";
    host = "test-host";
    ocaml = "5.5.0 64-bit release";
  }

let other_ident =
  {
    Baseline.machine = "othermachine";
    host = "other-host";
    ocaml = "5.5.0 64-bit release";
  }

let stale_ident = { ident with Baseline.ocaml = "5.4.0 64-bit release" }
let wall_time = Metric.wall_time
let alloc_words = Metric.alloc_words
let cpu_time = Metric.cpu_time
let ties n v = Array.make n v

let sampled ?(drifted = false) sorted =
  Run.Samples (Run.sampled ~sorted ~drifted)

let trial ?(k = 8) ?warnings ms = Run.Trial.make ~k ?warnings ms
let wall ?k ?drifted sorted = trial ?k [ (wall_time, sampled ?drifted sorted) ]
let alloc ?k n = trial ?k [ (alloc_words, Run.Exact n) ]

(* Nineteen samples at [v] and one at [100 v]: severely outlier-inflated,
   while the rank shift against tied samples at [x] stays [log v - log x]. *)
let spiked v = Array.append (ties 19 v) [| 100. *. v |]

(* Against tied 1s: the estimate and [L] are -50%, [U] is +100%. *)
let spread = [| 0.5; 0.5; 0.5; 2.0; 2.0 |]

(* The shifts of tied [1.5]s and [4]s against tied [1]s, so that a budget
   can sit exactly on one. *)
let d15 = expm1 (log 1.5)
let d4 = expm1 (log 4.0)

(* The case named [name], whose id is its slug. *)
let case ?budgets name =
  require_match
    (function Ok [ c ] -> Some c | Ok _ | Error _ -> None)
    (Bench.resolve [ Bench.bench ?budgets name ignore ])

let wall_row ?(k = 8) id samples =
  Baseline.sampled_row ~id ~metric:"wall_time" ~k ~samples

let alloc_row id n = Baseline.exact_row ~id ~metric:"alloc_words" n

let file_of ?(identity = ident) ?annotations rows =
  Baseline.set_section ?annotations
    (Baseline.empty ~suite:"digest")
    identity rows

let empty_file () = require_ok (Baseline.of_string "")

let relative ?(metric = wall_time) (e, r) =
  Budget.relative ~metric ~equivalent_within:e ~max_regression:r ()

(* Verdicts *)

let judge ?(load = Env.Quiet) ?(selection = `Full) ?(budgets = []) ?file cases =
  let file = match file with Some f -> f | None -> empty_file () in
  Verdict.judge ~identity:ident ~suite:"digest" ~load ~selection ~budgets ~file
    ~cases

(* The first pass, then [confirm id] as the confirmation of each case it
   asks for. *)
let decided ?load ?selection ?budgets ?file ?(decide_load = Env.Quiet)
    ?(confirm = fun _ -> None) cases =
  let p = judge ?load ?selection ?budgets ?file cases in
  let confirmations =
    List.filter_map
      (fun id -> Option.map (fun t -> (id, t)) (confirm id))
      (Verdict.confirmations p)
  in
  Verdict.decide ~load:decide_load ~confirmations p

(* Case "a" against [rows], by default a row of tied 1s. Its confirmation is
   [confirm], by default the first trial again, so a strong relation
   stands. *)
let one ?load ?budgets ?(rows = [ wall_row "a" (ties 5 1.) ]) ?decide_load
    ?confirm first =
  let confirm = Option.value confirm ~default:(Some first) in
  decided ?load ?budgets ~file:(file_of rows) ?decide_load
    ~confirm:(fun _ -> confirm)
    [ (case "a", first) ]

let reason_name = function
  | Verdict.Wide_interval -> "wide interval"
  | Non_positive -> "non-positive"
  | Baseline_unstable -> "baseline unstable"
  | Environment -> "environment"
  | Unconfirmed -> "unconfirmed"
  | Exactness_lost -> "exactness lost"
  | Batch_drifted -> "batch drifted"
  | Candidate_unstable -> "candidate unstable"
  | Candidate_drifted -> "candidate drifted"

(* A verdict's name, so that a mismatch prints both. *)
let describe = function
  | Verdict.Proposed -> "proposed"
  | Judged (Improved (Confirmed _)) -> "improved, confirmed"
  | Judged (Improved (Exact_change { baseline; candidate })) ->
      strf "improved, exact %d to %d" baseline candidate
  | Judged (Regressed (Confirmed _)) -> "regressed, confirmed"
  | Judged (Regressed (Exact_change { baseline; candidate })) ->
      strf "regressed, exact %d to %d" baseline candidate
  | Judged (Equivalent None) -> "equivalent, exact"
  | Judged (Equivalent (Some _)) -> "equivalent"
  | Judged (Changed_within_budget _) -> "changed within budget"
  | Judged (Within_budget _) -> "within budget"
  | Judged (Inconclusive { reason; _ }) -> "inconclusive, " ^ reason_name reason

let case_report ?(case = "a") t =
  require_match
    (List.find_opt (fun c -> String.equal c.Verdict.id case))
    (Verdict.cases t)

let report ?case ?(metric = wall_time) t =
  require_match
    (List.find_opt (fun r -> Metric.equal r.Verdict.metric metric))
    (case_report ?case t).Verdict.reports

let relation ?case ?metric t = describe (report ?case ?metric t).Verdict.verdict
let shift_triple (sh : Verdict.shift) = (sh.estimate, sh.lower, sh.upper)
let shift = triple (float 1e-9) (float 1e-9) (float 1e-9)

let outcome_name = function
  | `Pass -> "pass"
  | `Fail -> "fail"
  | `Inconclusive -> "inconclusive"

(* The file's lines, and a diff of two files as the lines each lacks. *)
let lines f = String.split_on_char '\n' (Baseline.to_string f)

let diff before after =
  let without l l' = List.filter (fun x -> not (List.mem x l')) l in
  (without (lines before) (lines after), without (lines after) (lines before))

let text_diff = pair (list string) (list string)

(* The line of row [id] in [f]. *)
let row_line f id =
  List.find_opt (String.starts_with ~prefix:(id ^ "\t")) (lines f)

let row_text row = Option.get (row_line (file_of [ row ]) (Baseline.row_id row))

(* Relations *)

let at_a_point =
  [
    (0.5, 0.05, "improved, confirmed");
    (0.5, 0.2, "improved, confirmed");
    (0.5, 0.0, "improved, confirmed");
    (0.97, 0.05, "improved, confirmed");
    (0.97, 0.2, "improved, confirmed");
    (0.97, 0.0, "improved, confirmed");
    (0.99, 0.05, "equivalent");
    (0.99, 0.2, "equivalent");
    (0.99, 0.0, "improved, confirmed");
    (1.0, 0.05, "equivalent");
    (1.0, 0.2, "equivalent");
    (1.0, 0.0, "within budget");
    (1.01, 0.05, "equivalent");
    (1.01, 0.2, "equivalent");
    (1.01, 0.0, "regressed, confirmed");
    (1.03, 0.05, "changed within budget");
    (1.03, 0.2, "changed within budget");
    (1.03, 0.0, "regressed, confirmed");
    (1.06, 0.05, "regressed, confirmed");
    (1.06, 0.2, "changed within budget");
    (1.06, 0.0, "regressed, confirmed");
    (1.5, 0.05, "regressed, confirmed");
    (1.5, 0.2, "regressed, confirmed");
    (1.5, 0.0, "regressed, confirmed");
  ]

(* Each row sits a bound of the interval on [-e], [e] or [r], or places it
   against the band, with the budget's [(e, r)]. *)
let edges =
  [
    ( "an interval ending at -e is equivalent",
      (0.5, 1.),
      ties 5 0.5,
      "equivalent" );
    ("an interval ending at e is equivalent", (1., 1.), ties 5 2., "equivalent");
    ( "an interval starting at e is within budget",
      (1., 4.),
      [| 2.; 2.; 4.; 4.; 4. |],
      "within budget" );
    ( "an interval above the band ending at r is changed within budget",
      (0.5, d4),
      [| 2.; 2.; 4.; 4.; 4. |],
      "changed within budget" );
    ( "an interval ending at r is within budget",
      (0.01, d15),
      [| 0.5; 0.5; 1.5; 1.5; 1.5 |],
      "within budget" );
    ( "an interval straddling the band from below is within budget",
      (0.025, 0.2),
      [| 1.; 1.; 1.05; 1.05; 1.05 |],
      "within budget" );
    ( "an interval reaching below the band is within budget",
      (0.025, 0.2),
      [| 0.5; 0.5; 1.05; 1.05; 1.05 |],
      "within budget" );
    ( "an interval past r and below the band is inconclusive",
      (0.025, 0.05),
      spread,
      "inconclusive, wide interval" );
    ( "at r = 0 an interval across 0 is inconclusive",
      (0., 0.),
      spread,
      "inconclusive, wide interval" );
  ]

(* The instability veto, with the budget's [(e, r)], the row's samples, this
   run's and the confirmation's. *)
let vetoes =
  let default = (0.025, 0.05) and tight = (0.025, 0.03) in
  let row = ties 5 1. and spiked_row = spiked 1. in
  [
    ( "an improvement within 2e falls back to within budget",
      default,
      row,
      spiked 0.96,
      None,
      "within budget" );
    ( "a change within budget within 2e falls back to within budget",
      default,
      row,
      spiked 1.03,
      None,
      "within budget" );
    ( "a regression within 2e is candidate unstable",
      tight,
      row,
      spiked 1.04,
      None,
      "inconclusive, candidate unstable" );
    ( "an equivalent shift is not vetoed",
      default,
      row,
      spiked 1.,
      None,
      "equivalent" );
    ( "an unstable row within 2e is baseline unstable",
      tight,
      spiked_row,
      ties 20 1.04,
      None,
      "inconclusive, baseline unstable" );
    ( "an unstable row takes precedence over an unstable trial",
      tight,
      spiked_row,
      spiked 1.04,
      None,
      "inconclusive, baseline unstable" );
    ( "a vetoed change ending at r is within budget",
      (d15 /. 2., d15),
      row,
      spiked 1.5,
      None,
      "within budget" );
    ( "a shift of exactly 2e is vetoed",
      (d15 /. 2., 0.3),
      row,
      spiked 1.5,
      None,
      "inconclusive, candidate unstable" );
    ( "an unstable row beyond 2e is judged",
      default,
      spiked_row,
      ties 20 5.,
      None,
      "regressed, confirmed" );
    ( "an unstable trial beyond 2e is judged",
      default,
      row,
      spiked 2.,
      Some (ties 5 2.),
      "regressed, confirmed" );
  ]

let vetoed (_, budget, row, first, confirmation, expected) =
  let confirm = Option.map (fun c -> Some (wall c)) confirmation in
  let t =
    one
      ~budgets:[ relative budget ]
      ~rows:[ wall_row "a" row ]
      ?confirm (wall first)
  in
  equal string expected (relation t)

(* The decision model's rule as its oracle: [decision-model/port.py]'s
   [judge] with [s2], ported line for line for a quiet host, one batch size
   and derived bands. *)
let port_relation ~r ~baseline ~cand ~conf =
  let e = Float.min 0.025 (r /. 2.) in
  let logs a = Array.map log a in
  let frac alpha c =
    let s =
      Stats.shift ~alpha_per_side:alpha ~baseline:(logs baseline)
        ~candidate:(logs c)
    in
    ( expm1 s.Stats.estimate,
      expm1 s.Stats.interval.Stats.lower,
      expm1 s.Stats.interval.Stats.upper )
  in
  let unstable v = v.(0) >= 0. && Stats.severe_outlier_inflation_sorted v in
  let est, l, u = frac 0.005 cand in
  let fallback reason =
    if u <= r then "within budget" else "inconclusive, " ^ reason
  in
  let near = Float.abs est <= 2. *. e in
  if u < -.e || l > r || (l > e && u <= r) then
    if near && unstable baseline then fallback "baseline unstable"
    else if near && unstable cand then fallback "candidate unstable"
    else if l > e && u <= r && not (u < -.e || l > r) then
      "changed within budget"
    else
      let improved = u < -.e in
      let ce, cl, cu = frac 0.05 conf in
      let reproduced = if improved then cu < -.e else cl > r in
      if (not reproduced) || (unstable conf && Float.abs ce <= 2. *. e) then
        fallback "unconfirmed"
      else if improved then "improved, confirmed"
      else "regressed, confirmed"
  else if -.e <= l && u <= e then "equivalent"
  else if u <= r then "within budget"
  else "inconclusive, wide interval"

let pp_port ppf (r, (b, c, f)) =
  let arr a =
    String.concat "; " (List.map (Printf.sprintf "%h") (Array.to_list a))
  in
  Format.fprintf ppf "r=%g baseline=[|%s|] cand=[|%s|] conf=[|%s|]" r (arr b)
    (arr c) (arr f)

(* Rows of 5 to 20 samples within 1% or 10% of their level, one in four
   spiked by an outlier at 100x; this run's level is mostly within 8% of the
   baseline's, else from half to one and a half times it. Every relation and
   both instability vetoes are reached. *)
let port_case =
  let open Gen in
  let row ~spiked level =
    let+ w = of_list [ 0.01; 0.1 ]
    and+ v = array ~size:(int_range 5 20) (float_range (-1.) 1.)
    and+ spike = map (fun k -> spiked && k = 0) (int_range 0 3) in
    let v = Array.map (fun x -> level *. (1. +. (w *. x))) v in
    if spike then v.(0) <- v.(0) *. 100.;
    Array.sort Float.compare v;
    v
  in
  let level =
    frequency [ (3, float_range 0.92 1.08); (1, float_range 0.5 1.5) ]
  in
  with_pp pp_port
    (let+ r = of_list [ 0.02; 0.05; 0.1; 0.2 ]
     and+ b = row ~spiked:true 1.0
     and+ c = bind level (row ~spiked:true)
     and+ f = bind level (row ~spiked:false) in
     (r, (b, c, f)))

let judgment_follows_the_port (r, (baseline, cand, conf)) =
  let row = wall_row "a" baseline in
  (* The row stores each sample as its [%.3e] text. *)
  let baseline =
    require_match
      (function
        | Baseline.Sampled { samples; _ } -> Some samples
        | Baseline.Exact_int _ -> None)
      (Baseline.row_evidence row)
  in
  let t =
    one
      ~budgets:[ Budget.no_slower_than r ]
      ~rows:[ row ]
      ~confirm:(Some (wall conf))
      (wall cand)
  in
  equal string (port_relation ~r ~baseline ~cand ~conf) (relation t)

(* The relation of an interval [L; U] with estimate [est], read from
   [relation]'s documentation clause by clause; [unstable] is whether this
   run's samples are, the row's being tied. *)
let documented_relation ~e ~r ~l ~u ~est ~unstable =
  let direction =
    if r = 0. then
      if u < 0. then Some "improved, confirmed"
      else if l > 0. then Some "regressed, confirmed"
      else None
    else if u < -.e then Some "improved, confirmed"
    else if l > r then Some "regressed, confirmed"
    else if -.e <= l && u <= e then None
    else if l > e && u <= r then Some "changed within budget"
    else None
  in
  match direction with
  | Some _ when unstable && Float.abs est <= 2. *. e ->
      if u <= r then "within budget" else "inconclusive, candidate unstable"
  | Some relation -> relation
  | None ->
      if r > 0. && -.e <= l && u <= e then "equivalent"
      else if u <= r then "within budget"
      else "inconclusive, wide interval"

let pp_interval ppf (r, (i, j)) =
  Format.fprintf ppf "r=%g [%g; %g]" r
    (float_of_int i /. 64.)
    (float_of_int j /. 64.)

(* A trial of two 1 + i/64 and three 1 + j/64 against tied 1s has
   [L = i/64], [U = j/64] and estimate [j/64] at both levels, and its
   confirmation, the same trial, reproduces any direction. No bound falls
   within an ulp of 0, e, 2e or r but on 0 itself, which [log 1] gives
   exactly. *)
let interval =
  let open Gen in
  with_pp pp_interval
    (let+ r = of_list [ 0.; 0.02; 0.05; 0.1; 0.2 ]
     and+ i = int_range (-40) 40
     and+ w = int_range 0 20 in
     (r, (i, min 40 (i + w))))

let every_interval_has_its_documented_relation (r, (i, j)) =
  let a = 1. +. (float_of_int i /. 64.) and b = 1. +. (float_of_int j /. 64.) in
  let samples = [| a; a; b; b; b |] in
  let t = one ~budgets:[ Budget.no_slower_than r ] (wall samples) in
  equal string
    (documented_relation
       ~e:(Float.min 0.025 (r /. 2.))
       ~r ~l:(a -. 1.) ~u:(b -. 1.) ~est:(b -. 1.)
       ~unstable:(Stats.severe_outlier_inflation_sorted samples))
    (relation t)

type budget = Rel of float | Cap of float

let alloc_budget = function
  | Rel r -> Budget.no_more_alloc_than r
  | Cap v -> Budget.at_most ~metric:alloc_words v

let exact_counts =
  [
    ("an equal count is equivalent", Rel 0., 54, 54, "equivalent, exact");
    ("a smaller count is improved", Rel 0., 54, 53, "improved, exact 54 to 53");
    ("growth beyond r is regressed", Rel 0., 54, 55, "regressed, exact 54 to 55");
    ( "growth within r is changed within budget",
      Rel 0.1,
      100,
      105,
      "changed within budget" );
    ( "growth of exactly r is changed within budget",
      Rel 0.1,
      100,
      110,
      "changed within budget" );
    ( "growth past r is regressed",
      Rel 0.1,
      100,
      111,
      "regressed, exact 100 to 111" );
    ( "growth from 0 is regressed under any r",
      Rel 0.1,
      0,
      1,
      "regressed, exact 0 to 1" );
    ( "a count over the cap is regressed",
      Cap 100.,
      100,
      120,
      "regressed, exact 100 to 120" );
    ( "a count over the cap and under the row is regressed",
      Cap 100.,
      200,
      150,
      "regressed, exact 200 to 150" );
    ( "a count under the cap and the row is improved",
      Cap 100.,
      100,
      80,
      "improved, exact 100 to 80" );
    ( "growth under the cap is changed within budget",
      Cap 100.,
      90,
      95,
      "changed within budget" );
    ( "growth to the cap is changed within budget",
      Cap 100.,
      90,
      100,
      "changed within budget" );
    ( "growth from 0 under the cap is changed within budget",
      Cap 10.,
      0,
      3,
      "changed within budget" );
    ( "an unchanged count under the cap is equivalent",
      Cap 100.,
      100,
      100,
      "equivalent, exact" );
  ]

(* The case's frozen batch size is its sampled row's, 32; the count is
   probed at 32 while that is at most 16 times the trial's. *)
let probed_counts =
  [
    ( "a count probed at the frozen size is compared",
      Rel 0.,
      32,
      55,
      "regressed, exact 54 to 55" );
    ( "a trial at 1/16 of the frozen size compares its count",
      Rel 0.,
      2,
      55,
      "regressed, exact 54 to 55" );
    ( "a changed count probed at another size is batch drifted",
      Rel 0.,
      1,
      55,
      "inconclusive, batch drifted" );
    ( "an unchanged count probed at another size is equivalent",
      Rel 0.,
      1,
      54,
      "equivalent, exact" );
    ( "a count over the cap probed at another size is regressed",
      Cap 100.,
      1,
      120,
      "regressed, exact 54 to 120" );
  ]

let probed_count (_, budget, k, count, expected) =
  let t =
    one
      ~budgets:[ alloc_budget budget ]
      ~rows:[ wall_row ~k:32 "a" (ties 5 1.); alloc_row "a" 54 ]
      (trial ~k
         [ (wall_time, sampled (ties 5 1.)); (alloc_words, Run.Exact count) ])
  in
  equal string expected (relation ~metric:alloc_words t)

(* A sampled row at batch size 8 against a trial at another size. *)
let moved_batch_sizes =
  [
    ( "a shift within 2e is batch drifted",
      32,
      ties 5 1.,
      "inconclusive, batch drifted" );
    ("a shift beyond 2e is judged", 16, ties 5 0.5, "improved, confirmed");
  ]

let sampled_alloc_row samples =
  Baseline.sampled_row ~id:"a" ~metric:"alloc_words" ~k:8 ~samples

let exactness =
  [
    ( "an exact row against a sampled count",
      Rel 0.,
      (fun () -> alloc_row "a" 54),
      (fun () -> sampled (ties 5 54.)),
      "inconclusive, exactness lost" );
    ( "a sampled row against an exact count",
      Rel 0.,
      (fun () -> sampled_alloc_row (ties 5 54.)),
      (fun () -> Run.Exact 54),
      "inconclusive, exactness lost" );
    ( "a sampled row against a sampled count under r = 0",
      Rel 0.,
      (fun () -> sampled_alloc_row (ties 5 54.)),
      (fun () -> sampled (ties 5 54.)),
      "inconclusive, exactness lost" );
    ( "a sampled row against a sampled count under r > 0",
      Rel 0.05,
      (fun () -> sampled_alloc_row (ties 5 54.)),
      (fun () -> sampled (ties 5 54.)),
      "equivalent" );
    ( "sampled counts under a cap read the default budget",
      Cap 150.,
      (fun () -> sampled_alloc_row (ties 5 100.)),
      (fun () -> sampled (ties 5 200.)),
      "regressed, confirmed" );
  ]

let relations =
  group "Relations"
    [
      cases "a point shift"
        ~name:(fun (v, r, _) -> strf "%g at r = %g" v r)
        at_a_point
        (fun (v, r, expected) ->
          equal string expected
            (relation
               (one ~budgets:[ Budget.no_slower_than r ] (wall (ties 5 v)))));
      cases "an interval"
        ~name:(fun (name, _, _, _) -> name)
        edges
        (fun (_, budget, samples, expected) ->
          equal string expected
            (relation (one ~budgets:[ relative budget ] (wall samples))));
      prop "every interval has its documented relation" interval
        every_interval_has_its_documented_relation;
      prop "judgment follows the decision model's port" port_case
        judgment_follows_the_port;
      cases "the instability veto"
        ~name:(fun (name, _, _, _, _, _) -> name)
        vetoes vetoed;
      cases "exact counts"
        ~name:(fun (name, _, _, _, _) -> name)
        exact_counts
        (fun (_, budget, row, count, expected) ->
          equal string expected
            (relation ~metric:alloc_words
               (one
                  ~budgets:[ alloc_budget budget ]
                  ~rows:[ alloc_row "a" row ]
                  (alloc count))));
      cases "an exact count at a moved batch size"
        ~name:(fun (name, _, _, _, _) -> name)
        probed_counts probed_count;
      cases "a sampled row at a moved batch size"
        ~name:(fun (name, _, _, _) -> name)
        moved_batch_sizes
        (fun (_, k, samples, expected) ->
          equal string expected
            (relation
               (one ~rows:[ wall_row ~k "a" (ties 5 1.) ] (wall ~k:8 samples))));
      cases "exactness"
        ~name:(fun (name, _, _, _, _) -> name)
        exactness
        (fun (_, budget, row, measurement, expected) ->
          equal string expected
            (relation ~metric:alloc_words
               (one
                  ~budgets:[ alloc_budget budget ]
                  ~rows:[ row () ]
                  (trial [ (alloc_words, measurement ()) ]))));
    ]

(* Reports *)

let budget_name = function
  | None -> "none"
  | Some b -> (
      match Budget.contract b with
      | Budget.Relative { max_regression; band } ->
          strf "r = %g, e = %g" max_regression band
      | Budget.Absolute_max v -> strf "at most %g" v)

let resolutions =
  [
    ( "a case's own budget wins over the run's",
      (fun () -> [ Budget.no_slower_than 0. ]),
      (fun () -> Some [ Budget.no_slower_than 0.5 ]),
      [ wall_time ],
      [ ("wall_time", "r = 0.5, e = 0.025") ] );
    ( "a budget on a metric the trial did not measure is dropped",
      (fun () -> [ Budget.no_slower_than 0.1; Budget.no_more_alloc_than 0. ]),
      (fun () -> None),
      [ wall_time ],
      [ ("wall_time", "r = 0.1, e = 0.025") ] );
    ( "a case left with none gets the default on wall_time",
      (fun () -> [ Budget.no_more_alloc_than 0. ]),
      (fun () -> None),
      [ wall_time ],
      [ ("wall_time", "r = 0.05, e = 0.025") ] );
    ( "the default binds no other metric",
      (fun () -> []),
      (fun () -> None),
      [ cpu_time ],
      [ ("cpu_time", "none") ] );
    ( "a metric without a budget has none, in the trial's order",
      (fun () -> [ Budget.no_slower_than 0.1 ]),
      (fun () -> None),
      [ cpu_time; wall_time ],
      [ ("cpu_time", "none"); ("wall_time", "r = 0.1, e = 0.025") ] );
    ( "a second budget for one metric is ignored",
      (fun () -> [ Budget.no_slower_than 0.1; Budget.no_slower_than 0.5 ]),
      (fun () -> None),
      [ wall_time ],
      [ ("wall_time", "r = 0.1, e = 0.025") ] );
  ]

let budgets_resolve (_, run_budgets, case_budgets, metrics, expected) =
  let t =
    decided ~budgets:(run_budgets ())
      [
        ( case ?budgets:(case_budgets ()) "a",
          trial (List.map (fun m -> (m, sampled (ties 5 1.))) metrics) );
      ]
  in
  equal
    (list (pair string string))
    expected
    (List.map
       (fun r -> (Metric.id r.Verdict.metric, budget_name r.Verdict.budget))
       (case_report t).Verdict.reports)

(* The confirmation's samples are judged and pooled, so a warning about them
   is the case's; one the first trial raised already is not repeated. *)
let a_confirmation_s_warnings_follow_the_first_trial_s () =
  let with_warnings warnings =
    trial ~warnings [ (wall_time, sampled (ties 5 2.)) ]
  in
  let t =
    one
      ~confirm:(Some (with_warnings [ "gc"; "folded" ]))
      (with_warnings [ "gc" ])
  in
  equal (list string) [ "gc"; "folded" ] (case_report t).Verdict.warnings

let reports =
  group "Reports"
    [
      cases "a case's budgets"
        ~name:(fun (name, _, _, _, _) -> name)
        resolutions budgets_resolve;
      test "a confirmation's warnings follow the first trial's, each once"
        a_confirmation_s_warnings_follow_the_first_trial_s;
    ]

(* Comparison states *)

let comparison_name = function
  | Verdict.No_baseline -> "no baseline"
  | Stale (Ocaml_mismatch { section; current }) ->
      strf "stale: %s, running %s" section current
  | Compared -> "compared"

let files =
  [
    ("an empty file", (fun () -> empty_file ()), "no baseline", None);
    ( "a file with another machine's section alone",
      (fun () -> file_of ~identity:other_ident [ wall_row "a" (ties 5 1.) ]),
      "no baseline",
      None );
    ( "a section of another compiler",
      (fun () -> file_of ~identity:stale_ident [ wall_row "a" (ties 5 1.) ]),
      "stale: 5.4.0 64-bit release, running 5.5.0 64-bit release",
      None );
    ( "a section of this compiler",
      (fun () -> file_of [ wall_row "a" (ties 5 1.) ]),
      "compared",
      Some "5.5.0 64-bit release" );
    ( "a section of this compiler in another suite's file",
      (fun () ->
        Baseline.set_section
          (Baseline.empty ~suite:"other")
          ident
          [ wall_row "a" (ties 5 1.) ]),
      "compared",
      Some "5.5.0 64-bit release" );
  ]

let a_file_is_compared_or_not (_, file, expected, section) =
  let file = file () in
  let t = decided ~file [ (case "a", wall (ties 5 1.)) ] in
  equal
    (pair string (option string))
    (expected, section)
    ( comparison_name (Verdict.comparison t),
      Option.map Baseline.ocaml_of
        (Verdict.compared_section ~identity:ident file) )

let every_metric_is_proposed_on a_file () =
  let t =
    decided
      ~budgets:[ Budget.no_slower_than 0.05; Budget.no_more_alloc_than 0. ]
      ~file:(a_file ())
      [
        ( case "a",
          trial
            [ (wall_time, sampled (ties 5 2.)); (alloc_words, Run.Exact 100) ]
        );
      ]
  in
  equal (list string) [ "proposed"; "proposed" ]
    (List.map
       (fun r -> describe r.Verdict.verdict)
       (case_report t).Verdict.reports)

let comparison_states =
  group "Comparison states"
    [
      cases "comparison and compared_section"
        ~name:(fun (name, _, _, _) -> name)
        files a_file_is_compared_or_not;
      test "on a stale section every metric is proposed"
        (every_metric_is_proposed_on (fun () ->
             file_of ~identity:stale_ident
               [ wall_row "a" (ties 5 1.); alloc_row "a" 54 ]));
      test "without a section every metric is proposed"
        (every_metric_is_proposed_on empty_file);
    ]

(* Judging *)

let loaded = Env.Loaded { load = 8.; cores = 8 }

(* The drift veto, with the budget's [(e, r)]. *)
let drifted_trials =
  [
    ( "an equivalent shift is candidate drifted",
      (0.025, 0.05),
      1.,
      "inconclusive, candidate drifted" );
    ( "a shift within 2e never falls back to within budget",
      (0.025, 0.05),
      1.04,
      "inconclusive, candidate drifted" );
    ( "a shift of exactly 2e is candidate drifted",
      (d15 /. 2., 0.3),
      1.5,
      "inconclusive, candidate drifted" );
    ("a shift beyond 2e is judged", (0.025, 0.05), 2., "regressed, confirmed");
  ]

(* Each row's reason is the first of judge's tests that the evidence meets. *)
let orders =
  [
    ( "a zero sample in the row is non-positive",
      Env.Quiet,
      [| 0.; 1.; 2. |],
      (fun () -> wall (ties 5 1.)),
      "inconclusive, non-positive" );
    ( "a zero sample in the trial is non-positive",
      Env.Quiet,
      ties 5 1.,
      (fun () -> wall (ties 5 0.)),
      "inconclusive, non-positive" );
    ( "a zero sample is non-positive on a loaded host",
      loaded,
      ties 5 1.,
      (fun () -> wall (ties 5 0.)),
      "inconclusive, non-positive" );
    ( "a loaded host is environment",
      loaded,
      ties 5 1.,
      (fun () -> wall (ties 5 2.)),
      "inconclusive, environment" );
    ( "a drifted trial on a loaded host is environment",
      loaded,
      ties 5 1.,
      (fun () -> wall ~drifted:true (ties 5 2.)),
      "inconclusive, environment" );
    ( "a three-sample row is compared",
      Env.Quiet,
      ties 3 1.,
      (fun () -> wall (ties 5 1.)),
      "equivalent" );
  ]

let an_exact_comparison_settles_on_a_loaded_host () =
  let t =
    one ~load:loaded
      ~budgets:[ Budget.no_more_alloc_than 0. ]
      ~rows:[ wall_row "a" (ties 5 1.); alloc_row "a" 54 ]
      (trial [ (wall_time, sampled (ties 5 2.)); (alloc_words, Run.Exact 100) ])
  in
  equal (pair string string)
    ("inconclusive, environment", "regressed, exact 54 to 100")
    (relation t, relation ~metric:alloc_words t)

let exactness_lost_holds_on_a_loaded_host () =
  let t =
    one ~load:loaded
      ~budgets:[ Budget.no_more_alloc_than 0. ]
      ~rows:[ alloc_row "a" 54 ]
      (trial [ (alloc_words, sampled (ties 5 54.)) ])
  in
  equal string "inconclusive, exactness lost" (relation ~metric:alloc_words t)

let confirmations_list_the_pending_cases_in_order () =
  let p =
    judge
      ~file:
        (file_of
           [
             wall_row "c1" (ties 5 1.);
             wall_row "c2" (ties 5 1.);
             wall_row "c3" (ties 5 1.);
             alloc_row "c4" 54;
           ])
      [
        (case "c1", wall (ties 5 2.));
        (case "c2", wall (ties 5 1.));
        (case "c3", wall (ties 5 0.5));
        (case ~budgets:[ Budget.no_more_alloc_than 0. ] "c4", alloc 100);
      ]
  in
  equal (list string) [ "c1"; "c3" ] (Verdict.confirmations p)

let a_case_with_two_pending_metrics_is_listed_once () =
  let p =
    judge
      ~file:
        (file_of
           [
             Baseline.sampled_row ~id:"a" ~metric:"cpu_time" ~k:8
               ~samples:(ties 5 1.);
             wall_row "a" (ties 5 1.);
           ])
      [
        ( case "a",
          trial
            [
              (wall_time, sampled (ties 5 2.)); (cpu_time, sampled (ties 5 2.));
            ] );
      ]
  in
  equal (list string) [ "a" ] (Verdict.confirmations p)

let nothing_to_confirm =
  [
    ("a loaded host", (fun () -> Budget.no_slower_than 0.05), loaded, 2.);
    ( "an unchanged row at r = 0",
      (fun () -> Budget.no_slower_than 0.),
      Env.Quiet,
      1. );
  ]

(* The first trial regresses by 2x against tied 1s unless a row says;
   [(e, r)] is the budget. *)
let confirmations =
  [
    ( "a confirmation that reproduces it",
      (0.025, 0.05),
      ties 5 2.,
      (fun () -> Some (wall (ties 5 2.))),
      "regressed, confirmed" );
    ( "a confirmation at the row's level",
      (0.025, 0.05),
      ties 5 2.,
      (fun () -> Some (wall (ties 5 1.))),
      "inconclusive, unconfirmed" );
    ( "a confirmation in the other direction",
      (0.025, 0.05),
      ties 5 2.,
      (fun () -> Some (wall (ties 5 0.5))),
      "inconclusive, unconfirmed" );
    ( "no confirmation",
      (0.025, 0.05),
      ties 5 2.,
      (fun () -> None),
      "inconclusive, unconfirmed" );
    ( "a drifted confirmation",
      (0.025, 0.05),
      ties 5 2.,
      (fun () -> Some (wall ~drifted:true (ties 5 2.))),
      "inconclusive, unconfirmed" );
    ( "a confirmation without the metric",
      (0.025, 0.05),
      ties 5 2.,
      (fun () -> Some (alloc 3)),
      "inconclusive, unconfirmed" );
    ( "a confirmation with a non-positive sample",
      (0.025, 0.05),
      ties 5 2.,
      (fun () -> Some (wall [| 0.; 2.; 2.; 2.; 2. |])),
      "inconclusive, unconfirmed" );
    ( "a confirmation at another batch size",
      (0.025, 0.05),
      ties 5 2.,
      (fun () -> Some (wall ~k:16 (ties 5 2.))),
      "inconclusive, unconfirmed" );
    ( "an unstable confirmation beyond 2e",
      (0.025, 0.05),
      ties 5 5.,
      (fun () -> Some (wall (spiked 5.))),
      "regressed, confirmed" );
    ( "a stable confirmation within 2e",
      (0.1, 0.1),
      ties 5 2.,
      (fun () -> Some (wall (ties 5 1.15))),
      "regressed, confirmed" );
    ( "an unstable confirmation within 2e",
      (0.1, 0.1),
      ties 5 2.,
      (fun () -> Some (wall (spiked 1.15))),
      "inconclusive, unconfirmed" );
    ( "an unstable confirmation of exactly 2e",
      (d15 /. 2., 0.3),
      ties 5 2.,
      (fun () -> Some (wall (spiked 1.5))),
      "inconclusive, unconfirmed" );
  ]

(* A sampled count regresses by 2x, and its confirmation is exact. *)
let a_confirmation_measured_as_exact_is_unconfirmed () =
  let t =
    one
      ~budgets:[ Budget.no_more_alloc_than 0.05 ]
      ~rows:[ sampled_alloc_row (ties 5 1.) ]
      ~confirm:(Some (alloc 2))
      (trial [ (alloc_words, sampled (ties 5 2.)) ])
  in
  equal string "inconclusive, unconfirmed" (relation ~metric:alloc_words t)

(* Against [0.9; 0.95; 1; 1.05; 1.1], one of the 25 differences of
   [1.14; 1.2; 1.2; 1.2; 1.2] is below [log 1.05]: the lower bound is about
   +3.6% at 0.005 per side and +9.1% at 0.05, and only the latter is beyond
   [r = 0.05]. *)
let the_confirmation_is_judged_at_0_05_per_side () =
  let t =
    one
      ~rows:[ wall_row "a" [| 0.9; 0.95; 1.0; 1.05; 1.1 |] ]
      ~confirm:(Some (wall [| 1.14; 1.2; 1.2; 1.2; 1.2 |]))
      (wall (ties 5 2.))
  in
  equal string "regressed, confirmed" (relation t)

let confirmed (r : Verdict.metric_report) =
  match r.verdict with
  | Judged (Regressed (Confirmed { first; confirmation; pooled; k }))
  | Judged (Improved (Confirmed { first; confirmation; pooled; k })) ->
      Some (first, confirmation, pooled, k)
  | _ -> None

let a_confirmed_relation_carries_both_shifts_and_the_pooled_samples () =
  let first, confirmation, pooled, k =
    require_match confirmed (report (one (wall (ties 5 2.))))
  in
  equal ~msg:"first" shift (1., 1., 1.) (shift_triple first);
  equal ~msg:"confirmation" shift (1., 1., 1.) (shift_triple confirmation);
  equal (pair (array float_exact) int) (ties 10 2., 8) (pooled, k)

let pooling_leaves_both_trials_unchanged () =
  let samples tr =
    require_match
      (function Some (Run.Samples s) -> Some s.Run.sorted | _ -> None)
      (Run.Trial.measurement tr wall_time)
  in
  let first = wall [| 0.4; 0.45; 0.5; 0.55; 0.6 |]
  and again = wall [| 0.42; 0.47; 0.52; 0.57; 0.62 |] in
  let t = one ~confirm:(Some again) first in
  let _, _, pooled, _ = require_match confirmed (report t) in
  ignore (Verdict.corrected t);
  equal ~msg:"pooled" (array float_exact)
    [| 0.4; 0.42; 0.45; 0.47; 0.5; 0.52; 0.55; 0.57; 0.6; 0.62 |]
    pooled;
  equal
    (pair (array float_exact) (array float_exact))
    ([| 0.4; 0.45; 0.5; 0.55; 0.6 |], [| 0.42; 0.47; 0.52; 0.57; 0.62 |])
    (samples first, samples again)

(* The first trial improves by half against tied 1s. *)
let improvements =
  [
    ( "not reproduced",
      (fun () -> Some (wall (ties 5 1.))),
      Env.Quiet,
      "within budget" );
    ("without a confirmation", (fun () -> None), Env.Quiet, "within budget");
    ( "on a loaded host at the confirmations",
      (fun () -> Some (wall (ties 5 0.5))),
      loaded,
      "inconclusive, environment" );
  ]

let an_unconfirmed_improvement_keeps_its_first_shift () =
  let t = one ~confirm:(Some (wall (ties 5 1.))) (wall (ties 5 0.5)) in
  let sh =
    require_match
      (fun (r : Verdict.metric_report) ->
        match r.verdict with Judged (Within_budget sh) -> Some sh | _ -> None)
      (report t)
  in
  equal shift (-0.5, -0.5, -0.5) (shift_triple sh);
  is_none (Verdict.corrected t)

let inconclusive_shift (r : Verdict.metric_report) =
  match r.verdict with
  | Judged (Inconclusive { reason; shift }) ->
      Some (reason_name reason, Option.map shift_triple shift)
  | _ -> None

(* An inconclusive relation keeps the first trial's shift iff the rank test
   ran, whatever its reason. A loaded host at the confirmations makes a
   pending relation environment whatever its confirmation, which here
   reproduces it. *)
let kept_shifts =
  [
    ( "unconfirmed",
      (fun () -> one ~confirm:None (wall (ties 5 2.))),
      ("unconfirmed", Some (1., 1., 1.)) );
    ( "on a loaded host at the confirmations",
      (fun () -> one ~decide_load:loaded (wall (ties 5 2.))),
      ("environment", Some (1., 1., 1.)) );
    ( "on a loaded host at the first pass",
      (fun () -> one ~load:loaded (wall (ties 5 2.))),
      ("environment", Some (1., 1., 1.)) );
    ( "a wide interval",
      (fun () -> one (wall spread)),
      ("wide interval", Some (-0.5, -0.5, 1.)) );
    ( "a drifted trial",
      (fun () -> one (wall ~drifted:true (ties 5 1.04))),
      ("candidate drifted", Some (0.04, 0.04, 0.04)) );
    ( "a non-positive sample",
      (fun () -> one (wall (ties 5 0.))),
      ("non-positive", None) );
  ]

let pp_load ppf = function
  | Env.Quiet -> Format.pp_print_string ppf "quiet"
  | Env.Loaded { load; cores } ->
      Format.fprintf ppf "loaded %g on %d" load cores

let host_load =
  Testable.make ~pp:pp_load ~equal:(fun a b ->
      match (a, b) with
      | Env.Quiet, Env.Quiet -> true
      | Env.Loaded a, Env.Loaded b ->
          Float.equal a.load b.load && a.cores = b.cores
      | Env.Quiet, Env.Loaded _ | Env.Loaded _, Env.Quiet -> false)

let decide_refuses () =
  let p =
    judge
      ~file:(file_of [ wall_row "a" (ties 5 1.) ])
      [ (case "a", wall (ties 5 2.)) ]
  in
  raises
    (Invalid_argument
       "Verdict.decide: confirmation for 'nope' was not requested") (fun () ->
      Verdict.decide ~load:Env.Quiet
        ~confirmations:[ ("nope", wall (ties 5 2.)) ]
        p);
  raises (Invalid_argument "Verdict.decide: duplicate confirmation id 'a'")
    (fun () ->
      Verdict.decide ~load:Env.Quiet
        ~confirmations:[ ("a", wall (ties 5 2.)); ("a", wall (ties 5 2.)) ]
        p)

let judging =
  group "Judging"
    [
      cases "the drift veto"
        ~name:(fun (name, _, _, _) -> name)
        drifted_trials
        (fun (_, budget, v, expected) ->
          equal string expected
            (relation
               (one
                  ~budgets:[ relative budget ]
                  ~confirm:(Some (wall (ties 5 v)))
                  (wall ~drifted:true (ties 5 v)))));
      cases "the order of the tests"
        ~name:(fun (name, _, _, _, _) -> name)
        orders
        (fun (_, load, row, first, expected) ->
          equal string expected
            (relation (one ~load ~rows:[ wall_row "a" row ] (first ()))));
      test "an exact comparison settles on a loaded host"
        an_exact_comparison_settles_on_a_loaded_host;
      test "exactness lost holds on a loaded host"
        exactness_lost_holds_on_a_loaded_host;
      test "judge refuses two cases with one id" (fun () ->
          raises (Invalid_argument "Verdict.judge: duplicate case id 'a'")
            (fun () ->
              judge
                [ (case "a", wall (ties 5 1.)); (case "a", wall (ties 5 1.)) ]));
      test "confirmations lists the cases with a pending relation, in order"
        confirmations_list_the_pending_cases_in_order;
      test "confirmations lists a case with two pending metrics once"
        a_case_with_two_pending_metrics_is_listed_once;
      cases "confirmations is empty"
        ~name:(fun (name, _, _, _) -> name)
        nothing_to_confirm
        (fun (_, budget, load, v) ->
          let p =
            judge ~load
              ~budgets:[ budget () ]
              ~file:(file_of [ wall_row "a" (ties 5 1.) ])
              [ (case "a", wall (ties 5 v)) ]
          in
          equal (list string) [] (Verdict.confirmations p));
      cases "decide, on a pending regression"
        ~name:(fun (name, _, _, _, _) -> name)
        confirmations
        (fun (_, budget, first, confirm, expected) ->
          equal string expected
            (relation
               (one
                  ~budgets:[ relative budget ]
                  ~confirm:(confirm ()) (wall first))));
      test "decide, on a pending count, with an exact confirmation"
        a_confirmation_measured_as_exact_is_unconfirmed;
      test "decide judges the confirmation at 0.05 per side"
        the_confirmation_is_judged_at_0_05_per_side;
      test "a confirmed relation carries both shifts and the pooled samples"
        a_confirmed_relation_carries_both_shifts_and_the_pooled_samples;
      test "pooling leaves both trials' samples unchanged"
        pooling_leaves_both_trials_unchanged;
      cases "decide, on a pending improvement"
        ~name:(fun (name, _, _, _) -> name)
        improvements
        (fun (_, confirm, decide_load, expected) ->
          equal string expected
            (relation
               (one ~decide_load ~confirm:(confirm ()) (wall (ties 5 0.5)))));
      test "an unconfirmed improvement keeps its first shift and no row"
        an_unconfirmed_improvement_keeps_its_first_shift;
      cases "an inconclusive relation's shift"
        ~name:(fun (name, _, _) -> name)
        kept_shifts
        (fun (_, t, expected) ->
          equal
            (pair string (option shift))
            expected
            (require_match inconclusive_shift (report (t ()))));
      test "the verdict's load is decide's" (fun () ->
          equal host_load loaded
            (Verdict.load (one ~decide_load:loaded (wall (ties 5 1.)))));
      test "decide refuses an unrequested or repeated confirmation"
        decide_refuses;
    ]

(* Observers *)

(* Each row's verdict has one case "a", and its first report is read. *)
let failing =
  [
    ( "a regression under a relative budget",
      (fun () ->
        one
          ~budgets:[ Budget.no_more_alloc_than 0. ]
          ~rows:[ alloc_row "a" 54 ]
          (alloc 55)),
      true );
    ( "an inconclusive relation under a relative budget",
      (fun () -> one (wall spread)),
      false );
    ( "a regressed count under a cap",
      (fun () ->
        one
          ~budgets:[ Budget.at_most ~metric:alloc_words 100. ]
          ~rows:[ alloc_row "a" 200 ]
          (alloc 150)),
      true );
    ( "a count at the cap",
      (fun () ->
        decided
          ~budgets:[ Budget.at_most ~metric:alloc_words 100. ]
          [ (case "a", alloc 100) ]),
      false );
    ( "a proposed count over the cap",
      (fun () ->
        decided
          ~budgets:[ Budget.at_most ~metric:alloc_words 100. ]
          [ (case "a", alloc 120) ]),
      true );
    ( "a count over the cap on a stale section",
      (fun () ->
        decided
          ~budgets:[ Budget.at_most ~metric:alloc_words 100. ]
          ~file:(file_of ~identity:stale_ident [ alloc_row "a" 50 ])
          [ (case "a", alloc 120) ]),
      true );
    ( "a count over the cap of a case without a row",
      (fun () ->
        decided
          ~budgets:[ Budget.at_most ~metric:alloc_words 100. ]
          ~file:(file_of [ alloc_row "b" 50 ])
          [ (case "a", alloc 120) ]),
      true );
    ( "a count over the cap against a sampled row",
      (fun () ->
        one
          ~budgets:[ Budget.at_most ~metric:alloc_words 100. ]
          ~rows:[ sampled_alloc_row (ties 5 50.) ]
          (alloc 120)),
      true );
    ( "a sampled count over the cap",
      (fun () ->
        decided
          ~budgets:[ Budget.at_most ~metric:alloc_words 100. ]
          [ (case "a", trial [ (alloc_words, sampled (ties 5 120.)) ]) ]),
      false );
    ( "a confirmed regression of sampled counts under a cap",
      (fun () ->
        one
          ~budgets:[ Budget.at_most ~metric:alloc_words 150. ]
          ~rows:[ sampled_alloc_row (ties 5 100.) ]
          (trial [ (alloc_words, sampled (ties 5 200.)) ])),
      false );
    ( "a confirmed regression without a budget",
      (fun () ->
        one
          ~rows:
            [
              Baseline.sampled_row ~id:"a" ~metric:"cpu_time" ~k:8
                ~samples:(ties 5 1.);
            ]
          (trial [ (cpu_time, sampled (ties 5 2.)) ])),
      false );
  ]

let first_report_fails (_, t, expected) =
  let t = t () in
  let c = case_report t in
  equal bool expected (Verdict.report_fails c (List.hd c.Verdict.reports))

(* One case "a": its wall_time against a row of 1s, with a budget or none,
   and its alloc_words count under a relative budget of 0 against a row of
   54 words. *)
let case_outcomes =
  [
    ("a failing report fails the case", true, ties 5 1., 55, `Fail);
    ( "a failing report fails the case beside an improved one",
      true,
      ties 5 0.5,
      55,
      `Fail );
    ("a failing report beats an inconclusive one", true, spread, 55, `Fail);
    ( "an inconclusive report with a budget makes it inconclusive",
      true,
      spread,
      54,
      `Inconclusive );
    ("an inconclusive report without a budget passes", false, spread, 54, `Pass);
    ("passing reports pass", true, ties 5 1., 53, `Pass);
  ]

let case_outcome (_, budgeted, samples, count, expected) =
  let t =
    one
      ~budgets:
        (Budget.no_more_alloc_than 0.
        :: (if budgeted then [ Budget.no_slower_than 0.05 ] else []))
      ~rows:[ wall_row "a" (ties 5 1.); alloc_row "a" 54 ]
      (trial [ (wall_time, sampled samples); (alloc_words, Run.Exact count) ])
  in
  equal string (outcome_name expected)
    (outcome_name (Verdict.case_overall (case_report t)))

(* Cases "a" and "b", each alloc_words under a relative budget of 0 against
   a row of 54 words. *)
let run_outcomes =
  [
    ("a failing case fails the run", Some 55, None, `Fail);
    ("an inconclusive case makes it inconclusive", None, Some 54, `Inconclusive);
    ("passing cases pass", Some 54, Some 53, `Pass);
  ]

(* An exact count, or else a sampled one, which loses exactness. *)
let count = function
  | Some n -> alloc n
  | None -> trial [ (alloc_words, sampled (ties 5 54.)) ]

let run_outcome (_, a, b, expected) =
  let t =
    decided
      ~budgets:[ Budget.no_more_alloc_than 0. ]
      ~file:(file_of [ alloc_row "a" 54; alloc_row "b" 54 ])
      [ (case "a", count a); (case "b", count b) ]
  in
  equal string (outcome_name expected) (outcome_name (Verdict.overall t))

let exit_codes =
  let compared () = file_of [ wall_row "a" (ties 5 1.) ] in
  [
    ("a pass", (fun () -> one (wall (ties 5 1.))), (0, 0));
    ( "a failure",
      (fun () ->
        one
          ~budgets:[ Budget.no_more_alloc_than 0. ]
          ~rows:[ alloc_row "a" 54 ]
          (alloc 55)),
      (1, 1) );
    ( "a failure on a loaded host",
      (fun () ->
        one ~load:loaded
          ~budgets:[ Budget.no_more_alloc_than 0. ]
          ~rows:[ alloc_row "a" 54 ]
          (alloc 55)),
      (1, 1) );
    ( "a first run over a cap",
      (fun () ->
        decided
          ~budgets:[ Budget.at_most ~metric:alloc_words 100. ]
          [ (case "a", alloc 120) ]),
      (1, 1) );
    ( "a sampled regression over a cap",
      (fun () ->
        one
          ~budgets:[ Budget.at_most ~metric:alloc_words 150. ]
          ~rows:[ sampled_alloc_row (ties 5 100.) ]
          (trial [ (alloc_words, sampled (ties 5 200.)) ])),
      (0, 0) );
    ("an inconclusive run", (fun () -> one (wall spread)), (0, 1));
    ( "a missing section",
      (fun () -> decided [ (case "a", wall (ties 5 1.)) ]),
      (0, 1) );
    ( "a stale section",
      (fun () ->
        decided
          ~file:(file_of ~identity:stale_ident [ wall_row "a" (ties 5 1.) ])
          [ (case "a", wall (ties 5 1.)) ]),
      (0, 1) );
    ( "a proposed metric",
      (fun () ->
        decided ~file:(compared ())
          [
            ( case "a",
              trial
                [
                  (wall_time, sampled (ties 5 1.)); (alloc_words, Run.Exact 54);
                ] );
          ]),
      (0, 1) );
  ]

let a_shift = { Verdict.estimate = 0.3; lower = 0.2; upper = 0.4 }

let strong_estimates =
  [
    ( "a confirmed relation's is its first shift's",
      Verdict.Confirmed
        { first = a_shift; confirmation = a_shift; pooled = [||]; k = 1 },
      Some 0.3 );
    ( "a growth's is relative to the row",
      Exact_change { baseline = 54; candidate = 81 },
      Some 0.5 );
    ( "a drop's is relative to the row",
      Exact_change { baseline = 100; candidate = 50 },
      Some (-0.5) );
    ( "growth from 0 has none",
      Exact_change { baseline = 0; candidate = 3 },
      None );
  ]

(* The row ids of the section are "a", "b-dead" and "a-dead"; the run judges
   the cases of [ids]. *)
let warned =
  let section identity () =
    file_of ~identity
      [
        wall_row "a" (ties 5 1.);
        wall_row "b-dead" (ties 5 1.);
        wall_row "a-dead" (ties 5 1.);
      ]
  in
  [
    ( "a full selection of a compared section names each absent case",
      section ident,
      `Full,
      [ "a" ],
      __POS_OF__
        {|
        case a-dead no longer exists in this binary; its rows will be pruned from the corrected file
        case b-dead no longer exists in this binary; its rows will be pruned from the corrected file
        |}
    );
    ( "a partial selection of a compared section",
      section ident,
      `Partial,
      [ "a" ],
      __POS_OF__ {||} );
    ( "a partial selection of a stale section counts the dropped cases",
      section stale_ident,
      `Partial,
      [ "a" ],
      __POS_OF__
        {| partial selection on a stale section: the corrected file re-records this machine's whole section and drops the rows of the 2 unselected cases |}
    );
    ( "a partial selection of a stale section with one dropped case",
      section stale_ident,
      `Partial,
      [ "a"; "a-dead" ],
      __POS_OF__
        {| partial selection on a stale section: the corrected file re-records this machine's whole section and drops the rows of the 1 unselected case |}
    );
    ( "a partial selection of a stale section that drops nothing",
      section stale_ident,
      `Partial,
      [ "a"; "a-dead"; "b-dead" ],
      __POS_OF__ {||} );
    ( "a full selection of a stale section",
      section stale_ident,
      `Full,
      [ "a" ],
      __POS_OF__ {||} );
  ]

let warnings_of (_, file, selection, ids, expected) =
  let t =
    decided ~selection ~file:(file ())
      (List.map (fun id -> (case id, wall (ties 5 1.))) ids)
  in
  expect (String.concat "\n" (Verdict.warnings t)) expected

(* The JSON document *)

let wall_rows ids = List.map (fun id -> wall_row id (ties 5 1.)) ids

(* Each document's name, and its verdict. *)
let documents =
  [
    ( "exact",
      fun () ->
        decided
          ~budgets:[ Budget.no_more_alloc_than 0. ]
          ~file:(file_of [ alloc_row "a" 54; alloc_row "b" 54 ])
          [
            (case "a", alloc 54);
            (case "b", trial [ (alloc_words, sampled [| 1.; 2.; 3. |]) ]);
            (case "c", alloc 7);
          ] );
    ("confirmed-regression", fun () -> one (wall (ties 5 2.)));
    ( "exact-changes",
      fun () ->
        decided
          ~budgets:[ Budget.no_more_alloc_than 0.1 ]
          ~file:
            (file_of
               [
                 alloc_row "improved" 100;
                 alloc_row "to-zero" 100;
                 alloc_row "regressed" 100;
                 alloc_row "from-zero" 0;
                 alloc_row "capped" 0;
               ])
          [
            (case "improved", alloc 50);
            (case "to-zero", alloc 0);
            (case "regressed", alloc 200);
            (case "from-zero", alloc 3);
            ( case ~budgets:[ Budget.at_most ~metric:alloc_words 10. ] "capped",
              alloc 3 );
          ] );
    ( "passing",
      fun () ->
        decided
          ~file:
            (file_of
               [
                 wall_row "within" (ties 5 1.);
                 Baseline.sampled_row ~id:"unbudgeted" ~metric:"cpu_time" ~k:8
                   ~samples:(ties 5 1.);
                 wall_row "unbudgeted" (ties 5 1.);
               ])
          [
            (case "within", wall [| 0.5; 0.5; 1.; 1.; 1. |]);
            ( case "unbudgeted",
              trial
                [ (wall_time, sampled (ties 5 1.)); (cpu_time, sampled spread) ]
            );
          ] );
    ( "environment",
      fun () ->
        one ~load:loaded
          ~budgets:[ Budget.no_slower_than 0.05; Budget.no_more_alloc_than 0. ]
          ~rows:[ wall_row "a" (ties 5 1.); alloc_row "a" 54 ]
          (trial
             [ (wall_time, sampled (ties 5 2.)); (alloc_words, Run.Exact 108) ])
    );
    ("unconfirmed", fun () -> one ~confirm:None (wall (ties 5 2.)));
    ("no-comparison", fun () -> one (wall (ties 5 0.)));
  ]

(* Each reason's spelling, on a verdict that holds it. *)
let spellings =
  let tight = [ relative (0.025, 0.03) ] in
  [
    ("wide_interval", fun () -> one (wall spread));
    ("non_positive", fun () -> one (wall (ties 5 0.)));
    ( "baseline_unstable",
      fun () ->
        one ~budgets:tight
          ~rows:[ wall_row "a" (spiked 1.) ]
          (wall (ties 20 1.04)) );
    ("environment", fun () -> one ~load:loaded (wall (ties 5 2.)));
    ("unconfirmed", fun () -> one ~confirm:None (wall (ties 5 2.)));
    ( "exactness_lost",
      fun () ->
        one
          ~budgets:[ Budget.no_more_alloc_than 0. ]
          ~rows:[ alloc_row "a" 54 ]
          (trial [ (alloc_words, sampled (ties 5 54.)) ]) );
    ( "batch_drifted",
      fun () -> one ~rows:[ wall_row ~k:32 "a" (ties 5 1.) ] (wall (ties 5 1.))
    );
    ("unstable", fun () -> one ~budgets:tight (wall (spiked 1.04)));
    ("drifted", fun () -> one (wall ~drifted:true (ties 5 1.)));
    ("missing_baseline", fun () -> decided [ (case "a", wall (ties 5 1.)) ]);
  ]

let a_change_within_budget_counts_as_equivalent () =
  let json =
    Verdict.to_json
      (one
         ~budgets:[ Budget.no_more_alloc_than 0.1 ]
         ~rows:[ alloc_row "a" 100 ]
         (alloc 105))
  in
  contains
    ~sub:
      {|"relation":"changed_within_budget","status":"pass","reason":null,"exact":true,"delta":0.050000000000000003|}
    json;
  contains ~sub:{|"n_equivalent":1,"n_inconclusive":0|} json

(* The name's id is its slug, "q-b-n". *)
let strings_are_escaped () =
  contains ~sub:{|"id":"q-b-n","full_name":"q\"b\\n\n\r\t\u0001é"|}
    (Verdict.to_json (decided [ (case "q\"b\\n\n\r\t\001\xc3\xa9", alloc 1) ]))

let to_json =
  group "to_json"
    [
      cases "a document" ~name:fst documents (fun (name, t) ->
          expect_file
            (Verdict.to_json (t ()))
            ("test/unit/json/" ^ name ^ ".json"));
      cases "a reason's spelling" ~name:fst spellings (fun (spelling, t) ->
          contains
            ~sub:(strf {|"reason":"%s"|} spelling)
            (Verdict.to_json (t ())));
      test "a change within budget counts as equivalent"
        a_change_within_budget_counts_as_equivalent;
      test "strings are escaped" strings_are_escaped;
    ]

let observers =
  group "Observers"
    [
      cases "overall"
        ~name:(fun (name, _, _, _) -> name)
        run_outcomes run_outcome;
      test "a run whose metrics are all proposed passes" (fun () ->
          let t =
            decided
              ~budgets:[ Budget.no_more_alloc_than 0. ]
              [ (case "a", alloc 54) ]
          in
          equal string (outcome_name `Pass) (outcome_name (Verdict.overall t)));
      cases "report_fails"
        ~name:(fun (name, _, _) -> name)
        failing first_report_fails;
      cases "case_overall"
        ~name:(fun (name, _, _, _, _) -> name)
        case_outcomes case_outcome;
      cases "strong_estimate"
        ~name:(fun (name, _, _) -> name)
        strong_estimates
        (fun (_, s, expected) ->
          equal (option (float 1e-12)) expected (Verdict.strong_estimate s));
      cases "warnings" ~name:(fun (name, _, _, _, _) -> name) warned warnings_of;
      cases "exit_code, then under strict"
        ~name:(fun (name, _, _) -> name)
        exit_codes
        (fun (_, t, expected) ->
          let t = t () in
          equal (pair int int) expected
            (Verdict.exit_code t, Verdict.exit_code ~strict:true t));
      to_json;
    ]

(* Write paths *)

let an_equivalent_run_changes_no_byte () =
  is_none (Verdict.corrected (one (wall (ties 5 1.))))

(* The diff of case "a"'s rows and the corrected file. *)
let corrected_diff ?budgets ~rows first =
  diff (file_of rows)
    (require_some (Verdict.corrected (one ?budgets ~rows first)))

(* "b" is judged equivalent and keeps its bytes. *)
let a_confirmed_improvement_advances_its_row () =
  let file = file_of (wall_rows [ "a"; "b" ]) in
  let t =
    decided ~file
      ~confirm:(fun _ -> Some (wall (ties 5 0.5)))
      [ (case "a", wall (ties 5 0.5)); (case "b", wall (ties 5 1.)) ]
  in
  equal text_diff
    ( [ row_text (wall_row "a" (ties 5 1.)) ],
      [ row_text (wall_row "a" (ties 10 0.5)) ] )
    (diff file (require_some (Verdict.corrected t)))

let the_advanced_row_takes_the_confirmation_s_batch_size () =
  equal text_diff
    ( [ row_text (wall_row ~k:8 "a" (ties 5 1.)) ],
      [ row_text (wall_row ~k:16 "a" (ties 10 0.5)) ] )
    (corrected_diff
       ~rows:[ wall_row ~k:8 "a" (ties 5 1.) ]
       (wall ~k:16 (ties 5 0.5)))

let an_exact_improvement_advances_to_the_count () =
  equal text_diff
    ([ row_text (alloc_row "a" 54) ], [ row_text (alloc_row "a" 50) ])
    (corrected_diff
       ~budgets:[ Budget.no_more_alloc_than 0. ]
       ~rows:[ alloc_row "a" 54 ]
       (alloc 50))

let proposals =
  [
    ( "a metric without a row",
      (fun () -> []),
      (fun () ->
        trial [ (wall_time, sampled (ties 5 1.)); (alloc_words, Run.Exact 54) ]),
      fun () -> alloc_row "a" 54 );
    ( "a count over its cap",
      (fun () -> [ Budget.at_most ~metric:alloc_words 100. ]),
      (fun () ->
        trial [ (wall_time, sampled (ties 5 1.)); (alloc_words, Run.Exact 120) ]),
      fun () -> alloc_row "a" 120 );
    ( "a drifted trial's samples",
      (fun () -> []),
      (fun () ->
        trial
          [
            (wall_time, sampled (ties 5 1.));
            (cpu_time, sampled ~drifted:true (ties 5 1.));
          ]),
      fun () ->
        Baseline.sampled_row ~id:"a" ~metric:"cpu_time" ~k:8
          ~samples:(ties 5 1.) );
  ]

(* The wall_time row regresses and keeps its bytes while alloc_words
   improves and advances. *)
let a_regression_keeps_its_row_beside_an_advance () =
  equal text_diff
    ([ row_text (alloc_row "a" 54) ], [ row_text (alloc_row "a" 50) ])
    (corrected_diff
       ~budgets:[ Budget.no_slower_than 0.05; Budget.no_more_alloc_than 0. ]
       ~rows:[ wall_row "a" (ties 5 1.); alloc_row "a" 54 ]
       (trial [ (wall_time, sampled (ties 5 2.)); (alloc_words, Run.Exact 50) ]))

(* "b" is new, so the corrected file exists; "dead" has no case. *)
let absent_cases selection =
  let file = file_of (wall_rows [ "a"; "dead" ]) in
  let t =
    decided ~selection ~file
      [ (case "a", wall (ties 5 1.)); (case "b", wall (ties 5 1.)) ]
  in
  diff file (require_some (Verdict.corrected t))

(* [file] with this machine's section recorded from the first trials. *)
let recorded_section file =
  Baseline.set_section
    (match Baseline.suite file with
    | Some _ -> file
    | None -> Baseline.empty ~suite:"digest")
    ident
    [ wall_row "a" (ties 5 2.); alloc_row "a" 100 ]

let replacements =
  [
    ("a missing section, under a new suite header", fun () -> empty_file ());
    ( "a stale section, with no annotation",
      fun () ->
        Baseline.set_section
          (file_of ~identity:stale_ident ~annotations:[ "forced: earlier" ]
             [ wall_row "a" (ties 5 1.); wall_row "old" (ties 5 1.) ])
          other_ident
          [ wall_row "z" (ties 5 1.) ] );
  ]

(* The host is loaded and the trial drifted: a replaced section records the
   trial as measured. *)
let a_section_is_replaced_by_the_first_trials (_, file) =
  let file = file () in
  let t =
    decided ~load:loaded ~file
      [
        ( case "a",
          trial
            [
              (wall_time, sampled ~drifted:true (ties 5 2.));
              (alloc_words, Run.Exact 100);
            ] );
      ]
  in
  equal string
    (Baseline.to_string (recorded_section file))
    (Baseline.to_string (require_some (Verdict.corrected t)))

let corrected_refuses_a_suite_it_cannot_head () =
  let t =
    Verdict.decide ~load:Env.Quiet ~confirmations:[]
      (Verdict.judge ~identity:ident ~suite:"" ~load:Env.Quiet ~selection:`Full
         ~budgets:[] ~file:(empty_file ())
         ~cases:[ (case "a", alloc 1) ])
  in
  raises
    (Invalid_argument
       "Baseline.empty: suite name must be non-empty and single-line (it heads \
        fresh baselines)") (fun () -> Verdict.corrected t)

(* The monotone-ratchet property *)

type outcome =
  | Improve_confirmed
  | Improve_unconfirmed
  | Regress_confirmed
  | Regress_unconfirmed
  | Equal
  | Fresh
  | Dead

let outcome_label = function
  | Improve_confirmed -> "improve+"
  | Improve_unconfirmed -> "improve-"
  | Regress_confirmed -> "regress+"
  | Regress_unconfirmed -> "regress-"
  | Equal -> "equal"
  | Fresh -> "fresh"
  | Dead -> "dead"

type scenario = {
  outcomes : (string * outcome) list;
  full : bool;
  other : bool;
}

let pp_scenario ppf s =
  Format.fprintf ppf "{%s; %s; other=%b}"
    (String.concat ", "
       (List.map (fun (id, o) -> id ^ ":" ^ outcome_label o) s.outcomes))
    (if s.full then "full" else "partial")
    s.other

let scenario =
  let open Gen in
  let outcome =
    of_list
      [
        Improve_confirmed;
        Improve_unconfirmed;
        Regress_confirmed;
        Regress_unconfirmed;
        Equal;
        Fresh;
        Dead;
      ]
  in
  with_pp pp_scenario
    (let+ outcomes = list ~size:(int_range 1 6) outcome
     and+ full = bool
     and+ other = bool in
     {
       outcomes = List.mapi (fun i o -> (Printf.sprintf "c%d" i, o)) outcomes;
       full;
       other;
     })

(* What the corrected file did to row [id]: [advanced] is a row of both
   trials' ten samples. *)
let fate ~before ~after id =
  match (row_line before id, row_line after id) with
  | None, None -> "absent"
  | None, Some _ -> "proposed"
  | Some _, None -> "pruned"
  | Some b, Some a when String.equal b a -> "kept"
  | Some _, Some a ->
      if String.starts_with ~prefix:(id ^ "\twall_time\tbatch=8\tn=10\t") a then
        "advanced"
      else "changed"

let expected_fate s = function
  | Improve_confirmed -> "advanced"
  | Improve_unconfirmed | Regress_confirmed | Regress_unconfirmed | Equal ->
      "kept"
  | Fresh -> "proposed"
  | Dead -> if s.full then "pruned" else "kept"

(* Every outcome but [Fresh] has a row, and a sentinel case "keep" keeps the
   section from being empty. *)
let the_ratchet_is_monotone s =
  let level = function
    | Improve_confirmed | Improve_unconfirmed -> 0.5
    | Regress_confirmed | Regress_unconfirmed -> 2.
    | Equal | Fresh | Dead -> 1.
  in
  let file =
    file_of
      (List.filter_map
         (fun (id, o) ->
           if o = Fresh then None else Some (wall_row id (ties 5 1.)))
         s.outcomes
      @ [ wall_row "keep" (ties 5 1.) ])
  in
  let file =
    if s.other then
      Baseline.set_section file other_ident [ wall_row "z" (ties 5 1.) ]
    else file
  in
  let confirm id =
    match List.assoc_opt id s.outcomes with
    | Some ((Improve_confirmed | Regress_confirmed) as o) ->
        Some (wall (ties 5 (level o)))
    | Some (Improve_unconfirmed | Regress_unconfirmed) ->
        Some (wall (ties 5 1.))
    | Some (Equal | Fresh | Dead) | None -> None
  in
  let t =
    decided
      ~selection:(if s.full then `Full else `Partial)
      ~file ~confirm
      (List.filter_map
         (fun (id, o) ->
           if o = Dead then None else Some (case id, wall (ties 5 (level o))))
         s.outcomes
      @ [ (case "keep", wall (ties 5 1.)) ])
  in
  let changes =
    List.exists
      (fun (_, o) -> o = Improve_confirmed || o = Fresh || (o = Dead && s.full))
      s.outcomes
  in
  let after =
    if changes then (
      let after = require_some (Verdict.corrected t) in
      not_equal string (Baseline.to_string file) (Baseline.to_string after);
      after)
    else (
      is_none (Verdict.corrected t);
      file)
  in
  let ids =
    List.map fst s.outcomes @ [ "keep" ] @ if s.other then [ "z" ] else []
  in
  let expected id =
    match List.assoc_opt id s.outcomes with
    | Some o -> expected_fate s o
    | None -> "kept"
  in
  equal
    (list (pair string string))
    (List.map (fun id -> (id, expected id)) ids)
    (List.map (fun id -> (id, fate ~before:file ~after id)) ids)

(* Bless *)

let bless_run () =
  Run.create
    [
      ( "a",
        trial [ (wall_time, sampled (ties 5 2.)); (alloc_words, Run.Exact 100) ]
      );
    ]

let blessed =
  [
    ( "a full selection of a stale section",
      `Full,
      fun () ->
        Baseline.set_section
          (file_of ~identity:stale_ident ~annotations:[ "forced: earlier" ]
             [ wall_row "a" (ties 5 1.); wall_row "old" (ties 5 1.) ])
          other_ident
          [ wall_row "z" (ties 5 1.) ] );
    ( "a full selection of a compared section",
      `Full,
      fun () -> file_of (wall_rows [ "a"; "old" ]) );
    ( "the empty file, under a new suite header",
      `Partial,
      fun () -> empty_file () );
  ]

let bless_rerecords_the_section (_, selection, file) =
  let file = file () in
  let result, warnings =
    Verdict.bless ~annotations:[ "forced: now" ] ~identity:ident ~suite:"digest"
      ~selection ~run:(bless_run ()) file
  in
  let expected =
    Baseline.set_section ~annotations:[ "forced: now" ]
      (match Baseline.suite file with
      | Some _ -> file
      | None -> Baseline.empty ~suite:"digest")
      ident
      [ alloc_row "a" 100; wall_row "a" (ties 5 2.) ]
  in
  equal
    (pair string (list string))
    (Baseline.to_string expected, [])
    (Baseline.to_string result, warnings)

(* The header and its annotations stay, every unselected row keeps its
   bytes, and the selected case's rows are replaced by case id: its new
   metric is added and the metric it no longer collects is removed. *)
let a_partial_bless_replaces_the_selected_cases_rows () =
  let file =
    file_of ~annotations:[ "forced: earlier" ]
      [
        wall_row "a" (ties 5 1.);
        Baseline.sampled_row ~id:"a" ~metric:"cpu_time" ~k:8
          ~samples:(ties 5 1.);
        wall_row "b" (ties 5 3.);
      ]
  in
  let result, warnings =
    Verdict.bless ~annotations:[ "forced: now" ]
      ~identity:{ ident with Baseline.host = "renamed-host" }
      ~suite:"digest" ~selection:`Partial ~run:(bless_run ()) file
  in
  equal (list string) [] warnings;
  equal text_diff
    ( [
        row_text
          (Baseline.sampled_row ~id:"a" ~metric:"cpu_time" ~k:8
             ~samples:(ties 5 1.));
        row_text (wall_row "a" (ties 5 1.));
      ],
      [
        "# forced: now";
        row_text (alloc_row "a" 100);
        row_text (wall_row "a" (ties 5 2.));
      ] )
    (diff file result);
  equal (list string)
    [ "# forced: earlier"; "# forced: now" ]
    (List.filter
       (String.starts_with ~prefix:"# forced")
       (String.split_on_char '\n' (Baseline.to_string result)))

let a_partial_bless_of_a_stale_section_says_what_it_drops () =
  let file =
    file_of ~identity:stale_ident
      [ wall_row "a" (ties 5 1.); wall_row "old" (ties 5 1.) ]
  in
  let result, warnings =
    Verdict.bless ~identity:ident ~suite:"digest" ~selection:`Partial
      ~run:(bless_run ()) file
  in
  equal
    (pair string (list string))
    ( Baseline.to_string
        (Baseline.set_section file ident
           [ alloc_row "a" 100; wall_row "a" (ties 5 2.) ]),
      [
        "partial selection on a stale section: the corrected file re-records \
         this machine's whole section and drops the rows of the 1 unselected \
         case";
      ] )
    (Baseline.to_string result, warnings)

let write_paths =
  group "Write paths"
    [
      test "an equivalent run changes no byte" an_equivalent_run_changes_no_byte;
      test "a confirmed improvement advances its row alone"
        a_confirmed_improvement_advances_its_row;
      test "the advanced row takes the confirmation's batch size"
        the_advanced_row_takes_the_confirmation_s_batch_size;
      test "an exact improvement advances to this run's count"
        an_exact_improvement_advances_to_the_count;
      cases "a proposed row is added"
        ~name:(fun (name, _, _, _) -> name)
        proposals
        (fun (_, budgets, first, row) ->
          equal text_diff
            ([], [ row_text (row ()) ])
            (corrected_diff ~budgets:(budgets ())
               ~rows:[ wall_row "a" (ties 5 1.) ]
               (first ())));
      test "a regression keeps its row beside an advance"
        a_regression_keeps_its_row_beside_an_advance;
      test "a full selection prunes the rows of absent cases" (fun () ->
          equal text_diff
            ( [ row_text (wall_row "dead" (ties 5 1.)) ],
              [ row_text (wall_row "b" (ties 5 1.)) ] )
            (absent_cases `Full));
      test "a partial selection prunes nothing" (fun () ->
          equal text_diff
            ([], [ row_text (wall_row "b" (ties 5 1.)) ])
            (absent_cases `Partial));
      cases "a section is replaced by the first trials" ~name:fst replacements
        a_section_is_replaced_by_the_first_trials;
      test "corrected refuses a suite name it cannot write"
        corrected_refuses_a_suite_it_cannot_head;
      prop "the ratchet is monotone" scenario the_ratchet_is_monotone;
      cases "bless re-records the section"
        ~name:(fun (name, _, _) -> name)
        blessed bless_rerecords_the_section;
      test "a partial bless replaces the selected cases' rows alone"
        a_partial_bless_replaces_the_selected_cases_rows;
      test "a partial bless of a stale section says what it drops"
        a_partial_bless_of_a_stale_section_says_what_it_drops;
    ]

let () =
  exit
    (run "verdict"
       [
         relations; reports; comparison_states; judging; observers; write_paths;
       ])
