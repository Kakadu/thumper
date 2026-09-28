# Testing thumper

`dune test` runs every unit suite and every cram session except the two
`@quiet` ones. No assertion in that run depends on the host being quiet,
because the machine running CI is the kind of host the product
distrusts. A test reads counts, files, exit codes and lines, and an
assertion on time is a bound that a slow host cannot break.

## The families

| Path | Holds | Pins |
| --- | --- | --- |
| `test/unit/test_<module>.ml` | one windtrap suite per interface of `lib/` | that interface's statements, grouped in its sections' order |
| `test/unit/test_thumper.ml` | the facade's suite | what only the facade shows |
| `test/unit/test_clock.ml` | the vendored clock's suite | the C stubs, on the host's clock |
| `test/unit/report/`, `test/unit/json/` | goldens | the report's states, the JSON document's states |
| `test/unit/stats/` | the corpus and its generator | `Stats` against reference values |
| `test/cram/*.t` | cram sessions | what only a process shows |
| `test/cram/quiet/` | the `@quiet` sessions | the timing verdicts, on a quiet host |

The library's internal modules are unreachable through the public
surface, so the unit suites reach them through `Thumper.Private`, the
facade's unconstrained re-export of them (`thumper.mli`). The library is
built once and linked; no test compiles its own copy of a unit, so an
edit to any `lib/` source rebuilds only the tests that depend on it,
under the library's own flags (`test/unit/dune`'s header comment).

`test_thumper` holds what only the facade shows: its values are the
internal ones, each refusal names the value as a user calls it,
`Thumper.run` returns its exit code, and the documented examples compile
and run. `test_clock` reads the host's clock and load average through the
stubs, and `test/unit/stop_stubs.c` is `test_measure`'s C fixture, a
worker that stops itself as a traced child.

A cram session pins what only a process shows: exit codes, which stream
a line goes to, the files a run leaves, two processes contending for the
measurement lock, a worker killed by a signal, the environment dune
gives a rule action, and the taught rule's dependency on the baseline and
its cache in a nested workspace. Every session drives the fixture executable
`test/cram/fixture/bench_fixture.exe`.

## Running the tests

```sh
dune test                                   # the default run
dune exec test/unit/test_check.exe -- --exclude-tag slow
dune test test/cram                         # the default run's cram sessions
dune build @test/cram/lock                  # one session, lock.t
dune build @quiet                           # the timing sessions
dune promote                                # accept a golden, once read
```

A suite's own flags follow `--` under `dune exec`; `--help` lists them,
and `-f PATTERN` runs the tests whose path contains `PATTERN`.
`test_stats` reads its corpus from its working directory, so run it from
`test/unit` as `dune exec ./test_stats.exe`.

A golden that no longer matches fails `dune test` with its diff: a
report state under `test/unit/report/`, a JSON document under
`test/unit/json/`, an `expect` block in `test_cli.ml` or
`test_verdict.ml`, or a cram session's output. Read the diff, then
`dune promote` accepts it. An `expect` literal carries `__POS_OF__`, so
the promotion rewrites the literal in the source.

## Owners

Each interface has one owner suite, and a claim is pinned once, in its
owner. `test_report` owns every line of the report: one golden per
report state, rendered from verdicts that `Verdict.judge` and
`Verdict.decide` build over recorded trials, and one styled golden that
keeps its escapes. `test_verdict` owns every relation and the JSON
document, one golden per verdict state. `test_cli` owns what `Cli.main`
decides and prints outside the report: stops, warnings, help, usage and
the files it writes. `test_os` owns the atomic write. A cram session
asserts the exit code, the stream and the line it owns, never the
report's layout.

The laws of [`architecture.md`](architecture.md) are the test
obligations. The pure-core laws are windtrap properties, among them
relation totality for every (L ≤ U, r, e) including r = 0, and the codec
round trips
(`parse ∘ print = id` byte-for-byte). The measurement lock is held and
released against a second process that `test_env` forks, since
exclusion shows only from another process. The other operational laws
(the lock seen through the command line, the single write path, the
exit codes) are pinned by `test_cli` and the cram sessions.

The JSON goldens' samples are chosen so that every delta is exact (0.5,
1, 2 and 4 against rows of 1), so the documents print the same digits on
any libm.

## The seams

