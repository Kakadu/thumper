(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** Benchmark trees: cases, groups, selection.

    The constructors build a tree ({!type:t}); {!resolve} flattens it into the
    suite's {{!type:case}cases}, with every case id and inherited setting
    computed; {!prepare} turns one case into the batch closure [Measure] drives.
    Nothing here measures, forks or reads a file.

    [Thumper] re-exports {!type:t}, {!type:filter}, the constructors and
    {!black_box}, with the id and inheritance rules as their user contract. This
    module implements those rules. A segment's characters are
    {!Baseline.valid_segment}'s, so changing them changes the baseline format.
    Inheritance here stops at the case: the run's budgets, dropping the budgets
    on uncollected metrics, and the default budget are [Verdict]'s. *)

(** {1:types Types} *)

type t
(** The type for benchmark trees: a case or a group. Only {!prepare} calls the
    closures inside. *)

type case
(** The type for resolved cases: a case id, a full display name, the tags,
    metrics and budgets after inheritance, and the setup that {!prepare} runs.
    Only {!resolve} builds one. *)

(** {1:constructors Constructors}

    A constructor raises [Invalid_argument] on a malformed node, with a message
    that opens with the name the user called: [Thumper.bench],
    [Thumper.bench_with_setup] or [Thumper.group]. The checks run in this order,
    and the first that fails raises:
    + [name] is empty.
    + [id] is not one segment.
    + [id] is absent and [name] holds no character a segment allows.
    + [metrics] is empty or names one metric twice.
    + [budgets] holds two budgets for one metric ({!Budget.check_distinct}).

    [tags] are not checked. *)

val bench :
  ?id:string ->
  ?tags:string list ->
  ?metrics:Metric.t list ->
  ?budgets:Budget.t list ->
  string ->
  (unit -> 'a) ->
  t
(** [bench name f] is the case [name] whose batch of [k] calls applies [f] [k]
    times ({!prepared}). [id] defaults to the slug of [name], and [tags] to
    [[]]. Without [metrics] or [budgets] the case inherits its groups'; an empty
    [budgets] list inherits the same way. *)

val bench_with_setup :
  ?id:string ->
  ?tags:string list ->
  ?metrics:Metric.t list ->
  ?budgets:Budget.t list ->
  setup:(unit -> 'env) ->
  ?teardown:('env -> unit) ->
  string ->
  ('env -> 'a) ->
  t
(** [bench_with_setup ~setup name f] is like {!val:bench} except that each
    {!prepare} runs [setup], and each batch applies [f] to the environment it
    returned. [teardown] defaults to [ignore]. Where and when setup and teardown
    run is {!Measure.case}'s rule: in a forked worker, only the worker holds the
    environment. *)

val group :
  ?id:string ->
  ?tags:string list ->
  ?metrics:Metric.t list ->
  ?budgets:Budget.t list ->
  string ->
  t list ->
  t
(** [group name children] is the group [name] over [children]. Each child's id
    is prefixed with the group's segment and ['/'], its display name with [name]
    and ['/'], and it inherits the group's tags, metrics and budgets. An empty
    [children] resolves to no case. *)

(** {1:selection Selection} *)

type filter =
  [ `Id of string
    (** The cases whose id contains the string, compared byte for byte; [`Id ""]
        selects every case. *)
  | `Tag of string
    (** The cases tagged with the string, or inside a group tagged with it. *)
  | `And of filter list
    (** The cases every filter selects; [`And []] selects every case. *)
  | `Or of filter list
    (** The cases some filter selects; [`Or []] selects none. *) ]
(** The type for case selections. *)

val matches : filter -> case -> bool
(** [matches f c] is [true] iff [f] selects [c]. *)

(** {1:resolving Resolving} *)

(** The type for invalid suites. *)
type error =
  | Duplicate_id of string
      (** Two cases have this id, the first repeated in authoring order. *)
  | Uncollected_budget of { scope : string; metric : string }
      (** A budget on the metric with id [metric] is stated at [scope], a
          group's or case's id ([""] for the run's list), where [metric] is not
          collected. *)

val pp_error : Format.formatter -> error -> unit
(** [pp_error ppf e] formats [e] with its remedy:
    [duplicate case id '<id>' (rename the case or pass ~id)],
    [the run has a budget on <metric> but does not collect it (add it to
     Config.metrics or drop the budget)], or
    ['<scope>' has a budget on <metric> but does not collect it (add it to
     ~metrics or drop the budget)]. The command line prints it on stderr after
    [thumper: ] and exits 2, for [check], [bless] and [list] alike. *)

val resolve : t list -> (case list, error) result
(** [resolve benches] is the cases of [benches] in authoring order, depth first,
    with inheritance applied, or [Error (Duplicate_id id)] if two share an id.
    An empty result is [Ok []]. No closure runs, and budgets on uncollected
    metrics are not checked ({!check_collected}).

    A selection must narrow the result of [resolve], never its input: a narrowed
    input could hide a duplicate id. *)

val check_collected :
  metrics:Metric.t list ->
  budgets:Budget.t list ->
  t list ->
  (unit, error) result
(** [check_collected ~metrics ~budgets benches] is [Ok ()] iff every budget
    names a metric collected where it is stated: at the scope's own [metrics],
    else at the nearest enclosing scope's, else in [metrics], the run's list.
    Otherwise it is [Error (Uncollected_budget _)] for the first contradiction,
    the run's budgets first and then the tree in authoring order. [budgets] is
    the run's own list, checked against [metrics]. A budget that a scope
    inherits on a metric it does not collect is valid; judgment drops it for
    that scope's cases. *)

(** {1:observers Case observers} *)

val id : case -> string
(** [id c] is [c]'s case id: the ['/']-joined segments of its groups and its
    own. Baseline rows, the JSON document and [`Id] selections key on it. *)

val full_name : case -> string
(** [full_name c] is the ['/']-joined display names of [c]'s groups and [c]. The
    JSON document carries it, but nothing keys on it: a name that contains ['/']
    can make two cases' full names equal. *)

val metrics : case -> Metric.t list option
(** [metrics c] is the [metrics] of the nearest scope that gave one, or [None]
    when no scope did and the config's list applies. It is never [Some []]. *)

val budgets : case -> Budget.t list option
(** [budgets c] is the budgets of [c] and its groups merged per metric, the
    nearest scope's first, or [None] when no scope gave a non-empty list. It may
    hold budgets on metrics [c] does not collect. *)

(** {1:running Running} *)

type prepared = {
  run_batch : int -> unit;
      (** [run_batch k] calls the case's function [k] times and passes each
          result through [Sys.opaque_identity]. It re-reads the function, and
          the environment of a case with setup, through [Sys.opaque_identity]
          once per batch, so the compiler can neither drop a call nor hoist its
          body out of the loop. *)
  teardown : unit -> unit;
      (** Releases what setup acquired; [ignore] for a case without setup. It
          must be called once, after the last batch. *)
}
(** The type for a case ready to measure. *)

val prepare : case -> prepared
(** [prepare c] runs [c]'s setup, if any, and is the batch closure and teardown
    over the environment it returned. Each call runs setup again. It must be
    called outside the timed region.

    Exceptions from setup, and later from [run_batch] or [teardown], propagate
    unchanged: containing them, and running the teardown after a failure, is
    {!Measure.case}'s job. *)

val black_box : 'a -> 'a
(** [black_box x] is [Sys.opaque_identity x], the barrier [run_batch] puts
    around each result. *)
