# Getting started

We write a benchmark, record its baseline, and watch the check fail when a
case gets slower. At the end, `dune build @bench` measures the suite and
fails the build on a confirmed regression.

## Installing thumper

```
opam install thumper
```

## A first benchmark

A benchmark is an executable that ends in `Thumper.run`. We keep ours in
our project's `bench/` directory, as `bench/bench_digest.ml` and, in the
next section, `bench/dune`. It measures an MD5 digest of a 64-byte string
and an iterative Fibonacci at two sizes.

`examples/02-getting-started/bench_digest.ml`:

```ocaml
let input64 = String.make 64 '\xa5'

let fib n =
  let rec go a b = function 0 -> a | n -> go b (a + b) (n - 1) in
  go 0 1 n

let () =
  exit
    (Thumper.run "digest"
       ~budgets:
         [
           Thumper.Budget.no_slower_than 0.05;
           Thumper.Budget.no_more_alloc_than 0.0;
         ]
       [
         Thumper.group "md5"
           [ Thumper.bench "string-64" (fun () -> Digest.string input64) ];
         Thumper.group "fib"
           (List.map
              (fun n ->
                Thumper.bench (Int.to_string n) (fun () ->
                    fib (Thumper.black_box n)))
              [ 10; 20 ]);
       ])
```

`bench` declares a case and `group` names a list of them, so the suite's
case ids are `md5/string-64`, `fib/10` and `fib/20`. `black_box n` is `n`,
hidden from the compiler. `no_slower_than 0.05` lets a case's time grow by
at most 5%, and `no_more_alloc_than 0.0` allows its allocation no
growth. `run` measures the suite, prints the report and returns the exit
code.

## Running it from dune

