(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** System calls shared across the library.

    [Os] holds the monotonic clock in seconds ({!monotonic_s}), the full write
    ({!write_all}) and the atomic file replace ({!write_atomic}). It depends on
    no module of the library, so every module can call it. [Env] cannot host
    these helpers, because [Env] depends on [Baseline], and [Baseline.write] and
    the command line's [--json] document both publish through {!write_atomic}.
*)

val monotonic_s : unit -> float
(** [monotonic_s ()] is {!Thumper_clock.now_ns} in seconds. Only the difference
    of two readings means anything. On Darwin and Linux it does not advance
    while the host is suspended, so neither does a wait or a deadline read on
    it. Prefer {!Thumper_clock.now_ns} in a measured region. *)

val write_all : Unix.file_descr -> string -> unit
(** [write_all fd s] writes every byte of [s] to [fd], restarting after [EINTR]
    and after a short write.

    Raises [Unix.Unix_error] on any other failure, with [EIO] if a write makes
    no progress. *)

val write_atomic : string -> string -> unit
(** [write_atomic path data] replaces the contents of [path] with [data], and no
    reader of [path] ever sees a partial file. It creates a temporary file
    [.thumper-<pid>-<n>.tmp] in [path]'s directory, exclusively and with mode
    [0o644] under the umask, writes [data] to it in full, [fsync]s it, and
    renames it over [path].

    An existing [path] keeps its permission bits, but not its owner or group,
    and a symbolic link at [path] is replaced by a regular file. Concurrent
    writers never interleave: the last rename wins with a whole file. Nothing
    here takes a lock. The directory is not [fsync]ed, so a crash after
    [write_atomic] returns may lose the rename. A process killed between the
    creation and the rename leaves its temporary file behind.

    On failure the temporary file is removed and [path] is unchanged.

    Raises [Unix.Unix_error] on failure, naming the failing call; when the names
    [n = 0] to [99] are all taken, it is [EEXIST] from [open]. On Windows an
    existing [path] makes [Unix.fchmod] raise [Invalid_argument] instead. *)
