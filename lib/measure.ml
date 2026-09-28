(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Every clock and counter read of the protocol goes through [instruments],
   so tests can script it; only the fork machinery and the GC discipline
   touch the operating system directly. *)

type instruments = {
  now_ns : unit -> int;
  cpu_ns : unit -> int;
  gc : unit -> Metric.gc_snapshot;
}

let default_instruments =
  {
    now_ns = Thumper_clock.now_ns;
    cpu_ns =
      (fun () ->
        let t = Unix.times () in
        int_of_float ((t.Unix.tms_utime +. t.Unix.tms_stime) *. 1e9));
    gc =
      (fun () ->
        let minor_words, promoted_words, major_words = Gc.counters () in
        let s = Gc.quick_stat () in
        {
          Metric.minor_words;
          promoted_words;
          major_words;
          minor_collections = s.Gc.minor_collections;
          major_collections = s.Gc.major_collections;
        });
  }

type failure =
  | Worker_died of { case : string; detail : string }
  | Case_raised of { case : string; exn : string }
  | Deadline_exceeded of { case : string; deadline : float }

let pp_failure ppf = function
  | Worker_died { case; detail } ->
      Format.fprintf ppf "worker for %s died: %s" case detail
  | Case_raised { case; exn } ->
      Format.fprintf ppf "case %s raised: %s" case exn
  | Deadline_exceeded { case; deadline } ->
      Format.fprintf ppf "case %s exceeded its deadline of %gs" case deadline

(* Constants *)

(* Below 0.2 times the default floor, 1 ms, a clock read is more than 0.01%
   of a batch; at 5 times, 20 samples take the whole 0.5 s case budget
   ([Config.default_deadline]). *)
let frozen_k_window_low = 0.2
let frozen_k_window_high = 5.0
let drift_alpha = 0.01

(* A per-call median under 1 ns is indistinguishable from a constant-folded
   body. *)
let fold_threshold_s = 1e-9

(* A batch of 2^30 calls under the default 5 ms floor is under 5 ps a call,
   far below [fold_threshold_s], so reaching it means the clock is not
   advancing; stopping there keeps calibration from looping forever. *)
let max_calibration_k = 1 lsl 30

(* A trial is a few KB at the presets' sample counts, so the worker's output
   has three orders of magnitude of headroom, and a runaway child still
   cannot exhaust the parent's memory. *)
let parent_read_bound = 16 * 1024 * 1024

(* How long the parent waits to reap a worker it killed. A stopped traced
   worker ignores SIGKILL until its tracer exits (macOS), so an unbounded
   wait would hang the run; past the bound the parent moves on, and the
   worker dies when thumper exits. Elsewhere the reap is immediate. *)
let reap_bound_s = 1.0

(* Raised by the in-process driver at a batch boundary past the deadline. *)
exception Deadline

(* Wraps an exception from the case's own code (setup, the measured function,
   teardown) and nothing else, so a bug in thumper propagates instead of being
   blamed on the case. *)
exception Case_error of exn

let seconds_of_ns ns = float_of_int ns *. 1e-9

let effective_metrics ~config bcase =
  match Bench.metrics bcase with Some ms -> ms | None -> config.Config.metrics

(* The wire protocol *)

