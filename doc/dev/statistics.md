# The statistics

For maintainers about to touch `stats.ml` or `verdict.ml`. This is the
decision procedure, its constants, and the scope of its false-positive
claim; read it before moving any number. It keeps the design
rationale, and `stats.mli` and `verdict.mli` are the per-function
contracts.

## Position

Timing noise is right-skewed, heavy-tailed, and autocorrelated, so
everything is rank-based and deterministic: no bootstrap, no RNG, no
normality assumption. Confidence intervals are closed intervals at
order-statistic endpoints, with cutoffs computed in exact integer
arithmetic. Two runs over the same vectors produce the same interval,
bit for bit, and coverage is conservative under ties.

The nominal levels assume exchangeable samples. The stated
preconditions that make that approximation hold: the 5 ms batch floor
absorbs most residual dependence, the drift check rejects trials whose
halves disagree, and on a loaded host, whose load makes
exchangeability a fiction, every sampled comparison is inconclusive.

## Per-trial diagnostics

For each sampled metric, a trial holds n per-batch samples
(per-call = interval / k). Outliers are never removed. Two
diagnostics decide whether a trial can support a direction:

- **drifted** (measurement time): two-sided Mann–Whitney between the
  first and second half in collection order, α = 0.01. A drifting
  trial produces no verdict within 2e of zero (`inconclusive:
  drifted`); a shift beyond 2e is judged. Collection order dies at sorting, so this
  is the one flag `measure` computes and stores. Baseline rows get no
  drift check: it ran when their trial was measured, though a drifted
  trial can still be recorded.
- **unstable** (judgment time): criterion's severe outlier-variance
  inflation (≥ 0.5 of variance explainable by outliers), computed from
  the sorted vector, the same way for a stored baseline row and for a
  trial. An unstable side supports no demonstrated direction within 2e
  of zero: since 2e ≤ r, such a direction is an improvement or a change
  within budget, and it reads within budget. A shift beyond 2e is
  judged as on a stable trial, the bound batch drift uses.

## The comparison

Per case, per sampled metric: baseline samples b₁…b_m from the
committed file (m is the n of the run that recorded the row),
candidate samples c₁…c_n, all in log space. Form
the m·n pairwise differences log cᵢ − log bⱼ; the shift estimate is
their median (Hodges–Lehmann) and the CI [L, U] is the Moses
order-statistic construction (valid for m ≠ n, conservative under
ties) at α = 0.005 per side. That is the Mann–Whitney test and its
confidence interval as one deterministic object. Mapped through
`expm1`, [L, U] bounds the fractional shift, compared against budget r
(5% for a metric no scope budgets) and equivalence band
e = min(2.5%, r/2):

improved iff U < −e · regressed iff L > r · equivalent iff
[L, U] ⊆ [−e, e] · changed within budget iff L > e and U ≤ r · else
within budget iff U ≤ r · else `inconclusive: wide interval`.

With r = 0 the band degenerates and the order improved (U < 0) →
regressed (L > 0) → within budget (U ≤ 0) → inconclusive is total.

**Within budget.** `within_budget` claims no direction, only "no slower
than the budget", at the first pass's α = 0.005 on the upper side. It
needs no confirmation: a confirmation guards against false failures,
and a pass adds none. A direction vetoed by instability within 2e and
an unconfirmed improvement fall back to it, both having U ≤ r; an
unconfirmed regression has L > r and never does.

**No stopping.** n is fixed, never a convergence target. Optional
stopping silently inflates type-I error in the high-frequency regime
of a loop that checks after every change, and a fixed n keeps
candidate and baseline protocols identical. Power anchors n: at
per-sample CoV ≈ 2% and m = n = 20, shifts ≥ ~3% are detected
essentially always; near-band shifts resolve as within budget or
inconclusive, not as flaky failures.

**Confirmation.** Every provisional regressed/improved is re-queued
after all other cases finish (temporal spacing decorrelates the
draws), re-measured with fresh warmup at its first trial's batch size
(in a fresh worker where cases fork), and stands only if the
confirmation alone reproduces the relation at α = 0.05 per side
against the same baseline samples. A confirmed relation carries both
shifts. Anything else is unconfirmed, with no in-run retry: an
unconfirmed regression is `inconclusive: unconfirmed`, and an
unconfirmed improvement reads within budget. That includes an unstable
confirmation within 2e of zero, and a confirmation that recalibrated
to another batch size, which measured another protocol than the
first trial. On a host loaded at confirmation time every pending
relation is `inconclusive: environment`.

