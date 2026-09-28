(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let alphabet = "0123456789abcdef"

let hex_encode s =
  let n = String.length s in
  let out = Bytes.create (2 * n) in
  for i = 0 to n - 1 do
    let b = Char.code (String.unsafe_get s i) in
    Bytes.set out (2 * i) alphabet.[b lsr 4];
    Bytes.set out ((2 * i) + 1) alphabet.[b land 0xf]
  done;
  Bytes.unsafe_to_string out

let hex_decode s =
  let v c =
    match c with
    | '0' .. '9' -> Char.code c - Char.code '0'
    | 'a' .. 'f' -> Char.code c - Char.code 'a' + 10
    | _ -> invalid_arg "hex_decode"
  in
  let n = String.length s / 2 in
  let out = Bytes.create n in
  for i = 0 to n - 1 do
    Bytes.set out i (Char.chr ((v s.[2 * i] lsl 4) lor v s.[(2 * i) + 1]))
  done;
  Bytes.unsafe_to_string out

let raw = String.make 64 '\xa5'
let hex = hex_encode raw

let () =
  exit
    (Thumper.run "budgets"
       ~budgets:[ Thumper.Budget.no_slower_than 0.05 ]
       [
         Thumper.group "codec"
           ~budgets:[ Thumper.Budget.no_more_alloc_than 0.0 ]
           [
             Thumper.bench "hex-encode" (fun () -> hex_encode raw);
             Thumper.bench "hex-decode"
               ~budgets:[ Thumper.Budget.no_slower_than 0.10 ]
               (fun () -> hex_decode hex);
           ];
         Thumper.bench "scratch-table"
           ~budgets:
             [ Thumper.Budget.at_most ~metric:Thumper.Metric.alloc_words 256. ]
           (fun () -> Array.make 63 0);
       ])
