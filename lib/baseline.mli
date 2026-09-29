(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The baseline file: the format-v1 codec, reading and the atomic write, and
    recording a run's evidence.

    A file holds evidence, sample vectors and exact counts, never conclusions.
    It has an optional suite header, then one section per machine key, each with
    its identity header and its rows. The format is specified in
    [doc/manual/baseline-format.md], which tools may rely on, so a change to
    what this module reads or prints is a change to that specification. Read a
    file with {!read} or {!of_string}, observe it with {!val-section} and
    {!find_row}, and record a run into it with {!record}, the write path of
    [bless]. Everything read prints back byte for byte, so a written file
    differs from the one read only in the rows and sections a write adds,
    replaces or removes, and in the annotations it appends. *)

(** {1:types Types, errors and quoting} *)

type t
(** The type for baseline files: an optional suite header, then sections in
    ascending machine-key order. Values are immutable, and every value prints
    ({!to_string}) to a text {!of_string} accepts. *)

type section
(** The type for one machine's section: its key, its [# host:] and [# ocaml:]
    lines, which are never empty, its annotations (the other [#] lines of its
    header) and its rows, in ascending (id, metric) order. A section may have no
    rows. *)

type row
(** The type for rows: the evidence of one metric of one case. A row keeps the
    text of its line, so a row read from a file prints back byte for byte. *)

(** The type for errors. An absent file is not an error ({!read}). [Corrupt]
    does not name the file, whose path the caller holds. *)
type error =
  | Corrupt of { line : int; reason : string }
      (** The text violates the grammar at the 1-based [line], and [reason] says
          how, showing file content through {!quote}. A missing final newline is
          reported at the last line. *)
  | Io of string
      (** The file could not be read or written. The message names the path and
          the system's error. *)

exception Error of error
(** Raised by {!read_exn} and {!write}. A printer registered by this module
    prints an uncaught [Error e] as [Thumper.Baseline.Error: ] followed by
    {!pp_error}'s text. *)

val pp_error : Format.formatter -> error -> unit
(** [pp_error ppf e] formats [e] for users:
    [corrupt baseline (line <line>): <reason>] for [Corrupt], the message for
    [Io]. *)

val quote : string -> string
(** [quote s] is [s] between single quotes, with each byte below [0x20] and the
    byte [0x7f] written [\xNN] and every other byte, UTF-8 included, as it is.
    This module's parser, {!Env} and the command line show file content and
    environment values through it, so their messages cannot write control
    sequences to a terminal. *)

(** {1:grammar Identifiers}

    The file grammar owns the identifier charset. A segment is a non-empty run
    of [[A-Za-z0-9._-]]; a case id is ['/']-separated segments, and a metric id
    and a machine key are one segment each. No identifier holds a space or a
    tab, so the tab- and space-separated grammar needs no escapes. {!Bench}
    validates case ids and {!Env} the [THUMPER_MACHINE] key against these
    predicates, so every id and key they accept is one this module can write. *)

val is_id_char : char -> bool
(** [is_id_char c] is [true] iff [c] is in [[A-Za-z0-9._-]]. *)

val valid_segment : string -> bool
(** [valid_segment s] is [true] iff [s] is not empty and every character of [s]
    satisfies {!is_id_char}. *)

val check_suite : fname:string -> string -> unit
(** [check_suite ~fname name] checks that [name] can be the body of a [# suite:]
    line, that is, that it is not empty and holds no newline. Any other byte
    passes, a tab or a carriage return included, and the header keeps it as it
    is. Every entry point that takes a suite name checks it with this function.

    Raises [Invalid_argument], the message starting with [fname], if [name] is
    empty or holds a newline. *)

(** {1:reading Reading and printing} *)

val read : string -> (t option, error) result
(** [read path] is:
    - [Ok (Some t)] for the file at [path];
    - [Ok None] if no file exists at [path], that is if opening it fails with
      [ENOENT], which a missing parent directory gives too;
    - [Error (Io _)] if it exists but cannot be read, a directory at [path]
      included;
    - [Error (Corrupt _)] if its text is refused by {!of_string}.

    A failure to read is never taken for an absent file. The file [read] opens
    is closed before it returns, and before any exception that interrupts it
    escapes. *)

val read_exn : string -> t option
(** [read_exn path] is [read path] without its errors.

    Raises [Error] if the file exists but cannot be read or parsed. *)

val of_string : string -> (t, error) result
(** [of_string s] parses [s] as a format-v1 file. The empty string is the valid
    file with no section. The parser requires the printer's layout: the header
    lines, the blank lines, rows in ascending (id, metric) order and sections in
    ascending key order (byte order, no duplicate), and a final newline. It
    requires each row's stored median to equal the median derived from its
    stored samples. It is lenient on the spelling of numbers: a sample is any
    finite float that [float_of_string] reads, and a count, a [batch=] or an
    [n=] value is any run of decimal digits, leading zeros included, up to
    [max_int]; a larger one is refused as out of range. A row edited by hand may
    therefore differ from the line {!record} prints. Every accepted [s] prints
    back as [s]: [to_string t = s] when the result is [Ok t]. *)

val to_string : t -> string
(** [to_string t] is [t]'s file text: what was read, byte for byte, and what was
    built in the print format, with fields separated by tabs, samples by spaces
    and printed [%.3e], and the median derived from the printed samples. That
    median is the central sample for an odd count and the midpoint [a/2 + b/2]
    of the two central ones for an even count, printed [%.3e]. It is [""] for
    the empty-file baseline. *)

(** {1:writing Writing} *)

val write : string -> t -> unit
(** [write path t] writes [to_string t] to [path] atomically
    ({!Os.write_atomic}). It writes a new temporary file in [path]'s directory,
    flushes it with [fsync] and renames it over [path], so no reader sees a
    partial file; the temporary file is removed on failure. An existing [path]
    keeps its permission bits, and a symbolic link at [path] is replaced by a
    regular file. The measurement lock covers measurement only, so writes are
    not serialized: of two concurrent writers, the last one's whole file wins.

    Raises [Error (Io _)] if the write fails. *)

(** {1:file Files} *)

val empty : suite:string -> t
(** [empty ~suite] is the file with the suite header [suite] and no section,
    which prints as [# thumper baseline v1\n# suite: <suite>\n].

    Raises [Invalid_argument] if {!check_suite} refuses [suite]. *)

val suite : t -> string option
(** [suite t] is the body of [t]'s [# suite:] line. It is [None] iff [t] is the
    empty-file baseline, [of_string ""]. *)

val machines : t -> string list
(** [machines t] is the keys of [t]'s sections, in ascending order. *)

val section : t -> string -> section option
(** [section t key] is [t]'s section for [key], if any. *)

(** {1:sections Section observers} *)

val ocaml_of : section -> string
(** [ocaml_of s] is the body of [s]'s [# ocaml:] line. {!Verdict} compares it
    with the running program's identity to decide staleness. *)

val find_row : section -> id:string -> metric:string -> row option
(** [find_row s ~id ~metric] is [s]'s row for case [id] and metric [metric], if
    any. *)

val case_frozen_k : section -> id:string -> int option
(** [case_frozen_k s ~id] is the batch size of the first sampled row of case
    [id] in [s]'s order, and [None] when the case has no sampled row.
    {!Check.run} freezes a case's first trial at it, and {!Verdict.judge}
    compares this run's batch size with it when it judges an exact row, so both
    read one value. The rows of one case can hold different batch sizes, as a
    file edited by hand may; the first sampled row then decides. *)

(** {1:rows Row observers} *)

(** The type for a row's evidence. *)
type evidence =
  | Exact_int of int  (** An exact per-call count, never negative. *)
  | Sampled of {
      k : int;  (** The batch size ([batch=]), at least [1]. *)
      samples : float array;
          (** The per-call values as the file stores them, sorted ascending, at
              least three of them, all finite; they may be zero or negative. *)
    }

val row_evidence : row -> evidence
(** [row_evidence r] is [r]'s evidence. A [Sampled] array is a fresh copy, so
    mutating it leaves [r] unchanged. *)

(** {1:recording Recording} *)

type identity = { machine : string; host : string; ocaml : string }
(** The type for a section's identity header, which {!Env} computes. [machine]
    is the key; [host] is the body of the [# host:] line, only displayed;
    [ocaml] is the body of the [# ocaml:] line, compared byte for byte for
    staleness. *)

val record :
  ?annotations:string list ->
  identity:identity ->
  suite:string ->
  selection:[ `Full | `Partial ] ->
  run:Run.t ->
  t ->
  t
(** [record ?annotations ~identity ~suite ~selection ~run t] is [t] with [run]'s
    trials recorded in the section of [identity.machine]. [selection] must
    describe [run], [`Full] iff [run] holds every case of the suite.

    A trial's exact count is a row [<id>\t<metric>\texact\t<n>]. Its samples are
    a row at the trial's batch size, each sample stored as its [%.3e] text read
    back, so the row's evidence is what its line holds, and the median derived
    from the stored samples.

    Under a [`Partial] selection of a current section, one whose [# ocaml:] line
    is [identity.ocaml], only the rows of [run]'s cases change: each case's rows
    become its trial's, and its rows for metrics the trial did not measure are
    removed. The header lines, [# host:] included, and every other row keep
    their bytes, and [annotations] are appended to the section's.

    Otherwise, under a [`Full] selection or on a missing or stale section, the
    section is replaced, or added at its place in key order, by one with
    [identity]'s header, [annotations] as its only annotations and the rows of
    [run]'s trials, so the rows of the cases [run] lacks are removed. A [t] with
    no header is replaced by [empty ~suite] first.

    [annotations] defaults to [[]]. Rows are in canonical order and other
    sections keep their bytes, so the result prints to a text {!of_string}
    accepts. Every trial is recorded as measured, whatever the host's load was.

    Raises [Invalid_argument] if [t]'s suite header is not [suite], if {!empty}
    refuses [suite], if [identity.machine] is not a segment, if [identity.host]
    or [identity.ocaml] is empty or holds a newline, if an annotation holds a
    newline or starts with [machine:], [host:], [ocaml:] or [suite:], if a case
    id of [run] is not ['/']-separated segments, or if an exact count is
    negative. *)
