(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The check loop: selecting cases, then measuring, judging, confirming and
    deciding under the measurement lock.

    {!run} is the loop and {!run_with} the same loop with its host seams
    exposed; {!measure} measures without judging, and {!select} is the selection
    all three make. {!Verdict} decides every relation and {!Measure} measures
    one case; this module owns the order between them: when the load is sampled,
    which batch size each trial is frozen at, and when the confirmation sweep is
    skipped. It reads and writes no baseline or JSON file; through {!Env} it
    takes the lock, whose file it writes, and reads host facts. *)

(** {1:errors Errors}

    An error stops the run without a verdict. *)

(** The type for operational failures. *)
type error =
  | Lock of Env.Lock.error
      (** The measurement lock timed out or its file is unusable. The command
          line takes the lock before calling this module, so only a library
          caller meets it. *)
  | Measurement of Measure.failure
      (** A case could not be measured, because its worker died, the case, its
          setup or its teardown raised, or it passed its deadline. The first
          failure ends the run, in either sweep. *)
  | Empty_selection  (** The filter selects no case, or the suite has none. *)
  | Invalid_suite of Bench.error
      (** {!Bench.resolve} or {!Bench.check_collected} refused the suite because
          two cases share an id or a budget names a metric its scope does not
          collect. The whole suite is checked before the filter, so a filter
          never hides the defect. *)

