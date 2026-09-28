(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** Facts about the host: the machine key and header lines of a baseline
    section, the load sample, and the measurement lock.

    {!machine_key} names this machine's section, and {!host_description} and
    {!ocaml_identity} fill its header; {!val-load} samples the host's load, and
    {!Lock.with_lock} runs a measurement under the measurement lock. The module
    depends on {!Baseline} only for the identifier charset and
    {!Baseline.quote}; it knows nothing of the file or of verdicts. *)

(** {1:identity Identifying the machine} *)

val hash : string -> string
(** [hash s] is the FNV-1a 64-bit hash of the bytes of [s], written as 16
    lowercase hexadecimal digits. The hash starts at [0xcbf29ce484222325]; for
    each byte it is XORed with the byte, then multiplied by [0x100000001b3]
    modulo 2{^ 64}. For example [hash "a"] is ["af63dc4c8601ec8c"].

    This recipe and {!machine_key}'s inputs define every computed machine key. A
    change to either gives the machines it concerns new keys, and their next run
    finds no section and proposes every row. *)

val machine_key : unit -> string
(** [machine_key ()] is the key of this machine's baseline section: the value of
    [THUMPER_MACHINE] when the variable is set, else
    [hash (host ^ ":" ^ os ^ ":" ^ cpu)], where:
    - [host] is the hardware UUID on macOS, in uppercase canonical form, and the
      host name ([Unix.gethostname]) elsewhere or when the UUID cannot be read;
    - [os] is the output of [uname -s] in lowercase ([darwin], [linux]), or
      ["unknown"] when [uname] fails or prints nothing;
    - [cpu] is the CPU model string, trimmed, with its bytes as detected: the
      output of [sysctl -n machdep.cpu.brand_string] on Darwin (tried again as
      [/usr/sbin/sysctl]), the first non-empty ["model name"] of [/proc/cpuinfo]
      on every other system, and [""] when neither gives one.

    The host facts are read once per process; [THUMPER_MACHINE] is read on every
    call, and its value is the key as given.

    Raises [Invalid_argument] if [THUMPER_MACHINE] is set to a value that is not
    a {!Baseline.valid_segment}; the message names the variable and shows the
    value through {!Baseline.quote}. *)

val cpu_model : unit -> string
(** [cpu_model ()] is the CPU model string of {!machine_key}'s recipe for
    display: ["unknown"] when none was detected, and every byte below [0x20]
    replaced by a space, so it is one line without tabs. *)

val host_description : unit -> string
(** [host_description ()] is the body of a section's [# host:] line: the host
    name, {!cpu_model}, the architecture and the operating system, joined by
    [" · "] (U+00B7). The host name is [Unix.gethostname ()] on every system;
    the architecture is the output of [uname -m]; the operating system is
    ["macos"] on Darwin and otherwise {!machine_key}'s [os]. The architecture
    and the operating system are ["unknown"] when undetected. Every byte below
    [0x20] is replaced by a space, so the value cannot break the file's line
    grammar. The value is only displayed, and no module compares it. *)

