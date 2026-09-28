(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let strf = Printf.sprintf

type contract =
  | Relative of { max_regression : float; band : float }
  | Absolute_max of float

type t = { metric : Metric.t; contract : contract }

let default_max_regression = 0.05
let band_cap = 0.025

(* Tolerances are tested with [not (x >= 0.)] so that NaN fails too: a NaN
   tolerance would make every later comparison false. An explicit band may
   exceed [band_cap] but never the budget, since the relations partition the
   shifts only when e <= r: with e > r, a confirmed shift in (r, e] would be
   both regressed and equivalent. At r = 0 the band is therefore 0. *)
let err_relative fname problem = strf "Thumper.Budget.%s: %s" fname problem

let make_relative ~fname ~metric ?equivalent_within max_regression =
  if not (max_regression >= 0.) then
    invalid_arg (err_relative fname "negative or NaN max_regression");
  let band =
    match equivalent_within with
    | Some e ->
        if not (e >= 0.) then
          invalid_arg (err_relative fname "negative or NaN equivalent_within");
        if e > max_regression then
          invalid_arg
            (err_relative fname "equivalent_within exceeds max_regression");
        e
    | None -> Float.min band_cap (max_regression /. 2.)
  in
  { metric; contract = Relative { max_regression; band } }

let relative ~metric ?equivalent_within ~max_regression () =
  make_relative ~fname:"relative" ~metric ?equivalent_within max_regression

let no_slower_than ?(metric = Metric.wall_time) ?equivalent_within
    max_regression =
  make_relative ~fname:"no_slower_than" ~metric ?equivalent_within
    max_regression

let no_more_alloc_than ?(metric = Metric.alloc_words) ?equivalent_within
    max_regression =
  make_relative ~fname:"no_more_alloc_than" ~metric ?equivalent_within
    max_regression

let at_most ~metric v =
  if not (v >= 0.) then
    invalid_arg "Thumper.Budget.at_most: negative or NaN threshold";
  (* A cap applies to exact evidence only, which only a counter metric has: on
     any other metric it could never fail, so it is refused as a negative
     tolerance is. *)
  if not (Metric.is_counter metric) then
    invalid_arg
      (strf
         "Thumper.Budget.at_most: metric %s can never be measured exactly, and \
          an absolute cap applies to exact evidence only; use a relative \
          budget"
         (Metric.id metric));
  { metric; contract = Absolute_max v }

let metric b = b.metric
let contract b = b.contract

(* Two budgets for one metric in a single list are ambiguous author intent:
   across scopes nearest wins, but within one list nothing breaks the tie. *)
let check_distinct ~fname budgets =
  let rec go seen = function
    | [] -> ()
    | b :: rest ->
        if List.exists (Metric.equal b.metric) seen then
          invalid_arg
            (strf "%s: two budgets for metric %s in one ~budgets list" fname
               (Metric.id b.metric))
        else go (b.metric :: seen) rest
  in
  go [] budgets

let defaults = [ no_slower_than default_max_regression ]
