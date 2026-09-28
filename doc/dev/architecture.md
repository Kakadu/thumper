# Architecture

For maintainers. The user contract is `lib/thumper.mli`; this file is
the map of what sits behind it and the laws that keep it coherent. The
internal `.mli`s are the module contracts, and when this page and an
`.mli` disagree, the `.mli` wins.

## The module map

Three layers. The **pure core** computes over values and can be tested
without a host; the **OS edge** owns every clock, fork, lock, and load
reading; the **adapters** own paths, argv, and rendering.

| module | layer | contents |
| --- | --- | --- |
| `stats` | pure | order statistics: median + binomial CI, severe-inflation predicate, Mann–Whitney drift test, Hodges–Lehmann/Moses shift, geomean. Unit-agnostic; no RNG |
| `metric` | pure | metric identity and how a quantity is read (`Wall_clock`, `Cpu_clock`, `Gc_counter`); the `gc_snapshot` record the seam traffics in |
| `budget` | pure | contracts (`Relative`, `Absolute_max`) and the default budget of a metric no scope budgets |
| `config` | pure | the protocol knob container (private record): n, batch floor, warmup, deadline, metrics, fork |
| `bench` | pure | authoring constructors, id validation, inheritance, the filter algebra, `resolve`, `prepare` |
| `run` | pure | the evidence model: `Trial` (frozen k, per-metric `Samples`/`Exact`, the drift flag, warnings), `Run.t` |
| `baseline` | pure¹ | the format-v1 codec: strict parse with the median checksum, byte-identical re-emission, the one write path `record`, one atomic `write` |
| `verdict` | pure | judgment (`judge`/`confirmations`/`decide`), relations with confirmation evidence in the type, JSON, exit codes |
| `os` | OS edge | `monotonic_s` (the clock that waits and deadlines read), the full write that restarts on EINTR, the atomic file replace (temp + fsync + rename) that the baseline and the JSON document use. It depends on no module of the library |
| `env` | OS edge | the machine key, the host and compiler identity strings, the load sample (`load`, `wait_quiet`), and the measurement lock (`Lock`) |
| `measure` | OS edge | one case → one trial: calibration with frozen-k reuse, warmup, GC discipline, fixed-n sampling, the k/2k exactness probe, the forked worker and its pipe `Protocol`, the in-process path; the `instruments` seam |
| `check` | OS edge | the orchestrator: select → lock → load → measure → judge → load → confirm → decide. It stays thin, since anything longer means policy leaked out of `verdict` |
| `cli` | adapter | subcommand grammar, startup unlinks, baseline I/O, terminal + GitHub rendering, `--json`, exit mapping |
| `thumper` | facade | re-exports the public surface; the tests reach every internal module but `os` through `Thumper.Private`, which is outside the API |

¹ `baseline` is a pure codec plus its reader and one call to
`Os.write_atomic`.

Vendored: `vendor/mtime` (`thumper_clock`), the monotonic clock stubs
(`now_ns`, an immediate `int` of nanoseconds) plus a `getloadavg` stub
and a `gethostuuid` stub for the macOS machine key. The library belongs
to the thumper package, and no other package can name it. The
dependency cone is `unix` + `thumper_clock`, full stop.

## The purity boundaries

**Judgment is pure and two-phase.** `Verdict.judge` produces a
provisional whose strong relations await confirmation;
`Verdict.confirmations` lists the cases to re-measure;
`Verdict.decide` folds the confirmation trials in. `Check.run` is the
only production caller of the triple; tests and offline re-judging
drive it directly with synthetic trials. A strong sampled relation
carries its confirmation evidence in the representation
(`Confirmed { first; confirmation }`), so an unconfirmed
`Regressed`/`Improved` is untypeable rather than a runtime
discipline.

**`Check.run` lives at the OS edge because confirmation is
measurement**: only the runner can collect the second sample the
decision needs. It renders nothing, writes nothing, and reads no
files. The CLI composes `Baseline.read`, the report and exit codes
around it; `check` writes no baseline.

**The write path is one pure function.** `Baseline.record` records a
run, the trials of `bless`, into the parsed file: the selected cases'
rows, or the whole section when the selection is full or the section
missing or stale. A verdict never reaches it, so no judgment decides
which rows change, and its rows come from trials, so every file it
builds is one the parser accepts.

