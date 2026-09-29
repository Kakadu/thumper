/*---------------------------------------------------------------------------
   Copyright (c) 2015 The mtime programmers. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*/

/* Thumper patch (vs. upstream mtime): getloadavg(3), used at the bottom
   of this file, is a BSD extension.  glibc declares it only under
   _DEFAULT_SOURCE and musl only under _BSD_SOURCE (or _GNU_SOURCE), and
   feature-test macros must be in effect before the first system header
   is included, which the caml/ headers below already do.  Both macros
   are usually on by default; defining them here keeps the declaration
   visible under strict -std= modes, where an implicit declaration is a
   hard error on modern compilers.

   Vendoring notes: every stub symbol is renamed from upstream's
   ocaml_mtime_clock_* to ocaml_thumper_clock_*: a consumer may link both
   thumper and the real mtime, and identical C symbols in two archives are
   a hard link error. Upstream's period_ns stub, elapsed clock and start
   latch are dropped, since thumper reads one clock, [now_ns]. [now_ns]
   returns an immediate OCaml int instead of upstream's boxed int64, so a
   read allocates nothing and can sit inside an allocation-counter
   interval; this needs 63-bit ints. The Windows tier converts counter
   ticks to nanoseconds in integer arithmetic, where upstream multiplies
   by a double-valued period. Error messages name Thumper_clock.now_ns and
   the system call that failed, not upstream's module. */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif
#ifndef _BSD_SOURCE
#define _BSD_SOURCE 1
#endif

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>

#if !defined(ARCH_SIXTYFOUR)
#error "thumper needs a 64-bit OCaml: Thumper_clock.now_ns is an immediate int"
#endif

#include <stdint.h>

#define Val_none Val_int(0)
#define OCAML_MTIME_RAISE_SYS_ERROR(ERR)                                \
  do {                                                                  \
    caml_raise_sys_error (caml_copy_string("Thumper_clock.now_ns: " ERR)); \
  } while (0)

/* Detect platform */

#if defined(__APPLE__) && defined(__MACH__)
  #define OCAML_MTIME_DARWIN
#elif defined(__unix__) || defined(__unix)
 #include <unistd.h>
 #if defined(__linux__)
   #define OCAML_MTIME_LINUX
 #endif
 #if defined(_POSIX_VERSION)
   #define OCAML_MTIME_POSIX
 #endif
#elif defined(_WIN32)
#define OCAML_MTIME_WINDOWS
#endif

/* Darwin */

#if defined(OCAML_MTIME_DARWIN)

#include <mach/mach_time.h>

/* Thumper patch (vs. upstream mtime): [now_ns] times individual benchmark
   batches, so it must be raw-monotonic.  Upstream selects
   mach_continuous_time on macOS >= 10.12, which keeps ticking through
   system sleep: a lid close mid-batch would inject the entire sleep into
   one sample.  mach_absolute_time does not advance during sleep and is
   not adjusted after boot, so we use it unconditionally. */

static mach_timebase_info_data_t scale = {0};

void ocaml_thumper_clock_init_scale (void)
{
  if (mach_timebase_info (&scale) != KERN_SUCCESS)
    OCAML_MTIME_RAISE_SYS_ERROR ("mach_timebase_info () failed");

  if (scale.denom == 0)
    OCAML_MTIME_RAISE_SYS_ERROR ("mach_timebase_info_data.denom is 0");
}

CAMLprim value ocaml_thumper_clock_now_ns (value unit)
{
  (void) unit;
  if (scale.denom == 0) { ocaml_thumper_clock_init_scale (); }
  uint64_t now = mach_absolute_time ();
  return Val_long ((now * scale.numer) / scale.denom);
}

/* POSIX */

#elif defined(OCAML_MTIME_POSIX)

#include <time.h>

/* Thumper patch (vs. upstream mtime): [now_ns] times individual benchmark
   batches, so it must be raw-monotonic.  Upstream uses CLOCK_BOOTTIME on
   Linux, which ticks through system suspend (a suspend mid-batch would
   inject the entire sleep into one sample) and is subject to NTP
   frequency slew (slew silently stretches or shrinks long batches).
   CLOCK_MONOTONIC_RAW has neither problem. */

