# Writing benchmarks

These recipes cover the code of a suite: budgets, fixtures, families of
cases, tags, metrics and the measurement protocol. Each one shows an
example from `examples/`, run as a project's `bench/` directory, and the
numbers in its transcripts are one run's. The contracts of every value
named here are in [`lib/thumper.mli`](../../lib/thumper.mli).

## Budgeting a group or a case

To bound a metric for the whole suite, pass a budget to `run`. To bound
it for a group or a single case, pass it to `group` or `bench`.

`examples/03-budgets/bench_budgets.ml`:

```ocaml
let () =
  exit
    (Thumper.run "budgets"
       ~budgets:[ Thumper.Budget.no_slower_than 0.05 ]
       [
         Thumper.group "codec"
           ~budgets:[ Thumper.Budget.no_more_alloc_than 0.0 ]
           [
             Thumper.bench "hex-encode" (fun () -> hex_encode raw);
             Thumper.bench "hex-decode"
               ~budgets:[ Thumper.Budget.no_slower_than 0.10 ]
               (fun () -> hex_decode hex);
           ];
         Thumper.bench "scratch-table"
           ~budgets:
             [ Thumper.Budget.at_most ~metric:Thumper.Metric.alloc_words 256. ]
           (fun () -> Array.make 63 0);
       ])
```

Every case here may be 5% slower than its baseline, except
`hex-decode`, which may be 10% slower. The two `codec` cases may not
allocate one word more. The rules for which budget reaches a case,
including a budget on an uncollected metric and the default, are under
Inheritance in the Defining benchmarks section of
[`lib/thumper.mli`](../../lib/thumper.mli).

A time row whose interval lies within the equivalence band reads
`equivalent`. A time row whose interval shows a slowdown that the budget
allows reads `within budget`, with the estimate and the interval. Both
pass. Under `no_more_alloc_than 0.`, one word more fails the case.

The first run of the example writes a corrected file, `mv` accepts it,
and the second run judges every row against it:

```
$ dune exec bench/bench_budgets.exe
thumper: waiting for the measurement lock (another run is measuring) ...
thumper: budgets — no baseline for machine 5c1e0a7f3b9d2486 (Apple M1 Max)

  proposed  160.91 ns  ±0.5%  18 w  codec/hex-encode
  proposed  327.83 ns  ±0.2%  10 w  codec/hex-decode
  proposed   30.43 ns  ±0.6%  64 w  scratch-table

  accept:  mv bench/budgets.thumper.corrected bench/budgets.thumper
  warning: load 39.7 on 10 cores; prefer a quiet host before accepting
$ mv bench/budgets.thumper.corrected bench/budgets.thumper
$ dune exec bench/bench_budgets.exe
thumper: budgets — 3 cases vs bench/budgets.thumper for machine 5c1e0a7f3b9d2486
warning: load 39.7 on 10 cores; timing verdicts degraded

  inconclusive  160.53 ns  ±0.8%  18 w  codec/hex-encode
      environment; equivalent (alloc exact)
  inconclusive  329.61 ns  ±1.1%  10 w  codec/hex-decode
      environment; equivalent (alloc exact)
  inconclusive   30.38 ns  ±5.1%  64 w  scratch-table
      environment; equivalent (alloc exact)

  3 cases: 0 passed, 3 inconclusive.
```

## Capping allocation

To bound a count whatever the baseline holds, give the case an `at_most`
budget, in the metric's unit.

`examples/03-budgets/bench_budgets.ml`:

```ocaml
Thumper.bench "scratch-table"
  ~budgets:
    [ Thumper.Budget.at_most ~metric:Thumper.Metric.alloc_words 256. ]
  (fun () -> Array.make 63 0);
```

The cap is judged on this run's exact count, so a count over it fails
the case on the first run too. A sampled count never fails the case.
Growth at or under the cap from a baseline row of `0` prints `+inf%`.
The other outcomes are `Budget.at_most`'s contract in
[`lib/thumper.mli`](../../lib/thumper.mli).

To see the cap fail, the example's array grows to 300 elements:

```ocaml
(fun () -> Array.make 300 0);
```

The case's row reads `REGRESSED` and the run exits 1:

```
$ dune exec bench/bench_budgets.exe
thumper: budgets — 3 cases vs bench/budgets.thumper for machine 5c1e0a7f3b9d2486
warning: load 39.7 on 10 cores; timing verdicts degraded

  inconclusive  161.22 ns  ±0.5%   18 w  codec/hex-encode
      environment; equivalent (alloc exact)
  inconclusive  328.32 ns  ±0.4%   10 w  codec/hex-decode
      environment; equivalent (alloc exact)
  REGRESSED     250.78 ns  ±0.8%  301 w  scratch-table
      alloc 64 w → 301 w (exact); inconclusive: environment

  rerun:   /private/var/folders/5p/vkxwhs6s5155xdsrlv6jg8mh0000gn/T/t5gen-w1a/writing-benchmarks/_build/default/bench/bench_budgets.exe \
           -f scratch-table

  3 cases: 0 passed, 1 regressed, 2 inconclusive.
$ echo $?
1
```

## Keeping a fixture out of the timed region

To build a case's input once per trial, outside the samples, declare the
case with `bench_with_setup`.

`examples/04-fixtures/bench_fixtures.ml`:

