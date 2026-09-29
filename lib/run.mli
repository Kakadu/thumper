(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** Measurement evidence.

    A {{!Trial}trial} is one case's evidence: its batch size, one sorted sample
    vector per sampled metric, one integer per exact metric, and its warnings. A
    {{!type:t}run} is the trials of the measured cases, in measurement order.
    Both are data: no judgment, no I/O, and no host identity, which travels
    beside a run. [Measure] builds trials; [Verdict] and the report read them.

    A trial stores the one quality flag that needs the collection order,
    [drifted]. Judgment derives every other reading from the sorted values, for
    a baseline row and a trial alike. A new flag that needs the collection order
    must be computed by [Measure] before sorting and carried both in
    {!type:sampled} and in the worker's [samples] line ({!Measure.Protocol}).

    [Thumper.Run] re-exports {!type:t}, {!case_ids} and the
    {{!projections}projections} with their user contract, and nothing else of
    this module. *)

(** {1:sampled Sampled evidence} *)

type sampled = private {
  sorted : float array;
      (** The per-call values, ascending and finite, at least 3 of them. The
          array is shared: a reader must not mutate it. *)
  drifted : bool;
      (** Whether {!Stats.drifted} found the values drifting in collection
          order, as [Measure] computed it before sorting. *)
}
(** The type for one sampled metric's evidence. Only {!val:sampled} builds one,
    so every value holds [sorted]'s invariant, which [Stats]' functions require.
*)

val sampled : sorted:float array -> drifted:bool -> sampled
(** [sampled ~sorted ~drifted] is the evidence of a copy of [sorted]: a later
    change to [sorted] does not reach it, and the checks apply to the copy.

    Raises [Invalid_argument] if [sorted] has fewer than 3 values, holds a
    non-finite value, or is not ascending. *)

(** {1:measurements Measurements} *)

(** The type for one metric's evidence in a trial. A time metric's is always
    [Samples]; a counter metric's is [Exact] when its probe succeeds and
    [Samples] when it fails. *)
type measurement =
  | Samples of sampled  (** Evidence compared statistically. *)
  | Exact of int
      (** A per-call count that [Measure]'s probe proved for this trial. *)

(** {1:trials Trials} *)

(** One case's evidence. *)
module Trial : sig
  type t
  (** The type for trials. *)

  val make :
    k:int -> ?warnings:string list -> (Metric.t * measurement) list -> t
  (** [make ~k ~warnings ms] is the trial measured at batch size [k] with the
      measurements [ms], in that order. [warnings] defaults to [[]]. It does not
      check that [ms] covers the case's metrics.

      Raises [Invalid_argument] if [k < 1], if two of [ms] share a {!Metric.id},
      or if an [Exact] measurement belongs to a metric that is not a counter
      ({!Metric.is_counter}). *)

  val k : t -> int
  (** [k t] is the batch size of every batch behind [t]'s samples, which a
      baseline row records as its batch size. *)

  val measurements : t -> (Metric.t * measurement) list
  (** [measurements t] is [t]'s evidence, one entry per metric, in the order
      given to {!make}. *)

  val measurement : t -> Metric.t -> measurement option
  (** [measurement t m] is [t]'s evidence for [m] ({!Metric.equal}), or [None]
      if [t] did not measure [m]. *)

  val warnings : t -> string list
  (** [warnings t] is the warnings [Measure] recorded for [t]'s case: a
      suspected constant fold, then each failed probe in metric order, then each
      changed GC parameter. *)
end

(** {1:runs Runs} *)

type t
(** The type for runs: trials keyed by case id, in measurement order. *)

val create : (string * Trial.t) list -> t
(** [create trials] is the run of [trials], in that order.

    Raises [Invalid_argument] if two of [trials] share a case id. *)

val trials : t -> (string * Trial.t) list
(** [trials r] is [r]'s (case id, trial) pairs, in run order. *)

val case_ids : t -> string list
(** [case_ids r] is [r]'s case ids, in run order. *)

(** {2:projections Projections} *)

val samples : t -> case:string -> Metric.t -> float array option
(** [samples r ~case m] is a copy of [m]'s sorted values in [case]'s trial, or
    [None] if [r] has no trial for [case], or its evidence for [m] is absent or
    exact. *)

val exact : t -> case:string -> Metric.t -> int option
(** [exact r ~case m] is [m]'s exact count in [case]'s trial, or [None] if [r]
    has no trial for [case], or its evidence for [m] is absent or sampled. *)

val warnings : t -> case:string -> string list
(** [warnings r ~case] is {!Trial.warnings} of [case]'s trial, or [[]] if [r]
    has no trial for [case]. *)
