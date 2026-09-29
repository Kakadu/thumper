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
 (locks %{project_root}/bench)
 (deps
  (glob_files *.thumper))
 (action
  (run %{exe:bench_digest.exe})))
```

`(locks %{project_root}/bench)` keeps two benchmark rules from measuring
at once. A lock's name is a path, so every suite of the project names
the same lock. `(deps (glob_files *.thumper))` makes the baseline visible
to the run once it exists, and dune reruns the rule when it changes.

## The first run

The transcripts below run the example in that `bench/` directory, their
numbers are one run's, and [the report](report.md) explains their columns
and words, such as `±`, `w` and `proposed`. With no baseline yet, every
row reads `proposed`, the build passes, and the `accept:` line names the
command that records the baseline:

<!-- placeholder: Q1 regenerates this transcript -->
```
$ dune build @bench
digest: no baseline for machine 5c1e0a7f3b9d2486 (Apple M1 Max)

  proposed  199.01 ns  ±0.9%  4 w  md5/string-64
  proposed    6.54 ns  ±0.5%  0 w  fib/10
  proposed   10.82 ns  ±0.2%  0 w  fib/20

accept: ./_build/default/bench/bench_digest.exe bless
3 proposed in 0.9s.
```

## Recording the baseline

We paste the `accept:` line. `bless` measures the cases again and records
them in `bench/digest.thumper`, the baseline we commit:

<!-- placeholder: Q1 regenerates this transcript -->
```
$ ./_build/default/bench/bench_digest.exe bless
digest: 3 cases for machine 5c1e0a7f3b9d2486

  blessed  199.40 ns  ±0.6%  4 w  md5/string-64
  blessed    6.55 ns  ±0.3%  0 w  fib/10
  blessed   10.83 ns  ±0.2%  0 w  fib/20

3 blessed into bench/digest.thumper in 0.9s.
```

The next run compares every case with the baseline, and all three pass:

<!-- placeholder: Q1 regenerates this transcript -->
```
$ dune build @bench
digest: 3 cases vs digest.thumper for machine 5c1e0a7f3b9d2486

  passed  199.12 ns  ±0.7%  4 w  md5/string-64
  passed    6.56 ns  ±0.4%  0 w  fib/10
  passed   10.84 ns  ±0.3%  0 w  fib/20

3 passed in 0.9s.
```

## A regression

We make each `fib` case do twice the work. In `bench/bench_digest.ml`,
the call
`fib (Thumper.black_box n)` becomes:

```ocaml
fib (2 * Thumper.black_box n)
```

The two `fib` rows now read `REGRESSED`, beside the change and its budget,
and the build fails:

<!-- placeholder: Q1 regenerates this transcript -->
```
$ dune build @bench
File "bench/dune", lines 5-11, characters 0-127:
 5 | (rule
 6 |  (alias bench)
 7 |  (locks %{project_root}/bench)
 8 |  (deps
 9 |   (glob_files *.thumper))
10 |  (action
11 |   (run %{exe:bench_digest.exe})))
digest: 3 cases vs digest.thumper for machine 5c1e0a7f3b9d2486

  passed     199.31 ns  ±0.5%  4 w  md5/string-64
  REGRESSED   13.07 ns  ±0.3%  0 w  fib/10
      +99.5% [+99.1, +99.9]  budget +5%
  REGRESSED   21.63 ns  ±0.2%  0 w  fib/20
      +99.7% [+99.5, +99.9]  budget +5%

rerun: ./_build/default/bench/bench_digest.exe -f fib/10 -f fib/20
1 passed, 2 regressed in 1.6s.
```

## The fix

We undo the edit, and the next run passes again:

<!-- placeholder: Q1 regenerates this transcript -->
```
$ dune build @bench
digest: 3 cases vs digest.thumper for machine 5c1e0a7f3b9d2486

  passed  199.25 ns  ±0.6%  4 w  md5/string-64
  passed    6.55 ns  ±0.4%  0 w  fib/10
  passed   10.83 ns  ±0.2%  0 w  fib/20

3 passed in 0.9s.
```

## Where to go next

- [Writing benchmarks](writing-benchmarks.md) budgets groups and cases,
  keeps fixtures out of the timed region, and tags cases.
- [Running checks](running-checks.md) measures one case while iterating,
  records an intended slowdown, and checks on CI runners and loaded hosts.
- [Programmatic use](programmatic.md) measures and checks from an OCaml
  program.

Every page of the manual is listed in the
[README](../../README.md#documentation), and the API is
[`lib/thumper.mli`](../../lib/thumper.mli).
