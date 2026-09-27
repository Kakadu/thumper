(*---------------------------------------------------------------------------
   Copyright (c) 2015 The mtime programmers. All rights reserved.
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** Raw-monotonic clock, host load average and host UUID.

    Vendored from {{:https://erratique.ch/software/mtime}mtime} and patched for
    thumper: {!now_ns} is the measurement clock — it times individual benchmark
    batches — so it reads a {e raw} monotonic source ([mach_absolute_time] on
    Darwin, [CLOCK_MONOTONIC_RAW] on Linux) that neither advances during system
    sleep (a lid close mid-batch must not inject the sleep into a sample) nor is
    slewed by NTP (slew silently stretches or shrinks long batches).
    {!load_average} and {!host_uuid} are thumper additions backed by
    [getloadavg(3)] and [gethostuuid(2)].

    See [vendor/mtime/LICENSE.md] for the original license. *)

val now_ns : unit -> int64
(** [now_ns ()] is an {e unsigned} 64-bit integer nanosecond timestamp on the
    raw monotonic clock: on Darwin and Linux it excludes time the system spent
    suspended and is not adjusted by NTP. Other POSIX systems fall back to
    [CLOCK_MONOTONIC], whose suspend and NTP-slew behavior is platform-defined.
    Reads are non-decreasing; the origin is unspecified, so only differences are
    meaningful, and only within a single program run.

    This is the clock thumper times measured regions and deadlines with.

    Raises [Sys_error] if the operating system clock is unavailable, which on
    supported platforms (Darwin, Linux, POSIX) does not happen in practice. *)

val load_average : unit -> float option
(** [load_average ()] is [Some l] with [l] the system's 1-minute load average,
    and [None] if the operating system cannot report it. [l] is non-negative.

    The value is host-wide: in a container it reports the host's load, not the
    container's cgroup. *)

val host_uuid : unit -> string option
(** [host_uuid ()] is [Some u] on Darwin, with [u] the hardware UUID that
    [gethostuuid(2)] returns, in uppercase canonical form
    (["5F1D3C9A-0B7E-4E2A-9C61-2D8B7A4E0F13"]), as System Information shows it.
    It is [None] on other systems, and on Darwin if the call fails. *)
