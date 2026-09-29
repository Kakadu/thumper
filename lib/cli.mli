(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The command line of [Thumper.run].

    {!main} reads the command line, the environment, the terminal and the file
    system, and composes {!Check}, {!Verdict}, {!Baseline} and {!Env} around
    them, and prints the reports {!Report} builds. {!default_baseline_dir} is
    the pure function that places the default baseline; {!main} applies it to
    the environment and to [Sys.executable_name].

    The facade re-exports none of these values: [Thumper.run] calls {!main}, and
    the module is otherwise visible only as [Thumper.Private.Cli], outside the
    API. [Thumper.run]'s documentation in the facade is the user contract of the
    command line: its grammar, its report, its files, its streams and its exit
    codes. What it states is stable, and so is the summary's colour, which
    follows the exit code ({!Report.val-check}). What it leaves unstated may
    change: the text of each message, the report's column widths, its other
    colours, and the wrapping of its [rerun:] line. *)

(** {1:paths The default baseline's directory} *)

val default_baseline_dir :
  dir_exists:(string -> bool) ->
  inside_dune:string option ->
  source_root:string option ->
  exe:string ->
  cwd:string ->
  string
(** [default_baseline_dir ~dir_exists ~inside_dune ~source_root ~exe ~cwd] is
    the directory of the default baseline. [inside_dune] and [source_root] are
    the values of [INSIDE_DUNE] and [DUNE_SOURCEROOT], [None] when unset, and
    [exe] is made absolute against [cwd], its [.] and [..] segments resolved as
    text.
    - When [inside_dune] is an absolute path [c], the build context's directory,
      and [source_root] is [Some r], it is [cwd] when [cwd] lies under
      [Filename.dirname c], as a rule action's does. Otherwise, when [exe] lies
      under [c], it is [exe]'s directory relative to [c] joined to [r], if
      [dir_exists] holds of it: [/w/_b/default/bench/x.exe] maps to [/w/bench]
      under [c = /w/_b/default] and [r = /w]. Else it is [cwd].
    - When both are [None], it is [cwd] when [cwd] has a [_build] segment, and
      otherwise the source directory of an [exe] containing [/_build/], if
      [dir_exists] holds of it: the part of [exe] before its last [/_build/],
      joined with what follows it less an optional [.sandbox/<hash>], the build
      context and the file name. Else it is [cwd].
    - Otherwise it is [cwd].

    [dir_exists] is the only query of the file system. *)

(** {1:command_line Command lines}

    {!main} reads [argv] with its first element, the program name, skipped. The
    first argument is the subcommand when it is [check], [bless] or [list], and
    the subcommand is [check] otherwise; a later one is a pattern. Before [--],
    a flag that takes a value takes the next argument, even one that starts with
    [-], and a long one given as [--opt=v] reads as [--opt v]. An argument that
    starts with [-], other than [-] alone, and names no flag is an unknown
    option. Every argument after [--] is a pattern, and so are the [-f]
    arguments and the bare arguments, in command-line order. [--baseline],
    [--json], [--wait-quiet] or [--color] given twice keeps its last argument.

    Arguments are read left to right, and the first of these ends the reading:
    [-h] or [--help] asks for the help, [-V] or [--version] for the version, and
    a defect refuses the command line. A defect is an unknown option, a flag
    with no argument left, a [--wait-quiet] argument that [float_of_string_opt]
    does not read as a finite non-negative number, a [--color] argument other
    than [auto], [always] or [never], the [--json] argument ["-"], or a value
    given with [=] to a flag that takes none ([--strict=no]). When the reading
    ends without one of these, a flag given to a subcommand it does not apply to
    refuses the command line, and when none is, [--quick] together with
    [--precise] does. [--color] applies to every subcommand and changes nothing
    under [list], which prints no styled text. *)

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
    + It parses [argv] ({{!command_line}command lines}). [-h] or [--help] prints
      the help and [-V] or [--version] the version on stdout, and both return
      [0]. A refused command line prints [thumper: <message>] and
      [Try '-h' for usage.] on stderr and returns [2]. None of the three touches
      a file.
    + It resolves the baseline path: [--baseline], else [baseline], else
      [<name>.thumper] in {!default_baseline_dir}'s directory. It passes that
      function [INSIDE_DUNE], [DUNE_SOURCEROOT] and [Sys.executable_name], not
      [argv.(0)]. The corrected file's path is the baseline path followed by
      [.corrected].
    + It removes the corrected file and the [--json] file, whatever the
      subcommand; a file it cannot remove stops the run. It stops when the
      directory of the [--json] file, or under [bless] that of the corrected
      file, is not a writable directory.
    + It decides once whether the report is coloured: always under
      [--color always], never under [--color never], and under [--color auto],
      the default, when stdout is a terminal or the process is a dune rule
      action, unless [NO_COLOR] is set and non-empty. The process is a dune rule
      action, where the rule's [diff?] stages the corrected file for
      [dune promote], iff [INSIDE_DUNE] is set to some [v] and the working
      directory has a [_build] segment or, when [v] is absolute, lies strictly
      under [Filename.dirname v]. Nothing [main] prints on stderr is coloured.
    + It runs the subcommand, whose exit code it returns.

    [check] and [bless] measure with [config], {!Config.default} by default,
    whose samples [--quick] and [--precise] set to {!Config.quick}'s and
    {!Config.precise}'s ({!Config.samples}); every other field, forking
    included, is [config]'s.

    [list] selects the cases with {!Check.select}, given the config's metrics
    and [budgets] and the patterns and [--tag]s as a filter: [`Or] of one
    [`Id p] per pattern when there are only patterns, [`And] of one [`Tag t] per
    tag when there are only tags, [`And] of both when there are both, and no
    filter when there are neither. It prints their ids on stdout, one per line.
    It reads neither the baseline nor [THUMPER_MACHINE] and takes no lock.

    [check] validates [THUMPER_MACHINE], selects the cases as [list] does, and
    reads the baseline. When there is no baseline file, it stops unless the
    corrected file's directory is a writable directory. It waits for a quiet
    host under [--wait-quiet]. It then holds the measurement lock
    ({!Env.Lock.with_lock}) around {!Check.run_with}, whose own acquisition
    nests. It writes the [--json] file, then the corrected file when
    {!Verdict.corrected} is [Some], prints {!Report.val-check}'s report on
    stdout and returns [Verdict.exit_code ~strict]. Its {!type:Report.render}
    has [exe] set to [argv.(0)], or [None] in a dune rule action; a path
    [argv.(0)] is made absolute against the working directory, its directory is
    resolved with [Unix.realpath], and it is written [./<rel>] when it lies
    under the working directory, absolute otherwise. Its [accept] is
    [dune promote] in a dune rule action and [mv <corrected> <baseline>]
    otherwise, each path written with {!Report.shell_arg}. Its [rerun_flags]
    hold [--quick] or [--precise] when given, [--baseline] when [argv] gave one,
    and one [--tag] per tag. When the corrected file cannot be written, the
    report prints without its [accept:] line before the stop.

    [bless] selects the cases as [list] does, validates [THUMPER_MACHINE], reads
    the baseline and waits under [--wait-quiet]. An expired wait stops the run
    unless [--force] is given or the host is quiet by then. It then holds the
    lock, samples the load, and stops on a loaded host unless [--force] is
    given, and then records the load through {!Verdict.bless}'s [annotations].
    It measures with {!Check.measure}, writes {!Verdict.bless}'s file as the
    corrected file, prints {!Report.val-bless}'s report on stdout, and returns
    [0]. *)