CAMLprim value ocaml_thumper_clock_now_ns (value unit)
{
  struct timespec now;
  clockid_t clockid;
  (void) unit;

/* Headers too old to know CLOCK_MONOTONIC_RAW (pre-2.6.28, 2008) fall
   back to the generic POSIX clock rather than failing to compile. */
#if defined(OCAML_MTIME_LINUX) && defined(CLOCK_MONOTONIC_RAW)
  clockid = CLOCK_MONOTONIC_RAW;
#else
  clockid = CLOCK_MONOTONIC;
#endif

  if (clock_gettime (clockid, &now))
    OCAML_MTIME_RAISE_SYS_ERROR ("clock_gettime () failed");

  return Val_long ((uint64_t)(now.tv_sec) * (uint64_t)1000000000 +
                   (uint64_t)(now.tv_nsec));
}

/* Windows */

#elif defined(OCAML_MTIME_WINDOWS)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* Ticks per second, fixed at boot. */
static uint64_t performance_frequency = 0;
static void set_performance_frequency(void)
{
  LARGE_INTEGER t_freq;
  if (!QueryPerformanceFrequency(&t_freq) || t_freq.QuadPart <= 0) {
    OCAML_MTIME_RAISE_SYS_ERROR ("QueryPerformanceFrequency () failed");
  }
  performance_frequency = (uint64_t)t_freq.QuadPart;
}

/* ticks * 10^9 would overflow 64 bits after about half an hour at the usual
   10 MHz, so whole seconds and the remainder convert separately:
   s * 10^9 stays below 2^62 for 146 years of uptime, and
   r * 10^9 < f * 10^9, below 2^64 for any frequency under 18 GHz. */
CAMLprim value ocaml_thumper_clock_now_ns (value unit)
{
  LARGE_INTEGER now;
  (void) unit;
  if (performance_frequency == 0) {
    set_performance_frequency();
  }
  if (!QueryPerformanceCounter(&now)) {
    OCAML_MTIME_RAISE_SYS_ERROR ("QueryPerformanceCounter () failed");
  }
  uint64_t ticks = (uint64_t)now.QuadPart;
  uint64_t f = performance_frequency;
  return Val_long ((ticks / f) * (uint64_t)1000000000 +
                   ((ticks % f) * (uint64_t)1000000000) / f);
}

/* Unsupported */

#else

#warning Thumper_clock: unsupported platform

CAMLprim value ocaml_thumper_clock_now_ns (value unit)
{ OCAML_MTIME_RAISE_SYS_ERROR ("unsupported platform"); }

#endif

/* Load average (thumper addition, not in upstream mtime).

   getloadavg(3) is available on Darwin, glibc and musl (and the BSDs).
   Failure is reported as None rather than an exception: Env then counts
   the host as quiet, and the run still measures. */

#if defined(OCAML_MTIME_DARWIN) || defined(OCAML_MTIME_POSIX)

#include <stdlib.h>

CAMLprim value ocaml_thumper_loadavg (value unit)
{
  CAMLparam1 (unit);
  CAMLlocal2 (avg, some);
  double load[1];

  if (getloadavg (load, 1) != 1) CAMLreturn (Val_none);

  avg = caml_copy_double (load[0]);
  some = caml_alloc (1, 0);
  Store_field (some, 0, avg);
  CAMLreturn (some);
}

#else

CAMLprim value ocaml_thumper_loadavg (value unit)
{
  (void) unit;
  return Val_none;
}

#endif

/* Host UUID (thumper addition, not in upstream mtime).

   On Darwin the machine key hashes the hardware UUID, which gethostuuid(2)
   returns, instead of the hostname, which follows the network there.  It
   is rendered in uppercase canonical form, as System Information shows it.
   Other systems, and a Darwin host where the call fails, report None: the
   key then hashes the hostname. */

#if defined(OCAML_MTIME_DARWIN)

#include <unistd.h>
#include <uuid/uuid.h>

CAMLprim value ocaml_thumper_host_uuid (value unit)
{
  CAMLparam1 (unit);
  CAMLlocal2 (str, some);
  uuid_t id;
  struct timespec wait = { 1, 0 };
  char buf[37];

  if (gethostuuid (id, &wait) != 0) CAMLreturn (Val_none);

  uuid_unparse_upper (id, buf);
  str = caml_copy_string (buf);
  some = caml_alloc (1, 0);
  Store_field (some, 0, str);
  CAMLreturn (some);
}

#else

CAMLprim value ocaml_thumper_host_uuid (value unit)
{
  (void) unit;
  return Val_none;
}

#endif
