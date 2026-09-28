(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let make_corpus size = String.init size (fun i -> Char.chr (i * 131 land 0xff))

let count_byte c s =
  let n = ref 0 in
  String.iter (fun ch -> if Char.equal ch c then incr n) s;
  !n

let scan_case kib =
  Thumper.bench_with_setup
    (Int.to_string kib ^ " KiB")
    ~setup:(fun () -> make_corpus (kib * 1024))
    (fun corpus -> count_byte '\x2a' corpus)

let () =
  exit
    (Thumper.run "fixtures"
       [
         Thumper.group "scan" (List.map scan_case [ 4; 64; 256 ]);
         Thumper.group "io"
           [
             Thumper.bench_with_setup "read-4KiB"
               ~setup:(fun () ->
                 let path = Filename.temp_file "thumper_fixtures" ".dat" in
                 Out_channel.with_open_bin path (fun oc ->
                     Out_channel.output_string oc (make_corpus 4096));
                 path)
               ~teardown:Sys.remove
               (fun path -> In_channel.with_open_bin path In_channel.input_all);
           ];
       ])
