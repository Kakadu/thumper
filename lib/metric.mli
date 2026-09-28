(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** Metrics: the per-call quantities thumper measures.

    A metric has an identity ({!id}), a {!type:kind} the report renders it by,
    and a {!type:source} [Measure] reads it from. The set is closed: the eight
    {{!builtins}built-ins} are every metric, and {!type:t} has no public
    constructor. A new metric is a new value in [metric.ml]; a new source also
    needs [Measure] to read it, since [Measure] matches on {!type:source}
    exhaustively. Whether a counter metric's evidence is exact is proven per
    trial by [Measure]'s probe, never assumed here.

    [Thumper.Metric] re-exports {!type:t}, {!id}, {!name}, {!units}, {!equal},
    {!compare}, {!pp} and the built-ins with their user contract, and nothing
    else of this module. *)

(** {1:sources Kinds and sources} *)

type kind = [ `Time | `Allocation | `Other ]
(** The type for how the report renders a metric's values. [`Time] values are
    seconds, [`Allocation] values are words, and [`Other] values are in their
    metric's {!units}. Only the report reads it, to choose columns, units and
    suffixes; judgment never does. *)

type gc_snapshot = {
  minor_words : float;
      (** Words allocated in the minor heap so far ([Gc.counters]). *)
  promoted_words : float;
      (** Words promoted from the minor to the major heap so far, which
          [minor_words] and [major_words] both count. *)
  major_words : float;
      (** Words allocated in the major heap so far, promotions included. *)
  minor_collections : int;  (** Minor collections so far. *)
  major_collections : int;  (** Major collection cycles completed so far. *)
}
(** The type for one reading of the runtime's cumulative counters. The word
    counts are floats holding whole numbers, exact below 2{^ 53}. *)

(** The type for how [Measure] reads a metric. *)
type source =
  | Wall_clock  (** The measurement clock, read around each batch. *)
  | Cpu_clock
      (** Process CPU time, user plus system ([Unix.times]), read around each
          batch. *)
  | Gc_counter of (gc_snapshot -> float)
      (** [Gc_counter p] reads the projection [p] of a {!gc_snapshot}, and a
          batch's value is [p after -. p before]. [p] must be linear in the
          counters, so that projecting and differencing commute. It must not
          decrease when they grow, and a decrease across the probe batches fails
          {!Measure.case}, which states how. *)

(** {1:metrics Metrics} *)

type t
(** The type for metrics. Identity is {!id} alone: {!equal}, {!compare}, the
    baseline's rows and the JSON document read nothing else. *)

(** {2:accessors Accessors} *)

val id : t -> string
(** [id m] is [m]'s identity, the spelling baseline rows and the JSON document
    store. A built-in's id never changes: changing one changes the baseline
    format. *)

val name : t -> string
(** [name m] is [m]'s label in words, such as ["wall time"] for {!wall_time}. No
    report prints it. *)

val units : t -> string
(** [units m] is the unit of [m]'s per-call values: ["s"], ["words"] or
    ["count"]. *)

val kind : t -> kind
(** [kind m] is how the report renders [m]'s values. *)

val source : t -> source
(** [source m] is how [Measure] reads [m]. *)

val is_counter : t -> bool
(** [is_counter m] is [true] iff [source m] is a {!Gc_counter}, and only a
    counter metric's evidence can be exact. A failed probe leaves a counter
    metric sampled for that trial. *)

(** {2:predicates Comparisons and formatting} *)

val equal : t -> t -> bool
(** [equal a b] is [String.equal (id a) (id b)]. *)

val compare : t -> t -> int
(** [compare a b] is [String.compare (id a) (id b)]. A baseline section orders
    one case's rows by the same comparison. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf m] formats [id m]. *)

(** {1:builtins Built-in metrics}

    Judgment reads every metric as lower-is-better: an increase is a regression.
    A metric for which higher is better needs a direction in [Verdict] first. *)

val wall_time : t
(** [wall_time] is the time per call on {!Wall_clock}, in seconds. Its id is
    ["wall_time"] and its kind [`Time]. *)

val alloc_words : t
(** [alloc_words] is [minor_words +. major_words -. promoted_words] per call, in
    words. Its id is ["alloc_words"], its kind [`Allocation], and it is a
    counter metric. *)

val cpu_time : t
(** [cpu_time] is the process CPU time per call on {!Cpu_clock}, in seconds. Its
    id is ["cpu_time"] and its kind [`Time]. *)

val minor_alloc_words : t
(** [minor_alloc_words] is the [minor_words] counter per call, in words. Its id
    is ["minor_alloc_words"], its kind [`Allocation], and it is a counter
    metric. *)

val major_alloc_words : t
(** [major_alloc_words] is the [major_words] counter per call, promotions
    included, in words. Its id is ["major_alloc_words"], its kind [`Allocation],
    and it is a counter metric. *)

val promoted_words : t
(** [promoted_words] is the [promoted_words] counter per call, in words. Its id
    is ["promoted_words"], its kind [`Allocation], and it is a counter metric.
*)

val minor_collections : t
(** [minor_collections] is the [minor_collections] counter per call, in units
    ["count"]. Its id is ["minor_collections"], its kind [`Other], and it is a
    counter metric. *)

val major_collections : t
(** [major_collections] is the [major_collections] counter per call, in units
    ["count"]. Its id is ["major_collections"], its kind [`Other], and it is a
    counter metric. *)