val ocaml_identity : unit -> string
(** [ocaml_identity ()] is the body of a section's [# ocaml:] line,
    [version · word size · profile], for example ["5.5.1 · 64-bit · release"].
    [version] is [Sys.ocaml_version] and the word size is [64-bit] or [32-bit].
    A section whose recorded [# ocaml:] line differs from this value in any byte
    is stale ({!Verdict.type-staleness}).

    The profile is the runtime variant for native code: ["release"], ["debug"]
    or ["instrumented"] for the standard, [d] and [i] runtimes, and any other
    variant's name as it is. Bytecode reads ["bytecode"] on the standard runtime
    and ["bytecode+"] followed by the variant otherwise; a [Sys.Other] backend
    reads the same way with its own name in place of ["bytecode"]. Compiler
    options that a program cannot observe at run time, flambda among them, are
    not recorded, so a compiler of the same version built with another such
    option reuses the section. *)

(** {1:load Sampling the load}

    A load sample reads the host-wide 1-minute load average, so inside a
    container it is the whole host's load, whatever the container's CPU quota. A
    host that reports no load average samples {!Quiet}, so it measures and
    records as a quiet host does. *)

val cores : unit -> int
(** [cores ()] is [Domain.recommended_domain_count ()], at least [1]. *)

val load_average : unit -> float option
(** [load_average ()] is the host's 1-minute load average, or [None] when the
    operating system does not report one. It is [getloadavg(3)] on Darwin and
    other POSIX systems, and [None] on Windows. *)

(** The type for load samples, as {!classify} decides them. *)
type load =
  | Quiet  (** The load per core is below [0.5], or no load was read. *)
  | Loaded of { load : float; cores : int }
      (** The 1-minute load average [load] divided by [cores] is at least [0.5].
      *)

val classify : load:float option -> cores:int -> load
(** [classify ~load ~cores] is [Loaded { load = l; cores }] if [load] is
    [Some l] and [l /. float cores >= 0.5], and [Quiet] otherwise, a NaN load
    included.

    Raises [Invalid_argument] if [cores < 1]. *)

val load : unit -> load
(** [load ()] is [classify ~load:(load_average ()) ~cores:(cores ())], the
    host's load now. *)

val wait_quiet :
  timeout_s:float ->
  ?poll_s:float ->
  ?load:(unit -> load) ->
  unit ->
  (unit, [ `Timeout ]) result
(** [wait_quiet ~timeout_s ?poll_s ?load ()] samples [load] until it is [Quiet]
    and is then [Ok ()], or is [Error `Timeout] once [timeout_s] seconds have
    passed on the monotonic clock. It samples at least once, so [timeout_s = 0.]
    is one sample and [infinity] waits without bound. It sleeps [poll_s] seconds
    between samples, [1.] by default, and cuts the last sleep short so the last
    sample falls at the deadline. [load] defaults to {!val-load}. It prints
    nothing.

    Raises [Invalid_argument] if [timeout_s] is negative or NaN, or if [poll_s]
    is not positive and finite. *)

(** {1:lock Holding the measurement lock}

    Every measurement runs under the measurement lock. {!Check.run_with} and
    {!Check.measure} hold it for their sweeps, and the command line takes it
    first, around them, to report its wait, so their acquisition is then nested.

    The lock is per user. Its file is [thumper-<euid>.lock], so it serializes
    the processes of one user that name the same directory, and two users on one
    host never wait for each other. A worker forked under the lock inherits the
    lock file's descriptor but not the lock, which belongs to the process that
    took it. A worker that exits or closes the descriptor therefore leaves the
    parent's lock held. *)

(** The measurement lock. *)
module Lock : sig
  (** The type for lock failures. Misuse of {!with_lock} raises
      [Invalid_argument] instead. *)
  type error =
    | Timeout of { path : string; wait_s : float }
        (** The holder of the lock file [path] kept the lock through [wait_s]
            seconds of waiting on it. *)
    | Unusable of string
        (** The lock file cannot be used, because it is not one regular file (a
            symbolic link, a directory, or a file replaced during acquisition),
            it is not owned by the effective user, its mode grants group or
            other permissions, or a system call on it failed. The message names
            the path and the defect. *)

  val pp_error : Format.formatter -> error -> unit
  (** [pp_error ppf e] formats [e] for users, naming the lock file. *)

  val with_lock :
    ?dir:string ->
    ?wait_s:float ->
    ?on_wait:(owner_changed:bool -> unit) ->
    (unit -> 'a) ->
    ('a, error) result
  (** [with_lock ?dir ?wait_s ?on_wait f] is [Ok (f ())], [f] running while this
      process holds the measurement lock, or [Error e] when the lock cannot be
      taken, and then [f] does not run. The lock is released when [f] returns
      and when it raises, and the exception propagates.
      - [dir] is the lock file's directory. It defaults to [THUMPER_LOCK_DIR]
        when the variable is set and not empty, else to
        [Filename.get_temp_dir_name ()]. A relative [dir] resolves against the
        working directory.
      - [wait_s] bounds the wait on one holder and defaults to [600.]. Each
        acquisition writes a holder stamp into the file, and a waiter that reads
        a new stamp restarts its deadline. A wait that reaches its deadline is
        [Error (Timeout _)].
      - [on_wait] is called after each failed attempt, every 50 ms while the
        lock is held elsewhere, the attempt at the deadline included.
        [owner_changed] is [true] iff the stamp differs from the previous
        attempt's, so it is [false] on the first call. It is never called when
        the lock is free.

      The lock is [lockf] on the whole file [<dir>/thumper-<euid>.lock]. The
      file is created with mode [0600] under [O_EXCL], so never through a
      symbolic link, and it is never removed. An existing file is used only if
      it is one regular file, owned by the effective user, without group or
      other permissions, and still the same file once locked; otherwise the
      result is [Error (Unusable _)].

      A nested call, made while this process holds the lock, runs [f] at once
      whatever its arguments and never calls [on_wait]. The flag that detects
      the nesting is not synchronized, so [with_lock] must not run in two
      domains at once.

      Raises [Invalid_argument] if [wait_s] is negative or NaN, a nested call
      included. *)
end
