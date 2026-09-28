(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let input = List.init 1_000 Fun.id

let () =
  exit
    (Thumper.run "hello"
       [ Thumper.bench "list-rev" (fun () -> List.rev input) ])
