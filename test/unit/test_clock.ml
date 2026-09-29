(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The stubs are the subject, so every test reads the real clock and the real
   host. What load can move is never asserted: the clock is compared with the
   wall clock over one interval, which both see whole whatever the scheduler
   does, and the load average is only checked for its sign. *)

open Windtrap

(* The index and the two readings of the first decrease, if any. *)
let first_decrease reads =
  let rec find i =
    if i >= Array.length reads then None
    else if reads.(i) < reads.(i - 1) then Some (i, reads.(i - 1), reads.(i))
    else find (i + 1)
  in
  find 1

let now_ns_never_decreases () =
  let reads = Array.init 10_000 (fun _ -> Thumper_clock.now_ns ()) in
  equal (option (triple int int int)) None (first_decrease reads)

(* The step between two readings that differ, the smallest over many steps,
   since a reading can be descheduled; a clock that never moves hangs here
   until the test's limit. *)
let now_ns_resolves_below_1ms () =
  let step () =
    let a = Thumper_clock.now_ns () in
    let rec next () =
      let b = Thumper_clock.now_ns () in
      if b = a then next () else b - a
    in
    next ()
  in
  let smallest = ref (step ()) in
  for _ = 1 to 1_000 do
    smallest := Int.min !smallest (step ())
  done;
  less ~msg:"ns between two readings" int ~than:1_000_000 !smallest

(* A wall-clock reading and the monotonic readings either side of it, retried
   until they are less than 100 us apart. *)
let paired () =
  let rec attempt n =
    if n = 0 then skip ~reason:"no two readings less than 100 us apart" ();
    let before = Thumper_clock.now_ns () in
    let wall = Unix.gettimeofday () in
    let after = Thumper_clock.now_ns () in
    if after - before < 100_000 then (before + ((after - before) / 2), wall)
    else attempt (n - 1)
  in
  attempt 1_000

(* A ticks-for-nanoseconds error in the stubs, such as a dropped mach timebase
   (24 MHz ticks on Apple Silicon, 41.67 times too few), passes the two tests
   above. Both clocks read the same interval, however long the scheduler makes
   the sleep, and the pairing bounds their disagreement by 0.2 ms against 10%
   of 20 ms. *)
let now_ns_counts_nanoseconds () =
  let mono0, wall0 = paired () in
  Unix.sleepf 0.02;
  let mono1, wall1 = paired () in
  equal
    (float_rel ~rel:0.1 ~abs:0.)
    (wall1 -. wall0)
    (float_of_int (mono1 - mono0) *. 1e-9)

let load_average_is_non_negative () =
  match Thumper_clock.load_average () with
  | None -> skip ~reason:"the host reports no load average" ()
  | Some l -> at_least float_exact ~than:0. l

(* The lines [prog] prints, or none if it cannot run. *)
let lines prog args =
  match Unix.open_process_args_in prog (Array.of_list (prog :: args)) with
  | exception Unix.Unix_error _ -> []
  | ic ->
      let lines = In_channel.input_lines ic in
      ignore (Unix.close_process_in ic);
      lines

(* ioreg reads the hardware UUID from the I/O Registry, apart from
   [gethostuuid(2)]. *)
let host_uuid_is_the_hardware_uuid () =
  let expected =
    match lines "uname" [ "-s" ] with
    | [ "Darwin" ] ->
        List.find_map
          (fun line ->
            match String.split_on_char '"' line with
            | [ _; "IOPlatformUUID"; _; uuid; _ ] -> Some uuid
            | _ -> None)
          (lines "/usr/sbin/ioreg" [ "-rd1"; "-c"; "IOPlatformExpertDevice" ])
    | _ -> None
  in
  equal (option string) expected (Thumper_clock.host_uuid ())

let () =
  exit
    (run "thumper_clock"
       [
         test "now_ns never decreases over 10k readings" now_ns_never_decreases;
         test ~timeout:10. "now_ns resolves below 1 ms"
           now_ns_resolves_below_1ms;
         test "now_ns counts nanoseconds, as the wall clock does"
           now_ns_counts_nanoseconds;
         test "load_average is non-negative when the host reports one"
           load_average_is_non_negative;
         test ~timeout:10.
           "host_uuid is the hardware UUID on Darwin and None elsewhere"
           host_uuid_is_the_hardware_uuid;
       ])
