(*---------------------------------------------------------------------------
   Copyright (c) 2015 The mtime programmers. All rights reserved.
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

external now_ns : unit -> int64 = "ocaml_thumper_clock_now_ns"
external load_average : unit -> float option = "ocaml_thumper_loadavg"

(* Read once at module initialization so that, on Darwin, the mach timebase
   is set up here and the first measured read does not pay for it. *)
let () = ignore (now_ns ())