`Measure.instruments` (clock, CPU clock, GC counters) is injectable, so
`test_measure` scripts the protocol's decisions in process: calibration
doubling to the floor, frozen-k reuse inside [0.2×, 5×] and
recalibration outside, the k/2k probe proving exactness with a planted
harness constant and failing it on nondeterministic counters, the probe
at the frozen batch size, the drift flag on a planted step, the
in-process deadline. Every scripted read records the case's call count,
so a test compares the batch sizes the protocol ran, in order. Scripted
instruments also cross a fork, since the worker runs on its copy of the
world; its teardown writes what it recorded to a file that the test
reads.

One level up, `Check.run_with` adds the load as a second seam.
`test_check` drives the loop in process with scripted instruments and a
scripted load, whose second sample also marks the point between the two
sweeps. It pins a regression confirmed, an improvement confirmed at the
frozen batch size, the two load samples, the batch size each trial is
frozen at, and the cases a filter judges. Scripted clocks must advance
across batches,
since a stuck scripted clock hangs the warmup by contract
(`measure.mli`).

The seams are these:

- `Measure.instruments` and `Measure.default_instruments`, taken as
  `?instruments` by `Measure.case`, `Check.measure` and
  `Check.run_with`;
- `?load` on `Check.run_with` and on `Env.wait_quiet`, and
  `Env.wait_quiet`'s `?poll_s`;
- `Config.fork`, which keeps a scripted clock in process.

They stay internal, reached through `Thumper.Private` and kept out of
the facade. A seam on the facade would be an API that only thumper's
own tests use, and the facade gains one only when a user needs it.
`Cli.main` has no seam, and a test never overrides the load or the
clock through the command line.

`Cli.main` is driven through its argv, in process: `test_cli` reads
what it prints, its exit code and the files it leaves. Most of its
claims are reached through a stop, which `main` makes before it
measures: the parse through the usage errors and `list`, the default
baseline path through the pre-flight stop of a directory that does not
exist, so that the stop names the resolved path and nothing is written.

## Real measurement and `slow`

A claim about what the protocol or the loop decides runs on scripted
instruments and a scripted load, in process or in a forked worker. The
host's clock and counters measure only where they are the subject:

1. the instruments themselves: `Thumper_clock`, and
   `default_instruments` proving an allocation exact in process;
2. process containment: the fork, the pipe, a raise, a signal, the
   parent's deadline, the bounded reap and a refused fork;
3. one smoke per entry point: `Check.run` and `Check.measure` in
   `test_check`, `Thumper.measure` with 3 samples and `Check.run`'s
   documented example in `test_thumper`, and the runs of `Cli.main` in
   `test_cli` that must print a report or write a file.

Every assertion on such a run reads something no timing can move: an
exact count, a sample count, a proposed row, an exit code, a file, or
the variant of the report that `main` chose. The runs through
`Cli.main` measure on a protocol of three samples at a 10 µs floor, in
process, collecting allocation counts alone. The preset cases are the
exception: they collect `wall_time`, at the sample count of the preset
they test, and read that count.

These tests are declared with windtrap's `slow` tag, so a suite run with
`--exclude-tag slow` is the fast loop. A test that waits on a process
carries its own `~timeout`.

Time enters an assertion in three places, each a bound that a loaded
host cannot break. `test_clock` compares the clock's interval with the
wall clock's over one sleep, within 10%. A ticks-for-nanoseconds error
is invisible to any scripted test, and the scheduler stretches both
clocks alike. `test_env` checks that `Env.wait_quiet` waits at least its
deadline and samples at most once per poll. The hung worker, in
`test_measure` under a 0.1 s deadline and in `worker_death.t` under
1 s, asserts that the run ends and how, never a duration.

## One measurement at a time

No two tests measure at once in the default run. The cram sessions
take dune's `(locks)` on `test/cram/measurement`, and so do the stanzas
of the four unit suites that measure (`test_measure`, `test_check`,
`test_cli` and `test_thumper`), which name it `../cram/measurement`. A
dune lock's name is a path relative to its stanza's directory, so the
three spellings in `test/unit`, `test/cram` and `test/cram/quiet` name
one lock. Without it the spinning workers of concurrent sessions would
raise the load average they sample, and on a loaded host every sampled
comparison reads inconclusive.

The measurement lock itself, thumper's per-user lock file, never makes
two tests wait on each other. Every test that runs `Cli.main`,
`Check.run` or the lock states `THUMPER_LOCK_DIR` as a directory of its
own, with `setenv`, and a cram session states it in its own directory
through `prelude.sh`.

## Cram sessions