**The measurement seam.** `Measure.instruments` (clock, CPU clock, GC
counters) is the injectable seam: scripted instruments make
calibration, the probe, drift, and deadlines deterministically
testable with zero wall-clock time. `Check.run_with` adds the load
sample (`?load`) as a second seam. `Measure.Protocol` exposes the
worker pipe grammar so parser containment is testable without
forking. See [`testing.md`](testing.md).

**The narrow waist** is the two serialized formats, the `.thumper`
file and the JSON document, both specified in the manual
([baseline-format](../manual/baseline-format.md),
[json](../manual/json.md)). External tools
build on those, never on internals.

## The laws

Each law names the failure it prevents, and a change to any of them
reopens the design. Each is a test obligation: windtrap properties
for the pure-core laws, cram for the rest ([`testing.md`](testing.md)).

1. **Single write path.** `bless` alone writes the baseline, through
   `Baseline.record`, atomically (temp + fsync + rename); `check`
   writes only the `--json` document, which is unlinked at startup and
   written atomically, or not at all. The measurement lock serializes
   measurement, not writes: the CLI writes after the lock is released,
   and atomicity makes concurrent writers last-wins-whole-file, so no
   reader ever observes a partial file. *Prevents:* a baseline that
   changes as a side effect of a check; stale-artifact reads.
2. **Recording is deliberate.** Only `bless` records, from a run it
   measures for that purpose, and it refuses a loaded host without
   `--force`. A proposed row and a confirmed improvement pass the
   check and name the `bless` command that records them. *Prevents:*
   one noisy draw overwriting recorded evidence; a red build for a row
   nobody regressed.
3. **Verdicts are earned.** `regressed`/`improved` arise only from an
   exact-integer comparison or a rank test plus confirmation; drifting
   trials within 2e and a loaded host yield `inconclusive`, and unstable
   samples within 2e yield `within budget`.
   *Prevents:* flaky CI; consumers re-implementing statistics.
4. **Comparability or refusal.** Comparison requires the same machine
   key, same compiler identity, and the frozen protocol; a stale
   section short-circuits to a fresh section in which every row is
   proposed. *Prevents:* silently wrong cross-machine or
   cross-compiler verdicts.
5. **Exactness is proven.** A metric is exact only when the k/2k
   differencing probe agrees this run. *Prevents:* false exactness
   claims.
6. **No capability lies.** A metric that cannot be measured on this
   platform is absent, not NaN. *Prevents:* a metric that exists in the
   API but reads NaN, so that no comparison on it means anything.
7. **Serialized measurement.** All measurement holds the measurement
   lock, one per user and host; waiting is bounded per holder and
   printed. *Prevents:* concurrent suites measuring each other's
   contention.
8. **Decision-grade exits.** No cross-metric forgiveness; every
   non-pass names its reason and remedy. *Prevents:* an exit code a
   consumer cannot act on without reading the report.
9. **Evidence, not conclusions.** The baseline stores sample vectors
   and exact integers, with the stored median verified on read.
   *Prevents:* verdicts drawn from stored summaries (interval overlap),
   which cannot be re-judged when the method changes; corrupt files
   passing silently.
10. **Only a failure exits 1.** The process exits 0 when rows are
    proposed or inconclusive; only `--strict` changes that, and for a
    proposed row alone.
    *Prevents:* training users to ignore a check that fails on noise.

## Dependency policy

`unix` plus the vendored clock, full stop. Each rejected dependency,
by name, with the reason it stays out:

- **`mtime`**: vendored and patched. `now_ns` reads
  `CLOCK_MONOTONIC_RAW` (Linux) or `mach_absolute_time` (Darwin), so
  NTP slew and suspend time never enter a sample, and it returns an
  immediate `int`, so a reading allocates nothing inside an allocation
  interval. The same stubs house `getloadavg` for the load sample and
  `gethostuuid` for the machine key. An upstream dependency could not
  carry the patch.
- **`digestif`**: the machine key is a 30-line FNV-1a hash, fully
  specified in `env.mli`.
- **`yojson`**: JSON is emitted, never parsed, by a small printer in
  `verdict.ml`.
- **`mirage-crypto-rng`**: nothing needs randomness, since the
  statistics are deterministic.

The bar for a new dependency is that it must beat vendoring and
writing the code, for a library that sits at the bottom of consumers'
benchmark closures.

## Platforms

Thumper needs 63-bit ints, because `now_ns` returns nanoseconds as an
immediate `int`. On Unix each case runs in a forked worker.
