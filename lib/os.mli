(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** System-call helpers shared by the modules that touch the OS.

    A leaf: it depends on nothing in the library, so every module can call it.
    ([Env] depends on [Baseline], so a writer hosted in [Env] could not serve
    [Baseline.write] without a cycle.) Each helper exists once here instead of
    once per caller: the monotonic clock in seconds, the EINTR-restarting full
    write, and the atomic file publish that [Baseline.write] and the command
    line's [--json] document share. *)

val monotonic_s : unit -> float
(** [monotonic_s ()] is the vendored monotonic clock in seconds. Only
    differences between two readings mean anything; deadlines and polling loops
    use it, never measurement (which reads the clock in nanoseconds). *)

val write_all : Unix.file_descr -> string -> unit
(** [write_all fd s] writes every byte of [s] to [fd], restarting on [EINTR] and
    after short writes. Raises [Unix.Unix_error] on any other failure, and [EIO]
    if a write makes no progress. *)

val write_atomic : string -> string -> unit
(** [write_atomic path data] replaces [path]'s contents with [data] so that no
    reader ever observes a partial file: a fresh temporary file in [path]'s
    directory (created exclusively, mode [0o644] under the umask), a full write,
    [fsync], then a rename over [path]. An existing [path] keeps its permission
    bits. On failure the temporary file is removed and [path] is untouched.

    Concurrent writers are last-wins, whole file: nothing here locks.

    Raises [Unix.Unix_error] on failure, carrying the failing call's name. *)