```ocaml
Thumper.bench_with_setup "read-4KiB"
  ~setup:(fun () ->
    let path = Filename.temp_file "thumper_fixtures" ".dat" in
    Out_channel.with_open_bin path (fun oc ->
        Out_channel.output_string oc (make_corpus 4096));
    path)
  ~teardown:Sys.remove
  (fun path -> In_channel.with_open_bin path In_channel.input_all);
```

`setup` writes a file and returns its path, each call reads the file, and
`teardown` removes it after the trial's last batch. When `teardown` runs
and when it does not is part of `bench_with_setup`'s contract in
[`lib/thumper.mli`](../../lib/thumper.mli).

## Measuring a family of sizes

To measure one function at several sizes, map a function that makes a
case over the sizes, inside a group.

`examples/04-fixtures/bench_fixtures.ml`:

```ocaml
let scan_case kib =
  Thumper.bench_with_setup
    (Int.to_string kib ^ " KiB")
    ~setup:(fun () -> make_corpus (kib * 1024))
    (fun corpus -> count_byte '\x2a' corpus)
```

```ocaml
Thumper.group "scan" (List.map scan_case [ 4; 64; 256 ]);
```

`list` prints the case ids, whose rules are under Ids in the Defining
benchmarks section of [`lib/thumper.mli`](../../lib/thumper.mli):

```
$ dune exec bench/bench_fixtures.exe -- list
scan/4-KiB
scan/64-KiB
scan/256-KiB
io/read-4KiB
```

To keep the compiler from folding a computation over an input it can
see, such as a constant the closure captures, wrap the input in
`Thumper.black_box`, as the next example does. What `bench` already
hides from the compiler is in its contract in
[`lib/thumper.mli`](../../lib/thumper.mli).

## Tagging cases

To run a subset of a suite by label, tag its cases or groups and select
them with `--tag`.

`examples/05-tags/bench_tags.ml`:

```ocaml
let size_tags kib = if kib >= 256 then [ "large" ] else []

let () =
  exit
    (Thumper.run "tags"
       [
         Thumper.group "scan"
           (List.map
              (fun kib ->
                Thumper.bench
                  (Int.to_string kib ^ " KiB")
                  ~tags:(size_tags kib)
                  (fun () -> count_byte '\x2a' (Thumper.black_box (kib * 1024))))
              [ 4; 256 ]);
         Thumper.group "md5" ~tags:[ "digest" ]
           (List.map
              (fun kib ->
                Thumper.bench
                  (Int.to_string kib ^ " KiB")
                  ~tags:(size_tags kib)
                  (fun () ->
                    Digest.substring corpus 0 (Thumper.black_box (kib * 1024))))
              [ 4; 256 ]);
       ])
```

A group's tags reach its cases, so both `md5` cases carry `digest`, and
`size_tags` tags the largest size of each group `large`:

```
$ dune exec bench/bench_tags.exe -- list --tag large
scan/256-KiB
md5/256-KiB
```

How `-f` and `--tag` combine is in
[Selecting cases](command-line.md#selecting-cases).

## Collecting other metrics

To collect another metric for the whole suite, pass `Config.metrics` a
list that names it together with the defaults the suite keeps,
`wall_time` and `alloc_words`. For a group or a case, pass the list as
its `?metrics`.

`examples/06-protocol/bench_protocol.ml`:

```ocaml
let () =
  exit
    (Thumper.run "protocol"
       ~config:
         Thumper.Config.(
           default |> samples 30 |> deadline 30.
           |> metrics
                Thumper.Metric.[ wall_time; alloc_words; minor_collections ])
       [
         Thumper.bench "sort-100k" (fun () ->
             Array.sort compare (Array.copy data));
         Thumper.bench "sum-100k" ~metrics:[ Thumper.Metric.wall_time ]
           (fun () -> Array.fold_left ( + ) 0 data);
       ])
```

`sort-100k` collects three metrics and `sum-100k` collects `wall_time`
alone:

```
$ dune exec bench/bench_protocol.exe
thumper: protocol — no baseline for machine 5c1e0a7f3b9d2486 (Apple M1 Max)

  proposed  18715.27 us  ±0.5%  475.4 kw  sort-100k
  proposed    227.71 us  ±4.3%            sum-100k
  warning: sort-100k: minor_collections: exactness probe failed: batch deltas 1 (k=1) and 4 (2k=2) give per-call 3 words with harness h -2 vs -2; treating as sampled

  accept:  mv bench/protocol.thumper.corrected bench/protocol.thumper
  warning: load 39.5 on 10 cores; prefer a quiet host before accepting
```

The built-in metrics, and how a scope's `?metrics` reaches its cases,
are under Metrics and Inheritance in [`lib/thumper.mli`](../../lib/thumper.mli).

## Changing the protocol

To change how every case is measured, pass `run` a `~config` built from
`Config.default` with its setters, as the example above does. It takes
30 samples per trial and lets a trial run 30 s before it is killed. Pick
the setter by the problem:
- A row reads `inconclusive: wide interval`: take more samples with
  `Config.samples`, or `--precise` for one run, or loosen the budget.
  With `Config.samples` below 10, no trial is found drifted.
- A row reads `inconclusive: non-positive sample`: a sample was zero or
  negative, as a `cpu_time` sample is when a batch takes less than one
  tick of the CPU clock. Raise the batch floor with `Config.batch_floor`, or
  budget `wall_time` in its place; more samples do not help.
- A case is killed at its deadline, 10 s by default: raise it with
  `Config.deadline`.
- To collect another metric, use `Config.metrics`, as above.

The other setters and their ranges are under Configuration in
[`lib/thumper.mli`](../../lib/thumper.mli).
