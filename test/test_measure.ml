(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Seam-driven tests for [Measure]. [Measure] is a private module of the library, reached — with its
   [Metric], [Config], [Bench], and [Run] dependencies — through the facade's
   [Thumper.Private] re-export.

   Every protocol behavior is driven through scripted [Measure.instruments]:
   the case closure advances a fake clock and fake counters, so calibration,
   frozen-k reuse, warmup arms, the exactness probe, quality flags, and the
   in-process deadline are all deterministic and consume zero wall-clock time.
   Only the fork tests (the forked deadline, the parent's, among them) and the
   pipe-parser tests touch the real OS. *)

open Windtrap
module Bench = Thumper.Private.Bench
module Config = Thumper.Private.Config
module Measure = Thumper.Private.Measure
module Metric = Thumper.Private.Metric
module Run = Thumper.Private.Run

(* The scripted world *)

type world = {
  mutable now : int; (* fake monotonic clock, ns *)
  mutable cpu : int; (* fake process CPU clock, ns *)
  mutable words : float; (* fake cumulative minor-heap words *)
  mutable calls : int; (* case-closure invocations so far *)
}

let world () = { now = 0; cpu = 0; words = 0.; calls = 0 }

(* Scripted instruments over [w]. [h] is the planted harness constant: every
   counter read allocates [h] words visible to the next read — the model the differencing probe must cancel. *)
let scripted ?(h = 0.) w =
  {
    Measure.now_ns = (fun () -> w.now);
    cpu_ns = (fun () -> w.cpu);
    gc =
      (fun () ->
        let s =
          {
            Metric.minor_words = w.words;
            promoted_words = 0.;
            major_words = 0.;
            minor_collections = 0;
            major_collections = 0;
          }
        in
        w.words <- w.words +. h;
        s);
  }

(* A case closure advancing the world: [step w.calls] gives this call's
   (clock advance in ns, words allocated). *)
let stepper w step () =
  w.calls <- w.calls + 1;
  let dt_ns, words = step w.calls in
  w.now <- w.now + dt_ns;
  w.words <- w.words +. words

let constant_ns dt_ns _call = (dt_ns, 0.)

let resolved bench =
  match Bench.resolve [ bench ] with
  | Ok [ c ] -> c
  | Ok cs -> failf "expected one resolved case, got %d" (List.length cs)
  | Error e -> failf "resolve: %a" Bench.pp_error e

let bench_stepping ?(name = "case") w step =
  resolved (Bench.bench name (stepper w step))

(* In-process configs: the driver under scripted instruments, no fork. *)
let base = Config.(default |> fork false)
let wall_only = Config.(base |> metrics [ Metric.wall_time ])

let measure ?h ?(frozen_k = None) ~config w case =
  Measure.case ~instruments:(scripted ?h w) ~config ~frozen_k case

(* Result plumbing *)

let failure = Testable.make ~pp:Measure.pp_failure ~equal:( = )

let trial_ok = function
  | Ok t -> t
  | Error f -> failf "expected a trial, got failure: %a" Measure.pp_failure f

let the_failure = function
  | Ok _ -> failf "expected a failure, got a trial"
  | Error f -> f

let samples_of trial m =
  match Run.Trial.measurement trial m with
  | Some (Run.Samples s) -> s
  | Some (Run.Exact v) ->
      failf "%s: expected samples, got exact %d" (Metric.id m) v
  | None -> failf "%s: not measured" (Metric.id m)

let exact_of trial m =
  match Run.Trial.measurement trial m with
  | Some (Run.Exact v) -> v
  | Some (Run.Samples _) ->
      failf "%s: expected exact, got samples" (Metric.id m)
  | None -> failf "%s: not measured" (Metric.id m)

let contains_sub s sub =
  let n = String.length sub and len = String.length s in
  let rec go i =
    i + n <= len && (String.equal (String.sub s i n) sub || go (i + 1))
  in
  go 0

let has_warning trial sub =
  List.exists (fun w -> contains_sub w sub) (Run.Trial.warnings trial)

let ms_ns = 1_000_000

(* Calibration *)

(* Default floor is 5 ms; at 1 ms/call the batch meets it at k = 8. *)
let calibration_doubles_to_floor () =
  let w = world () in
  let t =
    trial_ok
      (measure ~config:wall_only w (bench_stepping w (constant_ns ms_ns)))
  in
  equal ~msg:"k" int 8 (Run.Trial.k t);
  let s = samples_of t Metric.wall_time in
  equal ~msg:"n samples" int Config.default.Config.n (Array.length s.Run.sorted)

(* The frozen-k window is [0.2x, 5x] of the floor: [1 ms, 25 ms] here. *)
let frozen_k_cases =
  [
    ("reused inside the window", 1_000_000, 4);
    ("reused just above the low edge", 260_000, 4);
    (* 4 x 240 us = 0.96 ms < 1 ms: recalibrates; doubling at 240 us/call
       reaches the 5 ms floor at k = 32. *)
    ("recalibrated below the low edge", 240_000, 32);
    ("reused just under the high edge", 6_000_000, 4);
    (* 4 x 6.5 ms = 26 ms > 25 ms: recalibrates; one 6.5 ms call already
       meets the floor, so k = 1. *)
    ("recalibrated above the high edge", 6_500_000, 1);
  ]

let frozen_k_tests =
  List.map
    (fun (name, dt_ns, expected_k) ->
      test name (fun () ->
          let w = world () in
          let case = bench_stepping w (constant_ns dt_ns) in
          let t =
            trial_ok (measure ~frozen_k:(Some 4) ~config:wall_only w case)
          in
          equal int expected_k (Run.Trial.k t)))
    frozen_k_cases

let frozen_k_zero_is_programmer_error () =
  let w = world () in
  let case = bench_stepping w (constant_ns ms_ns) in
  raises (Invalid_argument "Measure.case: frozen_k must be >= 1") (fun () ->
      measure ~frozen_k:(Some 0) ~config:wall_only w case)

(* Warmup: max of the timed arm and the 3-batch arm *)

(* At 5 ms/call the first calibration batch meets the floor, so k = 1 and
   call counts decompose exactly: 1 calibration + warmup + n samples (no
   probe: wall_time only). *)
let warmup_batch_arm () =
  let w = world () in
  let case = bench_stepping w (constant_ns (5 * ms_ns)) in
  let config = Config.(wall_only |> warmup 0.) in
  ignore (trial_ok (measure ~config w case));
  equal ~msg:"calls = 1 calib + 3 warmup + 20 samples" int 24 w.calls

let warmup_timed_arm () =
  let w = world () in
  let case = bench_stepping w (constant_ns (5 * ms_ns)) in
  (* 32.5 ms of timed warmup at 5 ms/batch: the timed arm needs 7 batches,
     more than the 3-batch arm. *)
  let config = Config.(wall_only |> warmup 0.0325) in
  ignore (trial_ok (measure ~config w case));
  equal ~msg:"calls = 1 calib + 7 warmup + 20 samples" int 28 w.calls

(* The exactness probe *)

(* k = 1 must pass for a deterministic case: the differencing cancels the
   planted harness constant. *)
let probe_exact_at_k1 () =
  let w = world () in
  let case = bench_stepping w (fun _ -> (5 * ms_ns, 54.)) in
  let config = Config.(base |> warmup 0.) in
  let t = trial_ok (measure ~h:10. ~config w case) in
  equal ~msg:"k" int 1 (Run.Trial.k t);
  equal ~msg:"alloc" int 54 (exact_of t Metric.alloc_words);
  equal ~msg:"no warnings" (list string) [] (Run.Trial.warnings t)

let probe_exact_at_k8192 () =
  let w = world () in
  let case = bench_stepping w (fun _ -> (1_000, 54.)) in
  let config = Config.(base |> warmup 0.) in
  (* 8192 x 1 us = 8.192 ms sits inside the frozen-k window. *)
  let t = trial_ok (measure ~h:10. ~frozen_k:(Some 8192) ~config w case) in
  equal ~msg:"k" int 8192 (Run.Trial.k t);
  equal ~msg:"alloc" int 54 (exact_of t Metric.alloc_words)

(* At 6.5 ms per call the frozen k = 4 batch takes 26 ms, past the window,
   so the timing recalibrates to k = 1: 4 calls for the frozen batch, 1 to
   calibrate, 3 of warmup and 20 samples. The probe still runs at k = 4, 4
   and 8 calls, so the exact count is the one the baseline's batch size
   gives. *)
let probe_runs_at_the_frozen_k () =
  let w = world () in
  let case = bench_stepping w (fun _ -> (6_500_000, 54.)) in
  let config = Config.(base |> warmup 0.) in
  let t = trial_ok (measure ~h:10. ~frozen_k:(Some 4) ~config w case) in
  equal ~msg:"the timing recalibrated" int 1 (Run.Trial.k t);
  equal ~msg:"calls = 4 + 1 + 3 + 20 + (4 + 8)" int 40 w.calls;
  equal ~msg:"alloc" int 54 (exact_of t Metric.alloc_words)

(* An allocator that takes 100 more words every 4th call reads 54 words a
   call at k = 1 and 79 at k = 4. After the recalibration to k = 1 the probe
   covers calls 29 to 40 at k = 4, and proves the count of k = 4. *)
let probe_at_the_frozen_k_proves_its_count () =
  let w = world () in
  let case =
    bench_stepping w (fun call ->
        (6_500_000, if call mod 4 = 0 then 154. else 54.))
  in
  let config = Config.(base |> warmup 0.) in
  let t = trial_ok (measure ~frozen_k:(Some 4) ~config w case) in
  equal ~msg:"the timing recalibrated" int 1 (Run.Trial.k t);
  equal ~msg:"alloc at k = 4" int 79 (exact_of t Metric.alloc_words)

(* The bound on the probe's batch size, at 6.5 ms per call: a frozen k of
   16 or 17 recalibrates the samples to k = 1. At 16 = 16 x 1 the probe runs
   at the frozen k, 16 and 32 calls; at 17 it runs at k = 1, 1 and 2 calls.
   The rest is the frozen batch, 1 calibration, 3 of warmup and 20
   samples. *)
let probe_k_bound =
  [
    ("probes at a frozen k of 16 times the new k", 16, 16 + 24 + 48);
    ("probes at the new k past 16 times it", 17, 17 + 24 + 3);
  ]
  |> List.map (fun (name, frozen, calls) ->
      test name (fun () ->
          let w = world () in
          let case = bench_stepping w (fun _ -> (6_500_000, 54.)) in
          let config = Config.(base |> warmup 0.) in
          let t =
            trial_ok (measure ~h:10. ~frozen_k:(Some frozen) ~config w case)
          in
          equal ~msg:"the timing recalibrated" int 1 (Run.Trial.k t);
          equal ~msg:"calls" int calls w.calls;
          equal ~msg:"alloc" int 54 (exact_of t Metric.alloc_words)))

(* Without a frozen k the probe runs at the calibrated k, as before: 1
   calibration call, 3 of warmup, 20 samples, then 1 and 2 probe calls. *)
let probe_without_a_frozen_k_runs_at_the_calibrated_k () =
  let w = world () in
  let case = bench_stepping w (fun _ -> (6_500_000, 54.)) in
  let config = Config.(base |> warmup 0.) in
  let t = trial_ok (measure ~h:10. ~config w case) in
  equal ~msg:"k" int 1 (Run.Trial.k t);
  equal ~msg:"calls = 1 + 3 + 20 + (1 + 2)" int 27 w.calls;
  equal ~msg:"alloc" int 54 (exact_of t Metric.alloc_words)

let probe_downgrades_nondeterministic_counters () =
  let w = world () in
  (* 54/55 words alternating: at k = 8 the k/2k deltas differ by 436, whose
     division by 8 leaves residue 4 — no consistent integer per-call count
     exists. *)
  let case =
    bench_stepping w (fun call -> (ms_ns, if call mod 2 = 0 then 54. else 55.))
  in
  let config = Config.(base |> warmup 0.) in
  let t = trial_ok (measure ~h:10. ~config w case) in
  (match Run.Trial.measurement t Metric.alloc_words with
  | Some (Run.Samples _) -> ()
  | Some (Run.Exact v) -> failf "expected downgrade to samples, got exact %d" v
  | None -> fail "alloc_words not measured");
  is_true ~msg:"probe warning present" (has_warning t "exactness probe failed");
  is_true ~msg:"warning reports the overhead"
    (has_warning t "per-batch overhead of 10")

(* With [base] (5 ms floor, warmup 0.) and 5 ms calls, k = 1 and the call
   indices are fixed: 1 calibration, 2-4 warmup, 5-24 samples, 25 the k probe
   batch, 26-27 the 2k probe batch. [words call] plants that call's
   allocation. *)
let probe_planted w words =
  bench_stepping w (fun call -> (5 * ms_ns, words call))

let expect_downgrade t =
  (match Run.Trial.measurement t Metric.alloc_words with
  | Some (Run.Samples _) -> ()
  | Some (Run.Exact v) -> failf "expected downgrade to samples, got exact %d" v
  | None -> fail "alloc_words not measured");
  is_true ~msg:"probe warning present" (has_warning t "exactness probe failed")

(* Monotone counters can still produce a consistent negative slope: the k
   batch allocates 3 words in total, the 2k batch 2, so dk = 3, d2k = 2,
   a = -1 with h = 4 = h2 — the differencing alone would "prove" Exact (-1).
   A negative per-call count is nondeterminism, never evidence. *)
let probe_downgrades_when_the_2k_batch_underallocates () =
  let w = world () in
  let case = probe_planted w (function 25 -> 3. | 26 | 27 -> 1. | _ -> 0.) in
  let config = Config.(base |> warmup 0.) in
  expect_downgrade (trial_ok (measure ~config w case))

(* dk = 5, d2k = 15 at k = 1: slope a = 10 with residue 0, but the implied
   harness constant is h = -5 on both sides — a consistent negative h means
   the k batch under-allocated its own slope, i.e. nondeterminism. *)
let probe_downgrades_on_negative_harness_constant () =
  let w = world () in
  let case =
    probe_planted w (function 25 -> 5. | 26 -> 10. | 27 -> 5. | _ -> 0.)
  in
  let config = Config.(base |> warmup 0.) in
  expect_downgrade (trial_ok (measure ~config w case))

(* A counter that goes backward violates the instruments contract (real
   [Gc.counters] cannot): the probe rejects it loudly instead of feeding the
   differencing a negative interval. *)
let probe_rejects_backward_counters () =
  let w = world () in
  let case = probe_planted w (function 25 -> -5. | _ -> 0.) in
  let config = Config.(base |> warmup 0.) in
  raises_match
    (function
      | Invalid_argument m -> contains_sub m "non-decreasing" | _ -> false)
    (fun () -> measure ~config w case)

(* The regression test for the probe's differencing hygiene, on the real
   instruments: a deterministic 2-word allocator ([ref 0]) must prove
   Exact 2 in-process under the default finite deadline. The bug class it
   pins: any harness allocation between the probe's counter reads — one
   boxed int64 from a deadline check's clock read sufficed — lands in one
   interval but not the other, spuriously failing the probe at k >= 4 and
   silently proving a wrong count (Exact 5) at k = 1. *)
let probe_exact_with_real_instruments () =
  let case =
    resolved (Bench.bench "alloc2" (fun () -> Sys.opaque_identity (ref 0)))
  in
  let config =
    Config.(default |> fork false |> samples 3 |> warmup 0. |> batch_floor 1e-6)
  in
  let t = trial_ok (Measure.case ~config ~frozen_k:None case) in
  equal ~msg:"ref allocates exactly 2 words/call" int 2
    (exact_of t Metric.alloc_words)

(* Quality flags *)

(* Steady 5 ms calls, then 5.25 ms from the 15th call on: with k = 1 and
   warmup 0 the twenty samples are calls 5..24, so the two halves sit on
   opposite sides of the step. A 5% step drifts the rank test. *)
let drift_flag_on_planted_step () =
  let w = world () in
  let case =
    bench_stepping w (fun call ->
        ((if call < 15 then 5 * ms_ns else 5_250_000), 0.))
  in
  let config = Config.(wall_only |> warmup 0.) in
  let t = trial_ok (measure ~config w case) in
  let s = samples_of t Metric.wall_time in
  is_true ~msg:"drifted" s.Run.drifted

(* Two 200 ms spikes among 5 ms samples, one planted in each half: no drift,
   and the spikes stay in the evidence (outliers are never removed; judgment
   reads the inflation from the sorted vector). *)
let planted_outliers_are_kept () =
  let w = world () in
  let case =
    bench_stepping w (fun call ->
        ((if call = 9 || call = 19 then 200 * ms_ns else 5 * ms_ns), 0.))
  in
  let config = Config.(wall_only |> warmup 0.) in
  let t = trial_ok (measure ~config w case) in
  let s = samples_of t Metric.wall_time in
  is_false ~msg:"drifted" s.Run.drifted;
  equal ~msg:"both spikes kept" int 2
    (Array.fold_left (fun n x -> if x > 0.1 then n + 1 else n) 0 s.Run.sorted)

let clean_case_has_no_flags () =
  let w = world () in
  let case = bench_stepping w (constant_ns (5 * ms_ns)) in
  let config = Config.(wall_only |> warmup 0.) in
  let t = trial_ok (measure ~config w case) in
  let s = samples_of t Metric.wall_time in
  is_false ~msg:"drifted" s.Run.drifted

(* Alternating 5 ms / 6 ms calls: both collection-order halves hold five of
   each, so there is no drift — but the {e sorted} halves are all-5s vs
   all-6s, maximally different. A drift check computed after sorting would
   flag every case with distinct values; this pins that the flag is computed
   on collection order. *)
let alternating_samples_do_not_drift () =
  let w = world () in
  let case =
    bench_stepping w (fun call ->
        ((if call mod 2 = 0 then 6 * ms_ns else 5 * ms_ns), 0.))
  in
  let config = Config.(wall_only |> warmup 0.) in
  let t = trial_ok (measure ~config w case) in
  let s = samples_of t Metric.wall_time in
  is_false ~msg:"drifted" s.Run.drifted

(* The deadline *)

let jump_case w =
  (* 5 ms calls; the 10th call jumps the clock by 100 s, blowing the default
     10 s cap mid-sampling. *)
  bench_stepping ~name:"jump" w (fun call ->
      ((if call = 10 then 100_000 * ms_ns else 5 * ms_ns), 0.))

let deadline_exceeded_on_clock_jump () =
  let w = world () in
  let config = Config.(wall_only |> warmup 0.) in
  equal failure
    (Measure.Deadline_exceeded { case = "jump"; deadline = 10. })
    (the_failure (measure ~config w (jump_case w)))

let deadline_infinity_removes_the_cap () =
  let w = world () in
  let config = Config.(wall_only |> warmup 0. |> deadline infinity) in
  ignore (trial_ok (measure ~config w (jump_case w)))

(* Teardown containment (bench.mli pins that [Bench] does not) *)

let with_teardown ?id w ~torn ~step ~raise_teardown =
  resolved
    (Bench.bench_with_setup ?id
       ~setup:(fun () -> ())
       ~teardown:(fun () ->
         torn := !torn + 1;
         if raise_teardown then failwith "teardown-boom")
       "case"
       (fun () -> stepper w step ()))

let teardown_runs_on_success () =
  let w = world () in
  let torn = ref 0 in
  let case =
    with_teardown w ~torn ~step:(constant_ns (5 * ms_ns)) ~raise_teardown:false
  in
  let config = Config.(wall_only |> warmup 0.) in
  ignore (trial_ok (measure ~config w case));
  equal ~msg:"teardown ran once" int 1 !torn

let teardown_runs_when_the_case_raises () =
  let w = world () in
  let torn = ref 0 in
  let case =
    with_teardown w ~torn
      ~step:(fun call ->
        if call = 3 then failwith "boom-inside" else (5 * ms_ns, 0.))
      ~raise_teardown:false
  in
  let config = Config.(wall_only |> warmup 0.) in
  (match the_failure (measure ~config w case) with
  | Measure.Case_raised { case = "case"; exn } ->
      is_true ~msg:"exn text" (contains_sub exn "boom-inside")
  | f -> failf "expected Case_raised, got %a" Measure.pp_failure f);
  equal ~msg:"teardown ran once" int 1 !torn

let teardown_runs_when_the_deadline_fires () =
  let w = world () in
  let torn = ref 0 in
  let case =
    with_teardown ~id:"jump" w ~torn
      ~step:(fun call ->
        ((if call = 10 then 100_000 * ms_ns else 5 * ms_ns), 0.))
      ~raise_teardown:false
  in
  let config = Config.(wall_only |> warmup 0.) in
  equal failure
    (Measure.Deadline_exceeded { case = "jump"; deadline = 10. })
    (the_failure (measure ~config w case));
  equal ~msg:"teardown ran once" int 1 !torn

let raising_teardown_fails_the_case () =
  let w = world () in
  let torn = ref 0 in
  let case =
    with_teardown w ~torn ~step:(constant_ns (5 * ms_ns)) ~raise_teardown:true
  in
  let config = Config.(wall_only |> warmup 0.) in
  match the_failure (measure ~config w case) with
  | Measure.Case_raised { exn; _ } ->
      is_true ~msg:"exn text" (contains_sub exn "teardown-boom")
  | f -> failf "expected Case_raised, got %a" Measure.pp_failure f

let raising_setup_fails_the_case () =
  let w = world () in
  let case =
    resolved
      (Bench.bench_with_setup
         ~setup:(fun () -> failwith "setup-boom")
         "case"
         (fun () -> stepper w (constant_ns (5 * ms_ns)) ()))
  in
  let config = Config.(wall_only |> warmup 0.) in
  match the_failure (measure ~config w case) with
  | Measure.Case_raised { exn; _ } ->
      is_true ~msg:"exn text" (contains_sub exn "setup-boom")
  | f -> failf "expected Case_raised, got %a" Measure.pp_failure f

(* Warnings *)

let gc_param_mutation_is_warned () =
  let saved = Gc.get () in
  Fun.protect
    ~finally:(fun () -> Gc.set saved)
    (fun () ->
      let w = world () in
      let mutated = ref false in
      let case =
        resolved
          (Bench.bench "mutator" (fun () ->
               if not !mutated then (
                 mutated := true;
                 Gc.set
                   {
                     (Gc.get ()) with
                     Gc.space_overhead = (Gc.get ()).Gc.space_overhead + 40;
                   });
               stepper w (constant_ns (5 * ms_ns)) ()))
      in
      let config = Config.(wall_only |> warmup 0.) in
      let t = trial_ok (measure ~config w case) in
      is_true ~msg:"names the parameter" (has_warning t "space_overhead"))

(* Sub-nanosecond per-call medians smell of constant folding: 1 ns of clock
   advance every second call is 0.5 ns/call. *)
let fold_suspicion_is_warned () =
  let w = world () in
  let case =
    bench_stepping w (fun call -> ((if call mod 2 = 0 then 1 else 0), 0.))
  in
  let config = Config.(wall_only |> warmup 0. |> batch_floor 1e-6) in
  let t = trial_ok (measure ~config w case) in
  is_true ~msg:"fold warning"
    (has_warning t "possibly folded: wrap the input in black_box")

(* CPU time (opt-in metric, via the seam's cpu clock) *)

let cpu_time_is_sampled () =
  let w = world () in
  let case =
    resolved
      (Bench.bench "cpu" (fun () ->
           w.calls <- w.calls + 1;
           w.now <- w.now + 5_000_000;
           w.cpu <- w.cpu + 2_000_000))
  in
  let config =
    Config.(base |> warmup 0. |> metrics [ Metric.wall_time; Metric.cpu_time ])
  in
  let t = trial_ok (measure ~config w case) in
  let s = samples_of t Metric.cpu_time in
  equal ~msg:"n" int Config.default.Config.n (Array.length s.Run.sorted);
  equal ~msg:"per-call cpu" (float 1e-15) 0.002 s.Run.sorted.(0)

let measurement_order_follows_the_metric_list () =
  let w = world () in
  let case = bench_stepping w (fun _ -> (5 * ms_ns, 54.)) in
  let config =
    Config.(
      base |> warmup 0. |> metrics [ Metric.alloc_words; Metric.wall_time ])
  in
  let t = trial_ok (measure ~config w case) in
  equal (list string)
    [ "alloc_words"; "wall_time" ]
    (List.map (fun (m, _) -> Metric.id m) (Run.Trial.measurements t))

(* The pipe protocol parser (containment without forking) *)

let both_metrics = [ Metric.wall_time; Metric.alloc_words ]
let parse = Measure.Protocol.parse ~case:"c"

let protocol_round_trip () =
  let sorted =
    Run.sampled ~sorted:[| 6.883e-7; 6.911e-7; 7.084e-7 |] ~drifted:true
  in
  let trial =
    Run.Trial.make ~k:8192
      ~warnings:[ "wall_time 0.5 ns/call: possibly folded" ]
      [
        (Metric.wall_time, Run.Samples sorted);
        (Metric.alloc_words, Run.Exact 54);
      ]
  in
  let buf = Buffer.create 256 in
  Measure.Protocol.write buf (Ok trial);
  let parsed = trial_ok (parse ~metrics:both_metrics (Buffer.contents buf)) in
  equal ~msg:"k" int (Run.Trial.k trial) (Run.Trial.k parsed);
  equal ~msg:"warnings" (list string) (Run.Trial.warnings trial)
    (Run.Trial.warnings parsed);
  equal ~msg:"alloc" int 54 (exact_of parsed Metric.alloc_words);
  let s = samples_of parsed Metric.wall_time in
  equal ~msg:"samples survive %h exactly" (array float_exact)
    [| 6.883e-7; 6.911e-7; 7.084e-7 |]
    s.Run.sorted;
  is_true ~msg:"drifted" s.Run.drifted

let failure_round_trips =
  [
    ( "raised crosses the pipe",
      "raised Failure(\"boom\")\n",
      Measure.Case_raised { case = "c"; exn = "Failure(\"boom\")" } );
  ]
  |> List.map (fun (name, wire, expected) ->
      test name (fun () ->
          equal failure expected
            (the_failure (parse ~metrics:both_metrics wire));
          (* and the writer produces exactly this wire form *)
          let buf = Buffer.create 64 in
          Measure.Protocol.write buf (Error expected);
          equal ~msg:"writer" string wire (Buffer.contents buf)))

let write_rejects_parent_side_failures () =
  List.iter
    (fun f ->
      raises_match
        (function Invalid_argument _ -> true | _ -> false)
        (fun () -> Measure.Protocol.write (Buffer.create 16) (Error f)))
    [
      Measure.Worker_died { case = "c"; detail = "d" };
      Measure.Deadline_exceeded { case = "c"; deadline = 1. };
    ]

let valid_wire =
  "k 8\n\
   samples wall_time 3 0 0x1p-21 0x1.8p-21 0x1p-20\n\
   exact alloc_words 54\n\
   end\n"

let parse_accepts_the_pinned_grammar () =
  let t = trial_ok (parse ~metrics:both_metrics valid_wire) in
  equal ~msg:"k" int 8 (Run.Trial.k t);
  equal ~msg:"alloc" int 54 (exact_of t Metric.alloc_words);
  equal ~msg:"wall n" int 3
    (Array.length (samples_of t Metric.wall_time).Run.sorted);
  let zero =
    "k 8\n\
     samples wall_time 3 0 0x1p-21 0x1.8p-21 0x1p-20\n\
     exact alloc_words 0\n\
     end\n"
  in
  equal ~msg:"a zero count" int 0
    (exact_of (trial_ok (parse ~metrics:both_metrics zero)) Metric.alloc_words)

let malformed_wire =
  [
    ("empty output", "");
    ("no final newline", "k 8\nend");
    ("missing end", "k 8\nexact alloc_words 54\n");
    ("text after end", valid_wire ^ "garbage\n");
    ("a deadline line", "deadline\n");
    ("text after raised", "raised boom\nend\n");
    ("unparseable k line", "batch 8\nend\n");
    ("unparseable batch size", "k eight\nend\n");
    ( "k below 1",
      "k 0\n\
       samples wall_time 3 0 0x1p-21 0x1.8p-21 0x1p-20\n\
       exact alloc_words 54\n\
       end\n" );
    ( "unknown metric",
      "k 8\n\
       exact bogus 54\n\
       samples wall_time 3 0 0x1p-21 0x1.8p-21 0x1p-20\n\
       end\n" );
    ( "exact for a clock metric",
      "k 8\nexact wall_time 5\nexact alloc_words 54\nend\n" );
    ( "unparseable exact value",
      "k 8\n\
       exact alloc_words fifty\n\
       samples wall_time 3 0 0x1p-21 0x1.8p-21 0x1p-20\n\
       end\n" );
    ( "negative exact value",
      "k 8\n\
       exact alloc_words -3\n\
       samples wall_time 3 0 0x1p-21 0x1.8p-21 0x1p-20\n\
       end\n" );
    ("missing metric", "k 8\nexact alloc_words 54\nend\n");
    ( "duplicate metric",
      "k 8\n\
       exact alloc_words 54\n\
       exact alloc_words 54\n\
       samples wall_time 3 0 0x1p-21 0x1.8p-21 0x1p-20\n\
       end\n" );
    ( "hostile sample count",
      "k 8\n\
       samples wall_time 999999999 0 0x1p-21 0x1.8p-21 0x1p-20\n\
       exact alloc_words 54\n\
       end\n" );
    ( "short sample count",
      "k 8\n\
       samples wall_time 2 0 0x1p-21 0x1.8p-21 0x1p-20\n\
       exact alloc_words 54\n\
       end\n" );
    ( "unparseable sample",
      "k 8\n\
       samples wall_time 3 0 0x1p-21 six 0x1p-20\n\
       exact alloc_words 54\n\
       end\n" );
    ( "unsorted samples",
      "k 8\n\
       samples wall_time 3 0 0x1p-20 0x1.8p-21 0x1p-21\n\
       exact alloc_words 54\n\
       end\n" );
    ( "non-finite sample",
      "k 8\n\
       samples wall_time 3 0 0x1p-21 0x1.8p-21 inf\n\
       exact alloc_words 54\n\
       end\n" );
    ( "unparseable drifted flag",
      "k 8\n\
       samples wall_time 3 0,0 0x1p-21 0x1.8p-21 0x1p-20\n\
       exact alloc_words 54\n\
       end\n" );
    ( "non-boolean flag",
      "k 8\n\
       samples wall_time 3 2 0x1p-21 0x1.8p-21 0x1p-20\n\
       exact alloc_words 54\n\
       end\n" );
    ( "metric line after warnings",
      "k 8\n\
       samples wall_time 3 0 0x1p-21 0x1.8p-21 0x1p-20\n\
       warning w\n\
       exact alloc_words 54\n\
       end\n" );
  ]

let malformed_tests =
  List.map
    (fun (name, wire) ->
      test name (fun () ->
          match parse ~metrics:both_metrics wire with
          | Error (Measure.Worker_died { case = "c"; detail }) ->
              is_true ~msg:"detail names malformedness"
                (contains_sub detail "malformed worker output"
                || contains_sub detail "worker")
          | Ok _ -> fail "malformed wire parsed successfully"
          | Error f -> failf "expected Worker_died, got %a" Measure.pp_failure f))
    malformed_wire

(* Real-fork smoke (full containment is wave-6 cram) *)

let fork_round_trip () =
  let case =
    resolved (Bench.bench "alloc" (fun () -> Sys.opaque_identity (ref 0)))
  in
  let config = Config.(default |> samples 3 |> warmup 0. |> batch_floor 1e-6) in
  let t = trial_ok (Measure.case ~config ~frozen_k:None case) in
  is_true ~msg:"k >= 1" (Run.Trial.k t >= 1);
  let s = samples_of t Metric.wall_time in
  equal ~msg:"n" int 3 (Array.length s.Run.sorted);
  (* The exact value, not just exactness: a cold child can calibrate to
     k = 1, where a contaminated probe proves a plausible wrong count
     instead of failing. *)
  equal ~msg:"alloc proven exact" int 2 (exact_of t Metric.alloc_words)

let fork_reports_a_raising_case () =
  let case =
    resolved (Bench.bench "boom" (fun () -> failwith "boom-in-child"))
  in
  let config = Config.(default |> samples 3 |> warmup 0. |> batch_floor 1e-6) in
  match the_failure (Measure.case ~config ~frozen_k:None case) with
  | Measure.Case_raised { case = "boom"; exn } ->
      is_true ~msg:"exn text" (contains_sub exn "boom-in-child")
  | f -> failf "expected Case_raised, got %a" Measure.pp_failure f

(* A forked case's deadline is the parent's: the child never checks it, so a
   scripted clock jump past the cap inside the worker is just a slow sample. *)
let forked_child_does_not_check_the_deadline () =
  let w = world () in
  let config = Config.(default |> warmup 0. |> metrics [ Metric.wall_time ]) in
  ignore
    (trial_ok
       (Measure.case ~instruments:(scripted w) ~config ~frozen_k:None
          (jump_case w)))

(* The parent kills a worker that has not reported by the deadline, even one
   hung inside a single call. *)
let parent_kills_a_hung_worker_at_the_deadline () =
  let case =
    resolved
      (Bench.bench "hang" (fun () ->
           while true do
             ()
           done))
  in
  let config = Config.(default |> deadline 0.2) in
  equal failure
    (Measure.Deadline_exceeded { case = "hang"; deadline = 0.2 })
    (the_failure (Measure.case ~config ~frozen_k:None case))

external stop_traced : unit -> bool = "thumper_test_stop_traced"
external sigkill_ends_tracee : unit -> bool = "thumper_test_sigkill_ends_tracee"

(* A worker that writes its pid to a file, closes its report pipe and stops
   as a traced child: the parent sees end of file, then a stopped child.
   The failure names the signal, and the case returns: SIGKILL is sent and
   the reap is bounded. Where the kernel ends a traced child on SIGKILL
   (Linux), it is reaped before the case returns. macOS delivers the kill
   only once the tracer exits, so there the worker dies with the test
   runner and only the report is checked. A host that refuses tracing skips
   the test (the child exits 3). *)
let a_stopped_worker_is_killed_and_reaped () =
  let pid_file = Filename.temp_file "thumper-stop" ".pid" in
  let case =
    resolved
      (Bench.bench "stop" (fun () ->
           Out_channel.with_open_bin pid_file (fun oc ->
               output_string oc (string_of_int (Unix.getpid ())));
           if not (stop_traced ()) then exit 3))
  in
  let config = Config.(default |> samples 3 |> warmup 0. |> deadline 10.) in
  let outcome = Measure.case ~config ~frozen_k:None case in
  let pid =
    int_of_string (In_channel.with_open_bin pid_file In_channel.input_all)
  in
  Sys.remove pid_file;
  match the_failure outcome with
  | Measure.Worker_died { detail = "exited with code 3"; _ } ->
      skip ~reason:"this host refuses ptrace" ()
  | Measure.Worker_died { case = "stop"; detail } ->
      equal ~msg:"detail" string "stopped by SIGUSR1" detail;
      if sigkill_ends_tracee () then
        raises_match ~msg:"the worker is reaped"
          (function Unix.Unix_error (Unix.ECHILD, _, _) -> true | _ -> false)
          (fun () -> Unix.waitpid [ Unix.WNOHANG ] pid)
  | f -> failf "expected Worker_died, got %a" Measure.pp_failure f

(* OCaml refuses [Unix.fork] once the process has spawned a domain, even a
   joined one. A domain in this process would refuse every later fork, the
   test runner's included, so the refusal is staged in a child: it spawns
   and joins a domain, measures, and exits 0 iff the failure is
   [Worker_died] carrying the runtime's message and both pipe ends were
   closed (the next pipe reuses the lowest free descriptors, so a leak would
   shift them). *)
let refused_fork_is_worker_died () =
  let case = resolved (Bench.bench "x" (fun () -> ())) in
  let config = Config.(default |> samples 3 |> warmup 0. |> batch_floor 1e-6) in
  match Unix.fork () with
  | 0 ->
      Domain.join (Domain.spawn (fun () -> ()));
      let free_fds () =
        let r, w = Unix.pipe () in
        Unix.close r;
        Unix.close w;
        (r, w)
      in
      let before = free_fds () in
      let code =
        match Measure.case ~config ~frozen_k:None case with
        | Error (Measure.Worker_died { case = "x"; detail })
          when contains_sub detail "domain" ->
            if free_fds () = before then 0 else 2
        | _ -> 1
      in
      Unix._exit code
  | pid -> (
      match Unix.waitpid [] pid with
      | _, Unix.WEXITED 0 -> ()
      | _, Unix.WEXITED 2 -> fail "a refused fork leaked its pipe"
      | _, Unix.WEXITED c ->
          failf "a refused fork was not Worker_died (child exit %d)" c
      | _ -> fail "the staging child died")

(* Suite *)

let () =
  run "measure"
    [
      group "calibration"
        ([
           test "doubles k until a batch meets the floor"
             calibration_doubles_to_floor;
           test "frozen_k below 1 is a programmer error"
             frozen_k_zero_is_programmer_error;
         ]
        @ frozen_k_tests);
      group "warmup"
        [
          test "the 3-batch arm floors short warmups" warmup_batch_arm;
          test "the timed arm extends past 3 batches" warmup_timed_arm;
        ];
      group "exactness probe"
        [
          test "proves a planted count at k = 1" probe_exact_at_k1;
          test "proves a planted count at k = 8192" probe_exact_at_k8192;
          test "runs at the frozen k when the timing recalibrates"
            probe_runs_at_the_frozen_k;
          test "proves the frozen k's count after a recalibration"
            probe_at_the_frozen_k_proves_its_count;
          test "runs at the calibrated k without a frozen k"
            probe_without_a_frozen_k_runs_at_the_calibrated_k;
          group "bound on the frozen k" probe_k_bound;
          test "downgrades nondeterministic counters with a warning"
            probe_downgrades_nondeterministic_counters;
          test "downgrades when the 2k batch underallocates"
            probe_downgrades_when_the_2k_batch_underallocates;
          test "downgrades on a negative harness constant"
            probe_downgrades_on_negative_harness_constant;
          test "rejects backward counters" probe_rejects_backward_counters;
          test "proves a real allocator exact under a finite deadline"
            probe_exact_with_real_instruments;
        ];
      group "quality flags"
        [
          test "drift on a planted step" drift_flag_on_planted_step;
          test "alternating samples do not drift (order preserved)"
            alternating_samples_do_not_drift;
          test "planted outliers are kept, without drift"
            planted_outliers_are_kept;
          test "clean case has no flags" clean_case_has_no_flags;
        ];
      group "deadline"
        [
          test "a clock jump past the cap fails the case"
            deadline_exceeded_on_clock_jump;
          test "deadline infinity removes the cap"
            deadline_infinity_removes_the_cap;
        ];
      group "teardown"
        [
          test "runs on success" teardown_runs_on_success;
          test "runs when the case raises" teardown_runs_when_the_case_raises;
          test "runs when the deadline fires"
            teardown_runs_when_the_deadline_fires;
          test "raising teardown fails the case" raising_teardown_fails_the_case;
          test "raising setup fails the case" raising_setup_fails_the_case;
        ];
      group "warnings"
        [
          test "gc parameter mutation names the parameter"
            gc_param_mutation_is_warned;
          test "sub-nanosecond medians suggest folding" fold_suspicion_is_warned;
        ];
      group "metrics"
        [
          test "cpu_time is sampled from the cpu clock" cpu_time_is_sampled;
          test "measurement order follows the metric list"
            measurement_order_follows_the_metric_list;
        ];
      group "protocol"
        ([
           test "trial round-trips through the wire" protocol_round_trip;
           test "the pinned grammar parses" parse_accepts_the_pinned_grammar;
           test "write rejects the parent-side failures"
             write_rejects_parent_side_failures;
         ]
        @ failure_round_trips
        @ [ group "malformed wire is Worker_died" malformed_tests ]);
      group "fork"
        [
          test "protocol round-trips through a real fork" fork_round_trip;
          test "a raising case is reported through the pipe"
            fork_reports_a_raising_case;
          test "a refused fork is Worker_died" refused_fork_is_worker_died;
          test "the forked child does not check the deadline"
            forked_child_does_not_check_the_deadline;
          test "the parent kills a hung worker at the deadline"
            parent_kills_a_hung_worker_at_the_deadline;
          (* Its own limit: a blocking reap would otherwise wedge the run. *)
          test ~timeout:30. "a stopped worker is killed and reaped"
            a_stopped_worker_is_killed_and_reaped;
        ];
    ]
  |> exit
