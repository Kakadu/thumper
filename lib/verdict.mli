(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** Judgment: the relations between a run's evidence and this machine's baseline
    section, and the files that follow from them.

    Judging takes two passes, because a relation is confirmed by a second
    measurement. {!judge} compares every first trial and holds each strong
    sampled relation pending; {!confirmations} lists the cases to measure again;
    {!decide} folds their confirmation trials in and is the verdict.
    {!Check.run_with} is the library's one caller of the three. The write paths
    {!corrected} and {!bless} compute a {!Baseline.t} and write nothing.

    Every function here is pure: no I/O, no clock, no environment variable. The
    host's load arrives as an {!Env.type-load} value. In a verdict {!decide}
    returns, a strong relation over sampled evidence is always [Confirmed], and
    one over exact evidence is always [Exact_change], which needs no
    confirmation. *)

(** {1:relations Relations} *)

type shift = { estimate : float; lower : float; upper : float }
(** The type for relative changes, as fractions of the baseline value, positive
    when this run is worse; [0.312] is 31.2% slower or larger. [estimate] is the
    point estimate and \[[lower];[upper]\] its confidence interval, with
    [lower <= estimate <= upper]. A sampled shift is the Hodges–Lehmann estimate
    and Moses interval of the differences of the logarithms
    ({!Stats.val-shift}), each mapped through [expm1]. An exact shift is a
    point, [infinity] for growth from a count of [0]. *)

(** The type for the reasons a comparison is inconclusive. Each constructor
    names its spelling in the JSON document ({!to_json}). *)
type reason =
  | Wide_interval
      (** The interval matches none of the relations ({!type-relation}): its
          upper end is beyond the budget, and the noise exceeds what the budget
          can check. Its JSON spelling is [wide_interval]. *)
  | Non_positive
      (** A sample on either side is zero or negative, so the logarithmic
          comparison is undefined. A loaded host does not hide it. Its JSON
          spelling is [non_positive]. *)
  | Baseline_unstable
      (** The baseline row's samples show severe outlier variance inflation
          ({!Stats.severe_outlier_inflation_sorted}) and the shift is within
          [2e] of zero. It takes precedence over [Candidate_unstable]. Its JSON
          spelling is [baseline_unstable]. *)
  | Environment
      (** The load given to {!judge}, or to {!decide} for a pending relation,
          was [Loaded]. It concerns sampled comparisons only, and its shift is
          reported as information. Its JSON spelling is [environment]. *)
  | Unconfirmed
      (** The confirmation trial did not reproduce the pending regression, or
          could not ({!decide}). Its JSON spelling is [unconfirmed]. *)
  | Exactness_lost
      (** One side is exact and the other sampled, or both are sampled for a
          counter metric ({!Metric.is_counter}) under a relative budget of [0],
          which a rank test never judges. A loaded host keeps this reason. Its
          JSON spelling is [exactness_lost]. *)
  | Batch_drifted
      (** The batch size moved. For a sampled row, this trial's batch size is
          not the row's and the shift is within [2e] of zero; for an exact row,
          the count was probed at a batch size other than the case's frozen one
          ({!Baseline.case_frozen_k}), which happens only when the frozen one is
          more than 16 times this trial's ({!Measure.probe_k}), and the counts
          differ. Its JSON spelling is [batch_drifted]. *)
  | Candidate_unstable
      (** This run's samples show severe outlier variance inflation and the
          shift is within [2e] of zero. Its JSON spelling is [unstable]. *)
  | Candidate_drifted
      (** This run's trial carries the drift flag ({!Run.type-sampled}) and the
          shift is within [2e] of zero. The flag is read only on a quiet host.
          Its JSON spelling is [drifted]. *)

