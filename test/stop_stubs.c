/*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*/

/* The stopped-worker fixture of test_measure: a forked worker that closes
   its end of the report pipe and then stops as a traced child. A traced
   child's stop is reported by waitpid even without WUNTRACED, which is how
   the parent can see end of file and then a stopped worker. */

#include <caml/mlvalues.h>

#if !defined(_WIN32)
#include <signal.h>
#include <stddef.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/ptrace.h>
#endif

/* Close every descriptor above stderr, ask to be traced by the parent, and
   raise SIGUSR1, which stops the child. [false] when the host refuses
   tracing (or has no ptrace); [true] only if the child is ever resumed.
   Nothing here blocks. */
CAMLprim value thumper_test_stop_traced (value unit)
{
  (void) unit;
#if defined(_WIN32)
  return Val_false;
#else
  for (int fd = 3; fd < 1024; fd++) close (fd);
#if defined(PT_TRACE_ME)
  if (ptrace (PT_TRACE_ME, 0, NULL, 0) != 0) return Val_false;
#else
  if (ptrace (PTRACE_TRACEME, 0, NULL, NULL) != 0) return Val_false;
#endif
  kill (getpid (), SIGUSR1);
  return Val_true;
#endif
}

/* Whether SIGKILL ends a stopped traced child while its tracer lives.
   Darwin delivers it only once the tracer exits or resumes the child. */
CAMLprim value thumper_test_sigkill_ends_tracee (value unit)
{
  (void) unit;
#if defined(__APPLE__)
  return Val_false;
#else
  return Val_true;
#endif
}
