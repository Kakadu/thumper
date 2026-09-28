(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The baseline file: the format-v1 codec, reading and the atomic write, and
    the primitives the write paths build files with.

    A file holds evidence, sample vectors and exact counts, never conclusions.
    It has an optional suite header, then one section per machine key, each with
    its identity header and its rows. The format is specified in
    [doc/manual/baseline-format.md], which tools may rely on, so a change to
    what this module reads or prints is a change to that specification. Read a
    file with {!read} or {!of_string}, observe it with {!val-section} and
    {!val-rows}, and build a new one with {!set_section} or {!update_rows}.
    Everything read prints back byte for byte, so a written file differs from
    the one read only in the rows and sections the write paths add, replace or
    remove, and in the annotations they append. Which rows change is
    {!Verdict}'s decision; this module places rows and keeps their order. *)

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

    A failure to read is never taken for an absent file. *)

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
    [n=] value is any run of decimal digits, leading zeros included. A row
    edited by hand may therefore differ from the line {!sampled_row} prints.
    Every accepted [s] prints back as [s]: [to_string t = s] when the result is
    [Ok t]. *)

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

val machine_of : section -> string
(** [machine_of s] is [s]'s machine key. *)

val ocaml_of : section -> string
(** [ocaml_of s] is the body of [s]'s [# ocaml:] line. {!Verdict} compares it
    with the running program's identity to decide staleness. *)

val rows : section -> row list
(** [rows s] is [s]'s rows, in ascending (id, metric) order. *)

val find_row : section -> id:string -> metric:string -> row option
(** [find_row s ~id ~metric] is [s]'s row for case [id] and metric [metric], if
    any. *)

val case_frozen_k : section -> id:string -> int option
(** [case_frozen_k s ~id] is the batch size of the first sampled row of case
    [id] in [s]'s order, and [None] when the case has no sampled row.
    {!Check.run} freezes a case's first trial at it, and {!Verdict.judge}
    compares this run's batch size with it when it judges an exact row, so both
    read one value. The rows of one case can hold different batch sizes, when a
    row was advanced or re-recorded from a trial at another batch size; the
    first sampled row then decides. *)

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

val row_id : row -> string
(** [row_id r] is [r]'s case id. *)

val row_metric : row -> string
(** [row_metric r] is [r]'s metric id. *)

val row_evidence : row -> evidence
(** [row_evidence r] is [r]'s evidence. A [Sampled] array is a fresh copy, so
    mutating it leaves [r] unchanged. *)

(** {1:editing Building files}

    The write paths build a file from these values. {!set_section} and
    {!update_rows} return a new file that keeps the canonical order and every
    byte they do not replace. Every function here refuses what the grammar
    refuses, so a file built from them always prints to a text {!of_string}
    accepts. *)

type identity = { machine : string; host : string; ocaml : string }
(** The type for a section's identity header, which {!Env} computes. [machine]
    is the key; [host] is the body of the [# host:] line, only displayed;
    [ocaml] is the body of the [# ocaml:] line, compared byte for byte for
    staleness. *)

val exact_row : id:string -> metric:string -> int -> row
(** [exact_row ~id ~metric n] is the row [id], [metric], [exact], [n], separated
    by tabs.

    Raises [Invalid_argument] if [id] is not ['/']-separated segments, if
    [metric] is not a segment, or if [n] is negative. *)

val sampled_row :
  id:string -> metric:string -> k:int -> samples:float array -> row
(** [sampled_row ~id ~metric ~k ~samples] is the row of [samples] measured at
    batch size [k]. Each sample is stored as its [%.3e] text read back, so the
    row's evidence is what its line holds and a print and parse leave it
    unchanged; the median is derived from the stored samples. [samples] must
    hold at least three finite values in ascending order, and [k] must be at
    least [1].

    Raises [Invalid_argument] if [id] or [metric] is invalid (as for
    {!exact_row}), if [k < 1], or if [samples] breaks its requirement. *)

val set_section : ?annotations:string list -> t -> identity -> row list -> t
(** [set_section ?annotations t identity rows] is [t] with the section of
    [identity.machine] replaced, or added at its place in key order, by a
    section with [identity]'s header, [annotations] as its annotation lines
    ([[]] by default), and [rows] in canonical order whatever order they come
    in. The old section's annotations are dropped; every other section keeps its
    bytes.

    Raises [Invalid_argument] if [t] has no suite header (start from {!empty}),
    if [identity.machine] is not a segment, if [identity.host] or
    [identity.ocaml] is empty or holds a newline, if an annotation holds a
    newline or starts with [machine:], [host:], [ocaml:] or [suite:], or if two
    rows share a case id and a metric. *)

val update_rows :
  ?annotations:string list ->
  t ->
  machine:string ->
  advance:row list ->
  prune:(string * string) list ->
  t
(** [update_rows ?annotations t ~machine ~advance ~prune] is [t] with the
    section of [machine] edited in place:
    - each row of [advance] replaces the row with its case id and metric, or is
      inserted in order;
    - the row of each (id, metric) pair of [prune] is removed, and a pair
      without a row is ignored;
    - [annotations], [[]] by default, are appended after the section's
      annotations.

    The header lines, [# host:] and [# ocaml:] included, every other row and
    every other section keep their bytes.

    Raises [Invalid_argument] if an annotation is refused as by {!set_section},
    if [advance] holds two rows with one case id and metric, if a pair is in
    both [advance] and [prune], or if [t] has no section for [machine]. *)
