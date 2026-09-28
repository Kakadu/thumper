# Running checks

These recipes run a suite whose baseline is committed: while you change the
code, when you accept a new baseline, on several machines, in CI and on
loaded hosts. The transcripts run `examples/02-getting-started` as a
project's `bench/` directory, with its baseline accepted as at the end of
the [tutorial](getting-started.md). Their numbers are one run's.

## Measuring one case while iterating

To measure one case after an edit, run the executable with `-f` and the
case's id, and `--quick` for 11 samples in place of 20. `dune exec` builds
the executable and passes it the arguments after `--`:

```
$ dune exec bench/bench_digest.exe -- -f fib/20 --quick
thumper: digest — 1 case vs bench/digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 21.0 on 10 cores; timing verdicts degraded

  inconclusive  14.18 ns  ±106.0%  0 w  fib/20
      environment  +0.5% [-8.5, +81.9]; equivalent (alloc exact)

  1 case: 0 passed, 1 inconclusive.
```

`-f` selects every case whose id contains its pattern, as [selecting
cases](command-line.md#selecting-cases) shows.

## Re-measuring a failing case

A failing run outside a dune rule prints a `rerun:` line, which measures the
failing cases again with the run's flags. After the tutorial's
[regression](getting-started.md#a-regression):

```
$ dune exec bench/bench_digest.exe
thumper: digest — 3 cases vs bench/digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 21.0 on 10 cores; timing verdicts degraded

  inconclusive  208.84 ns  ±1.1%  4 w  md5/string-64
      environment  +0.8% [-1.7, +2.6]; equivalent (alloc exact)
  inconclusive   11.60 ns  ±0.2%  0 w  fib/10
      environment  +67.5% [+59.9, +69.4]; equivalent (alloc exact)
  inconclusive   20.64 ns  ±0.7%  0 w  fib/20
      environment  +79.6% [+34.5, +82.1]; equivalent (alloc exact)

  3 cases: 0 passed, 3 inconclusive.
```

To measure them again, paste the line:

```
$ ./_build/default/bench/bench_digest.exe -f fib/10 -f fib/20
thumper: digest — 2 cases vs bench/digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 21.0 on 10 cores; timing verdicts degraded

  inconclusive  11.55 ns  ±0.3%  0 w  fib/10
      environment  +65.8% [+57.2, +68.5]; equivalent (alloc exact)
  inconclusive  20.48 ns  ±1.0%  0 w  fib/20
      environment  +76.0% [+32.1, +80.5]; equivalent (alloc exact)

  2 cases: 0 passed, 2 inconclusive.
```

## Running the benchmarks again

Dune caches the benchmark rule like any other. With the executable and the
baseline unchanged, `dune build @bench` measures nothing and prints nothing.
To measure again anyway, add `--force`:

```
$ dune build @bench
$ dune build @bench --force
thumper: digest — 3 cases vs digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 20.0 on 10 cores; timing verdicts degraded

  inconclusive  206.20 ns  ±0.7%  4 w  md5/string-64
      environment  -1.3% [-3.8, +0.2]; equivalent (alloc exact)
  inconclusive    6.82 ns  ±1.1%  0 w  fib/10
      environment  -1.3% [-5.8, +0.2]; equivalent (alloc exact)
  inconclusive   11.31 ns  ±1.4%  0 w  fib/20
      environment  -3.6% [-27.6, -0.3]; equivalent (alloc exact)

  3 cases: 0 passed, 3 inconclusive.
```

## Accepting an improvement

An improvement fails the build too, until you accept it. The corrected file
advances the improved rows, and `diff?` fails the build on its diff until
`dune promote` accepts it. Here the `fib` cases do half the work: in
`bench/bench_digest.ml`, `fib (Thumper.black_box n)` became:

```ocaml
fib (Thumper.black_box (n / 2))
```

```
$ dune build @bench
thumper: digest — 3 cases vs digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 20.0 on 10 cores; timing verdicts degraded

  inconclusive  203.04 ns  ±1.3%  4 w  md5/string-64
      environment  -3.0% [-5.5, -0.8]; equivalent (alloc exact)
  inconclusive    4.99 ns  ±0.5%  0 w  fib/10
      environment  -28.0% [-31.3, -27.1]; equivalent (alloc exact)
  inconclusive    7.02 ns  ±0.4%  0 w  fib/20
      environment  -38.8% [-54.2, -38.1]; equivalent (alloc exact)

  3 cases: 0 passed, 3 inconclusive.
$ dune promote
```

Outside a dune rule, the report's `accept:` line is the `mv` that accepts
the corrected file. A corrected file never records a slower row ([what the
corrected file may
change](how-checks-decide.md#what-the-corrected-file-may-change)).

## Accepting an intended slowdown

To accept a slowdown you intend, re-record the cases with `bless`, then
accept its corrected file. `bless -f fib` re-records the cases whose id
contains `fib` in this machine's section, and keeps every other row. With
the regression's edit in place:

```
$ dune exec bench/bench_digest.exe -- bless -f fib
thumper: bless refused: load 19.8 on 10 cores; rerun with --wait-quiet SECS, or with --force to record it anyway
$ mv bench/digest.thumper.corrected bench/digest.thumper
mv: bench/digest.thumper.corrected: No such file or directory
$ dune build @bench
thumper: digest — 3 cases vs digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 19.8 on 10 cores; timing verdicts degraded

  inconclusive  206.03 ns   ±1.3%  4 w  md5/string-64
      environment  -0.4% [-1.6, +1.7]; equivalent (alloc exact)
  inconclusive   11.77 ns   ±2.8%  0 w  fib/10
      environment  +68.6% [+6.0, +72.9]; equivalent (alloc exact)
  inconclusive   21.03 ns  ±24.9%  0 w  fib/20
      environment  +81.4% [+76.8, +159.0]; equivalent (alloc exact)

  3 cases: 0 passed, 3 inconclusive.
```

`bless` refuses a loaded host ([checking on a loaded
host](#checking-on-a-loaded-host)). The commit that changes the baseline is
the place to say why the case is slower.

## Adding a machine

A machine with no section in the baseline proposes one on its first run, as
the tutorial's [first run](getting-started.md#the-first-run) does, and
`dune promote` accepts it. Each machine needs one accept when a suite is
born, and one after each compiler upgrade. A run judges only its own
machine's section, and never changes another's.

## Upgrading the compiler

A section recorded under another compiler is stale. Every row reads
`proposed`, and the corrected file records the section again. After a
compiler upgrade, the header names both compilers:

```
$ dune exec bench/bench_digest.exe
thumper: waiting for the measurement lock (another run is measuring) ...
thumper: the measurement lock changed owner; waiting on the new holder ...
thumper: digest — stale baseline for machine 5c1e0a7f3b9d2486 (ocaml 5.2.0 · 64-bit · release → 5.5.1 · 64-bit · release)

  proposed  204.43 ns  ±0.7%  4 w  md5/string-64
  proposed    6.79 ns  ±0.5%  0 w  fib/10
  proposed   11.46 ns  ±1.9%  0 w  fib/20

  accept:  mv bench/digest.thumper.corrected bench/digest.thumper
  warning: load 18.7 on 10 cores; prefer a quiet host before accepting
```

Accept it as a first run. Flambda is not part of the compiler identity
(Baselines in [`lib/thumper.mli`](../../lib/thumper.mli)). After a move to a
flambda compiler of the same version, re-record every case with `bless` and
accept the corrected file.

## Checking on a fleet of CI runners

Each runner of a fleet has its own machine key, and its own first run. To
give them one section, set `THUMPER_MACHINE` to a name of your choosing in
the job's environment. The name claims that every runner using it times
alike, as identical machines you control do.

Dune reruns a rule only when one of its dependencies changes. An environment
variable is one only when the rule declares it, and a run under a new key
prints nothing:

```
$ THUMPER_MACHINE=ci-linux dune build @bench
```

In the rule of `bench/dune`, beside `(locks bench)`, declare the variable:

```dune
(deps (env_var THUMPER_MACHINE))
```

The rule then runs under each key, and the first run under a new key
proposes its section:

```
$ THUMPER_MACHINE=ci-linux dune build @bench
thumper: digest — no baseline for machine ci-linux (Apple M1 Max)

  proposed  206.65 ns  ±1.6%  4 w  md5/string-64
  proposed    6.95 ns  ±2.0%  0 w  fib/10
  proposed   11.46 ns  ±1.4%  0 w  fib/20

  accept:  dune promote
  warning: load 18.7 on 10 cores; prefer a quiet host before accepting
File "bench/digest.thumper", line 1, characters 0-0:
diff --git a/_build/default/bench/digest.thumper b/_build/default/bench/digest.thumper.corrected
index e39d426..fe19fa0 100644
--- a/_build/default/bench/digest.thumper
+++ b/_build/default/bench/digest.thumper.corrected
@@ -11,3 +11,14 @@ fib/20	alloc_words	exact	0
 fib/20	wall_time	batch=524288	n=20	1.146e-08	1.102e-08 1.105e-08 1.111e-08 1.123e-08 1.127e-08 1.133e-08 1.134e-08 1.138e-08 1.142e-08 1.146e-08 1.146e-08 1.150e-08 1.156e-08 1.165e-08 1.176e-08 1.178e-08 1.260e-08 1.313e-08 1.471e-08 1.589e-08
 md5/string-64	alloc_words	exact	4
 md5/string-64	wall_time	batch=32768	n=20	2.045e-07	1.949e-07 1.988e-07 2.004e-07 2.013e-07 2.013e-07 2.020e-07 2.023e-07 2.024e-07 2.029e-07 2.043e-07 2.046e-07 2.047e-07 2.047e-07 2.047e-07 2.049e-07 2.054e-07 2.062e-07 2.072e-07 2.083e-07 2.465e-07
+
+# machine: ci-linux
+# host: laptop · Apple M1 Max · arm64 · macos
+# ocaml: 5.5.1 · 64-bit · release
+
+fib/10	alloc_words	exact	0
+fib/10	wall_time	batch=1048576	n=20	6.947e-09	6.711e-09 6.734e-09 6.863e-09 6.877e-09 6.888e-09 6.891e-09 6.896e-09 6.920e-09 6.925e-09 6.944e-09 6.949e-09 6.967e-09 6.976e-09 7.027e-09 7.175e-09 7.341e-09 7.752e-09 8.402e-09 9.096e-09 9.931e-09
+fib/20	alloc_words	exact	0
+fib/20	wall_time	batch=524288	n=20	1.145e-08	1.113e-08 1.130e-08 1.130e-08 1.133e-08 1.133e-08 1.134e-08 1.135e-08 1.140e-08 1.144e-08 1.144e-08 1.147e-08 1.150e-08 1.156e-08 1.162e-08 1.166e-08 1.172e-08 1.172e-08 1.191e-08 1.192e-08 1.474e-08
+md5/string-64	alloc_words	exact	4
+md5/string-64	wall_time	batch=32768	n=20	2.067e-07	2.013e-07 2.024e-07 2.039e-07 2.056e-07 2.056e-07 2.057e-07 2.059e-07 2.064e-07 2.065e-07 2.066e-07 2.067e-07 2.084e-07 2.089e-07 2.098e-07 2.123e-07 2.161e-07 2.200e-07 2.400e-07 2.401e-07 2.451e-07
```

The runner's corrected file is
`_build/default/bench/digest.thumper.corrected`, the whole baseline with its
section. To accept it, keep it as a job artifact and commit it as
`bench/digest.thumper`. A confirmed improvement fails the job the same way,
until its corrected file is accepted.

## Checking on hosted CI runners

Hosted runners give each job a new virtual machine, and not every one has
the same CPU model. A fleet key then puts two CPUs' timings in one section,
and a slower CPU reads as a confirmed regression. On hosted runners, budget
allocation alone, such as
`~budgets:[ Thumper.Budget.no_more_alloc_than 0. ]` given to `run` with no
time budget. An exact count is the same on every CPU and under any load, and
the time is reported and fails nothing ([exact
counts](how-checks-decide.md#exact-counts)). Check timing on machines you
control.

## Failing CI on anything but a pass

An inconclusive row, a proposed row and a stale section fail nothing. To
fail the run on anything but a pass, add `--strict`; under dune, add it to
the rule's `run` action. On a runner whose key has no section yet, every row
is proposed, and the run exits 1:

```
$ THUMPER_MACHINE=ci-arm dune exec bench/bench_digest.exe -- --strict
thumper: waiting for the measurement lock (another run is measuring) ...
thumper: the measurement lock changed owner; waiting on the new holder ...
thumper: digest — no baseline for machine ci-arm (Apple M1 Max)

  proposed  207.98 ns  ±7.3%  4 w  md5/string-64
  proposed    6.82 ns  ±1.7%  0 w  fib/10
  proposed   11.29 ns  ±0.7%  0 w  fib/20

  accept:  mv bench/digest.thumper.corrected bench/digest.thumper
  warning: load 18.7 on 10 cores; prefer a quiet host before accepting
$ echo $?
1
```

Use `--strict` on a runner that runs nothing else. On a shared host, a
loaded moment turns the timing rows inconclusive and fails the job.

## Checking on a loaded host

On a loaded host, every timing row reads `inconclusive: environment`, and
exact counts are still judged ([the report](report.md#the-header)). To wait
for a quiet host before measuring, add `--wait-quiet SECS`. When the host is
still loaded after `SECS` seconds, `check` warns and measures anyway:

```
$ dune exec bench/bench_digest.exe -- --wait-quiet 30
thumper: waiting up to 30s for a quiet host (load 18.7 on 10 cores)
thumper: warning: host still loaded after 30s; measuring anyway
thumper: digest — 3 cases vs bench/digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 18.4 on 10 cores; timing verdicts degraded

  inconclusive  204.11 ns  ±0.9%  4 w  md5/string-64
      environment  +0.1% [-1.3, +1.6]; equivalent (alloc exact)
  inconclusive    6.80 ns  ±0.6%  0 w  fib/10
      environment  +0.1% [-0.8, +1.1]; equivalent (alloc exact)
  inconclusive   11.25 ns  ±1.0%  0 w  fib/20
      environment  -2.2% [-4.7, -0.3]; equivalent (alloc exact)

  3 cases: 0 passed, 3 inconclusive.
```

`bless` refuses a host still loaded after the wait. With `--force`, it
records its rows anyway, and the section's `# forced:` line records the load
([sections](baseline-format.md#sections)).

## Measuring in a container

Inside a container the load average is the host's, and the container's own
CPU limit does not show in it. A starved container can read quiet. On such a
runner, schedule the job alone on its host and add `--strict`, in place of
`--wait-quiet`.

## Reading the verdict from a script

The exit code is `0` for a passing check, `1` for a failing one and `2` for
a run that stopped (`run` in [`lib/thumper.mli`](../../lib/thumper.mli)).
`--json PATH` writes the verdict as a [JSON document](json.md).

GitHub sets `GITHUB_ACTIONS` in every job. The report then ends with one
`::error::` line for each metric that fails its case, which GitHub shows as
an annotation ([GitHub annotations](report.md#github-annotations)):

```
$ GITHUB_ACTIONS=true dune build @bench
thumper: digest — 3 cases vs digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 17.4 on 10 cores; timing verdicts degraded

  inconclusive  202.59 ns  ±1.1%  4 w  md5/string-64
      environment  -0.3% [-2.0, +1.3]; equivalent (alloc exact)
  inconclusive   11.58 ns  ±0.3%  0 w  fib/10
      environment  +70.4% [+69.0, +71.7]; equivalent (alloc exact)
  inconclusive   20.51 ns  ±0.3%  0 w  fib/20
      environment  +78.9% [+74.4, +81.6]; equivalent (alloc exact)

  3 cases: 0 passed, 3 inconclusive.
```

## Running two benchmarks at once

Two runs of one user never measure at once. Each holds the measurement lock
while it measures, and another run waits for it, up to 600 s per holder,
with a notice on stderr:

```
$ dune exec bench/bench_digest.exe
thumper: waiting for the measurement lock (another run is measuring) ...
thumper: digest — 3 cases vs bench/digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 17.4 on 10 cores; timing verdicts degraded

  inconclusive  206.22 ns   ±1.1%  4 w  md5/string-64
      environment  +1.0% [-0.8, +2.7]; equivalent (alloc exact)
  inconclusive    6.83 ns   ±1.0%  0 w  fib/10
      environment  +1.0% [+0.1, +2.7]; equivalent (alloc exact)
  inconclusive   11.40 ns  ±13.7%  0 w  fib/20
      environment  +0.4% [-1.8, +25.0]; equivalent (alloc exact)

  3 cases: 0 passed, 3 inconclusive.
```

The lock is the file `thumper-<euid>.lock` in `THUMPER_LOCK_DIR`, else in
the temporary directory. Thumper creates it with mode `0600`. A file of that
name that another user owns, or whose mode grants others any access, stops
the run with exit 2. Dune's `(locks bench)` orders the benchmark rules of
one workspace, and the measurement lock every run of one user.

## Keeping the baseline elsewhere

To keep the baseline elsewhere than beside the benchmark's source, pass
`--baseline PATH`. Under dune, the default follows dune's environment,
whatever the build directory is called. Run by hand from a build directory
not named `_build`, an executable finds no dune environment and looks for
the default in the working directory. Pass it `--baseline`. The rules are
under Files in [`lib/thumper.mli`](../../lib/thumper.mli).
