(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let corpus = String.init (256 * 1024) (fun i -> Char.chr (i * 131 land 0xff))

let count_byte c len =
  let n = ref 0 in
  for i = 0 to len - 1 do
    if Char.equal (String.unsafe_get corpus i) c then incr n
  done;
  !n

let size_tags kib = if kib >= 256 then [ "large" ] else []

let () =
  exit
    (Thumper.run "tags"
       [
         Thumper.group "scan"
           (List.map
              (fun kib ->
                Thumper.bench
                  (Int.to_string kib ^ " KiB")
                  ~tags:(size_tags kib)
                  (fun () -> count_byte '\x2a' (Thumper.black_box (kib * 1024))))
              [ 4; 256 ]);
         Thumper.group "md5" ~tags:[ "digest" ]
           (List.map
              (fun kib ->
                Thumper.bench
                  (Int.to_string kib ^ " KiB")
                  ~tags:(size_tags kib)
                  (fun () ->
                    Digest.substring corpus 0 (Thumper.black_box (kib * 1024))))
              [ 4; 256 ]);
       ])