`test/cram/` is the executable specification of the command line: one
session per subcommand × state (a first run, a passing check, an
inconclusive check, exact allocation, a stale section, a corrupt file,
another suite's file, an uncollected budget, selection, the JSON
document, bless, list, the lock, worker death, the machine key from the
environment, usage). The rules that keep them deterministic:

- **Exact evidence only.** A session in `@runtest` judges exact counts,
  which no load moves: one run, no retry, no `--wait-quiet`. The alloc
  cases collect `alloc_words` alone, so no timed value enters their
  verdicts.
- **The fixture's modes** plant each outcome a session needs.
  `THUMPER_FIXTURE_MODE` holds a comma-separated list of them: `slow`
  (busy/spin does twice its work, a regression, and busy/half half, an
  improvement), `alloc_more` and `alloc_less` (one cons cell more for
  alloc/list, one word less for alloc/array), `alloc_grow` (alloc/list
  allocates more on every call, so the exactness probe fails), `raise`
  and `kill9` (worker containment), `nondet` (samples that never
  settle), `hang` (a case that never returns, under a 1 s deadline per
  case) and `uncollected` (a budget on a metric the case does not
  collect). `THUMPER_FIXTURE_RAN_PATH` gets a line per process start,
  which is how the dune-caching session sees a rerun without asserting
  time.
- **The stated environment.** Every session sources
  `test/cram/prelude.sh` first: `THUMPER_MACHINE=testkey` for a stable
  section, a `THUMPER_LOCK_DIR` in the session's directory, and
  `INSIDE_DUNE`, `DUNE_SOURCEROOT`, `CI`, `GITHUB_ACTIONS`, `NO_COLOR`
  and `TERM` unset. It keeps dune's `INSIDE_DUNE` in `CONTEXT`, for the
  sessions about a rule action's environment.
- **Verbatim lines.** A deterministic line (a usage error, a stop, a
  lock refusal, a dead worker) is printed whole, with `cat` or `grep`,
  so a failure shows what the program printed.
- **One scrub.** The summary ends with the run's duration, so a session
  reads it through `prelude.sh`'s `summary LOG`, which prints the
  summary line with its duration written `DURATION`, from a plain log and
  from a dune build's alike.
- **Bounded waits.** `test/cram/fixture/hold_lock.exe HELD RELEASE`
  takes the measurement lock, creates `HELD`, and holds the lock until
  the session creates `RELEASE`, so `lock.t`'s contention steps follow
  files, not time. It gives up after 60 s, and a session waits for a
  file or a line with `prelude.sh`'s `wait_for`, which gives up after
  60 s of wall clock too. A failed session never leaves a process or a
  loop behind.
- **A session's own limit.** Both cram stanzas stop a session after
  300 s (`(timeout 300)`).

## Timing verdicts on a quiet host

Only a quiet host earns a timing verdict; under load the check reads it
inconclusive and exits 0, by contract. The sessions that need one are in
`test/cram/quiet/`, on the `@quiet` alias outside `@runtest`.
`regression.t` pins a confirmed regression failing the build beside an
improvement that `bless` records, and `pass.t` an unchanged suite
passing and noise staying inconclusive. Each run, the recording of the
baseline too, waits up to 60 s for a quiet host (`--wait-quiet 60`), and
the judged runs then assert the quiet-host outcome alone. `test_check`
pins the same decisions in process on scripted clocks; these sessions
add that the command line reaches them on the host's clock.

Before a release:

1. Stop every other job on the host, and wait until its load average
   per core is under 0.5 (`uptime` prints the load average).
2. Run `dune build @quiet`.
3. On a failure, read the load again. A host still loaded after a 60 s
   wait makes the judged runs inconclusive, and the sessions are rerun
   once it is quiet; a failure on a quiet host is a regression in the
   timing path.

## The golden stats corpus

`stats.ml` is the highest-validation-risk module, since its numerics
are novel and have no OCaml reference. Its suite has three layers (see
the header of `test/unit/test_stats.ml`):

1. **The committed corpus**, `test/unit/stats/stats.tsv`, generated and
   scipy-cross-checked by `gen_stats_corpus.py` beside it.
   Order-statistic-exact quantities (medians, interval endpoints, HL
   estimates, counts, booleans) are compared bit for bit. A value
   computed through libm is compared to within 1e-12, and a p-value is
   checked through the decisions `drifted` takes on either side of it.
