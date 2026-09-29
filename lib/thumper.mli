(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** Benchmark regression tests.

    A benchmark is an executable that declares its cases with {!val:bench} and
    {!group} and ends with {!run}, the command line that measures the cases and
    checks them against the committed baseline of this machine. A failing check
    exits 1, so a dune rule that runs the benchmark fails the build. {!measure}
    and {!Check.run} are the measurement and the check as functions.

    {[
    let input = List.init 1_000 Fun.id

    let () =
      exit
        (Thumper.run "hello"
           [ Thumper.bench "list-rev" (fun () -> List.rev input) ])
    ]}

    The manual is in [doc/manual/] of thumper's source. *)

(* The internal modules, named before the public modules below shadow them,
   for [Private]. *)

module Baseline' := Baseline
module Budget' := Budget
module Check' := Check
module Config' := Config
module Metric' := Metric
module Run' := Run
module Verdict' := Verdict

(** {1:metrics Metrics} *)

(** Per-call quantities.

    A metric is a {e time metric} ({!Metric.wall_time}, {!Metric.cpu_time}) or a
    {e counter metric} (the other six, read from the GC's counters). A trial
    yields each metric either as {e sampled} evidence, one value per sample,
    which is compared statistically, or as {e exact} evidence, one integer count
    per call, which a counter metric yields when the trial proves the count
    constant. A time metric is always sampled. The metrics are the eight
    {{!Metric.builtins}built-ins}, and lower is better for each. *)
module Metric : sig
  type t
  (** The type for metrics. Metrics with the same {!id} are one metric. *)

  val id : t -> string
  (** [id m] is [m]'s identity, one segment of [[A-Za-z0-9._-]]. It appears
      verbatim in baseline rows and in the JSON document, and a built-in's id
      never changes. *)

  val name : t -> string
  (** [name m] is [m]'s name in words, such as ["wall time"]. Thumper prints it
      nowhere and writes it to no file. *)

  val units : t -> string
  (** [units m] is the unit of [m]'s per-call values: ["s"], ["words"] or
      ["count"]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [id a] and [id b] are equal. *)

  val compare : t -> t -> int
  (** [compare a b] orders [a] and [b] by {!id}, compatibly with {!equal}. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf m] formats [m]'s {!id}. *)

  (** {2:builtins Built-in metrics}

      {!wall_time} and {!alloc_words} are collected by default
      ({!Config.default}); the others are collected where {!Config.metrics} or a
      case's [?metrics] names them. *)

  val wall_time : t
  (** [wall_time] is elapsed time per call, in seconds, read from a monotonic
      clock. On macOS and Linux the clock stops while the system sleeps and is
      not adjusted by NTP. Id ["wall_time"]. *)

  val alloc_words : t
  (** [alloc_words] is the words allocated per call: minor plus major words,
      less the promoted words, which the minor and major counts both include. Id
      ["alloc_words"]. *)

  val cpu_time : t
  (** [cpu_time] is the process's CPU time per call, user plus system, in
      seconds. Id ["cpu_time"]. *)

  val minor_alloc_words : t
  (** [minor_alloc_words] is the words allocated in the minor heap per call. Id
      ["minor_alloc_words"]. *)

  val major_alloc_words : t
  (** [major_alloc_words] is the words allocated in the major heap per call,
      including the words promoted from the minor heap. Id
      ["major_alloc_words"]. *)

  val promoted_words : t
  (** [promoted_words] is the words promoted from the minor to the major heap
      per call. Id ["promoted_words"]. *)

  val minor_collections : t
  (** [minor_collections] is the minor collections per call. Id
      ["minor_collections"]. *)

  val major_collections : t
  (** [major_collections] is the completed major collection cycles per call. Id
      ["major_collections"]. *)
end

(** {1:budgets Budgets} *)

(** Performance budgets.

    A budget bounds one {!Metric.t} of a case. A relative budget
    ({!Budget.no_slower_than}, {!Budget.no_more_alloc_than},
    {!Budget.val-relative}) bounds the metric's change from the baseline, as a
    fraction of the baseline value; an absolute budget ({!Budget.at_most})
    bounds the measured value.

    A case fails when one of its budgeted metrics fails, whatever its other
    metrics did: an allocation regression fails a case whose time improved. A
    metric without a budget is compared under the default's tolerances and
    reported, and never fails its case or makes it inconclusive. Budgets attach
    to {!run}, {!Check.run}, {!group} and {!val:bench}, and the nearest one for
    a metric applies ({{!benchmarks}inheritance}). A case left with no budget on
    a metric it collects gets [no_slower_than 0.05] if it collects
    {!Metric.wall_time}. Its allocation is then reported and never fails it. *)
module Budget : sig
  type t
  (** The type for budgets. *)

  (** {2:relative Relative budgets}

      A relative budget [r] comes with an equivalence band [e], both fractions
      of the baseline value. A comparison of samples yields an interval
      \[[L];[U]\] for the change, positive when worse: the metric has regressed
      when [L > r], improved when [U < -e], is equivalent when \[[L];[U]\] lies
      within \[[-e];[e]\], within budget otherwise when [U <= r], and
      inconclusive otherwise, when the noise exceeds the budget. A sampled
      regression or improvement counts only when a second trial of the case
      confirms it ({!Check.run}); an improvement that is not confirmed is within
      budget. An exact count compares as an integer, with no second trial: it
      has improved when it shrinks, and regressed when it grows by more than [r]
      of its baseline value or grows at all from [0].

      Each constructor raises [Invalid_argument] if [r] or [e] is negative or
      NaN, or if [e] exceeds [r]. *)

  val relative :
    metric:Metric.t ->
    ?equivalent_within:float ->
    max_regression:float ->
    unit ->
    t
  (** [relative ~metric ?equivalent_within ~max_regression ()] is the budget
      [r = max_regression] on [metric] ([0.05] is 5%). [equivalent_within] is
      the band [e] and defaults to [min 0.025 (max_regression /. 2.)]; an
      explicit band may exceed [0.025]. With [max_regression = 0.] the band is
      [0.] and no sampled comparison is equivalent. A counter metric then
      compares exact counts only, and is [inconclusive: exactness lost] when
      either side is sampled. *)

  val no_slower_than :
    ?metric:Metric.t -> ?equivalent_within:float -> float -> t
  (** [no_slower_than r] is
      [relative ~metric ?equivalent_within ~max_regression:r ()]. [metric]
      defaults to {!Metric.wall_time}. *)

  val no_more_alloc_than :
    ?metric:Metric.t -> ?equivalent_within:float -> float -> t
  (** [no_more_alloc_than r] is {!no_slower_than} with [metric] defaulting to
      {!Metric.alloc_words}. [no_more_alloc_than 0.] allows no growth of the
      exact allocation count. *)

  (** {2:absolute Absolute budgets} *)

  val at_most : metric:Metric.t -> float -> t
  (** [at_most ~metric v] is the budget that bounds the measured value of
      [metric] by [v], in [metric]'s {!Metric.units}. An exact count over [v]
      fails the case on any run, whatever the baseline holds or lacks. At or
      under [v], an exact count compares with an exact baseline row as
      [equivalent], [improved] or [within budget], or is
      [inconclusive: batch drifted] when it changed at another batch size;
      against a sampled row it is [inconclusive: exactness lost]. Sampled
      evidence never fails the case. It is compared under the default's
      tolerances, and an inconclusive comparison makes the case inconclusive, as
      for any budgeted metric.

      Raises [Invalid_argument] if [v] is negative or NaN, or if [metric] is
      {!Metric.wall_time} or {!Metric.cpu_time}, which are never exact. *)
end

(** {1:config Configuration} *)

(** Measurement protocols.

    A configuration fixes how every selected case is measured: the samples per
    trial, the batch floor, the warmup, the deadline and the metrics collected.
    A trial calibrates a batch size, warms up, then takes its samples. Each
    sample is the time of one batch of calls divided by the batch size. Setters
    apply in any order. *)
module Config : sig
  type t
  (** The type for measurement protocols. *)

  (** {2:presets Presets} *)

  val default : t
  (** [default] takes 20 samples per trial, with a 5 ms batch floor, a warmup of
      at least 100 ms and 3 batches, a 10 s deadline, and {!Metric.wall_time}
      and {!Metric.alloc_words} collected. *)

  val quick : t
  (** [quick] is {!default} with 11 samples. *)

  val precise : t
  (** [precise] is {!default} with 40 samples. Prefer {!precise}, or a looser
      budget, when a comparison is [inconclusive: wide interval]. *)

  (** {2:setters Setters} *)

  val samples : int -> t -> t
  (** [samples n t] is [t] taking [n] samples per trial.

      Raises [Invalid_argument] if [n < 3]. *)

  val batch_floor : float -> t -> t
  (** [batch_floor s t] is [t] with a batch floor of [s] seconds. Calibration
      doubles the batch size, from one call, until one batch takes at least [s].

      Raises [Invalid_argument] if [s] is not finite and positive. *)

  val warmup : float -> t -> t
  (** [warmup s t] is [t] warming up for at least [s] seconds before the
      samples. The warmup also runs at least 3 batches, [warmup 0.] included.

      Raises [Invalid_argument] if [s] is negative or not finite. *)

  val deadline : float -> t -> t
  (** [deadline s t] is [t] with a cap of [s] seconds on each trial of a case,
      covering setup, calibration, warmup, the samples, the exactness probe and
      teardown. A case over its deadline is killed, and the run stops with
      {!Check.Error}. [deadline infinity] removes the cap, and a call that never
      returns then hangs the run.

      Raises [Invalid_argument] if [s] is not positive (NaN included). *)

  val metrics : Metric.t list -> t -> t
  (** [metrics ms t] is [t] collecting [ms], in that order, for every case whose
      scopes name no [?metrics] ({{!benchmarks}inheritance}).

      Raises [Invalid_argument] if [ms] is empty or names one metric twice. *)
end

(** {1:benchmarks Defining benchmarks}

    A {e case} is a named function to measure; a {e group} gives its children an
    id prefix and shares its tags, metrics and budgets with them.

    Each trial of a case runs in its own worker, a process forked from the
    benchmark whose standard input is [/dev/null]. Besides the samples, the
    measured function runs in calibration, in warmup and in the exactness
    probe's batches of [k] and [2k] calls. Its effects on the worker's memory
    never reach the benchmark's process or the next case. A program that has
    started a domain cannot fork, and the run then stops at its first case
    ({!Check.Error}).

    {b Ids.} Every case has an id: the ['/']-joined segments of its group path,
    each a nonempty run of [[A-Za-z0-9._-]]. Ids appear verbatim in baseline
    rows and in the JSON document, and [-f] selects by them. A node's segment is
    its [?id] when given, else the slug of its name: a name that is already a
    valid segment is used as is, otherwise every maximal run of other characters
    becomes one ['-'] and runs at either end are dropped. The name's own
    [[A-Za-z0-9._-]] characters, hyphens at either end included, are always
    kept. [bench "1 MiB copy"] has id ["1-MiB-copy"], and [bench " (parens) "]
    has id ["parens"].

    {b Inheritance.} A group's [?tags], [?metrics] and [?budgets] reach its
    descendants:
    - tags accumulate, outer scopes first, and are never removed;
    - the nearest scope naming [?metrics] chooses what is measured, else
      {!Config.metrics};
    - budgets merge per metric: the nearest budget for a metric applies, and
      budgets for other metrics keep flowing from outer scopes, then from the
      suite's budgets. [~budgets:[]] keeps the inherited budgets.

    A budget applies only to a metric the case collects: an inherited budget on
    another metric is dropped, and a budget stated at a scope that does not
    collect its metric makes the suite invalid ({!Check.Error}). A case left
    with no budget gets {!Budget}'s default.

    {b Errors.} Each constructor raises [Invalid_argument] if its name is empty,
    if [id] is not one valid segment (a ['/'] included), if [id] is absent and
    the name has no [[A-Za-z0-9._-]] character, if [metrics] is [[]] or names a
    metric twice, or if [budgets] holds two budgets for one metric. Two cases
    with one id make the suite invalid: {!measure} and {!Check.run} raise
    {!Check.Error}, and {!run} returns 2, before measuring. *)

type bench
(** The type for benchmark trees: a case or a group. *)

val bench :
  ?id:string ->
  ?tags:string list ->
  ?metrics:Metric.t list ->
  ?budgets:Budget.t list ->
  string ->
  (unit -> 'a) ->
  bench
(** [bench name f] is a case measuring [f]. A batch of size [k] calls [f] [k]
    times and passes each result to [Sys.opaque_identity], so no call is dead
    code. The compiler may still fold a computation over an input it can see. A
    case whose median call takes under 1 ns is warned as possibly folded
    ({!Run.warnings}). Prefer {!black_box} around such an input.
    - [id] is the case's segment, defaults to the slug of [name]
      ({{!benchmarks}ids}).
    - [tags] label the case for [`Tag] selection, defaults to [[]]. Any string
      is a tag.
    - [metrics] and [budgets] default to the inherited ones
      ({{!benchmarks}inheritance}).

    Raises [Invalid_argument] as described under {{!benchmarks}errors}. *)

val bench_with_setup :
  ?id:string ->
  ?tags:string list ->
  ?metrics:Metric.t list ->
  ?budgets:Budget.t list ->
  setup:(unit -> 'env) ->
  ?teardown:('env -> unit) ->
  string ->
  ('env -> 'a) ->
  bench
(** [bench_with_setup ~setup name f] is like {!val:bench} except that each trial
    calls [setup ()] once, in the worker, before the first batch, and each call
    is [f env] on its result [env]. [env] passes through [Sys.opaque_identity]
    at every batch. [teardown env] runs once after the trial's last batch, also
    when [f] raises, and defaults to doing nothing; it does not run when [setup]
    raises or when the case is killed at its deadline. An exception from
    [setup], [f] or [teardown] fails the case ({!Check.Error}), except that one
    from [teardown] after [f] raised is ignored.

    Raises [Invalid_argument] as described under {{!benchmarks}errors}. *)

val group :
  ?id:string ->
  ?tags:string list ->
  ?metrics:Metric.t list ->
  ?budgets:Budget.t list ->
  string ->
  bench list ->
  bench
(** [group name children] is a group of [children]. Their segments are prefixed
    with the group's segment ([id], defaulting to the slug of [name]) and ['/'],
    their names with [name] and ['/'] (the JSON document's [full_name]), and
    [tags], [metrics] and [budgets] reach them as described under
    {{!benchmarks}inheritance}. Groups nest, and [children] may be empty.

    Raises [Invalid_argument] as described under {{!benchmarks}errors}. *)

val black_box : 'a -> 'a
(** [black_box x] is [x] hidden from the compiler by [Sys.opaque_identity],
    which therefore cannot fold a computation over it. *)

(** {1:running Running benchmarks} *)

val run :
  ?baseline:string ->
  ?config:Config.t ->
  ?budgets:Budget.t list ->
  ?argv:string array ->
  string ->
  bench list ->
  int
(** [run name benches] is the benchmark's command line: it runs the subcommand
    [argv] names on [benches] and is the exit code. It never exits the process:
    a benchmark executable ends with [let () = exit (Thumper.run name benches)].
    - [baseline] is the baseline's path, defaults to [<name>.thumper] in the
      directory described under {{!files}files}. [--baseline PATH] replaces it.
    - [config] is the measurement protocol, defaults to {!Config.default}.
      [--quick] and [--precise] set its {!Config.samples} to 11 and 40.
    - [budgets] are the suite's budgets, as for {!Check.run}, and default to
      [[]].
    - [argv] is the command line, defaults to [Sys.argv]. Its first element is
      the program's name.

    The first argument names the subcommand, [check] when it names none:
    - [check] measures the selected cases, judges them against the baseline as
      {!Check.run} does, prints the {{!report}report}, and writes
      [<baseline>.corrected] when {!Verdict.corrected} is [Some]. It never
      writes the baseline. [--strict] makes the exit code
      [Verdict.exit_code ~strict:true], and [--json PATH] writes
      {!Verdict.to_json}'s document and a newline to [PATH] ([--json -] is a
      usage error).
    - [bless] measures the selected cases once, judging nothing, prints the
      report, and writes [<baseline>.corrected] with them re-recorded in this
      machine's section, or with this machine's section replaced by their rows
      when every case is selected or the section is missing or stale. It refuses
      a loaded host unless [--force], which records the load in a [# forced:]
      line of the section's header, naming the re-recorded cases when the
      selection is partial.
    - [list] prints the selected case ids, one per line, and measures nothing.

    [-f PAT] and bare arguments select the cases whose id contains [PAT], and
    [--tag T] selects the cases tagged [T]. A case is selected when it matches
    some pattern and every tag ({!type:filter}).

    [--wait-quiet SECS] waits up to [SECS] seconds for a quiet host before
    measuring. When the host is still loaded, [check] measures anyway, and
    [bless] refuses unless [--force].

    [--json] and [--strict] apply to [check] only, [--force] to [bless] only,
    and [--quick], [--precise], [--baseline] and [--wait-quiet] to both. A flag
    given to another subcommand is a usage error, and so are [--quick] and
    [--precise] together. [-h] prints every flag and [-V] the version.

    The exit code is:
    - [0] when [list], [bless], [-h] or [-V] succeeds, or when [check]'s
      {!Verdict.exit_code} is [0];
    - [1] when [check]'s {!Verdict.exit_code} is [1];
    - [2] on a usage error, and when the run stops: an invalid suite or an empty
      selection; a malformed [THUMPER_MACHINE] under [check] or [bless]; a
      baseline that cannot be read, is corrupt or names another suite; a
      measurement lock that timed out or is unusable; a case that cannot be
      measured; [bless] on a loaded host without [--force]; or a
      [<baseline>.corrected] or [--json] file that cannot be removed or written.

    Raises [Invalid_argument], before reading [argv], if [name] is empty or not
    single-line, or if [budgets] holds two budgets for one metric. [run] returns
    no exit code for these, and a program that lets one escape ends with the
    OCaml runtime's exit code 2. *)

(** {2:report The report}

    [check] and [bless] print one report on stdout once measurement completes
    and, for [bless], the corrected file is written; a run that stops earlier
    prints none. Its blocks are a header, a table of one row per case followed
    by the warnings, the actions and, for [check] against a current section, a
    summary. The warnings include each case's {!Run.warnings}, its second
    trial's too.

    A row's time is the median of the case's first time metric, followed after
    [±] by the half-width of that median's 95% confidence interval, as a
    percentage of the median. [REGRESSED] marks a metric that fails its case and
    is the report's only capitalised word; [regressed] is a regression that
    fails nothing. An allocation marked [~] is sampled. In [bless]'s report, and
    in [check]'s against a missing or stale section, every row reads [proposed]
    unless it fails.

    The actions are:
    - [rerun:], when some case fails and the run is not a dune rule action: a
      command that measures the failing cases again. It names the executable
      relative to the working directory when it lies under it, and absolute
      otherwise. It repeats the run's [--quick] or [--precise], a [--baseline]
      given on the command line, and its [--tag]s. Its [-f <id>] patterns are
      substrings and may select other cases too.
    - [accept:], when a corrected file was written: [dune promote] in a dune
      rule action and [mv <corrected> <baseline>] otherwise. [bless] always
      prints it.

    The summary counts each case once, by its outcome: [regressed] when it
    fails, [inconclusive] when a budgeted metric is inconclusive, and among the
    passing cases [proposed] when no metric has a baseline row, [improved] when
    its row opens on [improved], and [passed] otherwise. A row opens on its
    case's outcome: [REGRESSED] when the case fails, [inconclusive] when a
    budgeted metric is inconclusive, and a passing word otherwise. A [regressed]
    that fails nothing and an [inconclusive] without a budget follow on the
    row's detail line; a case whose only non-passing relations are these counts
    as passed. The summary ends with [; failed under --strict] when [--strict]
    alone made the run exit 1. *)

(** {2:files Files}

    [--baseline PATH], else the [baseline] argument, names the baseline as
    typed. Otherwise [<name>.thumper] resolves in the first of:
    + the working directory, when it lies inside dune's build directory, as in a
      dune rule action;
    + the benchmark's source directory, when the executable runs from dune's
      build directory and that source directory exists;
      [dune exec bench/bench_x.exe] then names the same file as the dune rule,
      whatever the build directory is called;
    + the working directory.

    Under dune the build and source directories are the ones its environment
    names ([INSIDE_DUNE] and [DUNE_SOURCEROOT]). A run by hand, with neither
    set, recognises a build directory named [_build].

    The report prints an explicit path as typed, less its [.] segments. It
    prints the default path as a bare file name in a dune rule action, relative
    to the working directory when the file is in a subdirectory of it, and
    absolute otherwise.

    Every subcommand, [list] included, starts by removing the
    [<baseline>.corrected] and [--json] files an earlier run left; [-h], [-V]
    and a usage error remove nothing. Both files are written atomically, the
    [--json] file first. Before measuring, [bless], a [check] with no baseline
    file and [--json] check that the directory they will write to exists and is
    writable. When [check]'s corrected file cannot be written after measurement,
    the report prints without its [accept:] line and the run exits 2; [bless]
    then prints no report. *)

(** {2:environment Streams and environment}

    Stderr carries:
    - [thumper: <reason>] when the run stops, followed by [Try '-h' for usage.]
      after a usage error;
    - while measuring, when stderr is a terminal, one status line naming the
      case being measured or confirmed, rewritten in place and erased before
      anything else prints;
    - a notice when the run waits for the measurement lock, and one each time
      the lock changes owner;
    - [--wait-quiet]'s notices, when the wait starts on a loaded host and when
      [check], or [bless --force], measures after the wait expired.

    [--color always] and [--color never] apply whatever the environment.
    [--color auto], the default, colours the report when stdout is a terminal or
    the run is a dune rule action, unless [NO_COLOR] is set and non-empty.
    Stderr is never coloured, and colour only styles words the report prints
    anyway.

    The environment variables are:
    - [THUMPER_MACHINE], which replaces the machine key
      ({!Baseline.machine_key}); [list] ignores it.
    - [THUMPER_LOCK_DIR], the measurement lock's directory
      ({{!measuring}measuring}).
    - [NO_COLOR], as above.
    - [GITHUB_ACTIONS], which, set to any value, ends the report with one
      [::error::] line for each metric that fails its case.
    - [INSIDE_DUNE], which marks a dune rule action when the working directory
      lies inside dune's build directory: the [accept:] line reads
      [dune promote], there is no [rerun:] line, and [auto] colours. Under
      [dune exec], which sets [INSIDE_DUNE] but keeps the shell's working
      directory, the run is not a rule action.
    - [INSIDE_DUNE] and [DUNE_SOURCEROOT] together, which name dune's build
      context and workspace root for the default baseline path
      ({{!files}files}). *)

(** {1:selection Selecting cases} *)

type filter =
  [ `Id of string
    (** Cases whose id contains the string, case-sensitively; [`Id ""] selects
        every case. *)
  | `Tag of string  (** Cases tagged with the string. *)
  | `And of filter list
    (** Cases that every filter selects; [`And []] selects every case. *)
  | `Or of filter list
    (** Cases that some filter selects; [`Or []] selects none. *) ]
(** The type for selections of cases by {{!benchmarks}id} and tag. An empty
    selection is an error wherever it would be measured ({!Check.Error}). *)

(** {1:measuring Measuring}

    Measuring holds the {e measurement lock}, the file [thumper-<euid>.lock] in
    [THUMPER_LOCK_DIR], or in the temporary directory when the variable is unset
    or empty. Two measurements by one user with one lock directory never
    overlap. A call waits for the lock up to 600 s per holder, the wait
    restarting each time another run takes it, and releases it when it returns
    or raises. {!measure} and {!Check.run} print nothing while they wait. *)

(** Measured evidence.

    A {!Run.t} holds one trial per measured case: its batch size, the sorted
    per-call samples of each sampled metric, and the count of each exact metric.
    {!measure} produces it. *)
module Run : sig
  type t
  (** The type for the evidence of one run. *)

  val case_ids : t -> string list
  (** [case_ids r] is the ids of [r]'s cases, in measurement order. *)

  val samples : t -> case:string -> Metric.t -> float array option
  (** [samples r ~case m] is [case]'s per-call samples of [m] in ascending
      order, one per sample of the trial, or [None] when [case] was not
      measured, [m] was not collected, or [m]'s evidence is exact. The array is
      a copy. *)

  val exact : t -> case:string -> Metric.t -> int option
  (** [exact r ~case m] is [case]'s exact count of [m] per call, or [None] when
      [case] was not measured, [m] was not collected, or [m]'s evidence is
      sampled, as a time metric's always is. *)

  val warnings : t -> case:string -> string list
  (** [warnings r ~case] is the warnings measuring [case] raised: a median call
      under 1 ns
      ([wall_time <t> ns/call: possibly folded: wrap the input in black_box]), a
      counter metric whose exactness probe failed and which is therefore
      sampled, and each GC parameter the case changed. The first two come in the
      order they arose, then the GC parameters. [warnings r ~case] is [[]] when
      [case] raised none or was not measured. *)
end

val measure : ?config:Config.t -> ?filter:filter -> bench list -> Run.t
(** [measure benches] measures the cases [filter] selects, all of them by
    default, under the measurement lock, and is their evidence. It reads and
    writes no baseline, samples no load and ignores [THUMPER_MACHINE]. [config]
    defaults to {!Config.default}.

    Raises {!Check.Error} if the measurement lock times out or is unusable, if a
    case cannot be measured, if the suite is invalid, or if the selection is
    empty. *)

(** {1:baselines Baselines} *)

(** Committed baselines.

    A baseline is a committed file, [<suite>.thumper] by default. It stores
    evidence, one section per {{!Baseline.machine_key}machine key}: each case's
    sorted samples and exact counts, under a header recording the host and the
    compiler. A section is {e stale} when its compiler identity differs from
    this run's. The identity is the OCaml version, the word size, and the
    backend and runtime variant, such as [5.5.1 · 64-bit · release]; flambda and
    other configure-time options are not part of it. The empty file is the
    baseline with no section. The format is specified in
    [doc/manual/baseline-format.md]. *)
module Baseline : sig
  (** {2:types Baselines and errors} *)

  type t
  (** The type for baselines. *)

  (** The type for baseline errors. An absent file is not one ({!read}). *)
  type error =
    | Corrupt of { line : int; reason : string }
        (** The file breaks the format at [line], counted from 1. [reason] says
            how, such as a malformed line or a stored median that disagrees with
            its samples. It names no file. *)
    | Io of string
        (** The file exists but cannot be read, or cannot be written. The string
            is the whole message and names the file, as in
            [cannot read <path>: <reason>]. *)

  exception Error of error
  (** Raised by {!read_exn} and {!write}. A program that lets it escape prints
      [Thumper.Baseline.Error: <text>], the text being {!pp_error}'s. *)

  val pp_error : Format.formatter -> error -> unit
  (** [pp_error ppf e] formats [e] as [corrupt baseline (line <n>): <reason>] or
      as [Io]'s message. *)

  (** {2:reading Reading and writing} *)

  val read : string -> (t option, error) result
  (** [read path] is [Ok (Some t)] when [path] holds the baseline [t], [Ok None]
      when no file exists at [path] (a dangling symbolic link included),
      [Error (Io _)] when the file cannot be read, and [Error (Corrupt _)] when
      it breaks the format. *)

  val read_exn : string -> t option
  (** [read_exn path] is like {!read} but raises {!Error} on an error. *)

  val write : string -> t -> unit
  (** [write path t] writes [t] to [path] atomically: a reader sees the previous
      file or the new one, never part of one, and an existing file's permissions
      are kept.

      Raises {!Error} with [Io _] if the file cannot be written. *)

  (** {2:observers Suites and machines} *)

  val suite : t -> string option
  (** [suite t] is the suite name in [t]'s header, and [None] iff [t] is the
      empty file. *)

  val machines : t -> string list
  (** [machines t] is the machine keys of [t]'s sections, in ascending order. *)

  val machine_key : unit -> string
  (** [machine_key ()] is [THUMPER_MACHINE] when it is set, read at each call.
      Otherwise it is the FNV-1a 64-bit hash of [<host>:<os>:<cpu>] in 16
      lowercase hexadecimal digits, where [<host>] is the hardware UUID on macOS
      and the host name elsewhere, [<os>] is [uname -s] in lowercase, and
      [<cpu>] is the CPU model, empty when undetected.

      Raises [Invalid_argument] naming the variable if [THUMPER_MACHINE] is set
      and empty or has a character outside [[A-Za-z0-9._-]]. *)
end

(** {1:verdicts Verdicts} *)

(** Judged runs.

    A verdict is what {!Check.run} returns. For each case and metric it holds a
    relation ([improved], [regressed], [equivalent], [within budget], or
    [inconclusive] with a reason), as {!Budget} defines them. A metric with no
    baseline row to compare with on this machine is {e proposed} and has no
    relation. {!Verdict.overall} and {!Verdict.exit_code} are its outcome,
    {!Verdict.to_json} its document, and {!Verdict.corrected} the corrected
    file. *)
module Verdict : sig
  type t
  (** The type for verdicts. *)

  val overall : t -> [ `Pass | `Fail | `Inconclusive ]
  (** [overall t] is [`Fail] when some case fails, else [`Inconclusive] when
      some budgeted metric is inconclusive, else [`Pass]. A metric fails its
      case when it regressed under a relative budget, or when its exact count is
      over its {!Budget.at_most} cap; a proposed metric fails only by the
      latter. *)

  val exit_code : ?strict:bool -> t -> int
  (** [exit_code t] is [1] when {!overall} is [`Fail], and [0] otherwise. With
      [strict] (defaults to [false]) it is also [1] when {!overall} is
      [`Inconclusive] or some metric is proposed. *)

  val to_json : t -> string
  (** [to_json t] is [t] as a JSON document on one line, with no final newline.
      Its schema is frozen and specified in [doc/manual/checking.md]. Its
      [overall] is {!overall}'s. A metric's [status] is its own: ["fail"] when
      it fails its case, ["inconclusive"] when its relation is inconclusive,
      budgeted or not, and ["pass"] otherwise. A proposed metric has a [null]
      [relation] and the [reason] ["missing_baseline"]. *)

  val corrected : t -> Baseline.t option
  (** [corrected t] is the corrected file: the baseline [t] was judged against,
      with this machine's section updated, or [None] when that changes no byte.
      Against a current section:
      - an improved metric's row advances, to the samples of both trials, which
        share one batch size, or to the new exact count;
      - a proposed metric's row is added;
      - when {!Thumper.run}'s [check] selects every case, the rows of cases the
        suite no longer has are removed; {!Check.run} removes none;
      - every other row and byte stays, other machines' sections included.

      Against a missing or stale section, the section is recorded from this
      run's trials of the selected cases, whatever their relations and the
      host's load, and replaces the old section, its annotations included. A
      baseline with no suite header gets the suite's name. *)
end

(** {1:checking Checking} *)

(** Checks as functions.

    {!Check.run} is what {!run}'s [check] subcommand does, without printing
    anything or writing any file but the measurement lock's. *)
module Check : sig
  type error
  (** The type for the failures that stop a run:
      - the measurement lock timed out or is unusable;
      - a case could not be measured: its worker died, its [setup], function or
        [teardown] raised, or it exceeded its deadline ({!Config.deadline}). The
        run stops at the first such case;
      - the suite is invalid: two cases share an id, or a budget is stated where
        its metric is not collected;
      - the selection is empty.

      {!Thumper.run} reports them on stderr and returns 2. *)

  val pp_error : Format.formatter -> error -> unit
  (** [pp_error ppf e] formats [e] as one line for users, which names the case,
      the lock file or the scope concerned. An invalid suite's line ends with
      its remedy, as [duplicate case id 'a/b' (rename the case or pass ~id)]
      does. *)

  exception Error of error
  (** Raised by {!run} and {!Thumper.measure}. A program that lets it escape
      prints [Thumper.Check.Error: <text>], the text being {!pp_error}'s. *)

  val run :
    ?config:Config.t ->
    ?budgets:Budget.t list ->
    ?filter:filter ->
    ?baseline:Baseline.t ->
    string ->
    bench list ->
    Verdict.t
  (** [run name benches] measures the cases [filter] selects under the
      measurement lock, judges them against this machine's section of [baseline]
      ({!Baseline.machine_key}), and is the verdict.
      - [config] defaults to {!Config.default}.
      - [budgets] are the suite's budgets ({{!benchmarks}inheritance}), defaults
        to [[]].
      - [filter] selects every case by default.
      - [baseline] is the baseline judged against. Without it, or when its
        section for this machine is missing or stale, every metric is proposed.

      [name] is the suite's name.

      [benches] need not be the whole suite: in a current section, the corrected
      file ({!Verdict.corrected}) keeps every row the run did not judge.

      The run measures every selected case once, then judges. A sampled
      improvement or regression is measured again in a second trial, after every
      case's first, at the first trial's batch size, and counts only when that
      trial, at that size, confirms it. A case with a sampled row in a current
      section measures its first trial at the row's batch size when one batch
      then takes 0.2 to 5 times the batch floor, and calibrates otherwise.

      The run samples the host's load when it holds the lock, and again before
      the second trials when there are any. A host is loaded when its load
      average per core is at least 0.5; a host with no load average reads quiet.
      On a loaded first sample, every sampled comparison is
      [inconclusive: environment], except one with a non-positive sample or one
      that is [inconclusive: exactness lost]; on a loaded second sample, no
      second trial is measured, and each pending relation is
      [inconclusive: environment]. Exact comparisons ignore the load.

      {[
      let baseline = Baseline.read_exn file in
      let v = Check.run ?baseline "programmatic" suite in
      print_endline (Verdict.to_json v);
      Option.iter (Baseline.write (file ^ ".corrected")) (Verdict.corrected v);
      exit (Verdict.exit_code v)
      ]}

      Raises {!Error} on a failure that stops the run. Raises
      [Invalid_argument], before measuring, if [name] is empty or not
      single-line, if [budgets] holds two budgets for one metric, if
      [THUMPER_MACHINE] is malformed ({!Baseline.machine_key}), or if
      [baseline]'s header names another suite. *)
end

(** {1:private Private} *)

(** Thumper's internal modules, for its own tests: they are not part of the API
    and change without notice. *)
module Private : sig
  module Baseline = Baseline'
  module Bench = Bench
  module Budget = Budget'
  module Check = Check'
  module Cli = Cli
  module Config = Config'
  module Env = Env
  module Measure = Measure
  module Metric = Metric'
  module Os = Os
  module Report = Report
  module Run = Run'
  module Stats = Stats
  module Verdict = Verdict'
end
