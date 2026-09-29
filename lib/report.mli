(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The reports of [check] and [bless], and the progress line.

    {!val-check} and {!val-bless} build a report as text, in blocks separated by
    a blank line and ending in a newline: a header, a table with one row per
    case, for [check] the [::error::] lines, and last the hints directly above
    the summary, the report's last line. They read nothing but their arguments
    and print nothing: {!Cli.main} prints the report on stdout. {!status_redraw}
    and {!status_erase} are the bytes of the progress line {!Cli.main} prints on
    stderr while a run measures.

    The module is visible only as [Thumper.Private.Report], outside the API.
    [Thumper.run]'s documentation states which parts of the report are stable
    ({!Cli}). *)

val status_redraw : Check.progress -> string
(** [status_redraw p] is the bytes that replace the status line on a terminal
    with the text of the progress tick [p]: a carriage return,
    [  [<index>/<total>] <id>…], with [: confirming] before the ellipsis in the
    confirmation sweep, and the erase to the end of the line. {!Cli.main} prints
    it on stderr at each tick while [check] and [bless] measure, when stderr is
    a terminal. *)

val status_erase : string
(** [status_erase] is the bytes that erase the status line on a terminal: a
    carriage return and the erase to the end of the line. *)

val loaded : load:float -> cores:int -> string
(** [loaded ~load ~cores] is how every line that reports a loaded host names the
    load: [load 7.9 on 8 cores, over 4.0], with the threshold of
    {!Env.loaded_at}. *)

val duration_str : float -> string
(** [duration_str secs] is [secs] as the summaries print it: [%.1fms] under 10
    ms, [%.0fms] under a second, and [%.1fs] from there, as [4.2ms], [310ms] and
    [3.2s]. *)

val shell_arg : string -> string
(** [shell_arg s] is [s] as one argument of a POSIX shell command: [s] itself
    when it is non-empty and each of its bytes is an ASCII letter, a digit or
    one of [_ . / : @ % + = , -], and [Filename.quote s] otherwise. *)

(** {1:check The check report} *)

type render = {
  color : bool;
      (** Whether to style the report with ANSI escapes. Removing the escapes
          from a styled report gives the unstyled one. *)
  exe : string;
      (** The program the [rerun:] and [accept:] lines run, which {!val-check}
          quotes with {!shell_arg}. *)
  github : bool;
      (** Whether the report ends with one [::error::] line per metric that
          fails its case. *)
  baseline_path : string;
      (** The baseline's path, which the header of a run against a current
          section prints. *)
  flags : string list;
      (** The arguments the [rerun:] and [accept:] lines repeat before their
          selection, one item per flag with its argument. {!val-check} prints
          them as given, so each argument must already be quoted with
          {!shell_arg}. *)
  patterns : string list;
      (** The run's patterns. A hint line selects by them, quoted, in place of
          its cases' ids: the [rerun:] line when no case or more than 10 cases
          fail, the [accept:] line when it records every case of the run. *)
  strict : bool;
      (** Whether the run was given [--strict]. The summary's colour follows it,
          and the summary ends with [; failed under --strict] when [--strict]
          alone makes the exit code [1]. *)
  cpu_model : string;
      (** The host's CPU model, which the header names when this machine has no
          section in the baseline. *)
  duration : float;
      (** The seconds the run measured for, which the summary prints. *)
}
(** The type for what {!val-check} needs besides the verdict. *)

val check : render -> Verdict.t -> string
(** [check r v] is the report of the [check] run judged as [v], ending in a
    newline. Its load warning reports [Verdict.load v], the sample [v] was
    judged under, and prints only when that sample is loaded.

    The report and {!Verdict.exit_code} share one predicate,
    {!Verdict.report_fails}. A metric reads [REGRESSED] iff it fails its case,
    and then has an [::error::] line when [r.github]. A case counts as regressed
    in the summary iff one of its metrics fails it. A row opens on its case's
    {!Verdict.case_overall}, the outcome the summary counts it by: [REGRESSED]
    for [`Fail], [inconclusive] for [`Inconclusive], and for [`Pass] a passing
    word: [improved], [proposed], or [passed] for the relations equivalent and
    within budget. Its other relations follow on the detail line. A regression
    and a relation within budget name their budget, [budget +5%] or [cap 64 w].

    An inconclusive metric's reason joins the hint that is its remedy. The
    [rerun:] line prints iff some case fails, and then names the failing cases,
    or else iff some metric is inconclusive for [Environment], [Unconfirmed] or
    [Candidate_drifted], and then repeats the run's own selection. The [accept:]
    line prints iff some case that does not fail has a [Proposed] or [Improved]
    metric, or one inconclusive for [Batch_drifted], or for [Exactness_lost]
    when the run's count is exact. It is the [bless] command that records those
    cases. [Wide_interval], [Non_positive] and a sampled count's
    [Exactness_lost] make no hint. A load is named by {!loaded}.

    The header is [<suite>: ] and the run's subject, and a failing case's id is
    bold. The summary counts each case once, by {!Verdict.case_overall}:
    [<n> passed], followed by [(<n> improved)] when some passing row opens on
    [improved], [<n> regressed], [<n> inconclusive], and [<n> proposed] for the
    passing cases whose every metric is proposed. A term of no case is left out.
    It then prints [in] and [r.duration] by {!duration_str}, and ends in a full
    stop. Red, on the [regressed] term and the [--strict] clause, appears iff
    [Verdict.exit_code ~strict:r.strict v] is [1], and [passed] is green iff it
    is [0]. *)

(** {1:bless The bless report} *)

val bless :
  color:bool ->
  suite:string ->
  machine:string ->
  baseline_path:string ->
  cases:int ->
  load:Env.load ->
  duration:float ->
  Run.t ->
  string
(** [bless ~color ~suite ~machine ~baseline_path ~cases ~load ~duration run] is
    the report of the [bless] run [run], which measured [cases] selected cases
    of [suite] for [duration] seconds and recorded them in [baseline_path] for
    the machine key [machine], ending in a newline. Its header names the cases
    and the machine, followed by a load warning when [load] is loaded: [load] is
    the load the run measured under, and only [--force] measures on a loaded
    host. Its table has one [blessed] row per trial of [run], followed by the
    trials' warnings. Its summary is
    [<cases> blessed into <baseline_path> in <duration>.]. [color] styles the
    report as {!render}'s [color] does. *)
