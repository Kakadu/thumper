# Running checks

These recipes run a suite whose baseline is committed: while you change the
code, when you record a new baseline, on several machines, in CI and on
loaded hosts. The transcripts run `examples/02-getting-started` as a
project's `bench/` directory, with its baseline recorded as at the end of
the [tutorial](getting-started.md). Their numbers are one run's.

## Measuring one case while iterating

To measure one case after an edit, run the executable with `-f` and the
case's id, and `--quick` for 11 samples in place of 20. `dune exec` builds
the executable and passes it the arguments after `--`:

<!-- placeholder: Q1 regenerates this transcript -->
```
$ dune exec bench/bench_digest.exe -- -f fib/20 --quick
digest: 1 case vs bench/digest.thumper for machine 5c1e0a7f3b9d2486

  passed  10.84 ns  ±0.4%  0 w  fib/20

1 passed in 0.3s.
```

`-f` selects every case whose id contains its pattern, as [selecting
cases](command-line.md#selecting-cases) shows. A `--quick` run judges its
11 samples against the baseline's `n=20` rows. Its intervals are wider
than a default run's, so more comparisons can be inconclusive for
`wide interval`.

## Re-measuring a failing case

A failing run prints a `rerun:` line, the command that measures the
failing cases again with the run's flags. It pastes where the run was
started, or from the workspace root after `dune build`. After the
tutorial's [regression](getting-started.md#a-regression):

<!-- placeholder: Q1 regenerates this transcript -->
```
$ dune exec bench/bench_digest.exe
digest: 3 cases vs bench/digest.thumper for machine 5c1e0a7f3b9d2486

  passed     199.31 ns  ±0.5%  4 w  md5/string-64
  REGRESSED   13.07 ns  ±0.3%  0 w  fib/10
      +99.5% [+99.1, +99.9]  budget +5%
  REGRESSED   21.63 ns  ±0.2%  0 w  fib/20
      +99.7% [+99.5, +99.9]  budget +5%

rerun: ./_build/default/bench/bench_digest.exe -f fib/10 -f fib/20
1 passed, 2 regressed in 1.6s.
```

To measure them again, paste the line:

<!-- placeholder: Q1 regenerates this transcript -->
```
$ ./_build/default/bench/bench_digest.exe -f fib/10 -f fib/20
digest: 2 cases vs bench/digest.thumper for machine 5c1e0a7f3b9d2486

  REGRESSED  13.06 ns  ±0.2%  0 w  fib/10
      +99.4% [+99.0, +99.8]  budget +5%
  REGRESSED  21.61 ns  ±0.3%  0 w  fib/20
      +99.6% [+99.3, +99.9]  budget +5%

rerun: ./_build/default/bench/bench_digest.exe -f fib/10 -f fib/20
2 regressed in 1.3s.
```

A run with an inconclusive comparison that another measurement may settle
prints a `rerun:` line too ([reasons](report.md#inconclusive-reasons)).

## Running the benchmarks again

Dune caches the benchmark rule like any other. With the executable and the
baseline unchanged, `dune build @bench` measures nothing and prints nothing.
To measure again anyway, add `--force`:

<!-- placeholder: Q1 regenerates this transcript -->
```
$ dune build @bench
$ dune build @bench --force
digest: 3 cases vs digest.thumper for machine 5c1e0a7f3b9d2486

  passed  199.18 ns  ±0.6%  4 w  md5/string-64
  passed    6.55 ns  ±0.3%  0 w  fib/10
  passed   10.83 ns  ±0.2%  0 w  fib/20

3 passed in 0.9s.
```

## Recording an improvement

A confirmed improvement passes, and its row reads `improved`. The
`accept:` line names the `bless` command that records the improved cases.
Until they are recorded, later runs compare with their old rows. Here the
`fib` cases do half the work: in `bench/bench_digest.ml`,
`fib (Thumper.black_box n)` becomes:

```ocaml
fib (Thumper.black_box (n / 2))
```

<!-- placeholder: Q1 regenerates this transcript -->
```
$ dune build @bench
digest: 3 cases vs digest.thumper for machine 5c1e0a7f3b9d2486

  passed    199.08 ns  ±0.6%  4 w  md5/string-64
  improved    4.43 ns  ±0.3%  0 w  fib/10
      -32.3% [-32.6, -32.0]
  improved    6.61 ns  ±0.2%  0 w  fib/20
      -39.0% [-39.2, -38.8]

accept: ./_build/default/bench/bench_digest.exe bless -f fib/10 -f fib/20
3 passed (2 improved) in 1.6s.
$ ./_build/default/bench/bench_digest.exe bless -f fib/10 -f fib/20
digest: 2 cases for machine 5c1e0a7f3b9d2486

  blessed  4.42 ns  ±0.2%  0 w  fib/10
  blessed  6.60 ns  ±0.2%  0 w  fib/20

2 blessed into bench/digest.thumper in 0.6s.
```

`bless -f` records the cases it selects and keeps every other row of the
section. A pattern selects every case whose id contains it, and `bless`'s
report lists each case it recorded. `git diff bench/digest.thumper` shows
the rows that changed, for review before the commit.

## Recording an intended slowdown

To keep a slowdown you intend, record the slower cases with `bless`.
`bless -f fib` records the cases whose id contains `fib` in this machine's
section. With the regression's edit in place:

<!-- placeholder: Q1 regenerates this transcript -->
```
$ dune exec bench/bench_digest.exe -- bless -f fib
digest: 2 cases for machine 5c1e0a7f3b9d2486

  blessed  13.05 ns  ±0.3%  0 w  fib/10
  blessed  21.60 ns  ±0.2%  0 w  fib/20

2 blessed into bench/digest.thumper in 0.6s.
$ dune build @bench
digest: 3 cases vs digest.thumper for machine 5c1e0a7f3b9d2486

  passed  199.22 ns  ±0.5%  4 w  md5/string-64
  passed   13.06 ns  ±0.2%  0 w  fib/10
  passed   21.62 ns  ±0.3%  0 w  fib/20

3 passed in 1.0s.
```

`bless` refuses a loaded host ([checking on a loaded
host](#checking-on-a-loaded-host)). The commit that changes the baseline is
the place to say why the case is slower.

## Adding a machine

A machine with no section in the baseline passes its first run with every
row `proposed`, as the tutorial's [first
run](getting-started.md#the-first-run) does, and `bless` records its
section. Each machine records once when a suite is born, and again after
each compiler upgrade. A run judges only its own machine's section, and
`bless` never changes another's.

## Upgrading the compiler

A section recorded under another compiler is stale. Every row reads
`proposed`, and `bless` records the section again. After a compiler
upgrade, the header names both compilers:

<!-- placeholder: Q1 regenerates this transcript -->
```
$ dune exec bench/bench_digest.exe
digest: stale baseline for machine 5c1e0a7f3b9d2486 (ocaml 5.2.0 · 64-bit · release → 5.5.1 · 64-bit · release)

  proposed  199.20 ns  ±0.6%  4 w  md5/string-64
  proposed    6.55 ns  ±0.3%  0 w  fib/10
  proposed   10.83 ns  ±0.2%  0 w  fib/20

accept: ./_build/default/bench/bench_digest.exe bless
3 proposed in 0.9s.
```

Flambda is not part of the compiler identity (Baselines in
[`lib/thumper.mli`](../../lib/thumper.mli)). After a move to a flambda
compiler of the same version, record every case again with `bless`.

## Checking in CI

A run passes when this machine has no section in the baseline, unless an
exact count is over its `at_most` cap. Every row then reads `proposed`,
and nothing is compared. Thumper cannot tell a
runner that should compare from a new machine, and a CI job that must
compare says so with `--strict`. It fails a run with a proposed metric,
and an inconclusive comparison still passes. Run each suite from a CI step
with `dune exec`, as here on a runner whose key has no section:

<!-- placeholder: Q1 regenerates this transcript -->
```
$ THUMPER_MACHINE=ci-linux dune exec bench/bench_digest.exe -- --strict
digest: no baseline for machine ci-linux (Apple M1 Max)

  proposed  199.14 ns  ±0.7%  4 w  md5/string-64
  proposed    6.55 ns  ±0.4%  0 w  fib/10
  proposed   10.84 ns  ±0.2%  0 w  fib/20

accept: ./_build/default/bench/bench_digest.exe bless
3 proposed in 0.9s; failed under --strict.
$ echo $?
1
```

## Recording a CI runner's section

Each runner has its own machine key, and so its own section. To give
runners that time alike one section, set `THUMPER_MACHINE` to a name of
your choosing in the job's environment. The name claims that every runner
using it times alike, as identical machines you control do. Record the
section with `bless` on one of those runners, and commit the baseline it
writes:

<!-- placeholder: Q1 regenerates this transcript -->
```
$ THUMPER_MACHINE=ci-linux dune exec bench/bench_digest.exe -- bless
digest: 3 cases for machine ci-linux

  blessed  199.10 ns  ±0.6%  4 w  md5/string-64
  blessed    6.55 ns  ±0.3%  0 w  fib/10
  blessed   10.83 ns  ±0.2%  0 w  fib/20

3 blessed into bench/digest.thumper in 0.9s.
$ THUMPER_MACHINE=ci-linux dune exec bench/bench_digest.exe -- --strict
digest: 3 cases vs bench/digest.thumper for machine ci-linux

  passed  199.16 ns  ±0.5%  4 w  md5/string-64
  passed    6.56 ns  ±0.4%  0 w  fib/10
  passed   10.84 ns  ±0.2%  0 w  fib/20

3 passed in 0.9s.
```

How the file leaves the runner, as a job artifact or a commit, is the
project's choice.

## Checking on hosted CI runners

Hosted runners give each job a new virtual machine, and not every one has
the same CPU model. A section recorded under one `THUMPER_MACHINE` name
holds one CPU's timings, and a slower CPU reads as a confirmed regression.
An exact count is the same on every CPU and under any load ([exact
counts](how-checks-decide.md#exact-counts)). A suite that collects only
`alloc_words` (`Config.metrics`, with no `wall_time` budget) compares
alike on every runner. To compare timings on hosted
runners, measure the base and the head in one job, as the next section
does.

## Comparing a base and a head on one runner

To compare a change with its base on one host, measure both trees in one
job. `bless` records the base's cases in a scratch baseline, and the
head's run checks against it:

```
git worktree add ../base main
(cd ../base && dune exec bench/bench_digest.exe -- bless --baseline /tmp/base.thumper)
dune exec bench/bench_digest.exe -- --baseline /tmp/base.thumper
```

`main` names the base revision. When both trees build with one compiler,
the head's run compares every case the base recorded, and a case the base
lacks reads `proposed`. `bless` refuses a loaded host here too.

## Checking on a loaded host

On a loaded host every sampled comparison is inconclusive for
`environment`, or for `non-positive sample` when a sample is zero or
negative, or for `exactness lost`, which the load does not change. Exact
counts are still judged. The warning under the header
names the load and the one at which a host is loaded ([the
header](report.md#the-header)). To wait for a quiet host before measuring,
add `--wait-quiet SECS`. When the host is still loaded after `SECS`
seconds, `check` warns and measures anyway:

<!-- placeholder: Q1 regenerates this transcript -->
```
$ dune exec bench/bench_digest.exe -- --wait-quiet 30
thumper: waiting up to 30s for a quiet host (load 18.7 on 10 cores, over 5.0)
thumper: warning: host still loaded after 30s; measuring anyway
digest: 3 cases vs bench/digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 18.4 on 10 cores, over 5.0; timing verdicts degraded

  inconclusive  204.11 ns  ±0.9%  4 w  md5/string-64
      environment  +0.1% [-1.3, +1.6]
  inconclusive    6.80 ns  ±0.6%  0 w  fib/10
      environment  +0.1% [-0.8, +1.1]
  inconclusive   11.25 ns  ±1.0%  0 w  fib/20
      environment  -2.2% [-4.7, -0.3]

rerun: ./_build/default/bench/bench_digest.exe
3 inconclusive in 1.0s.
```

`bless` refuses a host still loaded after the wait. With `--force`, it
records its rows anyway, and the section's `# forced:` line records the load
([sections](baseline-format.md#sections)).

## Measuring in a container

Inside a container the load average is the host's, and the container's own
CPU limit does not show in it. A starved container can read quiet, and
`--wait-quiet` then does not wait. Schedule such a job alone on its host.

## Reading the verdict from a script

The exit code is the one `run` in [`lib/thumper.mli`](../../lib/thumper.mli)
states, and `--json PATH` writes the verdict as a [JSON document](json.md).

GitHub sets `GITHUB_ACTIONS` in every job. The report then holds one
`::error::` line for each metric that fails its case, which GitHub shows as
an annotation ([GitHub annotations](report.md#github-annotations)):

<!-- placeholder: Q1 regenerates this transcript -->
```
$ GITHUB_ACTIONS=true dune build @bench
File "bench/dune", lines 5-11, characters 0-127:
 5 | (rule
 6 |  (alias bench)
 7 |  (locks %{project_root}/bench)
 8 |  (deps
 9 |   (glob_files *.thumper))
10 |  (action
11 |   (run %{exe:bench_digest.exe})))
digest: 3 cases vs digest.thumper for machine 5c1e0a7f3b9d2486

  passed     199.27 ns  ±0.5%  4 w  md5/string-64
  REGRESSED   13.08 ns  ±0.2%  0 w  fib/10
      +99.6% [+99.2, +99.9]  budget +5%
  REGRESSED   21.64 ns  ±0.3%  0 w  fib/20
      +99.8% [+99.5, +100.1]  budget +5%

::error::fib/10 regressed: wall_time +99.6% [+99.2, +99.9], budget +5%
::error::fib/20 regressed: wall_time +99.8% [+99.5, +100.1], budget +5%

rerun: ./_build/default/bench/bench_digest.exe -f fib/10 -f fib/20
1 passed, 2 regressed in 1.6s.
```

## Running two benchmarks at once

Two runs of one user with one lock directory never measure at once. Each
holds the measurement lock while it measures, and another run waits for it,
up to 600 s per holder, with a notice on stderr:

<!-- placeholder: Q1 regenerates this transcript -->
```
$ dune exec bench/bench_digest.exe
thumper: waiting for the measurement lock (another run is measuring) ...
digest: 3 cases vs bench/digest.thumper for machine 5c1e0a7f3b9d2486

  passed  199.24 ns  ±0.6%  4 w  md5/string-64
  passed    6.55 ns  ±0.3%  0 w  fib/10
  passed   10.83 ns  ±0.2%  0 w  fib/20

3 passed in 0.9s.
```

The lock's file and directory are under Measuring in
[`lib/thumper.mli`](../../lib/thumper.mli). Thumper creates the file
with mode `0600`. A lock file that another user owns, or whose mode
grants others any access, stops the run with exit 2. Dune's `(locks
%{project_root}/bench)` orders the benchmark rules of one project, and
the measurement lock every run of one user.

## Keeping the baseline elsewhere

To keep the baseline elsewhere than beside the benchmark's source, pass
`--baseline PATH`, and name the file in the rule's `deps` when a rule
passes it. Under dune, the default follows dune's environment, whatever
the build directory is called. Run by hand from a build directory not
named `_build`, an executable finds no dune environment and looks for the
default in the working directory. Pass it `--baseline`. The rules are
under Files in [`lib/thumper.mli`](../../lib/thumper.mli).