module Protocol = struct
  let sanitize s = String.map (function '\n' | '\r' -> ' ' | c -> c) s

  let write buf = function
    | Ok trial ->
        Printf.bprintf buf "k %d\n" (Run.Trial.k trial);
        List.iter
          (fun (m, meas) ->
            match meas with
            | Run.Exact v -> Printf.bprintf buf "exact %s %d\n" (Metric.id m) v
            | Run.Samples s ->
                Printf.bprintf buf "samples %s %d %d" (Metric.id m)
                  (Array.length s.Run.sorted)
                  (if s.Run.drifted then 1 else 0);
                Array.iter (fun x -> Printf.bprintf buf " %h" x) s.Run.sorted;
                Buffer.add_char buf '\n')
          (Run.Trial.measurements trial);
        List.iter
          (fun w -> Printf.bprintf buf "warning %s\n" (sanitize w))
          (Run.Trial.warnings trial);
        Buffer.add_string buf "end\n"
    | Error (Case_raised { exn; _ }) ->
        Printf.bprintf buf "raised %s\n" (sanitize exn)
    | Error (Deadline_exceeded _ | Worker_died _) ->
        invalid_arg
          "Measure.Protocol.write: Deadline_exceeded and Worker_died are \
           parent-side classifications"

  let parse ~case ~metrics content =
    let exception Malformed of string in
    let malformed fmt = Printf.ksprintf (fun d -> raise (Malformed d)) fmt in
    let resolve mid =
      match List.find_opt (fun m -> String.equal (Metric.id m) mid) metrics with
      | Some m -> m
      | None -> malformed "unknown metric %S" mid
    in
    let parse_drifted = function
      | "0" -> false
      | "1" -> true
      | v -> malformed "unparseable drifted flag %S" v
    in
    let parse_metric_line line =
      match String.split_on_char ' ' line with
      | [ "exact"; mid; v ] -> (
          let m = resolve mid in
          match int_of_string_opt v with
          | Some v when v >= 0 -> (m, Run.Exact v)
          | Some v -> malformed "negative exact value %d" v
          | None -> malformed "unparseable exact value %S" v)
      | "samples" :: mid :: count :: drifted :: values ->
          let m = resolve mid in
          let n =
            match int_of_string_opt count with
            | Some n -> n
            | None -> malformed "unparseable sample count %S" count
          in
          let drifted = parse_drifted drifted in
          (* Compare the claimed count against the values actually present
             before materializing anything: a hostile count allocates
             nothing. *)
          if List.length values <> n then
            malformed "sample count %d disagrees with %d values present" n
              (List.length values);
          let sorted =
            Array.of_list
              (List.map
                 (fun v ->
                   match float_of_string_opt v with
                   | Some f -> f
                   | None -> malformed "unparseable sample %S" v)
                 values)
          in
          let s =
            try Run.sampled ~sorted ~drifted
            with Invalid_argument m -> malformed "invalid samples: %s" m
          in
          (m, Run.Samples s)
      | _ -> malformed "unparseable line %S" line
    in
    (* Metric lines, then warning lines, then [end]. *)
    let rec body lines ms ws ~in_warnings =
      match lines with
      | [] -> malformed "truncated output: missing end"
      | "end" :: rest ->
          if rest <> [] then malformed "text after end";
          (List.rev ms, List.rev ws)
      | line :: rest ->
          if String.starts_with ~prefix:"warning " line then
            let w = String.sub line 8 (String.length line - 8) in
            body rest ms (w :: ws) ~in_warnings:true
          else if in_warnings then
            malformed "measurement line after warnings: %S" line
          else body rest (parse_metric_line line :: ms) ws ~in_warnings:false
    in
    try
      let len = String.length content in
      if len = 0 then malformed "empty output";
      if content.[len - 1] <> '\n' then
        malformed "truncated output: no final newline";
      match String.split_on_char '\n' (String.sub content 0 (len - 1)) with
      | [] -> malformed "empty output"
      | first :: rest ->
          if String.starts_with ~prefix:"raised " first then (
            if rest <> [] then malformed "text after raised";
            let exn = String.sub first 7 (String.length first - 7) in
            Error (Case_raised { case; exn }))
          else
            let k =
              match String.split_on_char ' ' first with
              | [ "k"; ks ] -> (
                  match int_of_string_opt ks with
                  | Some k -> k
                  | None -> malformed "unparseable batch size %S" ks)
              | _ -> malformed "expected \"k <int>\", got %S" first
            in
            let ms, warnings = body rest [] [] ~in_warnings:false in
            (* Every id resolved into [metrics] and [Trial.make] rejects
               duplicates, so an equal count is exact cover. *)
            if List.length ms <> List.length metrics then
              malformed "expected %d measurements, got %d" (List.length metrics)
                (List.length ms);
            let trial =
              try Run.Trial.make ~k ~warnings ms
              with Invalid_argument m -> malformed "invalid trial: %s" m
            in
            Ok trial
    with Malformed detail ->
      Error
        (Worker_died { case; detail = "malformed worker output: " ^ detail })
end

(* The protocol driver *)

