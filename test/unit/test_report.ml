(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* [Report] turns a verdict into text and reads nothing else, so every report
   here is rendered from a verdict that [Verdict.judge] and [Verdict.decide]
   build over recorded trials: nothing is measured. Each state of the report
   has one golden under [test/unit/report/], unstyled, and the styled form of
   every state is checked against it with its escapes removed. A state holds
   its verdict as a function, so the verdict is built inside the test, where
   mutants are armed. *)

open Windtrap
module Baseline = Thumper.Private.Baseline
module Bench = Thumper.Private.Bench
module Budget = Thumper.Private.Budget
module Check = Thumper.Private.Check
module Env = Thumper.Private.Env
module Metric = Thumper.Private.Metric
module Report = Thumper.Private.Report
module Run = Thumper.Private.Run
module Verdict = Thumper.Private.Verdict

let strf = Printf.sprintf

(* Recorded evidence *)

let m_wall = Metric.wall_time
let m_alloc = Metric.alloc_words

let ident =
  {
    Baseline.machine = "testkey";
    host = "test-host";
    ocaml = "5.5.0 · 64-bit · release";
  }

(* The identity of a section another compiler recorded. *)
let stale_ident = { ident with Baseline.ocaml = "5.4.0 · 64-bit · release" }
let ties n v = Array.make n v
let spiked v = Array.append (Array.make 19 v) [| 100. *. v |]
let sam ?(drifted = false) sorted = Run.sampled ~sorted ~drifted

(* A trial of [wall] seconds a call, with an exact allocation of 54 words
   unless [alloc] says otherwise. *)
let trial ?(k = 8) ?(drifted = false) ?(alloc = Some 54) wall =
  let ms = [ (m_wall, Run.Samples (sam ~drifted wall)) ] in
  let ms =
    match alloc with Some n -> ms @ [ (m_alloc, Run.Exact n) ] | None -> ms
  in
  Run.Trial.make ~k ms

let sampled_alloc ?(wall = ties 5 1e-6) words =
  Run.Trial.make ~k:8
    [
      (m_wall, Run.Samples (sam wall));
      (m_alloc, Run.Samples (sam (ties 5 words)));
    ]

let wall_row ?(k = 8) id samples =
  Baseline.sampled_row ~id ~metric:"wall_time" ~k ~samples

let alloc_row id n = Baseline.exact_row ~id ~metric:"alloc_words" n

let file_of ?(identity = ident) rows =
  Baseline.set_section (Baseline.empty ~suite:"digest") identity rows

(* The baseline of an empty file, which has no header and no section. *)
let empty_file () = require_ok (Baseline.of_string "")

let bcase ?budgets id =
  require_match
    (function [ c ] -> Some c | _ -> None)
    (require_ok (Bench.resolve [ Bench.bench ?budgets id (fun () -> ()) ]))

(* [cases] judged against [file], each pending case confirmed with the trial
   [confirm] gives for its id, decided under [decide_load]. *)