We attach the executable to its own alias, `bench`, next to its stanza
([why `@bench`](how-checks-decide.md#why-benchmarks-run-on-bench)).

`examples/02-getting-started/dune`:

```dune
(executable
 (name bench_digest)
 (libraries thumper))

(rule
 (alias bench)
 (locks bench)
 (action
  (progn
   (run %{exe:bench_digest.exe})
   (diff? digest.thumper digest.thumper.corrected))))
```

`(locks bench)` keeps two benchmark rules from measuring at once, and
`diff?` shows the corrected file a run writes as a diff to accept.

## The first run

The transcripts below run the example in that `bench/` directory, their
numbers are one run's, and [the report](report.md) explains their columns
and words, such as `±`, `w` and `inconclusive`. With no baseline yet,
every row reads `proposed`, and dune shows the corrected file as a diff
and fails the build:

```
$ dune build @bench
thumper: digest — no baseline for machine 5c1e0a7f3b9d2486 (Apple M1 Max)

  proposed  343.96 ns  ±386.2%  4 w  md5/string-64
  proposed   25.01 ns   ±76.2%  0 w  fib/10
  proposed   11.42 ns  ±222.3%  0 w  fib/20

  accept:  dune promote
  warning: load 96.0 on 10 cores; prefer a quiet host before accepting
File "bench/digest.thumper", line 1, characters 0-0:
diff --git a/_build/default/bench/digest.thumper.corrected b/_build/default/bench/digest.thumper.corrected
new file mode 100644
index 0000000..88f581b
--- /dev/null
+++ b/_build/default/bench/digest.thumper.corrected
@@ -0,0 +1,13 @@
+# thumper baseline v1
+# suite: digest
+
+# machine: 5c1e0a7f3b9d2486
+# host: laptop · Apple M1 Max · arm64 · macos
+# ocaml: 5.5.1 · 64-bit · release
+
+fib/10	alloc_words	exact	0
+fib/10	wall_time	batch=1048576	n=20	2.501e-08	6.767e-09 6.771e-09 6.789e-09 6.793e-09 6.845e-09 6.861e-09 6.930e-09 1.552e-08 2.076e-08 2.219e-08 2.783e-08 3.107e-08 3.940e-08 4.417e-08 4.499e-08 6.509e-08 1.032e-07 1.206e-07 1.325e-07 2.282e-07
+fib/20	alloc_words	exact	0
+fib/20	wall_time	batch=524288	n=20	1.143e-08	1.132e-08 1.133e-08 1.135e-08 1.137e-08 1.138e-08 1.139e-08 1.140e-08 1.140e-08 1.141e-08 1.142e-08 1.143e-08 1.525e-08 2.027e-08 3.302e-08 6.216e-08 1.364e-07 1.423e-07 1.560e-07 1.997e-07 2.481e-07
+md5/string-64	alloc_words	exact	4
+md5/string-64	wall_time	batch=16384	n=20	3.440e-07	2.016e-07 2.043e-07 2.056e-07 2.057e-07 2.063e-07 2.063e-07 2.064e-07 2.070e-07 2.080e-07 3.434e-07 3.445e-07 5.689e-07 5.952e-07 2.831e-06 2.863e-06 3.026e-06 3.533e-06 3.845e-06 4.404e-06 5.565e-06
```

## Accepting the baseline

`dune promote` accepts the corrected file as `bench/digest.thumper`, the
baseline we commit:

```
$ dune promote
Promoting _build/default/bench/digest.thumper.corrected to
  bench/digest.thumper.
```

The next run compares every case with the baseline, and all three pass:

```
$ dune build @bench
thumper: digest — 3 cases vs digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 97.4 on 10 cores; timing verdicts degraded

  inconclusive  201.26 ns    ±0.3%  4 w  md5/string-64
      environment  -3.3% [-71.7, -1.7]; equivalent (alloc exact)
  inconclusive    6.83 ns  ±169.8%  0 w  fib/10
      environment  -32.8% [-82.7, +0.8]; equivalent (alloc exact)
  inconclusive   11.34 ns    ±0.3%  0 w  fib/20
      environment  -0.8% [-81.6, -0.1]; equivalent (alloc exact)

  3 cases: 0 passed, 3 inconclusive.
```

## A regression

We make each `fib` case do twice the work. In
`examples/02-getting-started/bench_digest.ml`, the call
`fib (Thumper.black_box n)` becomes:

```ocaml
fib (2 * Thumper.black_box n)
```

The two `fib` rows now read `REGRESSED`, beside the change and its budget,
and the build fails:

```
$ dune build @bench
thumper: digest — 3 cases vs digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 97.6 on 10 cores; timing verdicts degraded

  inconclusive  202.29 ns   ±1.6%  4 w  md5/string-64
      environment  -40.8% [-92.9, -1.7]; equivalent (alloc exact)
  inconclusive   11.62 ns  ±12.9%  0 w  fib/10
      environment  -44.2% [-73.8, +70.1]; equivalent (alloc exact)
  inconclusive   21.46 ns  ±10.4%  0 w  fib/20
      environment  +80.2% [-62.7, +103.1]; equivalent (alloc exact)

  3 cases: 0 passed, 3 inconclusive.
```

## The fix

We undo the edit, and the next run passes again:

```
$ dune build @bench
thumper: digest — 3 cases vs digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 97.6 on 10 cores; timing verdicts degraded

  inconclusive  208.12 ns  ±5.2%  4 w  md5/string-64
      environment  -39.5% [-92.7, +0.5]; equivalent (alloc exact)
  inconclusive    7.00 ns  ±7.6%  0 w  fib/10
      environment  -68.7% [-84.7, +0.8]; equivalent (alloc exact)
  inconclusive   11.48 ns  ±8.2%  0 w  fib/20
      environment  -0.4% [-81.6, +2.0]; equivalent (alloc exact)

  3 cases: 0 passed, 3 inconclusive.
```

## Where to go next

- [Writing benchmarks](writing-benchmarks.md) budgets groups and cases,
  keeps fixtures out of the timed region, and tags cases.
- [Running checks](running-checks.md) measures one case while iterating,
  accepts an intended slowdown, and checks on CI runners and loaded hosts.
- [Programmatic use](programmatic.md) measures and checks from an OCaml
  program.

Every page of the manual is listed in the
[README](../../README.md#documentation), and the API is
[`lib/thumper.mli`](../../lib/thumper.mli).
