(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let strf = Printf.sprintf

type error =
  | Lock of Env.Lock.error
  | Measurement of Measure.failure
  | Empty_selection
  | Invalid_suite of Bench.error

exception Error of error

let pp_error ppf = function
  | Lock e -> Env.Lock.pp_error ppf e
  | Measurement f -> Measure.pp_failure ppf f
  | Empty_selection ->
      Format.pp_print_string ppf "no case matches the selection"
  | Invalid_suite e -> Bench.pp_error ppf e

(* An error that escapes a program prints as the facade names it, with its
   text, not as the internal constructor. *)
let () =
  Printexc.register_printer (function
    | Error e -> Some (Format.asprintf "Thumper.Check.Error: %a" pp_error e)
    | _ -> None)

let error e = raise (Error e)

type progress = {
  phase : [ `Measuring | `Confirming ];
  index : int;
  total : int;
  case : string;
}

let select ?filter ~metrics ~budgets benches =
  match Bench.resolve benches with
  | Error e -> error (Invalid_suite e)
  | Ok all -> (
      (match Bench.check_collected ~metrics ~budgets benches with
      | Error e -> error (Invalid_suite e)
      | Ok () -> ());
      let selected =
        match filter with
        | None -> all
        | Some f -> List.filter (Bench.matches f) all
      in
      match selected with
      | [] -> error Empty_selection
      | _ :: _ ->
          let selection =
            if List.length selected = List.length all then `Full else `Partial
          in
          (selected, selection))

(* [Verdict] reads a case's frozen batch size with the same
   [Baseline.case_frozen_k], so the batch size measured is the one judged. *)
let frozen_k section ~id =
  Option.bind section (fun s -> Baseline.case_frozen_k s ~id)

(* A failure ends the run in either sweep. In the first, a verdict over fewer
   cases than were selected would, under a full selection, prune the failed
   cases' rows from the corrected file. In the second, [Verdict.decide] reads a
   missing trial as unconfirmed, which exits 0: a dead worker must not pass. *)
let measured ?instruments ~config ~frozen_k case =
  match Measure.case ?instruments ~config ~frozen_k case with
  | Ok trial -> trial
  | Error f -> error (Measurement f)

let under_lock f =
  match Env.Lock.with_lock f with Ok v -> v | Error e -> error (Lock e)

let tick on_progress ~phase ~total ~index case =
  on_progress { phase; index; total; case = Bench.id case }

let measure ?instruments ?(on_progress = ignore) ?(config = Config.default)
    ?filter benches =
  let selected, _selection =
    select ?filter ~metrics:config.Config.metrics ~budgets:[] benches
  in
  let total = List.length selected in
  under_lock (fun () ->
      Run.create
        (List.mapi
           (fun i case ->
             tick on_progress ~phase:`Measuring ~total ~index:(i + 1) case;
             (Bench.id case, measured ?instruments ~config ~frozen_k:None case))
           selected))

(* [Baseline.of_string] accepts the empty string. *)
let empty_file =
  match Baseline.of_string "" with Ok f -> f | Error _ -> assert false

let run_with ?instruments ?load:(sample_load = Env.load) ?(on_progress = ignore)
    ?(config = Config.default) ?(budgets = []) ?(prune = false) ?filter
    ?baseline:(file = empty_file) name benches =
  Baseline.check_suite ~fname:"Thumper.Check.run" name;
  Budget.check_distinct ~fname:"Thumper.Check.run" budgets;
  let selected, selection =
    select ?filter ~metrics:config.Config.metrics ~budgets benches
  in
  (* Only a caller that holds the whole suite may judge a selection of every
     case as full, which prunes the rows of cases [benches] lacks. *)
  let selection = if prune then selection else `Partial in
  let identity =
    {
      Baseline.machine = Env.machine_key ();
      host = Env.host_description ();
      ocaml = Env.ocaml_identity ();
    }
  in
  (* Before the lock: a programmer error must neither wait on a holder nor
     spend a sweep before it raises. *)
  (match Baseline.suite file with
  | Some s when not (String.equal s name) ->
      invalid_arg
        (strf
           "Thumper.Check.run: baseline is for suite %s, not %s; pass this \
            suite's file, or update its '# suite:' header if the suite was \
            renamed"
           (Baseline.quote s) (Baseline.quote name))
  | _ -> ());
  (* Batch sizes are frozen from the section judgment compares against: a
     stale one is re-recorded from this run, so it pins nothing. *)
  let section = Verdict.compared_section ~identity file in
  under_lock (fun () ->
      let start_load = sample_load () in
      let total = List.length selected in
      let cases =
        List.mapi
          (fun i case ->
            tick on_progress ~phase:`Measuring ~total ~index:(i + 1) case;
            let frozen_k = frozen_k section ~id:(Bench.id case) in
            (case, measured ?instruments ~config ~frozen_k case))
          selected
      in
      let provisional =
        Verdict.judge ~identity ~suite:name ~load:start_load ~selection ~budgets
          ~file ~cases
      in
      match Verdict.confirmations provisional with
      | [] ->
          (* No second sample: with nothing pending, the load changes nothing. *)
          Verdict.decide ~load:start_load ~confirmations:[] provisional
      | queue -> (
          match sample_load () with
          | Env.Loaded _ as loaded ->
              (* [decide] would discard the confirmations of a loaded host. *)
              Verdict.decide ~load:loaded ~confirmations:[] provisional
          | Env.Quiet as quiet ->
              let total = List.length queue in
              let confirmations =
                List.mapi
                  (fun i id ->
                    match
                      List.find_opt
                        (fun (c, _) -> String.equal (Bench.id c) id)
                        cases
                    with
                    | Some (case, trial) ->
                        tick on_progress ~phase:`Confirming ~total
                          ~index:(i + 1) case;
                        (* One protocol for both trials of a case. *)
                        ( id,
                          measured ?instruments ~config
                            ~frozen_k:(Some (Run.Trial.k trial))
                            case )
                    | None ->
                        (* The queue is a subset of the judged cases
                           ([Verdict.confirmations]'s contract). *)
                        assert false)
                  queue
              in
              Verdict.decide ~load:quiet ~confirmations provisional))

(* The seams cannot be optional arguments of [run] itself: the facade exports
   [run] with a type that has none, and a signature constraint cannot remove an
   optional argument from a value's type. *)
let run ?config ?budgets ?filter ?baseline name benches =
  run_with ?config ?budgets ?filter ?baseline name benches
