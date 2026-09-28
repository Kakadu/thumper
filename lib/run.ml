(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Evidence comes from thumper's own measurement, which only produces it
   sorted, finite and at least 3 long: broken evidence is a bug, never data,
   so every check here raises [Invalid_argument]. *)

let strf = Printf.sprintf

type sampled = { sorted : float array; drifted : bool }

(* The checks run on the copy, so a caller changing its own array later
   cannot break them. Non-finite values are refused because [Stats] checks
   only the order of the values it computes the median and the outlier test
   from, and an infinity is in ascending position ([[| 1.; 2.; infinity |]]
   is sorted). Finiteness is checked first, for its message on NaN; the
   negated [<=] refuses NaN as well. *)
let sampled ~sorted ~drifted =
  let sorted = Array.copy sorted in
  let n = Array.length sorted in
  if n < 3 then invalid_arg (strf "Run.sampled: %d samples, need at least 3" n);
  Array.iter
    (fun x ->
      if not (Float.is_finite x) then
        invalid_arg "Run.sampled: non-finite sample")
    sorted;
  for i = 0 to n - 2 do
    if not (sorted.(i) <= sorted.(i + 1)) then
      invalid_arg "Run.sampled: vector not sorted ascending"
  done;
  { sorted; drifted }

type measurement = Samples of sampled | Exact of int

let first_duplicate ids =
  let rec go = function
    | [] -> None
    | id :: rest -> if List.mem id rest then Some id else go rest
  in
  go ids

module Trial = struct
  type t = {
    k : int;
    measurements : (Metric.t * measurement) list;
    warnings : string list;
  }

  let make ~k ?(warnings = []) measurements =
    if k < 1 then invalid_arg (strf "Run.Trial.make: k %d < 1" k);
    (match
       first_duplicate (List.map (fun (m, _) -> Metric.id m) measurements)
     with
    | Some id -> invalid_arg (strf "Run.Trial.make: duplicate metric %s" id)
    | None -> ());
    (* Only a counter metric's probe can prove a count exact. *)
    List.iter
      (fun (m, v) ->
        match v with
        | Exact _ when not (Metric.is_counter m) ->
            invalid_arg
              (strf
                 "Run.Trial.make: exact evidence for %s, which no probe can \
                  prove exact"
                 (Metric.id m))
        | Exact _ | Samples _ -> ())
      measurements;
    { k; measurements; warnings }

  let k t = t.k
  let measurements t = t.measurements

  (* Metrics carry closures: compare by id, never structurally. *)
  let measurement t m =
    List.find_map
      (fun (m', v) -> if Metric.equal m m' then Some v else None)
      t.measurements

  let warnings t = t.warnings
end

type t = (string * Trial.t) list

let create trials =
  match first_duplicate (List.map fst trials) with
  | Some id -> invalid_arg (strf "Run.create: duplicate case %s" id)
  | None -> trials

let trials t = t
let trial t id = List.assoc_opt id t
let case_ids t = List.map fst t

let measurement t ~case metric =
  match trial t case with
  | None -> None
  | Some tr -> Trial.measurement tr metric

let samples t ~case metric =
  match measurement t ~case metric with
  | Some (Samples s) -> Some (Array.copy s.sorted)
  | Some (Exact _) | None -> None

let exact t ~case metric =
  match measurement t ~case metric with
  | Some (Exact n) -> Some n
  | Some (Samples _) | None -> None

let warnings t ~case =
  match trial t case with None -> [] | Some tr -> Trial.warnings tr
