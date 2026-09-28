(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The command line of [Thumper.run].

    {!main} reads the command line, the environment, the terminal and the file
    system, and composes {!Check}, {!Verdict}, {!Baseline} and {!Env} around
    them. Every other value is a pure function that decides one thing {!main}
    needs: {!parse} reads the command line; {!filter_of} and {!config_of} turn
    the options into a selection and a configuration; {!use_color},
    {!default_baseline_dir} and {!promotion_staged} interpret the environment;
    {!status_line}, {!accept_command} and {!render_check} build printed text.

    The facade re-exports none of these values: [Thumper.run] calls {!main}, and
    the module is otherwise visible only as [Thumper.Private.Cli], outside the
    API. [Thumper.run]'s documentation in the facade is the user contract of the
    command line: its grammar, its report, its files, its streams and its exit
    codes. What it states is stable, and so is the summary's colour, which
    follows the exit code ({!render_check}). What it leaves unstated may change:
    the text of each message, the report's column widths, its other colours, and
    the wrapping of its [rerun:] line. *)

(** {1:parsing Command lines and options} *)

type subcommand = [ `Check | `Bless | `List ]
(** The type for subcommands, named [check], [bless] and [list] on the command
    line. *)

type color = [ `Auto | `Always | `Never ]
(** The type for [--color] modes, named [auto], [always] and [never]. *)

type options = {
  subcommand : subcommand;
      (** The first argument's subcommand, [`Check] when it names none. *)
  patterns : string list;
      (** The [-f] arguments, the bare arguments and every argument after [--],
          in command-line order. *)
  tags : string list;  (** The [--tag] arguments, in command-line order. *)
  preset : [ `Default | `Quick | `Precise ];
      (** [`Quick] under [--quick], [`Precise] under [--precise], and [`Default]
          otherwise. *)
  baseline : string option;  (** The [--baseline] argument. *)
  json : string option;  (** The [--json] argument, never ["-"]. *)
  strict : bool;  (** Whether [--strict] was given. *)
  wait_quiet : float option;
      (** The [--wait-quiet] argument in seconds, finite and non-negative. *)
  force : bool;  (** Whether [--force] was given. *)
  color : color;  (** The [--color] argument, [`Auto] without one. *)
}
(** The type for accepted command lines. [--baseline], [--json], [--wait-quiet]
    or [--color] given twice keeps its last argument. In a value {!parse}
    returns, every flag given applies to [subcommand]. [--color] applies to
    every subcommand and changes nothing under [list], which prints no styled
    text. *)

(** The type for parse results. *)
type parsed =
  | Run of options  (** An accepted command line. *)
  | Help  (** [-h] or [--help]. *)
  | Version  (** [-V] or [--version]. *)
  | Usage_error of string
      (** A refused command line, with the message that says why. *)

val parse : string array -> parsed
(** [parse argv] is the result of parsing [argv], whose first element, the
    program name, is skipped. [parse] reads no environment and prints nothing.

    The first argument is the subcommand when it is [check], [bless] or [list];
    a later one is a pattern. Before [--], a flag that takes a value takes the
    next argument, even one that starts with [-], and a long one given as
    [--opt=v] reads as [--opt v]. An argument that starts with [-], other than
    [-] alone, and names no flag is an unknown option. Every argument after [--]
    is a pattern.

    Arguments are read left to right, and the first of these ends the reading:
    [-h] or [--help] makes [Help], [-V] or [--version] makes [Version], and a
    defect makes [Usage_error]. A defect is an unknown option, a flag with no
    argument left, a [--wait-quiet] argument that [float_of_string_opt] does not
    read as a finite non-negative number, a [--color] argument other than
    [auto], [always] or [never], the [--json] argument ["-"], or a value given
    with [=] to a flag that takes none ([--strict=no]). When the reading ends
    without one of these, a flag given to a subcommand it does not apply to
    makes [Usage_error]. When none is, [--quick] together with [--precise] does.
*)

val filter_of : patterns:string list -> tags:string list -> Bench.filter option
(** [filter_of ~patterns ~tags] is the selection of the cases that contain one
    of the patterns in their id, when there are patterns, and carry every tag.
    With [`Or ps] holding one [`Id p] per pattern and [`And ts] one [`Tag t] per
    tag, it is [None] when both lists are empty, [Some (`Or ps)] when only
    [patterns] is non-empty, [Some (`And ts)] when only [tags] is, and
    [Some (`And [`Or ps; `And ts])] otherwise. *)

