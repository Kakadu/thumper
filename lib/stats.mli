(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** Deterministic rank statistics.

    [Stats] holds the median and its confidence interval, the two tests of a
    trial's quality, the Hodges–Lehmann shift with its Moses interval, and the
    geometric mean. Every function is pure, with no randomness and no normality
    assumption. An interval's cutoffs come from exact integer counts of the
    binomial and Mann–Whitney null distributions, and its endpoints are values
    of the data, so the same vectors give the same interval bit for bit.

    The functions ignore units. A caller passes logarithms to {!val:shift} for a
    relative comparison, and raw per-call values everywhere else.

    A function whose name ends in [_sorted] takes an ascending vector: an
    unsorted one, or one holding NaN, raises [Invalid_argument]. A vector
    shorter than a function's minimum raises [Invalid_argument] too. *)

(** {1:types Types} *)

type interval = { lower : float; upper : float }
(** The type for closed intervals \[[lower];[upper]\]. Every interval this
    module returns has [lower <= upper] and endpoints that are order statistics,
    so a repeated value never lowers its coverage below the nominal level. The
    full-range fallbacks of {!median_ci_sorted} and {!val:shift} are the
    exception. *)

type shift = { estimate : float; interval : interval }
(** The type for location shifts: the Hodges–Lehmann estimate and its Moses
    confidence interval, which always contains [estimate]. *)

(** {1:location Median and its confidence interval} *)

val median_sorted : float array -> float
(** [median_sorted v] is the central value of [v], or the midpoint
    [(a +. b) /. 2.] of its two central values [a] and [b] when its length is
    even.

    Raises [Invalid_argument] if [v] is empty or not sorted. *)

val median_ci_sorted : alpha:float -> float array -> interval
(** [median_ci_sorted ~alpha v] is a distribution-free confidence interval on
    the median of the population behind [v], which misses it with probability at
    most [alpha] ([~alpha:0.05] is a 95% interval). Its endpoints are
    [v.(l - 1)] and [v.(n - l)], with [l] the largest index such that a
    Binomial([n], 1/2) variable falls below [l] with probability at most
    [alpha /. 2.].

    When no order statistic reaches that level, the interval is the full range
    \[[v.(0)];[v.(n - 1)]\] and its coverage is below the nominal level. At
    [alpha = 0.05] that is the case for [n <= 5].

    Raises [Invalid_argument] if [v] has fewer than 3 values or is not sorted,
    or if [alpha] is outside \]0;1\[. *)

(** {1:stability Trial quality}

    These tests flag a vector and never remove an outlier. *)

val severe_outlier_inflation_sorted : float array -> bool
(** [severe_outlier_inflation_sorted v] is [true] iff the minimal fraction of
    [v]'s variance that outliers can explain is at least one half, by
    criterion's outlier-variance measure (its [Severe] grade). [v] holds raw
    per-call values, not logarithms, since the measure is not
    translation-invariant. A vector with zero variance is [false].

    Raises [Invalid_argument] if [v] has fewer than 3 values or is not sorted,
    or if [v.(0) < 0.]. *)

val drifted : alpha:float -> float array -> bool
(** [drifted ~alpha v] is [true] iff the first [n / 2] values of [v], in
    collection order, differ in location from the other [n - n / 2] by the
    two-sided Mann–Whitney test at level [alpha]: its exact p-value [2 q] is
    below [alpha], with [q] the smaller tail probability of the U statistic's
    exact null distribution without ties, decided in exact integer arithmetic. A
    rank test gives the same result on raw values and on their logarithms. The
    smallest p-value is [2 / C(n, n / 2)], so at [alpha = 0.01] a vector of
    [n <= 9] values never drifts.

    A tie adds 1/2 to U. The null distribution stays the tie-free one, whose
    support is the integers, so a half-integral U has unambiguous tails
    ([P(U <= floor U)] below, [P(U >= ceil U)] above). Without ties the p-value
    is scipy's [mannwhitneyu(method='exact')]. With ties the level is
    approximate, and under heavy ties the exact conditional p-value can be
    larger.

    Raises [Invalid_argument] if [v] has fewer than 3 values or a non-finite
    value, or if [alpha] is outside \]0;1\[. *)

(** {1:comparison Two-sample comparison} *)

val shift :
  alpha_per_side:float -> baseline:float array -> candidate:float array -> shift
(** [shift ~alpha_per_side ~baseline ~candidate] is the location shift of
    [candidate] from [baseline], estimated from the [m * n] differences
    [candidate.(i) -. baseline.(j)], with [m] and [n] the lengths of [baseline]
    and [candidate]. The [estimate] is their median (Hodges–Lehmann). The
    [interval] is their [k]-th smallest and [k]-th largest values (Moses), with
    [k - 1] the largest count at which the exact Mann–Whitney null distribution
    function is at most [alpha_per_side]. Each side then misses with probability
    at most [alpha_per_side].

    [m] and [n] may differ, and neither vector needs to be sorted. For a
    relative comparison, pass logarithms: the interval then bounds the
    log-ratio. When no order statistic reaches the level, the interval is the
    full range of the differences; at [alpha_per_side = 0.005] that is the case
    while [C(m + n, n) < 200].

    Raises [Invalid_argument] if [baseline] or [candidate] has fewer than 3
    values or a non-finite value, or if [alpha_per_side] is outside \]0;0.5\[.
*)

(** {1:aggregation Aggregation} *)

val geometric_mean : float array -> float
(** [geometric_mean v] is [exp (mean (log v))]. Unlike the intervals, it depends
    on the platform's [log] and [exp].

    Raises [Invalid_argument] if [v] is empty or holds a value that is not
    positive and finite. *)
