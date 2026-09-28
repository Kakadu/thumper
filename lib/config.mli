(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The measurement protocol as a value.

    A config holds the samples per trial, the batch floor, the warmup, the
    per-case deadline, the metrics collected, and whether each case runs in a
    forked worker. Every config is a preset ({!default}, {!quick}, {!precise})
    with setters applied. Each setter checks the invariant of the field it sets,
    so every invariant stated on {!type:t} holds for every config. [Measure],
    [Check] and the command line read the fields directly.

    [Thumper.Config] re-exports the presets and every setter but {!val:fork},
    over an abstract {!type:t}, with their user contract. *)

(** {1:types Types} *)

type t = private {
  n : int;
      (** The samples per trial, at least 3. Only the sampling phase grows with
          it; warmup, calibration and the probe do not. *)
  batch_floor : float;
      (** The shortest a batch may last, in seconds, finite and positive.
          Calibration doubles the batch size until one batch lasts this long
          ({!Measure.case}). *)
  warmup_time : float;
      (** The discarded warmup, in seconds, finite and non-negative. *)
  warmup_batches : int;
      (** The fewest discarded warmup batches, always 3; no setter changes it.
          Warmup lasts until [warmup_time] has passed and [warmup_batches]
          batches have run. *)
  deadline : float;
      (** The bound on one case's measurement, in seconds, positive, and
          [infinity] for none. A forked case is killed when it passes; an
          in-process case checks it between batches only. *)
  metrics : Metric.t list;
      (** The metrics collected, in report order, non-empty, and no two with one
          {!Metric.id}. A case's own [?metrics] replaces the list
          ({!Bench.metrics}). *)
  fork : bool;  (** Whether each case runs in a forked worker ({!val:fork}). *)
}
(** The type for measurement protocols. *)

(** {1:presets Presets} *)

val default : t
(** [default] is the protocol of 20 samples per trial, a 5 ms batch floor, a
    warmup of 100 ms and 3 batches, a 10 s deadline,
    [[Metric.wall_time; Metric.alloc_words]] collected, and a forked worker per
    case. *)

val quick : t
(** [quick] is {!default} with 11 samples. *)

val precise : t
(** [precise] is {!default} with 40 samples. *)

(** {1:setters Setters}

    Each setter is its config argument with one field replaced, and raises
    [Invalid_argument] if the new value breaks that field's invariant. No setter
    checks a combination of fields, so a chain of setters gives the same config
    in any order. *)

val samples : int -> t -> t
(** [samples n t] is [t] with [n] samples per trial.

    Raises [Invalid_argument] if [n < 3]: [Stats]' median interval, drift test
    and shift need at least 3 samples. *)

val batch_floor : float -> t -> t
(** [batch_floor s t] is [t] with a batch floor of [s] seconds.

    Raises [Invalid_argument] if [s] is not finite and positive. *)

val warmup : float -> t -> t
(** [warmup s t] is [t] with [s] seconds of warmup; the 3-batch minimum stays.

    Raises [Invalid_argument] if [s] is negative or not finite. *)

val deadline : float -> t -> t
(** [deadline s t] is [t] with a deadline of [s] seconds; [deadline infinity]
    removes it.

    Raises [Invalid_argument] if [s] is not positive (NaN included). *)

val metrics : Metric.t list -> t -> t
(** [metrics ms t] is [t] collecting [ms], in that order.

    Raises [Invalid_argument] if [ms] is empty or two of its metrics share an
    id. *)

val fork : bool -> t -> t
(** [fork b t] is [t] measuring each case in a forked worker if [b], and in the
    calling process otherwise.

    Forked, each case runs in a new process: its crash is a
    {!Measure.Worker_died} failure, and the deadline bounds the case whatever it
    does. In-process, the cases share the calling process and its heap. A crash
    ends that process, and a call that never returns hangs it, since the
    deadline is checked only between batches. {!Measure.case} states both modes.
*)