val config_of : ?config:Config.t -> options -> Config.t
(** [config_of ?config o] is [config] with its samples set to [Config.quick]'s
    under [--quick] and to [Config.precise]'s under [--precise]
    ({!Config.samples}). [config] defaults to {!Config.default}. Every other
    field, forking included, is [config]'s. *)

(** {1:terminal Terminal output} *)

val use_color :
  color -> is_tty:bool -> rule_action:bool -> no_color:bool -> bool
(** [use_color mode ~is_tty ~rule_action ~no_color] is whether a stream is
    coloured: [true] under [`Always], [false] under [`Never], and
    [(is_tty || rule_action) && not no_color] under [`Auto]. [is_tty] is whether
    the stream is a terminal, [rule_action] whether the process is a dune rule
    action ({!promotion_staged}), and [no_color] whether [NO_COLOR] is set and
    non-empty. *)

val status_line : Check.progress -> string
(** [status_line p] is the text of the progress tick [p],
    [thumper: <verb> <index>/<total> — <id>], where [<verb>] is [measuring] or
    [confirming] for [p]'s phase. It holds no carriage return and no escape
    sequence. {!main} prints it on stderr at each tick while [check] and [bless]
    measure, when stderr is a terminal. *)

(** {1:paths Paths and dune rule actions} *)

val default_baseline_dir :
  dir_exists:(string -> bool) ->
  exe:string ->
  cwd:string ->
  cwd_in_build:bool ->
  string
(** [default_baseline_dir ~dir_exists ~exe ~cwd ~cwd_in_build] is the directory
    of the default baseline, the first of:
    + [cwd], when [cwd_in_build];
    + the source directory of [exe], when [exe], made absolute against [cwd],
      contains [/_build/] and [dir_exists] holds of that directory;
    + [cwd].

    The source directory is the part of [exe] before its last [/_build/], joined
    with what follows it less an optional [.sandbox/<hash>], the build context
    and the file name: [/w/_build/default/bench/x.exe] maps to [/w/bench].
    [_build] is the only build directory name recognised. [dir_exists] is the
    only query of the file system. *)

val promotion_staged : inside_dune:string option -> cwd:string -> bool
(** [promotion_staged ~inside_dune ~cwd] is whether the process is a dune rule
    action, where the rule's [diff?] stages the corrected file for
    [dune promote]. [inside_dune] is the value of [INSIDE_DUNE], [None] when it
    is unset. The result is [true] iff [inside_dune] is [Some v] and [cwd] has a
    [_build] segment or, when [v] is absolute, lies strictly under
    [Filename.dirname v]. *)

val accept_command :
  promotion_staged:bool -> corrected:string -> baseline:string -> string
(** [accept_command ~promotion_staged ~corrected ~baseline] is the command that
    replaces [baseline] with [corrected]: ["dune promote"] when
    [promotion_staged], and ["mv <corrected> <baseline>"] otherwise. A path
    stays bare when it is non-empty and each of its bytes is an ASCII letter, a
    digit or one of [_ . / : @ % + = , -]; any other path is quoted by
    [Filename.quote]. *)

(** {1:rendering Rendering the report} *)

type render = {
  color : bool;
      (** Whether to style the report with ANSI escapes. Removing the escapes
          from a styled report gives the unstyled one. *)
  accept : string;
      (** The command of the [accept:] line ({!accept_command}). *)
  exe : string option;
      (** The program the [rerun:] line runs, which {!render_check} quotes as
          {!accept_command} quotes a path; [None] for no [rerun:] line. *)
  github : bool;
      (** Whether the report ends with one [::error::] line per metric that
          fails its case. *)
  baseline_path : string;
      (** The baseline's path, which the header of a run against a current
          section prints. *)
  corrected_path : string;
      (** The corrected file's path. {!render_check} does not read it; the path
          it prints is the one in [accept]. *)
  wrote_corrected : bool;
      (** Whether the corrected file was written. The [accept:] line prints iff
          it was. The load warning beside it prints when it was, the section is
          missing or stale, and [Verdict.load] is loaded. *)
  rerun_flags : string list;
      (** The [rerun:] line's arguments before its selection, one item per flag
          with its argument. {!render_check} prints them as given, so each
          argument must already be quoted as {!accept_command} quotes a path. *)
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
(** The type for what {!render_check} needs besides the verdict. *)

val render_check : render -> Verdict.t -> string
(** [render_check r v] is the report of the [check] run judged as [v], ending in
    a newline. Its load warning reports [Verdict.load v], the sample [v] was
    judged under, and prints only when that sample is loaded.

    The report and {!Verdict.exit_code} share one predicate,
    {!Verdict.report_fails}. A metric reads [REGRESSED] iff it fails its case,
    and then has an [::error::] line when [r.github]. A case counts as regressed
    in the summary iff one of its metrics fails it. The [rerun:] line prints iff
    [r.exe] is [Some _] and some case fails. The summary, which only a run
    against a current section prints, is red iff
    [Verdict.exit_code ~strict:r.strict v] is not [0]. *)

(** {1:running Running a command line} *)

val main :
  ?baseline:string ->
  ?config:Config.t ->
  ?budgets:Budget.t list ->
  argv:string array ->
  name:string ->
  Bench.t list ->
  int
(** [main ?baseline ?config ?budgets ~argv ~name benches] runs the command line
    [argv] on the suite [name] of [benches] and is its exit code. It never exits
    the process. [Thumper.run] is [main] with [argv] defaulting to [Sys.argv].

    A {e stop} prints [thumper: <message>] on stderr and makes [main] return
    [2]. A {!Check.Error}, a {!type:Baseline.error} from reading or writing a
    file, a {!type:Env.Lock.error}, the [Invalid_argument] of a malformed
    [THUMPER_MACHINE], and a [Unix.Unix_error] of an unlink, a pre-flight or the
    [--json] write are stops; any other exception escapes [main]. The steps, in
    order:
    + [main] raises [Invalid_argument] if [name] fails {!Baseline.check_suite}
      or [budgets] fails {!Budget.check_distinct}, whatever [argv] holds.
    + It parses [argv]. [Help] prints the help and [Version] the version on
      stdout, and both return [0]. [Usage_error] prints [thumper: <message>] and
      [Try '-h' for usage.] on stderr and returns [2]. None of the three touches
      a file.
    + It resolves the baseline path: [--baseline], else [baseline], else
      [<name>.thumper] in {!default_baseline_dir}'s directory. It passes that
      function [Sys.executable_name], not [argv.(0)], and a [cwd_in_build] true
      iff the working directory has a [_build] segment. The corrected file's
      path is the baseline path followed by [.corrected].
    + It removes the corrected file and the [--json] file, whatever the
      subcommand; a file it cannot remove stops the run. It stops when the
      directory of the [--json] file, or under [bless] that of the corrected
      file, is not a writable directory.
    + It decides once whether the report is coloured: {!use_color} for stdout,
      with {!promotion_staged}'s result as [rule_action]. Nothing [main] prints
      on stderr is coloured.
    + It runs the subcommand, whose exit code it returns.

    [list] selects the cases with {!Check.select}, given the config's metrics
    and [budgets], and prints their ids on stdout, one per line. It reads
    neither the baseline nor [THUMPER_MACHINE] and takes no lock.

    [check] validates [THUMPER_MACHINE], selects the cases as [list] does, and
    reads the baseline. When there is no baseline file, it stops unless the
    corrected file's directory is a writable directory. It waits for a quiet
    host under [--wait-quiet]. It then holds the measurement lock
    ({!Env.Lock.with_lock}) around {!Check.run_with}, whose own acquisition
    nests. It writes the [--json] file, then the corrected file when
    {!Verdict.corrected} is [Some], prints {!render_check}'s report on stdout
    and returns [Verdict.exit_code ~strict]. Its {!type:render} has [exe] set to
    [argv.(0)], or [None] in a dune rule action, and [rerun_flags] holding
    [--quick] or [--precise] when given, [--baseline] when [argv] gave one, and
    one [--tag] per tag. When the corrected file cannot be written, the report
    prints without its [accept:] line before the stop.

    [bless] selects the cases as [list] does, validates [THUMPER_MACHINE], reads
    the baseline and waits under [--wait-quiet]. An expired wait stops the run
    unless [--force] is given or the host is quiet by then. It then holds the
    lock, samples the load, and stops on a loaded host unless [--force] is
    given, and then records the load through {!Verdict.bless}'s [annotations].
    It measures with {!Check.measure}, writes {!Verdict.bless}'s file as the
    corrected file, prints its own report on stdout, built without
    {!render_check}, and returns [0]. *)
