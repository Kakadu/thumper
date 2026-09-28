(*---------------------------------------------------------------------------
   Copyright (c) 2015 The mtime programmers. All rights reserved.
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** Monotonic clock, host load average and host UUID.

    The stubs are vendored from mtime and patched for thumper. {!now_ns} is the
    clock thumper times batches and deadlines with; {!load_average} and
    {!host_uuid} are thumper's additions, over [getloadavg(3)] and
    [gethostuuid(2)]. The library belongs to the thumper package and no other
    package can name it. Its C symbols are renamed from mtime's, so a program
    can link both thumper and mtime.

    See [vendor/mtime/LICENSE.md] for mtime's license. *)

val now_ns : unit -> int
(** [now_ns ()] is a timestamp in nanoseconds on a monotonic clock. Its origin
    is unspecified: only the difference of two readings taken in one program run
    means anything. Successive readings never decrease.

    Darwin reads [mach_absolute_time] and Linux [CLOCK_MONOTONIC_RAW]; neither
    advances while the system is suspended, and NTP does not adjust either.
    Other POSIX systems, and Linux built against headers without
    [CLOCK_MONOTONIC_RAW], read [CLOCK_MONOTONIC]; Windows reads
    [QueryPerformanceCounter]. How they behave across suspend and NTP adjustment
    depends on the platform.

    The timestamp is an immediate [int], so a reading allocates nothing and can
    sit inside an allocation-counter interval. It needs 63-bit ints, which hold
    146 years of nanoseconds. A 32-bit platform is not supported, and nothing
    refuses to build on one.

    The module reads the clock once when it is initialized, so a clock that
    fails raises when the program starts, before thumper runs any code.

    Raises [Sys_error] if the operating system's clock fails or the platform is
    unsupported; the message names [Thumper_clock.now_ns] and the failing call,
    or the unsupported platform. *)

val load_average : unit -> float option
(** [load_average ()] is [Some l] with [l] the host's 1-minute load average, and
    [None] if the operating system cannot report it, which is always the case on
    Windows. [l] is non-negative. The value is host-wide: in a container it is
    the host's load, not the container's. *)

val host_uuid : unit -> string option
(** [host_uuid ()] is [Some u] on Darwin, with [u] the hardware UUID that
    [gethostuuid(2)] reports, as 32 uppercase hexadecimal digits in the
    hyphenated 8-4-4-4-12 form. It is [None] on other systems, and on Darwin
    when the call fails or does not answer within 1 s. *)
