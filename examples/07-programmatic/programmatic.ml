(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

open Thumper

let input = List.init 1_000 Fun.id

let suite =
  [
    bench "rev" (fun () -> List.rev input);
    bench "sum" (fun () -> List.fold_left ( + ) 0 input);
  ]

let file = "programmatic.thumper"

let print_evidence () =
  let run = measure ~config:Config.quick suite in
  List.iter
    (fun case ->
      let median =
        match Run.samples run ~case Metric.wall_time with
        | Some s -> Printf.sprintf "%.1f ns" (1e9 *. s.(Array.length s / 2))
        | None -> "-"
      in
      let alloc =
        match Run.exact run ~case Metric.alloc_words with
        | Some w -> Printf.sprintf "%d w" w
        | None -> "-"
      in
      Printf.printf "%s: %s, %s\n" case median alloc)
    (Run.case_ids run)

let check () =
  let baseline = Baseline.read_exn file in
  let v = Check.run ?baseline "programmatic" suite in
  print_endline (Verdict.to_json v);
  exit (Verdict.exit_code v)

let bless () =
  let baseline = Baseline.read_exn file in
  let run = measure suite in
  Baseline.write file (Baseline.record ?baseline "programmatic" run)

let () =
  match Sys.argv with
  | [| _; "bless" |] -> bless ()
  | _ ->
      print_evidence ();
      check ()
