# Thumper examples

Each directory is a self-contained benchmark executable with its own dune
stanza, recreating the journey from the top-level README: from first numbers,
to a build-failing regression gate, to the library underneath the CLI.

- `01-first-benchmark` — the smallest suite: `run` + `bench` in one
  executable; a bare run is the whole flow. A benchmark is an executable.
- `02-getting-started` — the manual `@bench` rule with `(locks bench)` and
  `diff?`: the first run proposes the baseline, `dune promote` accepts it,
  confirmed regressions fail the build (the gate cycle, below).
- `03-budgets` — per-metric contracts: `no_slower_than`, the
  `no_more_alloc_than 0.0` allocation pin, an absolute `at_most` cap, and
  per-metric inheritance — a case that relaxes wall time keeps its group's
  allocation pin.
- `04-setup-and-tags` — `bench_with_setup`: fixtures outside the timed
  region, families by partial application, tags, and `--tag` / `-f`
  selection.
- `05-config-and-noise` — the protocol as a value: presets and setters,
  `--quick` / `--precise`, what inconclusive means, `--wait-quiet` /
  `--strict` / `--color`, and `THUMPER_MACHINE` CI lanes.
- `07-programmatic` — the library without the CLI: `measure`, `Run`
  projections, `Baseline`, `Check.run`, and `Verdict.corrected` / `to_json` /
  `exit_code` — the CI gate as a program.

Everything compiles under plain `dune build`; nothing here runs under
`dune runtest`. Measurement is deliberate: by hand with `dune exec`, or
through example 02's manual `@bench` alias.

## Running one

Subcommands and flags go after `--`; `check` is the default subcommand, so
a bare run is the whole flow. With no baseline yet it measures, prints
every row as proposed, and writes a candidate for review next to the
example's *source* — the committable location, wherever you run it from —
nothing is installed behind your back:

```
$ dune exec examples/01-first-benchmark/bench_hello.exe
thumper: hello — no baseline for machine ca352e279bc47cb1 (Apple M1 Max)

  proposed   1.43 us  ±2.4%      3 kw  list-rev

  accept:  mv examples/01-first-benchmark/hello.thumper.corrected examples/01-first-benchmark/hello.thumper
  warning: load 7.6 on 10 cores; prefer a quiet host before accepting
```

(This capture raced a parallel build — on a quiet host the load note
disappears. Accept the candidate with the `mv`, or delete it; `--baseline
PATH` points the whole flow anywhere, as example 03 shows.)

`list` prints ids without measuring; selection composes from repeatable `-f`
(id substring, OR'd) and `--tag` (exact membership, AND'd):

```
$ dune exec examples/04-setup-and-tags/bench_corpus.exe -- list
scan/4-KiB
scan/64-KiB
scan/256-KiB
io/read-4KiB
$ dune exec examples/04-setup-and-tags/bench_corpus.exe -- list --tag large
scan/256-KiB
```

## The gate cycle (example 02)

No `digest.thumper` is committed here, on purpose: a baseline is measured
evidence, one section per machine, so a checked-out repository cannot ship
one that means anything on your hardware. The first build bootstraps it:

```
$ dune build @bench
thumper: digest — no baseline for machine ca352e279bc47cb1 (Apple M1 Max)

  proposed    1.40 us  ±0.9%  54 w  md5/string-64
  proposed    1.10 us  ±0.7%   0 w  fib/10
  proposed  135.50 us  ±1.0%   0 w  fib/20

  accept:  dune promote
File "examples/02-getting-started/digest.thumper", line 1, characters 0-0:
...
+# thumper baseline v1
+# suite: digest
+
+# machine: ca352e279bc47cb1
+# host: Thibauts-MacBook-2.local · Apple M1 Max · arm64 · macos
+# ocaml: 5.4.1 · 64-bit · release
+
+fib/10	alloc_words	exact	0
+fib/10	wall_time	batch=1048576	n=20	1.104e-06	1.101e-06 1.102e-06 ... 1.171e-06
...
```

The differing `diff?` leaves the build red — the failure *is* the promotion
prompt. What is proposed is evidence, never conclusions: proven-exact
allocation integers and sorted timing sample vectors. Accept it, and in your
own project commit it:

