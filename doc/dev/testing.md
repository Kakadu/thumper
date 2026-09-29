# Testing thumper

How thumper tests itself. `dune runtest` runs everything but the
`@quiet` sessions (under "Cram conventions"); no test it runs sleeps
on host speed or asserts a timing — every suite is engineered to be
deterministic on a loaded machine, because the machine running CI is
exactly the kind of host the product distrusts.

Three deliberate exceptions, all about subjects that *are* the clock:
`test_clock` sleeps and compares the clock's interval with the wall
clock's over the same sleep, within 10% (a ticks-vs-nanoseconds unit
error is invisible to any scripted test, and the scheduler stretches both
clocks alike),
the hung-worker cram leg (`worker_death.t`, fixture `hang` mode)
runs a case that spins forever under a 1 s per-case deadline inside a
60 s budget, and `test_measure` forks one such case under a 0.2 s
deadline — the assertion is termination and classification, never
a duration.

## Layout

One windtrap suite per module under `test/unit/`: `test_os`,
`test_stats`, `test_metric`, `test_budget`, `test_config`, `test_run`,
`test_bench`, `test_env`, `test_baseline`, `test_measure`,
`test_verdict`, `test_check`, `test_report`, `test_cli`, plus
`test_thumper` (what only the facade shows: its values are the internal
ones, each refusal names the value as a user calls it, `Thumper.run`
returns its exit code, and the documented examples compile and run) and
`test_clock` (the vendored stubs). The library's internal modules are
unreachable through the public surface, so the unit suites reach them
through `Thumper.Private` — the facade's unconstrained re-export,
existing for exactly this purpose (`thumper.mli`). The library is built
once and linked; no test compiles its own copy of a unit, so an edit to
any `lib/` source rebuilds exactly the tests that depend on it, under
the library's own flags (`test/unit/dune`'s header comment).

`test_report` owns the report's layout: one golden per report state
under `test/unit/report/`, rendered from verdicts that `Verdict.judge`
and `Verdict.decide` build over recorded trials, and one styled golden
that keeps its escapes. A changed layout shows as a `diff?` of its
golden; read it, then `dune promote`.

The laws of [`architecture.md`](architecture.md) are the test
obligations. The pure-core laws are windtrap properties — notably the
monotone ratchet (random verdicts × files: a candidate never moves a
non-confirmed-improved row), relation totality for every (L ≤ U, r, e)
including r = 0, an unconfirmed direction never advancing a row, staleness
short-circuit, codec round-trips (`parse ∘ print = id` byte-for-byte),
and JSON goldens. The measurement lock is held and released against a
second process that `test_env` forks, since exclusion shows only from
another process; the other operational laws (the lock seen through the
command line, single write path, honest exits) are cram scenarios.

The JSON goldens are `test_verdict`'s documents under `test/unit/json/`,
one per verdict state, compared with windtrap's `expect_file`: a changed
document fails `dune runtest` with its diff, and `dune promote` accepts
it once read. Their samples are chosen so that every delta is exact
(0.5, 1, 2 and 4 against rows of 1), so the documents print the same
digits on any libm.

## The golden stats corpus

`stats.ml` is the highest-validation-risk module: novel numerics with
no OCaml reference. Its suite has three layers (see the header of
`test/unit/test_stats.ml`):

1. **The committed corpus** — `test/unit/stats/stats.tsv`, generated and
   scipy-cross-checked by `gen_stats_corpus.py` beside it.
   Order-statistic-exact quantities (medians, interval endpoints, HL
   estimates, counts, booleans) are compared bit-for-bit;
   libm-dependent quantities with a principled tolerance.
2. **Windtrap properties** on the dyadic grid k/2¹⁶, where +, −, /2
   are IEEE-exact, so algebraic laws (centering, antisymmetry,
   translation equivariance) hold with zero tolerance.
3. **Hand-derived anchors** — expected values derived by brute-force
   enumeration of rank arrangements, independent of both the
   implementation and the generator.

The generator is dual-use. `python3 test/unit/stats/gen_stats_corpus.py`
verifies that a fresh in-memory regeneration is **byte-identical** to
the committed file; it needs no scipy, and CI runs it.
`uv run test/unit/stats/gen_stats_corpus.py --write` regenerates the
file and runs the scipy cross-checks, which uv installs. Regenerate
whenever the statistical method changes, and read the diff as a code
change.

**The mutation practice.** The corpus generator and `stats.ml` mirror
each other's construction, so a shared misconception passes layer 1 —
layer 3 is the net. When touching `stats.ml`, verify the net still
catches: introduce a boundary mutation by hand (flip a `<` to `<=` on
a cutoff, off-by-one an order-statistic index), confirm the suite goes
red, revert. A mutation that survives means a missing anchor: add one
before landing the real change.

## The measurement seam

`Measure.instruments` (clock, CPU clock, GC counters) is injectable,
so `test_measure` scripts the protocol's decisions in process:
calibration doubling to the floor, frozen-k reuse inside [0.2×, 5×]
and recalibration outside, the k/2k probe proving exactness with a
planted harness constant and failing it on nondeterministic counters,
the probe at the frozen batch size, the drift flag on a planted step,
the in-process deadline. Every scripted read records the case's call
count, so a test compares the batch sizes the protocol ran, in order.
Scripted instruments also cross a fork: the worker runs on its copy of
the world and its teardown writes what it recorded to a file.

The tests that fork a worker or read the real instruments are declared
`slow`, so `--exclude-tag slow` runs the scripted ones alone. They
assert only what no timing moves: a failure, an exact count, a sample
count. `Measure.Protocol.parse` is exposed so worker-pipe containment
(malformed lines, truncation, hostile counts) is tested without
forking.