exception Error of error
(** Raised by {!select}, {!run}, {!run_with} and {!measure}. A printer
    registered by this module prints an uncaught [Error e] as
    [Thumper.Check.Error: ] followed by {!pp_error}'s text. *)

val pp_error : Format.formatter -> error -> unit
(** [pp_error ppf e] formats [e] for users: the text of the lock error, of the
    measurement failure or of the suite error, and
    [no case matches the selection] for [Empty_selection]. *)

(** {1:progress Progress} *)

type progress = {
  phase : [ `Measuring | `Confirming ];
      (** [`Measuring] in the first sweep, [`Confirming] in the confirmation
          sweep. *)
  index : int;  (** The case's 1-based position in the sweep. *)
  total : int;  (** The number of cases in the sweep. *)
  case : string;  (** The case id. *)
}
(** The type for progress ticks. A sweep reports one tick per case, immediately
    before measuring it, so the last tick names the case being measured. A tick
    carries no measurement. Its consumer runs under the lock, before each case,
    and an exception it raises ends the run. *)

(** {1:selecting Selecting} *)

val select :
  ?filter:Bench.filter ->
  metrics:Metric.t list ->
  budgets:Budget.t list ->
  Bench.t list ->
  Bench.case list * [ `Full | `Partial ]
(** [select ?filter ~metrics ~budgets benches] is the cases of [benches] that
    [filter] selects, all of them without a filter, in the order of
    {!Bench.resolve}, and [`Full] iff they are every case of the suite, else
    [`Partial]. A [`Full] selection lets {!Verdict.corrected} prune the rows of
    cases the suite no longer has, when the caller holds the whole suite
    ({!run_with}'s [prune]). [metrics] and [budgets] are the run's, for
    {!Bench.check_collected}. It measures nothing and takes no lock, so a caller
    that takes the lock itself can select first, and a broken suite or filter
    then fails without waiting.

    Raises [Error (Invalid_suite _)] if {!Bench.resolve} or
    {!Bench.check_collected} refuses [benches], and [Error Empty_selection] if
    no case is selected. *)

(** {1:checking Checking} *)

val run :
  ?config:Config.t ->
  ?budgets:Budget.t list ->
  ?filter:Bench.filter ->
  ?baseline:Baseline.t ->
  string ->
  Bench.t list ->
  Verdict.t
(** [run ?config ?budgets ?filter ?baseline name benches] measures the cases of
    [benches] that [filter] selects, judges them against this machine's section
    of [baseline], and is the decided verdict. In order, it:
    + checks [name] ({!Baseline.check_suite}) and [budgets]
      ({!Budget.check_distinct}), selects the cases ({!select}, with [config]'s
      metrics and [budgets]), reads the machine key ({!Env.machine_key}), and
      checks that [baseline]'s suite header, if it has one, is [name].
      {!Verdict.judge} relies on these checks.
    + takes the measurement lock and samples the load.
    + measures each selected case ({!Measure.case}) at the batch size
      {!Baseline.case_frozen_k} reads from this machine's section when that
      section is compared ({!Verdict.compared_section}); a missing or stale
      section, or a case without a sampled row, freezes nothing. {!Measure.case}
      reuses a frozen batch size only while its batch time stays within [0.2] to
      [5] times the batch floor, and recalibrates otherwise.
    + judges the trials ({!Verdict.judge}) under the first load sample, as a
      [`Partial] selection whatever it covers: [benches] need not be the whole
      suite, so in a current section {!Verdict.corrected} keeps every row the
      run did not judge.
    + when {!Verdict.confirmations} is not empty, samples the load again. On a
      quiet host it measures each queued case once more, in queue order, at the
      batch size of its first trial. On a loaded host it measures nothing, since
      {!Verdict.decide} then makes every pending relation
      [Inconclusive Environment] whatever trials it gets.
    + decides ({!Verdict.decide}) under the last load sample.

    [config] defaults to {!Config.default}; with [config.fork] each trial runs
    in a fresh worker process, else in this process. [budgets] are the suite's
    budgets and default to [[]] (per-case resolution is {!Verdict.judge}'s).
    [baseline] defaults to the empty-file baseline, against which every metric
    is proposed. [name] heads the file {!Verdict.corrected} proposes over the
    empty-file baseline.

    Raises [Invalid_argument] if [name] is empty or not single-line, if
    [budgets] holds two budgets for one metric, if [THUMPER_MACHINE] is set to
    an invalid key, or if [baseline]'s header names another suite, all before
    the lock is taken. Raises [Error] on an operational failure: [Invalid_suite]
    and [Empty_selection] before the lock, [Lock] and [Measurement] under it. *)

val run_with :
  ?instruments:Measure.instruments ->
  ?load:(unit -> Env.load) ->
  ?on_progress:(progress -> unit) ->
  ?config:Config.t ->
  ?budgets:Budget.t list ->
  ?prune:bool ->
  ?filter:Bench.filter ->
  ?baseline:Baseline.t ->
  string ->
  Bench.t list ->
  Verdict.t
(** [run_with ?instruments ?load ?on_progress ?prune name benches] is {!run}
    with its host seams exposed, and its pruning:
    - [instruments] reads every clock and counter of both sweeps
      ({!Measure.case}), {!Measure.default_instruments} by default.
    - [load] samples the load at the start and before a non-empty confirmation
      queue, {!Env.val-load} by default.
    - [on_progress] receives the ticks of both sweeps, and of none for a queue
      left unmeasured on a loaded host. It ignores them by default.
    - [prune], [false] by default, judges a selection of every case of [benches]
      as {!select}'s [`Full], so that {!Verdict.corrected} prunes the rows of
      cases [benches] lacks. Only a caller that holds the whole suite passes
      [true], as {!Cli.main} does. *)

(** {1:measuring Measuring} *)

val measure :
  ?instruments:Measure.instruments ->
  ?on_progress:(progress -> unit) ->
  ?config:Config.t ->
  ?filter:Bench.filter ->
  Bench.t list ->
  Run.t
(** [measure ?instruments ?on_progress ?config ?filter benches] measures the
    cases of [benches] that [filter] selects, under the measurement lock, and is
    their evidence, one trial per case in selection order. Every case calibrates
    its batch size freely. No machine key, suite name or load is read and
    nothing is judged; a trial's warnings and drift flag travel with it
    ({!Run}). The selection is {!select}'s with [config]'s metrics and no run
    budgets, so a case or group budget on a metric its scope does not collect is
    still refused. [instruments] and [on_progress] are as for {!run_with}, every
    tick being [`Measuring]; [config] defaults to {!Config.default}.

    Raises [Error] as {!run} does. *)