let verdict_of_cases ?(load = Env.Quiet) ?(decide_load = Env.Quiet)
    ?(selection = `Full) ?file ?(confirm = fun _ -> None) cases =
  let file = match file with Some f -> f | None -> empty_file () in
  let p =
    Verdict.judge ~identity:ident ~suite:"digest" ~load ~selection ~budgets:[]
      ~file ~cases
  in
  let confirmations =
    List.filter_map
      (fun id -> Option.map (fun t -> (id, t)) (confirm id))
      (Verdict.confirmations p)
  in
  Verdict.decide ~load:decide_load ~confirmations p

let verdict_of ?load ?decide_load ?file ?confirm case_trial =
  verdict_of_cases ?load ?decide_load ?file ?confirm [ case_trial ]

let loaded = Env.Loaded { load = 7.9; cores = 8 }

let render ?(color = false) ?(accept = "dune promote") ?(exe = Some "bench.exe")
    ?(github = false) ?(wrote = false) ?(rerun_flags = [])
    ?(rerun_patterns = []) ?(strict = false) () =
  {
    Report.color;
    accept;
    exe;
    github;
    baseline_path = "digest.thumper";
    wrote_corrected = wrote;
    rerun_flags;
    rerun_patterns;
    strict;
    cpu_model = "Test CPU";
  }

(* Verdicts *)

(* An exact allocation regression (54 w to 71 w) under the zero pin, the timing
   equivalent. *)
let exact_regression_case id =
  ( bcase ~budgets:[ Budget.no_more_alloc_than 0.0 ] id,
    trial ~alloc:(Some 71) (ties 5 1e-6) )

(* [n] cases failing on their exact allocation, ids [case-01]... *)
let failing_cases n =
  let ids = List.init n (fun i -> strf "case-%02d" (i + 1)) in
  let file =
    file_of
      (List.concat_map
         (fun id -> [ wall_row id (ties 5 1e-6); alloc_row id 54 ])
         ids)
  in
  verdict_of_cases ~file (List.map exact_regression_case ids)

(* A 71-word exact count under a [cap]-word cap, with no baseline row for the
   count: on a first run ([file] empty), or beside a compared time row. *)
let over_cap ?file ?(cap = 64.) ?(count = 71) () =
  verdict_of ?file
    ( bcase ~budgets:[ Budget.at_most ~metric:m_alloc cap ] "alpha",
      trial ~alloc:(Some count) (ties 5 1e-6) )

let time_row_only () = file_of [ wall_row "alpha" (ties 5 1e-6) ]

let mixed () =
  let file =
    file_of
      [
        wall_row "alpha" (ties 5 1e-6);
        alloc_row "alpha" 54;
        wall_row "beta" (ties 5 2e-6);
        alloc_row "beta" 2100;
        wall_row "gamma" (ties 5 1e-6);
        alloc_row "gamma" 3000;
      ]
  in
  let trial_for = function
    | "alpha" -> trial (ties 5 2e-6)
    | "beta" -> trial ~alloc:(Some 2100) (ties 5 1e-6)
    | _ -> trial ~alloc:(Some 3000) (ties 5 1e-6)
  in
  verdict_of_cases ~file
    ~confirm:(fun id -> Some (trial_for id))
    (List.map (fun id -> (bcase id, trial_for id)) [ "alpha"; "beta"; "gamma" ])

let equivalent () =
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  verdict_of ~file (bcase "alpha", trial (ties 5 1e-6))

let no_baseline () = verdict_of (bcase "alpha", trial (ties 5 1e-6))

let no_baseline_loaded () =
  verdict_of ~load:loaded ~decide_load:loaded
    (bcase "alpha", trial (ties 5 1e-6))

let proposed_metric () =
  verdict_of ~file:(time_row_only ()) (bcase "alpha", trial (ties 5 1e-6))

(* Under load a doubled time is inconclusive, and its estimate is printed. *)
let loaded_regression () =
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  verdict_of ~load:loaded ~decide_load:loaded ~file
    (bcase "alpha", trial (ties 5 2e-6))

(* Under load, a doubled time beside an allocation the section has no row
   for, so the corrected file is written. *)
let loaded_proposed () =
  verdict_of ~load:loaded ~decide_load:loaded ~file:(time_row_only ())
    (bcase "alpha", trial (ties 5 2e-6))

(* A time regression that fails its budget beside an allocation regression a
   cap does not gate. *)
let failing_first () =
  let file =
    file_of
      [
        wall_row "alpha" (ties 5 1e-6);
        Baseline.sampled_row ~id:"alpha" ~metric:"alloc_words" ~k:8
          ~samples:(ties 5 100.0);
      ]
  in
  let both () = sampled_alloc ~wall:(ties 5 2e-6) 200.0 in
  verdict_of ~file
    ~confirm:(fun _ -> Some (both ()))
    ( bcase
        ~budgets:
          [ Budget.no_slower_than 0.05; Budget.at_most ~metric:m_alloc 150. ]
        "alpha",
      both () )

let improvement () =
  let file = file_of [ wall_row "alpha" (ties 5 2e-6); alloc_row "alpha" 54 ] in
  verdict_of ~file
    ~confirm:(fun _ -> Some (trial (ties 5 1e-6)))
    (bcase "alpha", trial (ties 5 1e-6))

(* A noisy row whose interval ends within the budget, and a demonstrated
   change within it. *)
let within_budget () =
  let file =
    file_of
      [
        wall_row "alpha" (ties 5 1e-6);
        alloc_row "alpha" 54;
        wall_row "beta" (ties 5 1e-6);
        alloc_row "beta" 54;
      ]
  in
  verdict_of_cases ~file
    [
      (bcase "alpha", trial [| 0.9e-6; 0.95e-6; 1e-6; 1.03e-6; 1.04e-6 |]);
      (bcase "beta", trial (ties 5 1.03e-6));
    ]

(* A regression no confirmation trial reproduced. *)
let unconfirmed () =
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  verdict_of ~file (bcase "alpha", trial (ties 5 2e-6))

let exact_regression () =
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  verdict_of_cases ~file [ exact_regression_case "alpha" ]

(* One case per reason but [Environment], which needs a loaded run and is the
   loaded state's. A budget whose band is close to its tolerance puts a
   regression within twice the band, where instability vetoes it. *)
let every_reason () =
  let narrow =
    [
      Budget.relative ~metric:m_wall ~equivalent_within:0.025
        ~max_regression:0.03 ();
    ]
  in
  let flat = ties 5 1e-6 in
  let file =
    file_of
      [
        wall_row "wide-interval" (ties 5 2e-6);
        wall_row "non-positive" flat;
        wall_row "baseline-unstable" (spiked 1e-6);
        wall_row "unconfirmed" flat;
        wall_row "exactness-lost" flat;
        alloc_row "exactness-lost" 54;
        wall_row "batch-drifted" flat;
        wall_row "unstable" flat;
        wall_row "drifted" flat;
      ]
  in
  verdict_of_cases ~file
    [
      ( bcase "wide-interval",
        trial ~alloc:None [| 1e-6; 1e-6; 1e-6; 4e-6; 4e-6 |] );
      (bcase "non-positive", trial ~alloc:None (ties 5 0.));
      ( bcase ~budgets:narrow "baseline-unstable",
        trial ~alloc:None (ties 20 1.04e-6) );
      (bcase "unconfirmed", trial ~alloc:None (ties 5 2e-6));
      ( bcase ~budgets:[ Budget.no_more_alloc_than 0.0 ] "exactness-lost",
        sampled_alloc 54. );
      (bcase "batch-drifted", trial ~k:16 ~alloc:None flat);
      (bcase ~budgets:narrow "unstable", trial ~alloc:None (spiked 1.04e-6));
      (bcase "drifted", trial ~drifted:true ~alloc:None flat);
    ]

(* A column holding 1.4 us and 33 ms. *)
let time_units () =
  let file =
    file_of
      [
        wall_row "fast" (ties 5 1.4e-6);
        alloc_row "fast" 54;
        wall_row ~k:1 "slow" (ties 5 3.3e-2);
        alloc_row "slow" 54;
      ]
  in
  verdict_of_cases ~file
    [
      (bcase "fast", trial (ties 5 1.4e-6));
      (bcase "slow", trial ~k:1 (ties 5 3.3e-2));
    ]

(* Exact counts from zero to five digits beside one sampled count. *)
let exact_alloc () =
  verdict_of_cases
    [
      (bcase "zero", trial ~alloc:(Some 0) (ties 5 1e-6));
      (bcase "alpha", trial ~alloc:(Some 54) (ties 5 1e-6));
      (bcase "beta", trial ~alloc:(Some 320) (ties 5 1e-6));
      (bcase "gamma", trial ~alloc:(Some 3000) (ties 5 1e-6));
      (bcase "epsilon", trial ~alloc:(Some 32730) (ties 5 1e-6));
      (bcase "delta", sampled_alloc 2100.);
    ]

(* Sampled counts whose scaled [%.3g] would turn to exponent notation. *)
let sampled_alloc_large () =
  verdict_of_cases
    [
      (bcase "a", trial ~alloc:(Some 3000) (ties 5 1e-6));
      (bcase "b", trial ~alloc:(Some 12_345_678) (ties 5 1e-6));
      (bcase "c", sampled_alloc 2_345_678.);
      (bcase "d", sampled_alloc 3000.);
      (bcase "e", trial ~alloc:(Some 6) (ties 5 1e-6));
      (bcase "g", sampled_alloc 999_500.);
    ]

let sampled_alloc_small () =
  verdict_of_cases
    [
      (bcase "a", trial ~alloc:(Some 54) (ties 5 1e-6));
      (bcase "b", sampled_alloc 1234.5);
    ]

let case_warning () =
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  let warned =
    Run.Trial.make ~k:8
      ~warnings:[ "possibly folded: wrap the input in black_box" ]
      [ (m_wall, Run.Samples (sam (ties 5 1e-6))); (m_alloc, Run.Exact 54) ]
  in
  verdict_of ~file (bcase "alpha", warned)

(* A confirmed sampled allocation regression (100 w to 200 w) whose only
   allocation budget is a cap, which gates exact counts only. *)
let over_cap_sampled () =
  let file =
    file_of
      [
        wall_row "alpha" (ties 5 1e-6);
        Baseline.sampled_row ~id:"alpha" ~metric:"alloc_words" ~k:8
          ~samples:(ties 5 100.0);
      ]
  in
  verdict_of ~file
    ~confirm:(fun _ -> Some (sampled_alloc 200.0))
    ( bcase ~budgets:[ Budget.at_most ~metric:m_alloc 150. ] "alpha",
      sampled_alloc 200.0 )

(* Growth from a count of zero, which a cap allows. *)
let growth_from_zero () =
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 0 ] in
  verdict_of ~file
    ( bcase ~budgets:[ Budget.at_most ~metric:m_alloc 10. ] "alpha",
      trial ~alloc:(Some 5) (ties 5 1e-6) )

(* A full run of a suite that no longer has the case [gone]. *)
let pruned () =
  let file =
    file_of
      [
        wall_row "alpha" (ties 5 1e-6);
        alloc_row "alpha" 54;
        wall_row "gone" (ties 5 1e-6);
        alloc_row "gone" 54;
      ]
  in
  verdict_of ~file (bcase "alpha", trial (ties 5 1e-6))

(* A partial run against a section another compiler recorded. *)
let stale_partial () =
  let file =
    file_of ~identity:stale_ident
      [
        wall_row "alpha" (ties 5 1e-6);
        alloc_row "alpha" 54;
        wall_row "beta" (ties 5 1e-6);
        alloc_row "beta" 54;
      ]
  in
  verdict_of_cases ~selection:`Partial ~file
    [ (bcase "alpha", trial (ties 5 1e-6)) ]

let github () =
  let file =
    file_of
      [
        wall_row "alpha" (ties 5 1e-6);
        alloc_row "alpha" 54;
        wall_row "beta" (ties 5 1e-6);
        alloc_row "beta" 54;
      ]
  in
  verdict_of_cases ~file
    ~confirm:(fun _ -> Some (trial (ties 5 2e-6)))
    [ (bcase "alpha", trial (ties 5 2e-6)); exact_regression_case "beta" ]

let blessed_run () =
  Run.create
    [
      ("alpha", trial (ties 5 1e-6));
      ( "beta",
        Run.Trial.make ~k:8
          ~warnings:[ "possibly folded: wrap the input in black_box" ]
          [
            (m_wall, Run.Samples (sam (ties 5 2.5e-6)));
            (m_alloc, Run.Exact 3000);
          ] );
    ]

(* The notices of a partial bless over a stale section. *)
let stale_partial_notices run =
  let file = file_of ~identity:stale_ident [ wall_row "gamma" (ties 5 1e-6) ] in
  snd
    (Verdict.bless ~identity:ident ~suite:"digest" ~selection:`Partial ~run file)

(* The gallery *)

(* A report state: the claim it shows, its golden's name and the report in
   either style. *)
type state = { claim : string; golden : string; report : color:bool -> string }

let check ?github ?wrote golden claim verdict =
  let report ~color =
    Report.check (render ~color ?github ?wrote ()) (verdict ())
  in
  { claim; golden; report }

let bless ?(load = Env.Quiet) ?(notices = fun _ -> []) golden claim =
  let report ~color =
    let run = blessed_run () in
    Report.bless ~color ~suite:"digest" ~machine:"testkey" ~cases:2 ~load
      ~notices:(notices run) ~accept:"dune promote" run
  in
  { claim; golden; report }

let check_states =
  [
    check ~wrote:true "mixed"
      "a mixed run prints the header, the table, the actions and the summary"
      mixed;
    check "equivalent"
      "a passing run prints the header, the table and the summary" equivalent;
    check ~wrote:true "no-baseline"
      "a run with no baseline proposes every row above the accept line"
      no_baseline;
    check ~wrote:true "no-baseline-loaded"
      "a loaded run with no baseline warns beside the accept line"
      no_baseline_loaded;
    check ~wrote:true "proposed-metric"
      "a metric without a row reads proposed beside a compared one"
      proposed_metric;
    check "loaded"
      "a loaded run warns under the header and prints the estimate it withheld"
      loaded_regression;
    check ~wrote:true "loaded-proposed"
      "a loaded run that writes the corrected file warns once, under the header"
      loaded_proposed;
    check "failing-first" "the failing metric opens the row" failing_first;
    check ~wrote:true "improved" "an improvement prints its interval"
      improvement;
    check "within-budget"
      "within budget prints the interval, or the estimate of a change"
      within_budget;
    check "unconfirmed" "an unconfirmed regression names its reason" unconfirmed;
    check "exact-regressed" "a failing exact count prints both counts"
      exact_regression;
    check "inconclusive" "every inconclusive reason prints in its words"
      every_reason;
    check "time-units" "the time column takes the unit of its smallest value"
      time_units;
    check ~wrote:true "exact-alloc"
      "an exact count prints whole words beside a scaled sampled one"
      exact_alloc;
    check ~wrote:true "sampled-alloc"
      "a large sampled count prints a grouped integer in the column's unit"
      sampled_alloc_large;
    check ~wrote:true "sampled-alloc-small"
      "a small sampled count keeps three significant digits" sampled_alloc_small;
    check "case-warning" "a case's warnings print after the table" case_warning;
    check ~wrote:true ~github:true "over-cap-first-run"
      "an exact count over its cap fails a first run" over_cap;
    check ~wrote:true "over-cap-new-row"
      "an exact count over its cap fails without a row" (fun () ->
        over_cap ~file:(time_row_only ()) ());
    check ~github:true "over-cap-sampled"
      "a sampled count over a cap reads regressed and passes" over_cap_sampled;
    check "growth-from-zero" "growth from zero within a cap prints +inf%"
      growth_from_zero;
    check ~wrote:true "pruned" "a full run warns of each pruned row" pruned;
    check ~wrote:true "stale-partial"
      "a partial run against a stale section warns of the dropped rows"
      stale_partial;
    check ~github:true "github" "each failing metric has its ::error:: line"
      github;
  ]

let bless_states =
  [
    bless "bless"
      "the header heads proposed rows, their warnings and the accept line";
    bless ~load:loaded ~notices:stale_partial_notices "bless-forced"
      "a forced bless warns that the load was recorded, beside the notices";
  ]

let golden_path name = strf "test/unit/report/%s.txt" name

let matches_its_golden s =
  expect_file (s.report ~color:false) (golden_path s.golden)

(* The report with every CSI sequence removed: ESC, [, parameter and
   intermediate bytes, one final byte. *)
let unstyled s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let rec text i =
    if i >= n then ()
    else if s.[i] = '\027' && i + 1 < n && s.[i + 1] = '[' then csi (i + 2)
    else (
      Buffer.add_char b s.[i];
      text (i + 1))
  and csi i =
    if i >= n then ()
    else if s.[i] >= '\x20' && s.[i] <= '\x3f' then csi (i + 1)
    else text (i + 1)
  in
  text 0;
  Buffer.contents b

let escapes_removed_give_the_unstyled_report s =
  let plain = s.report ~color:false and styled = s.report ~color:true in
  not_contains ~msg:"unstyled" ~sub:"\027" plain;
  contains ~msg:"styled" ~sub:"\027[" styled;
  equal string plain (unstyled styled)

let gallery name states =
  [
    cases ~name:(fun s -> s.claim) name states matches_its_golden;
    cases
      ~name:(fun s -> s.golden)
      "removing the escapes gives the unstyled report" states
      escapes_removed_give_the_unstyled_report;
  ]

(* The status line *)

let progress phase index total case = { Check.phase; index; total; case }

let status_line =
  group "The status line"
    [
      cases "status_line names the sweep, the index and the case"
        ~name:(fun (name, _, _) -> name)
        [
          ( "measuring",
            progress `Measuring 3 6 "busy/spin",
            "thumper: measuring 3/6: busy/spin" );
          ( "confirming",
            progress `Confirming 1 2 "alloc/list",
            "thumper: confirming 1/2: alloc/list" );
        ]
        (fun (_, p, expected) -> equal string expected (Report.status_line p));
      test "status_redraw returns to column 0 and erases what is left"
        (fun () ->
          equal string "\rthumper: measuring 3/6: busy/spin\027[K"
            (Report.status_redraw (progress `Measuring 3 6 "busy/spin")));
      test "status_erase returns to column 0 and erases the line" (fun () ->
          equal string "\r\027[K" Report.status_erase);
    ]