2. **Windtrap properties** on the dyadic grid k/2¹⁶, where +, −, /2
   are IEEE-exact, so algebraic laws (centering, antisymmetry,
   translation equivariance) hold with zero tolerance.
3. **Hand-derived anchors**: expected values derived by brute-force
   enumeration of rank arrangements, independent of both the
   implementation and the generator.

The generator is dual-use. `python3 test/unit/stats/gen_stats_corpus.py`
verifies that a fresh in-memory regeneration is byte-identical to the
committed file; it needs no scipy, and CI runs it.
`uv run test/unit/stats/gen_stats_corpus.py --write` regenerates the
file and runs the scipy cross-checks, which uv installs. Regenerate
whenever the statistical method changes, and read the diff as a code
change.

**The mutation practice.** The corpus generator and `stats.ml` mirror
each other's construction, so a shared misconception passes layer 1,
and layer 3 is the net. When touching `stats.ml`, verify the net still
catches: introduce a boundary mutation by hand (flip a `<` to `<=` on
a cutoff, off-by-one an order-statistic index), confirm the suite goes
red, revert. A mutation that survives means an anchor is missing; add
one before landing the change.

## Exports kept for the tests

Apart from the seams, every value an internal interface exports has a
caller in `lib/` outside its module, except four. Each stays because its
own tests pin something no path through a production caller reaches:

- `Env.hash` is the FNV-1a hash behind the machine key. Its reference
  vectors in `test_env` pin the key's printed form: 16 digits, unsigned,
  over bytes from 0x80 and NUL. A test of `machine_key` can only compare
  the key with the same recipe applied to this host's strings, which a
  change of the printed form leaves passing.
- `Env.classify` turns a load average and a core count into a load.
  Only literal readings reach its threshold at half a task per core and
  its refusal of fewer than one core, since `Env.load` reads the host
  and every `?load` seam takes a load already classified.
- `Measure.Protocol` is the worker pipe's `write` and `parse`. `write` runs
  only in a forked worker, which exits through `_exit`, so neither
  coverage nor a mutation run sees it there; the in-process round trip
  pins it, its drifted flag included. `parse`'s malformed outputs
  (unknown, missing and repeated metrics, truncation, hostile counts)
  are tested without forking.
- `Cli.default_baseline_dir` resolves the default baseline's directory.
  `Cli.main` passes it the test's own executable, so the other layouts
  (an executable outside `_build`, a `.sandbox/<hash>` segment, a
  missing source directory, an executable directly in `_build`, a
  relative path with `..`) are reached only through its direct table.

## Stated, not tested

These contracts are stated in the interfaces and no test in the default
run asserts them:

- What `Cli.main` prints on a loaded host: `--wait-quiet`'s waiting and
  expiry lines and bless's two refusals. The host's load decides
  whether they appear.
- That `--wait-quiet` passes its seconds to `Env.wait_quiet` unchanged.
  Only the length of a wait on a loaded host would show it.
- That `Env.wait_quiet` at a timeout of 0 samples once, even when the
  clock has not moved. `test_env` repeats the call 1000 times, but a
  wait that went on past one sample shows only when two clock readings
  are equal, which the clock on Apple silicon (41.67 ns steps) gives in
  some calls and Linux's never.
- That `--color auto` colours a terminal. A test's stdout is never a
  terminal.
- Which arm of `cli.ml`'s wait paths runs. `test_cli` runs `check` and
  `bless --force` with `--wait-quiet 0` and reads their exit codes; the
  host's load decides whether they take the loaded arms (the waiting
  line, the expired wait's warning) or the quiet ones.
- That a waiter restarts its deadline when the lock changes holder
  (`env.mli`), and that `Cli.main` then prints that the lock changed
  owner. No test waits through a change of holder; `lock.t` pins the
  waiting line alone.

## Docs and examples

`examples/` holds seven graded suites (first benchmark, getting
started, budgets, fixtures, tags, protocol, programmatic);
`02-getting-started` carries the rule the manual teaches: the `@bench`
alias, `(locks %{project_root}/bench)`, `(deps (glob_files *.thumper))` and
a bare `run`. Nothing in `examples/` measures under
runtest, since the `@bench` alias is manual. Every OCaml and dune snippet
in the manual and the README is a run of lines of an example's file, and
`dune build` compiles the examples.
`test_thumper` holds the facade's two examples verbatim: the module
doc's compiles, and `Check.run`'s, the check of `07-programmatic`, runs
against a synthetic baseline and changes no file.
