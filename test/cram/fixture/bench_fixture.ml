(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The benchmark executable behind the cram suite: one suite of seven cases,
   whose behaviour THUMPER_FIXTURE_MODE selects. It holds a comma-separated
   list of modes; unset, every case runs as recorded in a fast baseline.

     slow         busy/spin does twice its work (a regression against a fast
                  baseline) and busy/half half of its work (an improvement)
     alloc_more   alloc/list allocates one more cons cell per call
     alloc_less   alloc/array allocates one word less per call
     alloc_grow   alloc/list allocates more on each call than on the call
                  before, so the exactness probe fails
     raise        err/raise raises
     kill9        err/kill9 kills its worker with SIGKILL
     nondet       nondet/flip alternates between two costs on a 20 ms wall
                  clock cadence, so its samples never settle
     hang         err/raise never returns, under a 1 s deadline per case
     uncollected  adds the case cpu, which budgets wall_time and collects
                  cpu_time only

   THUMPER_FIXTURE_RAN_PATH, when set, gets one line per process start: how a
   session sees whether dune reran a rule action. *)

let known =
  [
    "slow";
    "alloc_more";
    "alloc_less";
    "alloc_grow";
    "raise";
    "kill9";
    "nondet";
    "hang";
    "uncollected";
  ]

let modes =
  match Sys.getenv_opt "THUMPER_FIXTURE_MODE" with
  | None -> []
  | Some s ->
      let modes = String.split_on_char ',' s in
      List.iter
        (fun m ->
          if not (List.mem m known) then
            failwith ("bench_fixture: unknown THUMPER_FIXTURE_MODE: " ^ m))
        modes;
      modes

let mode m = List.mem m modes

let () =
  match Sys.getenv_opt "THUMPER_FIXTURE_RAN_PATH" with
  | None -> ()
  | Some path ->
      let oc = open_out_gen [ Open_creat; Open_append; Open_text ] 0o600 path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc "ran\n")

(* Allocation-free busy work: tail recursion over immediate values, so the
   busy cases record exact rows of 0 words. *)
let rec spin acc i = if i = 0 then acc else spin (acc lxor i) (i - 1)

(* About 4000 iterations take a few microseconds: far above the 1 ns fold
   threshold, far below the 5 ms batch floor. *)
let spin_iters = if mode "slow" then 8_000 else 4_000
let half_iters = if mode "slow" then 4_000 else 8_000
let rec hang () = hang (ignore (spin 0 4_000))

(* The alloc cases collect alloc_words alone, so no timed value enters their
   verdicts, and a case without a sampled row has no frozen batch size, so a
   changed count is never read as a drifted batch. *)
let list_len = if mode "alloc_more" then 101 else 100
let array_len = if mode "alloc_less" then 99 else 100

(* Under alloc_grow each call allocates 32 cells (96 words) more than the one
   before. The probe's batches of k and 2k calls then fit a whole per-call
   count only with a per-batch overhead of h0 - 288k^2 words, where h0 is the
   counter reads' own: negative at every k, so the probe fails and the count
   stays sampled. Each call also spins for about a millisecond, which keeps a
   trial to a few hundred calls, so the lists stay short. *)
let calls = ref 0

let alloc_list () =
  if mode "alloc_grow" then begin
    incr calls;
    ignore (spin 0 2_000_000)
  end;
  let len = list_len + (32 * !calls) in
  List.init (Thumper.black_box len) Fun.id

let alloc_array () = Array.make (Thumper.black_box array_len) 0

let raise_case () =
  if mode "raise" then failwith "fixture raise mode"
  else if mode "hang" then hang ()
  else spin 0 2_000

let kill9_case () =
  if mode "kill9" then Unix.kill (Unix.getpid ()) Sys.sigkill;
  spin 0 2_000

(* Two costs, switched by the wall clock every 20 ms: an 11-batch trial at the
   5 ms floor spans several windows, so its samples always mix both. *)
let flip_case () =
  let iters =
    if mode "nondet" then
      let ms = int_of_float (Unix.gettimeofday () *. 1000.) in
      if ms / 20 mod 2 = 0 then 4_000 else 12_000
    else 4_000
  in
  spin 0 (Thumper.black_box iters)

(* A deadline bounds the hang: a cap on damage, far below the session's own
   time, never a timing claim. *)
let config =
  if mode "hang" then Thumper.Config.(default |> deadline 1.)
  else Thumper.Config.default

let uncollected =
  if mode "uncollected" then
    [
      Thumper.bench "cpu"
        ~metrics:[ Thumper.Metric.cpu_time ]
        ~budgets:[ Thumper.Budget.no_slower_than 0.05 ]
        (fun () -> spin 0 (Thumper.black_box 4_000));
    ]
  else []

let () =
  exit
    (Thumper.run "fixture" ~config
       ~budgets:
         [
           Thumper.Budget.no_slower_than 0.05;
           Thumper.Budget.no_more_alloc_than 0.0;
         ]
       ([
          Thumper.group "busy" ~tags:[ "cpu" ]
            [
              Thumper.bench "spin" (fun () ->
                  spin 0 (Thumper.black_box spin_iters));
              Thumper.bench "half" ~tags:[ "lab" ] (fun () ->
                  spin 0 (Thumper.black_box half_iters));
            ];
          Thumper.group "alloc" ~tags:[ "lab" ]
            ~metrics:[ Thumper.Metric.alloc_words ]
            [
              Thumper.bench "list" alloc_list; Thumper.bench "array" alloc_array;
            ];
          Thumper.group "err"
            [
              Thumper.bench "raise" raise_case; Thumper.bench "kill9" kill9_case;
            ];
          Thumper.group "nondet" [ Thumper.bench "flip" flip_case ];
        ]
       @ uncollected))