One level up, `Check.run_with` adds the load as a second seam:
`test_check` drives the loop in process with scripted instruments and
a scripted load, whose second sample also marks the point between the
two sweeps: a regression confirmed, an improvement pooled at the frozen
batch size, the two load samples, the batch size each trial is frozen
at, pruning. Each test states its environment with `setenv`
(`THUMPER_MACHINE`, a `THUMPER_LOCK_DIR` under its own `temp_dir`).
Two `slow` tests run `Check.run` and `Check.measure` on their default
seams and read only what no timing moves. Scripted clocks must advance
across batches: a stuck scripted clock hangs the warmup arm by contract
(`measure.mli`).

`Cli.main` has no seam: `test_cli` drives it through its argv, in
process, and reads what it prints, its exit code and the files it
leaves. Most of its claims are reached through a stop, which `main`
makes before it measures: the parse through the usage errors and
`list`, the default baseline path through the pre-flight stop of a
directory that does not exist, so that the stop names the resolved
path and nothing is written. The runs that must print a report, for
the variant `main` chose (colour, the `rerun:` and `accept:` lines,
the GitHub annotations), the files a run writes and the pruning, measure
for real, in process, on a millisecond protocol that collects
allocation counts alone; they are `slow`. What `main` prints on a
loaded host (`--wait-quiet`'s lines, bless's refusal, the `# forced:`
record) depends on the host's load, so no unit test asserts it.

Through the facade, `test_thumper` measures twice, in `slow` tests:
`Thumper.measure` with 3 samples, and `Check.run`'s documented example
against a synthetic baseline. They read a sample count, an exact count,
an exit code and the sections of the corrected file.

The stanzas of `test_measure`, `test_check`, `test_cli` and
`test_thumper` take the cram sessions' measurement lock, so their real
measurements never share the host with a cram session's.

## Cram conventions

`test/cram/` is the executable specification of the CLI: one scenario
per subcommand × state (NEW, PASS, FAIL, inconclusive, exact
allocation, stale, corrupt, selection, JSON, bless,
list, lock, worker death, machine env, usage). Scenarios assert **exit codes, file
effects, and grep'd output shapes — never timings**.

The determinism kit:

- **The fixture** — `test/cram/fixture/bench_fixture.exe`, seven
  cases driven by `THUMPER_FIXTURE_MODE`, a comma-separated list of
  modes: `slow` (busy/spin does 2× the work — a regression — and
  busy/half half — an improvement), `alloc_more` and `alloc_less` (one
  cons cell more for alloc/list, one word less for alloc/array),
  `alloc_grow` (alloc/list allocates more on every call, so the
  exactness probe fails), `raise` and `kill9` (worker containment),
  `nondet` (bimodal plateaus that can only resolve inconclusive),
  `hang` (a case that spins forever under a 1 s per-case deadline —
  parent-side containment). The alloc cases collect `alloc_words`
  alone, so their verdicts compare whole counts that no load can move.
  `THUMPER_FIXTURE_RAN_PATH` appends a line per process start — how
  the dune-caching scenario observes re-runs without asserting time.
- **Environment pinning** — every session sources
  `test/cram/prelude.sh` first: `THUMPER_MACHINE=testkey` (stable
  section keys), a `THUMPER_LOCK_DIR` in the session's directory, and
  `INSIDE_DUNE`, `DUNE_SOURCEROOT`, `CI`, `GITHUB_ACTIONS`, `NO_COLOR`
  and `TERM` unset. It keeps dune's `INSIDE_DUNE` in `CONTEXT`, for the
  sessions about a rule action's environment.
- **The lock holder** — `test/cram/fixture/hold_lock.exe HELD
  RELEASE` takes the measurement lock, creates `HELD`, and holds it
  until the session creates `RELEASE`, so `lock.t`'s contention steps
  follow files, not time. It gives up after 60 s, and a session waits
  for a file or a line with `prelude.sh`'s `wait_for`, which gives up
  after 60 s of wall clock too: a failed session never leaves a process
  or a loop behind. Both cram stanzas stop a session after 300 s.
- **`(locks measurement)`** in `test/cram/dune` serializes the
  scenarios: a dozen concurrent spinning workers would push the load
  average over the gate's threshold and the suite would flake itself
  into inconclusive.
- **Timing verdicts on a quiet host.** Only a quiet host earns a timing
  verdict: under load the gate reads it inconclusive, exit 0, by
  contract. The sessions that need one — a confirmed regression failing
  the build, an improvement pooled across both sweeps, an unchanged
  suite passing, noise staying inconclusive — are in
  `test/cram/quiet/`, on the `@quiet` alias outside `@runtest`. Each
  run, the baseline's recording too, waits up to 60 s for a quiet host
  (`--wait-quiet 60`); the judged runs then assert the quiet-host
  outcome alone. Run `dune build @quiet` on a
  quiet machine before a release. `test_check` pins the same decisions
  in process on scripted clocks; the sessions add that the real path
  agrees.

## Docs and examples

`examples/` holds seven graded suites (first benchmark, getting
started, budgets, fixtures, tags, protocol, programmatic);
`02-getting-started` carries the real `@bench` + `(locks bench)` +
`diff?` rule the manual teaches. Nothing in `examples/` measures under
runtest — the `@bench` alias is manual. `doc/manual/snippets/`
compiles every OCaml snippet in the manual (build-only — nothing there
ever measures under runtest); a snippet that rots breaks the build.
`test_thumper` holds the facade's two examples verbatim: the module
doc's compiles, and `Check.run`'s, the check of `07-programmatic`, runs
against a synthetic baseline.