(* Shell arguments *)

let shell_arg =
  group "shell_arg"
    [
      cases "an argument of plain bytes stays bare, any other is quoted"
        ~name:(fun (name, _, _) -> name)
        [
          ("a path", "./_build/default/bench.exe", "./_build/default/bench.exe");
          ("every plain punctuation", "_.:/@%+=,-", "_.:/@%+=,-");
          ("a space", "my dir/bench.exe", "'my dir/bench.exe'");
          ("a dollar", "$HOME", "'$HOME'");
          ("a quote", "it's", Filename.quote "it's");
          ("empty", "", "''");
        ]
        (fun (_, arg, expected) -> equal string expected (Report.shell_arg arg));
    ]

(* The check report *)

let rerun_line report =
  require_match
    (List.find_opt (String.starts_with ~prefix:"  rerun:"))
    (String.split_on_char '\n' report)

let the_rerun_line_carries_the_flags () =
  let report =
    Report.check
      (render ~exe:(Some "my dir/bench.exe")
         ~rerun_flags:[ "--quick"; "--baseline alt/base.thumper"; "--tag lab" ]
         ())
      (exact_regression ())
  in
  contains
    ~sub:
      "  rerun:   'my dir/bench.exe' --quick --baseline alt/base.thumper --tag \
       lab \\\n\
      \           -f alpha\n"
    report