let gc_param_warnings (before : Gc.control) (after : Gc.control) =
  let changed name proj =
    if proj before <> proj after then
      Some
        (Printf.sprintf "gc parameter %s changed during measurement (%d -> %d)"
           name (proj before) (proj after))
    else None
  in
  List.filter_map Fun.id
    [
      changed "minor_heap_size" (fun (c : Gc.control) -> c.minor_heap_size);
      changed "major_heap_increment" (fun (c : Gc.control) ->
          c.major_heap_increment);
      changed "space_overhead" (fun (c : Gc.control) -> c.space_overhead);
      changed "verbose" (fun (c : Gc.control) -> c.verbose);
      changed "max_overhead" (fun (c : Gc.control) -> c.max_overhead);
      changed "stack_limit" (fun (c : Gc.control) -> c.stack_limit);
      changed "allocation_policy" (fun (c : Gc.control) -> c.allocation_policy);
      changed "window_size" (fun (c : Gc.control) -> c.window_size);
      changed "custom_major_ratio" (fun (c : Gc.control) ->
          c.custom_major_ratio);
      changed "custom_minor_ratio" (fun (c : Gc.control) ->
          c.custom_minor_ratio);
      changed "custom_minor_max_size" (fun (c : Gc.control) ->
          c.custom_minor_max_size);
    ]

(* The readings of the measured phases, before any derivation. *)
type raw = {
  raw_k : int;
  raw_wall : float array; (* per-call seconds, collection order *)
  raw_cpu : float array; (* per-call seconds; [||] unless Cpu_clock asked *)
  raw_gc0 : Metric.gc_snapshot array; (* per-batch counter reads, before *)
  raw_gc1 : Metric.gc_snapshot array; (* per-batch counter reads, after *)
  raw_probe :
    (Metric.gc_snapshot * Metric.gc_snapshot * Metric.gc_snapshot) option;
}

