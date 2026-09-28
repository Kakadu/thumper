(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Windtrap suite for the vendored raw-monotonic clock
  . *)

open Windtrap

let reads = 10_000

let now_non_decreasing () =
  let prev = ref (Thumper_clock.now_ns ()) in
  for i = 1 to reads do
    let now = Thumper_clock.now_ns () in
    if now < !prev then
      failf "now_ns went backwards at read %d: %d then %d" i !prev now;
    prev := now
  done

let load_average_some_non_negative () =
  match Thumper_clock.load_average () with
  | None -> fail "load_average is None on this host (getloadavg failed)"
  | Some l -> if l < 0.0 then failf "load_average is negative: %g" l

(* Two consecutive reads must land within 1 ms of each other: a clock
   whose reads are that close is fine-grained (and cheap) enough for 5 ms
   batches. A single pair could be descheduled between the reads, so take
   the minimum over many pairs. *)
let resolution_below_1ms () =
  let min_delta = ref max_int in
  for _ = 1 to 1_000 do
    let a = Thumper_clock.now_ns () in
    let b = Thumper_clock.now_ns () in
    min_delta := min (b - a) !min_delta
  done;
  if !min_delta >= 1_000_000 then
    failf "consecutive now_ns reads are %d ns apart (>= 1 ms)" !min_delta

(* A ticks-vs-nanoseconds confusion in the stubs (e.g. dropping the mach
   timebase conversion on Apple Silicon, where raw ticks run at 24 MHz, so
   every value is ~42x too small) passes both the monotonicity and the
   resolution tests above. Only cross-checking against an independently
   timed wall-clock interval catches a constant-factor unit error. The
   bounds are loose ([0.04, 0.5] s for a 50 ms sleep) to tolerate
   scheduler delay while still catching any such factor. *)
let tracks_sleep () =
  let t0 = Thumper_clock.now_ns () in
  Unix.sleepf 0.05;
  let t1 = Thumper_clock.now_ns () in
  let s = float_of_int (t1 - t0) /. 1e9 in
  if s < 0.04 || s > 0.5 then
    failf "now_ns measured %.6f s across a 50 ms sleep (unit error?)" s

let () =
  run "thumper_clock"
    [
      group "clock"
        [
          test "now_ns is non-decreasing over 10k rapid reads"
            now_non_decreasing;
          test "consecutive now_ns reads differ by less than 1 ms"
            resolution_below_1ms;
          test "now_ns tracks a 50 ms wall-clock sleep" tracks_sleep;
        ];
      group "load"
        [
          test "load_average is Some non-negative on this host"
            load_average_some_non_negative;
        ];
    ]
  |> exit
