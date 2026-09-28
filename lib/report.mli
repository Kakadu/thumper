(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The reports of [check] and [bless], and the progress line.

    {!check} and {!bless} build a report as text, in blocks separated by a blank
    line and ending in a newline: a header, a table with one row per case, the
    actions, and for [check] against a current section a summary. They read
    nothing but their arguments and print nothing: {!Cli.main} prints the report
    on stdout. {!status_line} is the text of the progress line {!Cli.main}
    prints on stderr while a run measures.

    The module is visible only as [Thumper.Private.Report], outside the API.
    [Thumper.run]'s documentation states which parts of the report are stable
    ({!Cli}). *)

val status_line : Check.progress -> string
(** [status_line p] is the text of the progress tick [p],
    [thumper: <verb> <index>/<total> — <id>], where [<verb>] is [measuring] or
    [confirming] for [p]'s phase. It holds no carriage return and no escape
    sequence. {!Cli.main} prints it on stderr at each tick while [check] and
    [bless] measure, when stderr is a terminal. *)

val shell_arg : string -> string
(** [shell_arg s] is [s] as one argument of a POSIX shell command: [s] itself
    when it is non-empty and each of its bytes is an ASCII letter, a digit or
    one of [_ . / : @ % + = , -], and [Filename.quote s] otherwise. *)

(** {1:check The check report} *)

type render = {
  color : bool;
      (** Whether to style the report with ANSI escapes. Removing the escapes
          from a styled report gives the unstyled one. *)
  accept : string;
      (** The command of the [accept:] line ({!Cli.accept_command}). *)
  exe : string option;
      (** The program the [rerun:] line runs, which {!check} quotes with
          {!shell_arg}; [None] for no [rerun:] line. *)
  github : bool;
      (** Whether the report ends with one [::error::] line per metric that
          fails its case. *)
  baseline_path : string;
      (** The baseline's path, which the header of a run against a current
          section prints. *)
  corrected_path : string;
      (** The corrected file's path. {!check} does not read it; the path it
          prints is the one in [accept]. *)
  wrote_corrected : bool;
      (** Whether the corrected file was written. The [accept:] line prints iff
          it was. The load warning beside it prints when it was, the section is
          missing or stale, and [Verdict.load] is loaded. *)
  rerun_flags : string list;
      (** The [rerun:] line's arguments before its selection, one item per flag
          with its argument. {!check} prints them as given, so each argument
          must already be quoted with {!shell_arg}. *)
  rerun_patterns : string list;
      (** The run's patterns. The [rerun:] line selects by them, quoted, in
          place of the failing ids when more than 10 cases fail. *)
  strict : bool;
      (** Whether the run was given [--strict]. The summary's colour follows it,
          and the summary ends with [; failed under --strict] when [--strict]
          alone makes the exit code [1]. *)
  cpu_model : string;
      (** The host's CPU model, which the header names when this machine has no
          section in the baseline. *)
}
(** The type for what {!check} needs besides the verdict. *)

val check : render -> Verdict.t -> string
(** [check r v] is the report of the [check] run judged as [v], ending in a
    newline. Its load warning reports [Verdict.load v], the sample [v] was
    judged under, and prints only when that sample is loaded.

    The report and {!Verdict.exit_code} share one predicate,
    {!Verdict.report_fails}. A metric reads [REGRESSED] iff it fails its case,
    and then has an [::error::] line when [r.github]. A case counts as regressed
    in the summary iff one of its metrics fails it. The [rerun:] line prints iff
    [r.exe] is [Some _] and some case fails. The summary, which only a run
    against a current section prints, is red iff
    [Verdict.exit_code ~strict:r.strict v] is not [0]. *)

(** {1:bless The bless report} *)

val bless :
  color:bool ->
  suite:string ->
  machine:string ->
  cases:int ->
  load:Env.load ->
  notices:string list ->
  accept:string ->
  Run.t ->
  string
(** [bless ~color ~suite ~machine ~cases ~load ~notices ~accept run] is the
    report of the [bless] run [run], which measured [cases] selected cases of
    [suite] for the machine key [machine], ending in a newline. Its table has
    one [proposed] row per trial of [run], followed by the trials' warnings. Its
    actions are a load warning when [load] is loaded, one warning per notice of
    {!Verdict.bless}, and the [accept:] line of [accept]. [load] is the load the
    run measured under: only [--force] measures on a loaded host, and the
    warning says it was recorded. [color] styles the report as {!render}'s
    [color] does. *)
