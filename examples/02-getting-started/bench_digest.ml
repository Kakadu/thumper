(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let input64 = String.make 64 '\xa5'

let fib n =
  let rec go a b = function 0 -> a | n -> go b (a + b) (n - 1) in
  go 0 1 n

let () =
  exit
    (Thumper.run "digest"
       ~budgets:
         [
           Thumper.Budget.no_slower_than 0.05;
           Thumper.Budget.no_more_alloc_than 0.0;
         ]
       [
         Thumper.group "md5"
           [ Thumper.bench "string-64" (fun () -> Digest.string input64) ];
         Thumper.group "fib"
           (List.map
              (fun n ->
                Thumper.bench (Int.to_string n) (fun () ->
                    fib (Thumper.black_box n)))
              [ 10; 20 ]);
       ])
