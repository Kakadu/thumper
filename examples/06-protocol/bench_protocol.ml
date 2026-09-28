(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let data = Array.init 100_000 (fun i -> i * 2_654_435_761 land 0xffff)

let () =
  exit
    (Thumper.run "protocol"
       ~config:
         Thumper.Config.(
           default |> samples 30 |> deadline 30.
           |> metrics
                Thumper.Metric.[ wall_time; alloc_words; minor_collections ])
       [
         Thumper.bench "sort-100k" (fun () ->
             Array.sort compare (Array.copy data));
         Thumper.bench "sum-100k" ~metrics:[ Thumper.Metric.wall_time ]
           (fun () -> Array.fold_left ( + ) 0 data);
       ])
