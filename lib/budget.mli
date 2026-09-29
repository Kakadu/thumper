(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** Budgets: one metric and the {!type:contract} that bounds it.

    A budget is validated when it is built. The module never sees evidence: what
    a contract makes of a comparison, the equivalence band included, is
    [Verdict]'s rule. [Thumper.Budget] re-exports {!type:t} and the four
    {{!constructors}constructors} with their user contract, and nothing else of
    this module. *)

(** {1:types Types} *)

type t
(** The type for budgets. *)

(** The type for what a budget bounds. *)
type contract =
  | Relative of float
      (** A bound [r] on the change from the baseline, as a fraction of the
          baseline value: non-negative and not NaN. *)
  | Absolute_max of float
      (** A cap on this run's exact count, in the metric's {!Metric.units}:
          non-negative, not NaN, and only on a counter metric
          ({!Metric.is_counter}). A count over the cap fails its case whatever
          the baseline holds; sampled evidence never does. *)

(** {1:constructors Constructors}

    Each constructor raises [Invalid_argument] if its tolerance is negative or
    NaN. *)

val relative : metric:Metric.t -> float -> t
(** [relative ~metric r] is the budget on [metric] with the contract
    [Relative r]. *)

val no_slower_than : float -> t
(** [no_slower_than r] is [relative ~metric:Metric.wall_time r]. *)

val no_more_alloc_than : float -> t
(** [no_more_alloc_than r] is [relative ~metric:Metric.alloc_words r]. *)

val at_most : metric:Metric.t -> float -> t
(** [at_most ~metric v] is the budget on [metric] with the contract
    [Absolute_max v].

    Raises [Invalid_argument] if [metric] is not a counter metric
    ({!Metric.is_counter}), as {!Metric.wall_time} and {!Metric.cpu_time} are
    not. A negative or NaN [v] is refused first, whatever [metric]. *)

(** {1:observers Observers and checks} *)

val metric : t -> Metric.t
(** [metric b] is the metric [b] binds. A list of budgets holds at most one
    budget per metric ({!check_distinct}), so this metric, compared with
    {!Metric.equal}, is the list's key. *)

val contract : t -> contract
(** [contract b] is [b]'s contract. *)

val check_distinct : fname:string -> t list -> unit
(** [check_distinct ~fname budgets] checks that no two of [budgets] bind the
    same metric. Every [~budgets] list the library accepts is checked by it, so
    the rule and its message have one owner.

    Raises [Invalid_argument]
    [<fname>: two budgets for metric <id> in one ~budgets list], naming the
    first metric found twice. [fname] must be the name of the value the user
    called. *)

(** {1:defaults Defaults} *)

val default_max_regression : float
(** [default_max_regression] is [0.05]. [Verdict] judges a metric without a
    budget, and sampled evidence under an {!at_most} cap, with this [r]. *)

val defaults : t list
(** [defaults] is [[no_slower_than default_max_regression]]: the budgets of a
    case left with none once the budgets on metrics it does not collect are
    dropped. It binds only a case that collects {!Metric.wall_time}. *)