**Exact metrics** compare as integers: over an `at_most` cap →
regressed, whatever the baseline (a proposed row over its cap fails
its case too); growth under a cap → within budget; growth beyond r →
regressed; growth within r → within budget; less → improved; equal →
equivalent. No CI, no confirmation. Two edges: an exact row whose
batch recalibrated this run is `inconclusive: batch drifted` when the
integers differ and the cap holds (amortized allocators can be
k-phase-dependent); a mixed exact/sampled comparison, sampled
evidence under a cap, and a zero-tolerance budget on a downgraded
metric are `inconclusive: exactness lost`, never a rank test.

**Batch drift** annotates rather than blocks: after recalibration the
comparison proceeds at the new k, and only when the measured shift is
bias-comparable (|estimate| ≤ 2e) does the relation degrade to
`inconclusive: batch drifted`. A ≥5× regression is a regression, not
a calibration event.

## The false-positive claim and its scope

The distribution-free guarantee is per-case FP ≤ 0.005, averaged over
baseline draws. The confirmation multiplies the rate down only for
noise independent across the two passes (within-run sampling error).
It does not defend against a lucky baseline draw or session-shared
bias (thermal state, frequency regime, layout). Those are bounded
instead by the load check and, until U1 clears it, the consumer's
spaced re-run of a failing check. Under a between-pass independence
approximation the compound rate is ≈ 2.5 × 10⁻⁴ per case (≈ 1% per
40-case suite); quoting that number as a guarantee waits for U1. Exact
metrics contribute zero either way. Errors fall toward `inconclusive`,
never toward a failure caused by noise.

### U1: the validation plan and kill criterion

The decision procedure is validated on real data, not asserted:
repeated runs of a production suite archiving raw sample vectors
(~10 min of machine time per configuration). If the advertised rates
fail, the fallback ladder is: raise n (linear cost) → widen e →
tighten the confirmation α. The write path and the evidence format stand
regardless, since the statistics iterate without a format break.

**Kill criterion.** Until U1 clears the claim, a consumer re-runs a
failing check after a spacing before trusting it. If the spaced re-run
overturns an in-tool-confirmed failure even once in the first ~50
confirmed verdicts, the FP claim is falsified: at the advertised rate
the expected count is ~0.01, so a single overturn is decisive. The
consumer's spaced re-run then stays, and the single-binary design
(runner and judge in one process) must be re-argued.

## The constants

Every tunable, its deriving law, and its status. Change one only with
its law; NAKED entries are flagged, not smuggled. A chosen constant
has a reason but no derivation.

| constant | owner | law | status |
| --- | --- | --- | --- |
| batch floor 5 ms | `config.ml` | clock read ≤ 0.01% needs ≥ 1 ms; ×5 margin amortizes a minor-GC cycle | derived |
| frozen-k window [0.2×, 5×] | `measure.ml` | lower: clock law still holds at 1 ms; upper: 5× × n=20 ≈ the 0.5 s case budget | derived |
| n = 20 / 11 / 40 | `config.ml` | power: CoV ≈ 2%, m=n=20 ⇒ ~3% shifts always detected; scaled against the ~0.4 s case budget | derived; U1 validates |
| α 0.005 initial + 0.05 confirmation | `verdict.ml` | suite FP ≲ 1% at 40 cases under independence; the split is underdetermined | flagged; U1 decides |
| band e = min(2.5%, r/2) | `verdict.ml` | 2e ≤ r, so a direction within 2e ends within the budget; r/2 and the 2.5% cap are chosen | chosen |
| bias-comparability 2e | `verdict.ml` | batch-size bias small relative to the ≥2.5× shift that triggered recalibration | derived |
| default budget r = 5% | `budget.ml` | none | NAKED |
| warmup 100 ms / 3 batches | `config.ml` | fixed-not-adaptive (protocol identity); ≥ frequency-ramp settling | part-derived |
| drift α 0.01 | `measure.ml` | none | NAKED; U1 validates |
| load threshold ½ cores | `env.ml` | raven's production rule, adopted | chosen; U1 validates |
| lock wait 600 s per holder | `env.ml` | > worst observed single-suite run | flagged |

Every constant is a named top-level `let` in its owner module.

## Guardrails when changing `stats.ml`

The golden corpus (`test/unit/stats/stats.tsv`) pins every function
against scipy-cross-checked reference values and must be regenerated,
with `uv run test/unit/stats/gen_stats_corpus.py --write`, whenever the
method changes. The byte-identity rule and the hand-derived anchor
layer that catches boundary-convention mutations are described in
[`testing.md`](testing.md). One convention to know before you read
the code: `drifted`'s rank test uses midranks against the tie-free null
(a screening diagnostic); the confidence intervals never use midranks,
and their tie conservatism is exact.