(* [deadline] is the cap the driver checks at batch boundaries: the config's
   in-process, [infinity] in a forked child, whose deadline is the parent's. *)
let measure_case ~instruments ~config ~deadline ~frozen_k bcase =
  let case_id = Bench.id bcase in
  let metrics = effective_metrics ~config bcase in
  let n = config.Config.n in
  let floor_s = config.Config.batch_floor in
  let now = instruments.now_ns in
  let start_ns = now () in
  let deadline_at =
    let d = deadline in
    (* 2^61 ns (73 years) keeps the addition inside a 63-bit int; anything
       larger is operationally uncapped. *)
    if Float.is_finite d && d *. 1e9 < 0x1p61 then
      Some (start_ns + int_of_float (d *. 1e9))
    else None
  in
  let check_deadline () =
    match deadline_at with Some d when now () > d -> raise Deadline | _ -> ()
  in
  let need_cpu =
    List.exists
      (fun m ->
        match Metric.source m with Metric.Cpu_clock -> true | _ -> false)
      metrics
  in
  let need_gc =
    List.exists
      (fun m ->
        match Metric.source m with Metric.Gc_counter _ -> true | _ -> false)
      metrics
  in
  let gc_before = Gc.get () in
  (* The full measured protocol against [run_batch]. *)
  let protocol run_batch =
    let batch_seconds k =
      check_deadline ();
      let t0 = now () in
      run_batch k;
      seconds_of_ns (now () - t0)
    in
    let calibrate () =
      let rec go k =
        if batch_seconds k >= floor_s || k >= max_calibration_k then k
        else go (k * 2)
      in
      go 1
    in
    let k =
      match frozen_k with
      | Some k0 ->
          let t = batch_seconds k0 in
          if
            t >= frozen_k_window_low *. floor_s
            && t <= frozen_k_window_high *. floor_s
          then k0
          else calibrate ()
      | None -> calibrate ()
    in
    let warmup_start = now () in
    let rec warm batches =
      let timed_arm_met =
        seconds_of_ns (now () - warmup_start) >= config.Config.warmup_time
      in
      if batches < config.Config.warmup_batches || not timed_arm_met then (
        check_deadline ();
        run_batch k;
        warm (batches + 1))
    in
    warm 0;
    Gc.full_major ();
    let kf = float_of_int k in
    let wall = Array.make n 0. in
    let cpu = if need_cpu then Array.make n 0. else [||] in
    let dummy =
      {
        Metric.minor_words = 0.;
        promoted_words = 0.;
        major_words = 0.;
        minor_collections = 0;
        major_collections = 0;
      }
    in
    let gc0 = if need_gc then Array.make n dummy else [||] in
    let gc1 = if need_gc then Array.make n dummy else [||] in
    (* The read order keeps the timed region clean. The wall-clock reads
       straddle only [run_batch k], whose constant overhead (one closure
       entry, the [Sys.opaque_identity] of the closure and its environment)
       the batch floor amortizes; the cpu reads sit just outside them, and the
       counter reads are outermost. The clock reads allocate nothing, so a
       counter interval holds only the [c1] read's [Unix.times] record and the
       counter reads' own constant tail: a per-batch constant, the same at the
       same frozen k on both sides of a comparison. All derived arithmetic
       runs after the last read. *)
    for i = 0 to n - 1 do
      check_deadline ();
      let c0 = if need_cpu then instruments.cpu_ns () else 0 in
      if need_gc then gc0.(i) <- instruments.gc ();
      let t0 = now () in
      run_batch k;
      let t1 = now () in
      let c1 = if need_cpu then instruments.cpu_ns () else 0 in
      if need_gc then gc1.(i) <- instruments.gc ();
      wall.(i) <- seconds_of_ns (t1 - t0) /. kf;
      if need_cpu then cpu.(i) <- seconds_of_ns (c1 - c0) /. kf
    done;
    check_deadline ();
    (* The exactness probe diffs the counters around batches of k and 2k
       calls, so the harness constant cancels. Between the [a] and [c] reads
       nothing may allocate but the two batches and the counter reads
       themselves: a few words landing in one interval and not the other are
       an asymmetry the differencing cannot cancel, which fails the probe for
       every deterministic case at k >= 4 and silently inflates the exact
       count at k <= 3. The deadline check allocates nothing, so it runs
       around these batches too. *)
    let probe =
      if need_gc then (
        let a = instruments.gc () in
        run_batch k;
        let b = instruments.gc () in
        check_deadline ();
        run_batch (2 * k);
        let c = instruments.gc () in
        check_deadline ();
        Some (a, b, c))
      else None
    in
    {
      raw_k = k;
      raw_wall = wall;
      raw_cpu = cpu;
      raw_gc0 = gc0;
      raw_gc1 = gc1;
      raw_probe = probe;
    }
  in
  (* Run the protocol with case-code exceptions tagged and teardown
     guaranteed on every path. *)
  let outcome =
    match
      let prepared = try Bench.prepare bcase with e -> raise (Case_error e) in
      let run_batch k =
        try prepared.Bench.run_batch k with e -> raise (Case_error e)
      in
      match protocol run_batch with
      | raw ->
          (* Success: teardown runs and may still fail the case. *)
          (try prepared.Bench.teardown () with e -> raise (Case_error e));
          raw
      | exception e ->
          (* A failure is in flight: teardown still runs, and its own error
             must not mask the first failure. *)
          (try prepared.Bench.teardown () with _ -> ());
          raise e
    with
    | raw -> Ok raw
    | exception Deadline ->
        Error (Deadline_exceeded { case = case_id; deadline })
    | exception Case_error e ->
        Error (Case_raised { case = case_id; exn = Printexc.to_string e })
  in
  match outcome with
  | Error _ as e -> e
  | Ok raw ->
      let gc_changes = gc_param_warnings gc_before (Gc.get ()) in
      let kf = float_of_int raw.raw_k in
      let warnings = ref [] in
      let warn w = warnings := w :: !warnings in
      (* The fold check reads the batch times, which exist whether or not
         wall_time is collected. *)
      let sorted_wall = Array.copy raw.raw_wall in
      Array.sort Float.compare sorted_wall;
      let wall_median = Stats.median_sorted sorted_wall in
      if wall_median < fold_threshold_s then
        warn
          (Printf.sprintf
             "wall_time %.3g ns/call: possibly folded: wrap the input in \
              black_box"
             (wall_median *. 1e9));
      (* Drift is the one quality flag that needs the collection order, so it
         is computed here, before sorting; judgment derives the rest from the
         sorted vector. *)
      let sampled_of collection =
        let drifted = Stats.drifted ~alpha:drift_alpha collection in
        let sorted = Array.copy collection in
        Array.sort Float.compare sorted;
        Run.sampled ~sorted ~drifted
      in
      let probe_exact m proj =
        match raw.raw_probe with
        | None -> None
        | Some (sa, sb, sc) ->
            let dk = proj sb -. proj sa and d2k = proj sc -. proj sb in
            (* Every built-in projection is a non-decreasing function of
               non-decreasing counters, so a negative interval is a broken
               instrument, not data. Refuse it before the differencing hides
               it: dk = 3, d2k = 2 at k = 1 would give an exact -1 with a
               consistent h. *)
            if dk < 0. || d2k < 0. then
              invalid_arg
                (Printf.sprintf
                   "Measure: %s decreased across a probe batch (deltas %g, \
                    %g); instrument counters must be non-decreasing"
                   (Metric.id m) dk d2k);
            (* The counters are floats holding whole numbers, exact below
               2^53, so these differences are exact. *)
            let diff = d2k -. dk in
            let quotient = Float.floor (diff /. kf) in
            let residue = diff -. (kf *. quotient) in
            let a = quotient in
            let h = dk -. (kf *. a) and h2 = d2k -. (2. *. kf *. a) in
            (* Monotone counters can still give a consistent negative slope
               (a 2k batch allocating less in total than the k batch, as an
               allocator with warm-up or phase behavior does): that is
               nondeterminism, so [a < 0.] stays sampled. *)
            if residue < 1. && residue >= 0. && a >= 0. && h = h2 && h >= 0.
            then Some (int_of_float a)
            else (
              warn
                (Printf.sprintf
                   "%s: exactness probe failed: batch deltas %g (k=%d) and %g \
                    (2k=%d) give per-call %g words with harness h %g vs %g; \
                    treating as sampled"
                   (Metric.id m) dk raw.raw_k d2k (2 * raw.raw_k) (diff /. kf) h
                   h2);
              None)
      in
      let measurements =
        List.map
          (fun m ->
            match Metric.source m with
            | Metric.Wall_clock -> (m, Run.Samples (sampled_of raw.raw_wall))
            | Metric.Cpu_clock -> (m, Run.Samples (sampled_of raw.raw_cpu))
            | Metric.Gc_counter proj -> (
                match probe_exact m proj with
                | Some v -> (m, Run.Exact v)
                | None ->
                    let collection =
                      Array.init n (fun i ->
                          (proj raw.raw_gc1.(i) -. proj raw.raw_gc0.(i)) /. kf)
                    in
                    (m, Run.Samples (sampled_of collection))))
          metrics
      in
      let warnings = List.rev !warnings @ gc_changes in
      Ok (Run.Trial.make ~k:raw.raw_k ~warnings measurements)

(* The fork worker *)

let rec waitpid_retry pid =
  match Unix.waitpid [] pid with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_retry pid

(* [Unix.WSIGNALED] carries OCaml's internal signal numbers (negative), which
   mean nothing to a reader; render the conventional name. *)
let signal_name s =
  let names =
    [
      (Sys.sigabrt, "SIGABRT");
      (Sys.sigalrm, "SIGALRM");
      (Sys.sigbus, "SIGBUS");
      (Sys.sigfpe, "SIGFPE");
      (Sys.sighup, "SIGHUP");
      (Sys.sigill, "SIGILL");
      (Sys.sigint, "SIGINT");
      (Sys.sigkill, "SIGKILL");
      (Sys.sigpipe, "SIGPIPE");
      (Sys.sigquit, "SIGQUIT");
      (Sys.sigsegv, "SIGSEGV");
      (Sys.sigterm, "SIGTERM");
      (Sys.sigusr1, "SIGUSR1");
      (Sys.sigusr2, "SIGUSR2");
      (Sys.sigxcpu, "SIGXCPU");
      (Sys.sigxfsz, "SIGXFSZ");
    ]
  in
  match List.assoc_opt s names with
  | Some n -> n
  | None -> Printf.sprintf "signal %d" s

(* [Unix._exit], not [exit]: the child runs no [at_exit] and flushes no
   channel it shares with the parent. *)
let run_child ~instruments ~config ~frozen_k bcase w =
  let code =
    try
      let null = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
      Unix.dup2 null Unix.stdin;
      Unix.close null;
      let result =
        measure_case ~instruments ~config ~deadline:infinity ~frozen_k bcase
      in
      let buf = Buffer.create 1024 in
      Protocol.write buf result;
      Os.write_all w (Buffer.contents buf);
      (try Unix.close w with Unix.Unix_error _ -> ());
      0
    with e ->
      prerr_endline ("thumper: worker: " ^ Printexc.to_string e);
      125
  in
  Unix._exit code

(* The reads are bounded in size, and in time under a finite deadline, so a
   runaway or hung worker cannot wedge the run. *)
let parent_collect ~deadline_s ~case pid r =
  let chunk = Bytes.create 65536 in
  let buf = Buffer.create 4096 in
  let deadline_at = Option.map (fun s -> Os.monotonic_s () +. s) deadline_s in
  let kill_and_reap () =
    (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
    let until = Os.monotonic_s () +. reap_bound_s in
    let rec reap () =
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ ->
          if Os.monotonic_s () < until then (
            Unix.sleepf 0.005;
            reap ())
      | _ -> ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap ()
    in
    reap ()
  in
  let rec wait_readable () =
    let timeout =
      match deadline_at with None -> -1. | Some d -> d -. Os.monotonic_s ()
    in
    if timeout <= 0. && deadline_at <> None then
      (* Past the deadline: take anything already delivered, else hung. *)
      match Unix.select [ r ] [] [] 0. with
      | [], _, _ -> `Timeout
      | _ -> `Readable
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_readable ()
    else
      match Unix.select [ r ] [] [] timeout with
      | [], _, _ -> wait_readable ()
      | _ -> `Readable
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_readable ()
  in
  let rec drain () =
    match wait_readable () with
    | `Timeout -> `Timeout
    | `Readable -> (
        match Unix.read r chunk 0 (Bytes.length chunk) with
        | 0 -> `Eof
        | n ->
            Buffer.add_subbytes buf chunk 0 n;
            if Buffer.length buf > parent_read_bound then `Oversized
            else drain ()
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> drain ())
  in
  let result = drain () in
  (try Unix.close r with Unix.Unix_error _ -> ());
  match result with
  | `Timeout ->
      kill_and_reap ();
      `Failure
        (Deadline_exceeded
           { case; deadline = Option.value deadline_s ~default:infinity })
  | `Oversized ->
      kill_and_reap ();
      `Failure
        (Worker_died
           {
             case;
             detail =
               Printf.sprintf "output exceeded %d bytes" parent_read_bound;
           })
  | `Eof -> (
      match waitpid_retry pid with
      | Unix.WEXITED 0 -> `Parse (Buffer.contents buf)
      | Unix.WEXITED c ->
          `Failure
            (Worker_died
               { case; detail = Printf.sprintf "exited with code %d" c })
      | Unix.WSIGNALED s ->
          `Failure
            (Worker_died
               { case; detail = Printf.sprintf "killed by %s" (signal_name s) })
      | Unix.WSTOPPED s ->
          (* Only a traced worker reports a stop here ([waitpid] has no
             [WUNTRACED]): kill it, so no stopped worker outlives the run. *)
          kill_and_reap ();
          `Failure
            (Worker_died
               { case; detail = Printf.sprintf "stopped by %s" (signal_name s) })
      )

let case_forked ~instruments ~config ~frozen_k bcase =
  let case = Bench.id bcase in
  let r, w = Unix.pipe () in
  match Unix.fork () with
  | exception e -> (
      (* No child exists: close both pipe ends, or a run that cannot fork
         leaks two fds per failed case. The runtime refuses to fork once the
         process has spawned a domain; its message states the rule. *)
      (try Unix.close r with Unix.Unix_error _ -> ());
      (try Unix.close w with Unix.Unix_error _ -> ());
      match e with
      | Failure msg -> Error (Worker_died { case; detail = msg })
      | Unix.Unix_error (err, fn, _) ->
          Error
            (Worker_died { case; detail = fn ^ ": " ^ Unix.error_message err })
      | e -> raise e)
  | 0 ->
      (try Unix.close r with Unix.Unix_error _ -> ());
      run_child ~instruments ~config ~frozen_k bcase w
  | pid -> (
      Unix.close w;
      let deadline_s =
        let d = config.Config.deadline in
        if Float.is_finite d then Some d else None
      in
      match parent_collect ~deadline_s ~case pid r with
      | `Failure f -> Error f
      | `Parse content ->
          let metrics = effective_metrics ~config bcase in
          Protocol.parse ~case ~metrics content)

(* Entry point *)

let case ?(instruments = default_instruments) ~config ~frozen_k bcase =
  (match frozen_k with
  | Some k when k < 1 -> invalid_arg "Measure.case: frozen_k must be >= 1"
  | Some _ | None -> ());
  if config.Config.fork then case_forked ~instruments ~config ~frozen_k bcase
  else
    measure_case ~instruments ~config ~deadline:config.Config.deadline ~frozen_k
      bcase