let without_an_executable_no_rerun_line () =
  let report = Report.check (render ~exe:None ()) (exact_regression ()) in
  not_contains ~sub:"rerun:" report;
  contains ~sub:"\n  REGRESSED  1.00 us  \xc2\xb10.0%  71 w  alpha\n" report

let the_rerun_line_wraps_within_80_columns () =
  let report =
    Report.check
      (render ~exe:(Some "./_build/default/bench/bench_digest.exe")
         ~rerun_flags:[ "--quick"; "--baseline bench/digest.thumper" ]
         ())
      (failing_cases 4)
  in
  contains
    ~sub:
      "  rerun:   ./_build/default/bench/bench_digest.exe --quick \\\n\
      \           --baseline bench/digest.thumper -f case-01 -f case-02 -f \
       case-03 \\\n\
      \           -f case-04\n"
    report

(* An executable of [n] bytes puts the first item's backslash at column
   [n + 26]. *)
let exe n = "./" ^ String.make n 'x'

let column_80 =
  [
    ("ending at column 80, stays", 54, "  rerun:   " ^ exe 54 ^ " -f case-01 \\");
    ("ending at column 81, moves", 55, "  rerun:   " ^ exe 55 ^ " \\");
  ]

let past_ten_cases_the_patterns_select () =
  let report =
    Report.check
      (render ~rerun_patterns:[ "case"; "my case" ] ())
      (failing_cases 11)
  in
  contains ~sub:"  rerun:   bench.exe -f case -f 'my case'\n" report;
  not_contains ~sub:"-f case-01" report