```
$ dune promote && git add examples/02-getting-started/digest.thumper
```

From then on, `dune build @bench` is the gate:

- **Green over a clean table** — measured, verified, everything within
  budget: the report prints its header, one `equivalent` row per case, and
  the summary. A green *silent* build is the other good outcome: an
  unchanged executable + baseline is a dune cache hit, and no measurement
  runs at all.
- **A confirmed regression** is red with a `REGRESSED` verdict cell (run by
  hand, the report adds a `rerun:` action naming the exact command to
  re-measure the case). A strong verdict must reproduce in the in-run
  confirmation pass before it may fail the build.
- **A confirmed improvement** is red with a one-row diff — the ratchet;
  `dune promote` advances the baseline, and the diff is the reviewable
  evidence.
- **An intentional regression** cannot be promoted — a candidate never
  carries regressed evidence. Accepting slower code is a deliberate
  whole-section re-record: `bless` (the check loop below shows it).
- **Noise** degrades to inconclusive: exit 0, never a red build.

A new machine's first build proposes its own section through the same flow,
and every write byte-preserves the other machines' sections.

## A check loop without dune rules (example 03)

`check` is the default subcommand and `--baseline` points it anywhere, so
the same cycle works by hand — first run proposes, moving the candidate over
the baseline accepts (that is all `dune promote` does in example 02):

```
$ dune exec examples/03-budgets/bench_budgets.exe -- check --baseline /tmp/budgets.thumper
thumper: budgets — no baseline for machine ca352e279bc47cb1 (Apple M1 Max)

  proposed  12.87 us  ±0.8%  2,048 w  codec/hex-encode
  proposed   8.13 us  ±0.9%  1,024 w  codec/hex-decode
  proposed   0.03 us  ±1.2%     64 w  scratch-table

  accept:  mv /tmp/budgets.thumper.corrected /tmp/budgets.thumper
$ mv /tmp/budgets.thumper.corrected /tmp/budgets.thumper
$ dune exec examples/03-budgets/bench_budgets.exe -- check --baseline /tmp/budgets.thumper
thumper: budgets — 3 cases vs /tmp/budgets.thumper for machine ca352e279bc47cb1

  equivalent  12.88 us  ±0.8%  2,048 w  codec/hex-encode
  equivalent   8.12 us  ±0.8%  1,024 w  codec/hex-decode
  equivalent   0.03 us  ±1.1%     64 w  scratch-table

  3 cases: 3 passed.
$ echo $?
0
```

The same move accepts an *intentional* regression — promotion never can,
because a candidate never carries regressed evidence. `bless` is the
deliberate override: it re-records this machine's whole section from this
run's evidence and writes it as the same `.corrected` candidate (the
baseline itself is never written; a loaded host is refused unless
`--force`):

```
$ dune exec examples/03-budgets/bench_budgets.exe -- bless --baseline /tmp/budgets.thumper
$ mv /tmp/budgets.thumper.corrected /tmp/budgets.thumper
```

The report always prints whole — there is no silent mode. On a busy machine
the same check tells you exactly what the load cost it — this one raced a
parallel build:

```
thumper: budgets — 3 cases vs /tmp/budgets.thumper for machine ca352e279bc47cb1
warning: load 7.6 on 10 cores; timing verdicts degraded

  inconclusive  12.91 us  ±1.1%  2,048 w  codec/hex-encode
      environment; equivalent (alloc exact)
  inconclusive   8.11 us  ±1.4%  1,024 w  codec/hex-decode
      environment; equivalent (alloc exact)
  inconclusive   0.03 us  ±1.9%     64 w  scratch-table
      environment; equivalent (alloc exact)

  3 cases: 0 passed, 3 inconclusive.
```

Still exit 0 — noise is never a red build — and the exact allocation
comparisons stayed earned and visible while the timing side degraded.
Example 05 is about exactly this.

## The library without the command line (example 07)

`dune exec examples/07-programmatic/programmatic.exe` measures the suite and
prints each case's median time and exact allocation, then checks it against
`programmatic.thumper` in the working directory, prints the JSON document,
writes `programmatic.thumper.corrected` when it proposes a change, and exits
with the verdict's exit code.
