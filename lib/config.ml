(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

type t = {
  n : int;
  batch_floor : float;
  warmup_time : float;
  warmup_batches : int;
  deadline : float;
  metrics : Metric.t list;
  fork : bool;
}

(* Power: at CoV ≈ 2%, m = n = 20 detects ~3% shifts;
   scaled against the ~0.4 s case budget. *)
let default_n = 20
let quick_n = 11
let precise_n = 40

(* Clock read: ≤ 0.01% of a batch needs ≥ 1 ms; the ×5
   margin lets one batch amortize a minor-GC cycle. *)
let default_batch_floor = 5e-3

(* Warmup: fixed, never adaptive (protocol identity);
   sized to cover frequency ramp and cache/pagefault settling. *)
let default_warmup_time = 0.1
let default_warmup_batches = 3

(* Deadline: 20x the default protocol's case budget of 0.5 s (20 samples,
   each a batch at the frozen-k window's ceiling of 5 x 5 ms). It admits
   every path the protocol takes, single-call batches included: at k = 1 a
   default trial makes 27 calls (1 calibration, 3 warmup, 20 samples, 1 + 2
   probe), so 10 s holds calls of up to 0.37 s, setup and teardown aside.
   The bound does not scale with n: under [precise] (47 calls) it is 0.21 s
   per call. A recalibration from a frozen k runs one batch at the frozen k,
   and probes at it only while it is at most 16 times the new k
   ([Measure.probe_k]): those four batches take at most as long as 64 new
   ones, at k = 1 the trial makes at most 16 + 24 + 48 = 88 calls, and 10 s
   holds calls of up to 0.11 s. Past 16 times, the one batch at the frozen k
   takes the slowdown times its baseline time of 1 to 25 ms, so only a case
   slowed by several hundred times can reach the deadline there. *)
let default_deadline = 10.

(* Default quantities: wall_time (sampled) and alloc_words (exact when
   proven); the rest are opt-in. *)
let default_metrics = [ Metric.wall_time; Metric.alloc_words ]

(* Forked worker per case is the default; [fork false] is the
   in-process library/test seam. *)
let default_fork = true

let default =
  {
    n = default_n;
    batch_floor = default_batch_floor;
    warmup_time = default_warmup_time;
    warmup_batches = default_warmup_batches;
    deadline = default_deadline;
    metrics = default_metrics;
    fork = default_fork;
  }

let quick = { default with n = quick_n }
let precise = { default with n = precise_n }

let samples n t =
  if n < 3 then
    invalid_arg
      (Printf.sprintf "Thumper.Config.samples: %d (need at least 3 batches)" n);
  { t with n }

let batch_floor s t =
  (* [not (s > 0.)] also rejects NaN; the explicit finiteness check rejects
     [infinity] (calibration would never meet the floor). *)
  if (not (s > 0.)) || not (Float.is_finite s) then
    invalid_arg
      (Printf.sprintf
         "Thumper.Config.batch_floor: %g (need a finite positive duration in \
          seconds)"
         s);
  { t with batch_floor = s }

let warmup s t =
  if (not (s >= 0.)) || not (Float.is_finite s) then
    invalid_arg
      (Printf.sprintf
         "Thumper.Config.warmup: %g (need a finite non-negative duration in \
          seconds)"
         s);
  { t with warmup_time = s }

let deadline s t =
  (* [infinity] passes and removes the cap; NaN fails [s > 0.]. *)
  if not (s > 0.) then
    invalid_arg
      (Printf.sprintf
         "Thumper.Config.deadline: %g (need a positive duration in seconds)" s);
  { t with deadline = s }

let rec check_no_duplicate = function
  | [] -> ()
  | m :: rest ->
      if List.exists (Metric.equal m) rest then
        invalid_arg ("Thumper.Config.metrics: duplicate metric " ^ Metric.id m)
      else check_no_duplicate rest

let metrics ms t =
  (match ms with
  | [] -> invalid_arg "Thumper.Config.metrics: empty metric list"
  | _ :: _ -> check_no_duplicate ms);
  { t with metrics = ms }

let fork b t = { t with fork = b }