(** The type for demonstrated directions. *)
type strong =
  | Exact_change of { baseline : int; candidate : int }
      (** The baseline count and this run's count. *)
  | Confirmed of {
      first : shift;  (** The first trial's shift, the one reported. *)
      confirmation : shift;
          (** The confirmation trial's shift against the same baseline samples,
              at α = 0.05 per side. *)
      pooled : float array;
          (** Both trials' samples, sorted ascending, which an advanced row
              stores. *)
      k : int;  (** The batch size of both trials. *)
    }

(** The type for relations. A relation compares this run's evidence with a
    baseline row under the metric's budget: its relative tolerance [r] and
    equivalence band [e] ({!Budget.type-contract}), or those of the default
    budget ([r = 0.05], [e = 0.025]) for a metric with an [at_most] cap or no
    budget.

    Over samples, with [L] and [U] the shift's bounds, the relation is
    [Improved] if [U < -e], [Regressed] if [L > r], [Equivalent] if [-e <= L]
    and [U <= e], [Changed_within_budget] if [L > e] and [U <= r],
    [Within_budget] if [U <= r], and [Inconclusive Wide_interval] otherwise. At
    [r = 0], hence [e = 0], it is [Improved] if [U < 0], [Regressed] if [L > 0],
    [Within_budget] if [U <= 0] and [Wide_interval] otherwise, never
    [Equivalent]. An [Improved], [Regressed] or [Changed_within_budget] relation
    whose estimate is within [2e] of zero is vetoed when a side's samples are
    unstable: it is [Within_budget] if [U <= r], and otherwise
    [Baseline_unstable] or [Candidate_unstable], the baseline's taking
    precedence. An [Improved] or [Regressed] relation then waits for its
    confirmation ({!decide}).

    Over exact counts [b] (baseline) and [c] (this run), the relation is
    [Equivalent None] if [c = b] and [Improved] if [c < b]. A growth is
    [Regressed] when it exceeds [r] of [b] or starts from [b = 0], and is
    [Changed_within_budget] otherwise. Under an [at_most] cap [v], a count
    [c > v] is [Regressed] whatever [b], and any other growth is
    [Changed_within_budget]. When the count was probed at a batch size other
    than the case's frozen one ({!Baseline.case_frozen_k}), as
    {!Measure.probe_k} decides from the frozen one and this trial's, a changed
    count is [Batch_drifted], except over the cap.

    An [at_most] cap thus yields [Equivalent None], [Improved],
    [Changed_within_budget], [Regressed] or [Inconclusive Batch_drifted] on
    exact counts, [Inconclusive Exactness_lost] when one side is exact and the
    other sampled, and the default budget's relations when both are sampled;
    only an exact count over the cap fails the case ({!report_fails}). *)
type relation =
  | Improved of strong  (** A confirmed or exact improvement. *)
  | Regressed of strong  (** A confirmed or exact regression. *)
  | Equivalent of shift option
      (** No change beyond the band; [None] for equal counts. *)
  | Changed_within_budget of shift
      (** A demonstrated slowdown the budget allows. *)
  | Within_budget of shift
      (** No slowdown beyond the budget, and no direction shown: the sampled
          shift's upper bound is within the budget. *)
  | Inconclusive of { reason : reason; shift : shift option }
      (** No relation, for [reason]. [shift] is the first trial's shift iff the
          rank test ran, whatever the reason. *)

(** The type for a metric's verdict. *)
type metric_verdict =
  | Proposed
      (** The section has no row for this case and metric, or no section is
          compared ({!type-comparison}). This run's evidence is proposed for the
          corrected file. An exact count over an [at_most] cap still fails its
          case ({!report_fails}). *)
  | Judged of relation  (** The relation with the section's row. *)

(** {1:reports Reports} *)

type metric_report = {
  metric : Metric.t;  (** The metric. *)
  verdict : metric_verdict;  (** Its verdict. *)
  budget : Budget.t option;
      (** The budget that binds it after {!judge}'s resolution. With [None] the
          metric never fails its case or makes it inconclusive. *)
}
(** The type for one metric of one case. *)

type case_report = {
  id : string;  (** The case id. *)
  full_name : string;  (** The case's {!Bench.full_name}. *)
  trial : Run.Trial.t;
      (** The first trial: the evidence a proposed row or a replaced section
          records. The confirmation trial is not kept. *)
  reports : metric_report list;
      (** One report per metric the trial measured, in the trial's order. *)
  warnings : string list;
      (** The first trial's warnings, then those of the confirmation trial that
          the first did not raise. *)
}
(** The type for one case's result. *)

(** {1:comparability Comparison states} *)

(** The type for staleness. *)
type staleness =
  | Ocaml_mismatch of { section : string; current : string }
      (** The section's [# ocaml:] line [section] differs from the running
          program's identity [current] ({!Env.ocaml_identity}). The compiler
          identity is the only cause of staleness. *)

(** The type for what judgment found for this machine's section. *)
type comparison =
  | No_baseline
      (** The file has no section for this machine; the empty-file baseline has
          none. Every metric is [Proposed]. *)
  | Stale of staleness
      (** The section is stale. Every metric is [Proposed], and {!corrected}
          replaces the section. *)
  | Compared  (** The section's identity is the running program's. *)

val compared_section :
  identity:Baseline.identity -> Baseline.t -> Baseline.section option
(** [compared_section ~identity file] is [identity.machine]'s section of [file]
    when it is compared, that is when its [# ocaml:] line is [identity.ocaml],
    and [None] when it is missing or stale. {!judge} compares rows of this
    section, and {!Check.run} freezes batch sizes from it, so the two read the
    same rows. *)

(** {1:judging Judging} *)

type t
(** The type for decided verdicts. A verdict keeps the baseline file it was
    judged against, the input of {!corrected}. *)

type provisional
(** The type for first-pass verdicts: every metric is settled or waits for its
    case's confirmation trial. *)

val judge :
  identity:Baseline.identity ->
  suite:string ->
  load:Env.load ->
  selection:[ `Full | `Partial ] ->
  budgets:Budget.t list ->
  file:Baseline.t ->
  cases:(Bench.case * Run.Trial.t) list ->
  provisional
(** [judge ~identity ~suite ~load ~selection ~budgets ~file ~cases] is the first
    pass over [cases], each a case and its first trial, against the section of
    [file] for [identity.machine]. The section is found here, so evidence is
    never judged against another machine's section.
    - [identity] is this machine's identity; its [ocaml] decides staleness.
    - [suite] heads the file {!corrected} builds over the empty-file baseline.
    - [load] is the load the first pass is judged under.
    - [selection] may be [`Full] only when [cases] is every case of the suite.
      On a compared section, [`Full] lets {!corrected} prune the rows of absent
      cases and adds one warning per pruned case id ({!val-warnings}).
    - [budgets] are the suite's budgets. For each metric a case's own budget
      wins and the others inherit [budgets]; budgets on metrics the trial did
      not measure are dropped, and a case left with none gets
      {!Budget.val-defaults}, whose budget binds only a case that measures
      [wall_time].
    - [file] is kept for {!corrected}.

    A sampled comparison tests a non-positive sample ([Non_positive]) first. It
    then computes the shift at α = 0.005 per side and tests, in order, a loaded
    host ([Environment]), this trial's drift flag ([Candidate_drifted]) and a
    moved batch size ([Batch_drifted]) before the relation ({!type-relation}).
    [Exactness_lost] is decided before all of these. An exact comparison settles
    here, on a loaded host too, and a strong sampled relation waits for
    {!decide}.

    The caller must have checked that [budgets] holds at most one budget per
    metric and that [file]'s suite header, if any, is [suite], as {!Check.run}
    does. [judge] checks neither, so it ignores a second budget for a metric and
    judges a file of another suite.

    Raises [Invalid_argument] if two cases share an id. *)

val confirmations : provisional -> string list
(** [confirmations p] is the ids of the cases with a pending relation, each
    once, in the order of {!judge}'s [cases]. It is empty iff {!decide} needs no
    confirmation trial. *)

val decide :
  load:Env.load -> confirmations:(string * Run.Trial.t) list -> provisional -> t
(** [decide ~load ~confirmations p] is the verdict, each pending relation
    resolved with its case's confirmation trial from [confirmations]. The
    relation is [Confirmed], with both shifts and the pooled samples, when the
    confirmation alone reproduces it against the same baseline samples at α =
    0.05 per side ([U < -e] for an improvement, [L > r] for a regression). It is
    unconfirmed when the confirmation does not, and when the trial is missing,
    lacks the metric, measured it as exact, is drifted, holds a non-positive
    sample, ran at another batch size than the first trial, or is unstable with
    an estimate within [2e] of zero. An unconfirmed improvement is
    [Within_budget] with the first shift, since its [U < -e] is within any
    budget; an unconfirmed regression is [Inconclusive Unconfirmed]. When [load]
    is [Loaded], every pending relation is [Inconclusive Environment] instead,
    whatever the trials. An inconclusive relation keeps the first shift. Settled
    metrics are unchanged, and [load] is recorded as {!load}.

    Raises [Invalid_argument] if [confirmations] names a case twice or names a
    case {!confirmations} did not list. *)

(** {1:observers Observers} *)

val overall : t -> [ `Pass | `Fail | `Inconclusive ]
(** [overall t] is [`Fail] if some case's {!case_overall} is [`Fail], else
    [`Inconclusive] if some case's is [`Inconclusive], else [`Pass]. *)

val comparison : t -> comparison
(** [comparison t] is what {!judge} found for the section. *)

val cases : t -> case_report list
(** [cases t] is the case reports, in the order of {!judge}'s [cases]. *)

val report_fails : case_report -> metric_report -> bool
(** [report_fails c r] is [true] iff [r] fails its case [c]. Under a relative
    budget, [r] fails iff it is [Regressed]. Under an [at_most] cap [v], [r]
    fails iff [c]'s trial measured the metric as an exact count above [v],
    whatever [r]'s verdict, [Proposed] included; a sampled count never fails a
    cap. Without a budget, [r] never fails. A caller that shows a failure must
    decide it with this predicate or {!case_overall}, so the report agrees with
    {!exit_code} and {!to_json}. *)

val case_overall : case_report -> [ `Pass | `Fail | `Inconclusive ]
(** [case_overall c] is [`Fail] if one of [c]'s reports fails it
    ({!report_fails}), else [`Inconclusive] if one of its reports has a budget
    and is [Inconclusive], else [`Pass]. *)

val strong_estimate : strong -> float option
(** [strong_estimate s] is the estimate of the first shift for [Confirmed], and
    [(c - b) / b] for [Exact_change] with counts [b] and [c], [None] when
    [b = 0]. *)

val warnings : t -> string list
(** [warnings t] is the run's warnings about rows the corrected file drops:
    - under a [`Full] selection of a compared section, one per row id of the
      section that no judged case has, in ascending order, saying its rows are
      pruned;
    - under a [`Partial] selection of a stale section, one counting the
      section's row ids outside the selection, when there are any, saying the
      corrected file drops their rows. {!bless} returns the same one.

    A case's own warnings are in its {!case_report}. *)

val suite : t -> string
(** [suite t] is {!judge}'s [suite]. *)

val identity : t -> Baseline.identity
(** [identity t] is {!judge}'s [identity]. *)

val load : t -> Env.load
(** [load t] is the [load] given to {!decide}. Under {!Check.run_with} it is the
    last sample judgment used: the first one when no case was pending, else the
    one taken before the confirmation sweep. A report that prints the host's
    load must print this value, so its load message agrees with the relations.
*)

val exit_code : ?strict:bool -> t -> int
(** [exit_code ~strict t] is [1] if [overall t] is [`Fail] and [0] otherwise.
    With [strict], [false] by default, it is also [1] if [overall t] is
    [`Inconclusive], if the section is not [Compared], or if some metric is
    [Proposed]. It is never [2], the code the caller gives an operational
    failure. *)

val to_json : t -> string
(** [to_json t] is [t]'s JSON document, on one line without a final newline. Its
    field names and values are frozen. The fields, in order:
    - [overall]: [overall t] as ["pass"], ["fail"] or ["inconclusive"];
    - [machine]: [identity t]'s key;
    - [summary]: an object mapping each metric id, in order of first appearance
      in the case reports, to [n_improved], [n_regressed], [n_equivalent]
      ([Changed_within_budget] and [Within_budget] included), [n_inconclusive]
      ([Proposed] included) and [geomean_delta];
    - [cases]: per case, [id], [full_name], [overall] ({!case_overall}) and
      [metrics], one object per report.

    A metric object holds, in order:
    - [metric], its id;
    - [relation]: ["improved"], ["regressed"], ["equivalent"],
      ["changed_within_budget"], ["within_budget"] or ["inconclusive"], and
      [null] for [Proposed];
    - [status], the metric's own: ["fail"] iff {!report_fails}, else
      ["inconclusive"] for an [Inconclusive] relation, budgeted or not, else
      ["pass"]. A case can pass over a metric that is ["inconclusive"];
    - [reason]: the reason's spelling ({!type-reason}) for [Inconclusive],
      ["missing_baseline"] for [Proposed], else [null];
    - for a [Judged] metric, [exact: true] when the first trial's evidence is
      exact, else [confirmed] ([true] iff [Improved] or [Regressed]) and [n],
      the first trial's sample count;
    - [delta], [lower_delta] and [upper_delta]: the relation's shift, the first
      one for [Confirmed], [(c - b) / b] for [Exact_change] and [0] for
      [Equivalent None]. The bounds are [null] for exact evidence; all three are
      [null] for [Proposed], for an [Inconclusive] without a shift and for a
      change from a count of [0].

    [geomean_delta] is the geometric mean of the ratios [1 + delta] that are
    finite and positive, minus 1, and [null] when there are none. A float prints
    [%.17g], and [null] when it is not finite. A string escapes the double quote
    and the backslash with a backslash, newline, carriage return and tab by
    name, and other bytes below [0x20] as [\u00XX]; every other byte is copied,
    so a [full_name] that is not UTF-8 makes an invalid document. *)

(** {1:write Write paths} *)

val corrected : t -> Baseline.t option
(** [corrected t] is the corrected file: the baseline [t] was judged against,
    with this machine's section updated. It is [None] when that changes no byte.

    On a compared section ({!Baseline.update_rows}), each [Improved] row
    advances, to the pooled samples at the batch size [k] for [Confirmed] and to
    this run's count for [Exact_change]. Each [Proposed] metric adds this run's
    evidence as a row, one that fails its cap included. Under a [`Full]
    selection the rows of case ids no judged case has are pruned. Every other
    row, the section's header and its annotations keep their bytes, so
    [Regressed], [Equivalent], [Changed_within_budget], [Within_budget] and
    [Inconclusive] rows keep their old evidence.

    On a missing or stale section ({!Baseline.set_section}), the section is
    replaced by one with [identity t]'s header, no annotation and the rows of
    every first trial. The result starts from a new file headed [suite t] when
    the judged file has no header.

    Other machines' sections keep their bytes. The result never replaces a
    compared row with unconfirmed evidence. A proposed row or a replaced section
    records this run's trials as measured, loaded host, drift flag and
    instability included.

    Raises [Invalid_argument] if the judged file has no header and
    {!Baseline.check_suite} refuses [suite t], or if a trial holds evidence the
    file refuses ({!Baseline.sampled_row}, {!Baseline.exact_row}). *)

val bless :
  ?annotations:string list ->
  identity:Baseline.identity ->
  suite:string ->
  selection:[ `Full | `Partial ] ->
  run:Run.t ->
  Baseline.t ->
  Baseline.t * string list
(** [bless ?annotations ~identity ~suite ~selection ~run file] is [file] with
    [run]'s trials recorded in the section of [identity.machine], and the
    warnings of that re-record. [selection] must describe [run], [`Full] iff
    [run] holds every case of the suite.

    Under a [`Partial] selection of a compared section
    ({!Baseline.update_rows}), only the rows of [run]'s cases change: each
    case's rows become its trial's, and its rows for metrics the trial did not
    measure are removed. The header lines, [# host:] included, and every other
    row keep their bytes, [annotations] are appended to the section's, and there
    is no warning.

    Otherwise, under a [`Full] selection or on a missing or stale section
    ({!Baseline.set_section}), the section is replaced by one with [identity]'s
    header, [annotations] as its only annotations and the rows of [run]'s
    trials, starting from a new file headed [suite] when [file] has no header. A
    [`Partial] selection of a stale section returns {!val-warnings}'s warning
    about the dropped rows.

    [annotations] defaults to [[]]. Other sections keep their bytes. [bless]
    records every trial, regressions included; refusing to record on a loaded
    host is the caller's decision.

    Raises [Invalid_argument] if [identity], an annotation or a trial breaks the
    file grammar, or if [file] has no header and {!Baseline.check_suite} refuses
    [suite] ({!Baseline.set_section}, {!Baseline.update_rows}). *)
