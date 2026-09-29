(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let strf = Printf.sprintf

type contract = Relative of float | Absolute_max of float
type t = { metric : Metric.t; contract : contract }

let default_max_regression = 0.05

(* Tolerances are tested with [not (x >= 0.)] so that NaN fails too: a NaN
   tolerance would make every later comparison false. *)
let make_relative ~fname ~metric r =
  if not (r >= 0.) then
    invalid_arg (strf "Thumper.Budget.%s: negative or NaN tolerance" fname);
  { metric; contract = Relative r }

let relative ~metric r = make_relative ~fname:"relative" ~metric r

let no_slower_than r =
  make_relative ~fname:"no_slower_than" ~metric:Metric.wall_time r

let no_more_alloc_than r =
  make_relative ~fname:"no_more_alloc_than" ~metric:Metric.alloc_words r

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
