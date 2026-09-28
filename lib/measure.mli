(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The measurement protocol: one case in, one trial out.

    {!case} measures a case and is its {!Run.Trial.t} or the {!type:failure}
    that stopped it. It reads every clock and counter through
    {!type:instruments}, which a caller may replace with scripted readings. It
    runs each case in a forked worker that reports over a pipe ({!Protocol}), or
    in the calling process when [config.fork] is [false] ({!Config.val-fork}).
    It knows nothing of baselines ([frozen_k] arrives as a number), budgets or
    verdicts, and its caller holds the measurement lock. *)

(** {1:instruments Instruments} *)

type instruments = {
  now_ns : unit -> int;  (** A monotonic clock, in nanoseconds. *)
  cpu_ns : unit -> int;
      (** The process's CPU time, user plus system, in nanoseconds. *)
  gc : unit -> Metric.gc_snapshot;
      (** The runtime's cumulative word counts and collection counts. *)
}
(** The type for the readings the protocol takes. Successive readings of
    [now_ns], of [cpu_ns] and of each [gc] counter must never decrease.

    {!case} checks only the counter metrics it collects, across its probe
    batches. A decrease raises [Invalid_argument] in-process, and in a forked
    worker it ends the case as {!Worker_died}. A clock that runs backwards is
    not refused: its negative samples reach judgment, which reads them as a
    non-positive sample. A scripted [now_ns] must advance, since warmup waits
    for [warmup_time] to pass on it. With [warmup_time > 0.], a clock that never
    advances hangs {!case}; a forked worker is killed at a finite
    [config.deadline]. Calibration stops doubling at 2{^ 30} calls per batch, so
    a stuck clock costs 31 calibration batches. *)

val default_instruments : instruments
(** [default_instruments] reads {!Thumper_clock.now_ns}, [Unix.times] truncated
    to whole nanoseconds (its resolution is the operating system's), and
    [Gc.counters] with [Gc.quick_stat]. *)

(** {1:failures Failures} *)

(** The type for why a case has no trial. [case] is the case id. *)
type failure =
  | Worker_died of { case : string; detail : string }
      (** The worker could not be forked, exited abnormally, was killed, or
          wrote a report that {!Protocol.parse} refuses or that is longer than
          16 MiB. [detail] says which: [exited with code <c>],
          [killed by <signal>], [stopped by <signal>],
          [output exceeded 16777216 bytes],
          [malformed worker output: <deviation>], or for a refused fork the
          runtime's message or [fork: <reason>]. The runtime refuses to fork
          once the program has spawned a domain. *)
  | Case_raised of { case : string; exn : string }
      (** The case's setup, measured function or teardown raised, and [exn] is
          [Printexc.to_string] of the exception. From a forked worker, its
          newlines and carriage returns are spaces. *)
  | Deadline_exceeded of { case : string; deadline : float }
      (** The case did not complete within [deadline] seconds
          ({!Config.val-deadline}). No partial trial is kept, since the sample
          count is part of the protocol. *)

val pp_failure : Format.formatter -> failure -> unit
(** [pp_failure ppf f] formats [f] for users: [worker for <id> died: <detail>],
    [case <id> raised: <exn>] or [case <id> exceeded its deadline of <s>s]. The
    command line prints it on stderr after [thumper: ] and exits 2, whether or
    not stderr is a terminal, with [--json] or without. *)

(** {1:measuring Measuring} *)

val case :
  ?instruments:instruments ->
  config:Config.t ->
  frozen_k:int option ->
  Bench.case ->
  (Run.Trial.t, failure) result
(** [case ~config ~frozen_k c] is the trial of [c] measured under [config], or
    the failure that stopped it. It measures {!Bench.metrics} of [c], else
    [config.metrics], with one measurement per metric in that order.
    [instruments] defaults to {!default_instruments}.

    The protocol runs these steps:
    + Calibration. With [frozen_k = Some k], one batch of [k] calls is timed,
      and [k] is kept if the batch took between 0.2 and 5 times
      [config.batch_floor], both included. Otherwise, and with [None], [k]
      doubles from 1 until one batch lasts [config.batch_floor] or [k] reaches
      2{^ 30}. [Verdict] compares {!Run.Trial.k} with the baseline row's batch
      size, and a confirmation measured at a [k] other than its first trial's
      leaves the relation unconfirmed ([Verdict.decide]).
    + Warmup. Batches of [k] calls are discarded until [config.warmup_time] has
      passed and [config.warmup_batches] batches have run.
    + One [Gc.full_major], after which the GC runs freely.
    + Sampling. Each of [config.n] batches gives every sampled metric one
      per-call sample, its interval over the batch divided by [k]. Each vector
      is tested for drift in collection order ({!Stats.drifted} at [0.01]), then
      sorted.
    + The exactness probe, when a counter metric is collected. The counters are
      read around one batch of [k] calls and one of [2k], with deltas [dk] and
      [d2k]. A metric is exact with [a] per call iff [d2k -. dk = float k *. a]
      for a whole [a >= 0.] and [dk -. float k *. a >= 0.]. The differencing
      cancels [dk -. float k *. a], a batch's constant overhead, so [k = 1]
      proves a deterministic case exact. A metric whose probe fails stays
      sampled, from its sampling batches.

    The trial's warnings are, in order: a median wall time under 1 ns per call
    ([possibly folded]), each failed probe in metric order, and each GC
    parameter that differs after teardown from its value before setup. Nothing
    judges them.

    Forked ([config.fork], the default), the whole protocol, setup and teardown
    included, runs in a child whose stdin is [/dev/null], and the child reports
    in {!Protocol}'s grammar. The parent bounds its wait by [config.deadline]
    from the fork, on [Os.monotonic_s], and kills the child when it passes: a
    call that never returns becomes [Deadline_exceeded], and the child runs no
    teardown. The child never checks a deadline.

    In-process ([config.fork = false]), the protocol runs on the calling
    process's heap. The deadline is read on [instruments.now_ns] from before
    setup, and checked between batches, and after the last one: a batch runs to
    its end, so a call that never returns hangs the run, and a crash ends it.

    The teardown runs once after setup completes, whatever the protocol does,
    unless the process running it dies first: a forked worker killed at its
    deadline runs none. If it raises after the protocol completed, the case
    fails with [Case_raised]; if it raises while another failure is in flight,
    its exception is dropped.

    Raises [Invalid_argument] if [frozen_k] is [Some k] with [k < 1], and,
    in-process, if a counter decreases across the probe batches; that raise
    comes after the teardown has run. In-process, an exception from thumper's
    own code escapes too; forked, it ends the child with exit code 125 after the
    child prints [thumper: worker: <exception>] on stderr. Raises
    [Unix.Unix_error] if the pipe to a forked worker cannot be created. *)

(** {1:protocol The worker pipe protocol}

    A forked worker reports to its parent in lines, each ended by ['\n']:
    {v
    k <int>
    exact <metric-id> <int>
    samples <metric-id> <n> <drifted> <h1> ... <hn>
    warning <text>
    end
    v}
    A trial is a [k] line, one [exact] or [samples] line per metric, the
    [warning] lines, then [end]. [<drifted>] is [0] or [1]. The samples are
    ascending, printed as [%h] hexadecimal floats, which read back to the same
    values. A case that raised is the one line [raised <text>]. *)

module Protocol : sig
  val write : Buffer.t -> (Run.Trial.t, failure) result -> unit
  (** [write b r] appends [r]'s report to [b]. Newlines and carriage returns in
      a warning or exception text become spaces.

      Raises [Invalid_argument] on [Error (Worker_died _)] and
      [Error (Deadline_exceeded _)], which only the parent produces. *)

  val parse :
    case:string ->
    metrics:Metric.t list ->
    string ->
    (Run.Trial.t, failure) result
  (** [parse ~case ~metrics s] is the result that [s] reports for the case with
      id [case]. [s] must report each metric of [metrics] once, and no other
      metric. Any deviation is [Error (Worker_died _)], never an exception, with
      a [detail] of [malformed worker output: ] and the deviation: an unknown,
      missing or repeated metric, a negative exact count, a sample count that
      disagrees with the values present, evidence that {!Run.val-sampled} or
      {!Run.Trial.make} refuses, a measurement line after a warning, text after
      [end] or [raised], or truncated output. A sample count is compared with
      the values present before any array is built. The order of the metric
      lines is not checked. *)
end