let absent_columns =
  [
    ( "the allocation column",
      (fun () ->
        Run.Trial.make ~k:8 [ (m_wall, Run.Samples (sam (ties 5 1e-6))) ]),
      "\n  proposed  1.00 us  \xc2\xb10.0%  alpha\n" );
    ( "the time column",
      (fun () -> Run.Trial.make ~k:8 [ (m_alloc, Run.Exact 54) ]),
      "\n  proposed  54 w  alpha\n" );
  ]

let caps =
  [
    ( "a fractional cap",
      64.5,
      71,
      "alloc 71 w, over its 64.5 w cap (exact)",
      "alloc_words 71 w, over its 64.5 w cap (exact)" );
    ( "a fraction below six decimals",
      64.0000001,
      71,
      "alloc 71 w, over its 64 w cap (exact)",
      "alloc_words 71 w, over its 64 w cap (exact)" );
    ( "a large integral cap",
      1e6,
      1_234_568,
      "alloc 1,234,568 w, over its 1,000,000 w cap (exact)",
      "alloc_words 1,234,568 w, over its 1,000,000 w cap (exact)" );
    ( "a large fractional cap",
      1234567.5,
      1_234_568,
      "alloc 1,234,568 w, over its 1,234,567.5 w cap (exact)",
      "alloc_words 1,234,568 w, over its 1,234,567.5 w cap (exact)" );
  ]

let a_cap_prints_grouped (_, cap, count, cell, annotation) =
  let report =
    Report.check (render ~github:true ())
      (over_cap ~file:(time_row_only ()) ~cap ~count ())
  in
  contains ~sub:("\n      " ^ cell ^ "\n") report;
  contains ~sub:("\n::error::alpha regressed: " ^ annotation ^ "\n") report

(* A unit starts at its own magnitude. *)
let units =
  [
    ("a millisecond", (fun () -> trial ~alloc:None (ties 5 1e-3)), " 1.00 ms ");
    ("a second", (fun () -> trial ~alloc:None (ties 5 1.)), " 1.00 s ");
    ("a thousand words", (fun () -> sampled_alloc 1e3), " ~1 kw ");
    ("a million words", (fun () -> sampled_alloc 1e6), " ~1 Mw ");
  ]

let one_proposed () =
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  verdict_of_cases ~file
    [
      (bcase "alpha", trial (ties 5 1e-6)); (bcase "beta", trial (ties 5 1e-6));
    ]

let summaries =
  [
    ("without --strict", false, "  2 cases: 1 passed, 1 proposed.\n");
    ( "under --strict",
      true,
      "  2 cases: 1 passed, 1 proposed; failed under --strict.\n" );
  ]

let summary_colours =
  [
    ( "green when every case passes",
      equivalent,
      false,
      "\027[32m1 case: 1 passed.\027[0m" );
    ( "yellow when a case is inconclusive",
      loaded_regression,
      false,
      "\027[33m1 case: 0 passed, 1 inconclusive.\027[0m" );
    ( "red when --strict fails the run",
      loaded_regression,
      true,
      "\027[31m1 case: 0 passed, 1 inconclusive; failed under --strict.\027[0m"
    );
  ]

let header_of_stale recorded =
  let file =
    file_of
      ~identity:{ ident with Baseline.ocaml = recorded }
      [ wall_row "alpha" (ties 5 1e-6) ]
  in
  let report =
    Report.check (render ())
      (verdict_of ~file (bcase "alpha", trial (ties 5 1e-6)))
  in
  List.hd (String.split_on_char '\n' report)

let recorded_identities =
  [
    ( "an escape",
      "5.4.0\027[2J",
      "thumper: digest \xe2\x80\x94 stale baseline for machine testkey (ocaml \
       '5.4.0\\x1b[2J' \xe2\x86\x92 5.5.0 \xc2\xb7 64-bit \xc2\xb7 release)" );
    ( "a DEL byte",
      "5.4\127",
      "thumper: digest \xe2\x80\x94 stale baseline for machine testkey (ocaml \
       '5.4\\x7f' \xe2\x86\x92 5.5.0 \xc2\xb7 64-bit \xc2\xb7 release)" );
    ( "plain text stays bare",
      "5.4.0 \xc2\xb7 64-bit",
      "thumper: digest \xe2\x80\x94 stale baseline for machine testkey (ocaml \
       5.4.0 \xc2\xb7 64-bit \xe2\x86\x92 5.5.0 \xc2\xb7 64-bit \xc2\xb7 \
       release)" );
  ]

(* A row opens on the word of its most severe relation, and the summary counts
   the case by [Verdict.case_overall], which ignores a metric without a
   budget. *)
let an_inconclusive_row_is_not_counted_as_passed () =
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  let lines =
    String.split_on_char '\n'
      (Report.check (render ())
         (verdict_of ~file (bcase "alpha", sampled_alloc 54.)))
  in
  let opens_inconclusive =
    List.exists (String.starts_with ~prefix:"  inconclusive") lines
  in
  let counted_inconclusive =
    List.exists (String.ends_with ~suffix:" 1 inconclusive.") lines
  in
  equal bool opens_inconclusive counted_inconclusive

let first (name, _, _) = name
let first4 (name, _, _, _) = name
let first5 (name, _, _, _, _) = name

let check_report =
  group "The check report"
    (gallery "each state matches its golden" check_states
    @ [
        test "a styled report prints its escapes" (fun () ->
            expect_file
              (Report.check (render ~color:true ~wrote:true ()) (mixed ()))
              (golden_path "mixed-styled"));
        test "the accept line prints the accept command" (fun () ->
            contains
              ~sub:"\n  accept:  mv digest.thumper.corrected digest.thumper\n"
              (Report.check
                 (render ~wrote:true
                    ~accept:"mv digest.thumper.corrected digest.thumper" ())
                 (no_baseline ())));
        test "the rerun line carries the run's flags and quotes the executable"
          the_rerun_line_carries_the_flags;
        test "without an executable there is no rerun line"
          without_an_executable_no_rerun_line;
        test "the rerun line wraps within 80 columns under the executable"
          the_rerun_line_wraps_within_80_columns;
        cases "an item joins the line while its backslash fits in 80 columns"
          ~name:first column_80 (fun (_, n, expected) ->
            equal string expected
              (rerun_line
                 (Report.check
                    (render ~exe:(Some (exe n)) ())
                    (failing_cases 2))));
        test "the rerun line names ten failing cases" (fun () ->
            contains ~sub:" -f case-10\n"
              (Report.check (render ()) (failing_cases 10)));
        test "past ten failing cases the run's patterns select"
          past_ten_cases_the_patterns_select;
        cases "a column no case fills is left out" ~name:first absent_columns
          (fun (_, trial, row) ->
            contains ~sub:row
              (Report.check (render ()) (verdict_of (bcase "alpha", trial ()))));
        cases "each unit starts at its own magnitude" ~name:first units
          (fun (_, trial, cell) ->
            contains ~sub:cell
              (Report.check (render ()) (verdict_of (bcase "alpha", trial ()))));
        cases "a cap prints grouped, never in exponent notation" ~name:first5
          caps a_cap_prints_grouped;
        cases "the summary counts a proposed case apart" ~name:first summaries
          (fun (_, strict, summary) ->
            contains ~sub:summary
              (Report.check (render ~strict ()) (one_proposed ())));
        cases "the summary's colour follows the exit code" ~name:first4
          summary_colours (fun (_, verdict, strict, summary) ->
            contains ~sub:summary
              (Report.check (render ~color:true ~strict ()) (verdict ())));
        xfail
          ~reason:
            "a case that passes over an inconclusive metric without a budget \
             opens its row on inconclusive, and the summary counts it passed"
          (test "a row that opens on inconclusive is not counted as passed"
             an_inconclusive_row_is_not_counted_as_passed);
        cases "a recorded identity is quoted when it holds a control byte"
          ~name:first recorded_identities (fun (_, recorded, header) ->
            equal string header (header_of_stale recorded));
      ])

(* The bless report *)

let bless_report =
  group "The bless report"
    (gallery "each state matches its golden" bless_states)

let () =
  exit (run "report" [ status_line; shell_arg; check_report; bless_report ])
