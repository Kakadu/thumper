# Programmatic use

A program can measure a suite and check it with thumper's library, without
the command line. This page measures and checks the suite of
`examples/07-programmatic`, and the contracts of the values it names are in
[`lib/thumper.mli`](../../lib/thumper.mli).

## Measuring without a baseline

To get a suite's numbers with no baseline and no verdict, call `measure`. It
measures every case as the command line does, and is the evidence:

`examples/07-programmatic/programmatic.ml`:

```ocaml
let print_evidence () =
  let run = measure ~config:Config.quick suite in
  List.iter
    (fun case ->
      let median =
        match Run.samples run ~case Metric.wall_time with
        | Some s -> Printf.sprintf "%.1f ns" (1e9 *. s.(Array.length s / 2))
        | None -> "-"
      in
      let alloc =
        match Run.exact run ~case Metric.alloc_words with
        | Some w -> Printf.sprintf "%d w" w
        | None -> "-"
      in
      Printf.printf "%s: %s, %s\n" case median alloc)
    (Run.case_ids run)
```

`Run.samples` is a case's per-call samples of a metric, sorted, and
`Run.exact` its exact count per call; each is `None` when the metric's
evidence has the other form. `measure` reads no baseline and samples no
load.

## Checking from a program

To check a suite against a baseline, read the baseline, pass it to
`Check.run`, and act on the verdict:

`examples/07-programmatic/programmatic.ml`:

```ocaml
let check () =
  let v = Check.run ?baseline:(Baseline.read_exn file) "programmatic" suite in
  print_endline (Verdict.to_json v);
  Option.iter (Baseline.write (file ^ ".corrected")) (Verdict.corrected v);
  exit (Verdict.exit_code v)
```

`Check.run` measures the suite, judges it against this machine's section,
and is the verdict. `Verdict.to_json` is the [JSON document](json.md),
`Verdict.corrected` the corrected file when there is one, and
`Verdict.exit_code` the exit code `check` returns for the verdict.

The example prints its evidence, then checks. Its first run finds no
`programmatic.thumper`, so every metric is proposed, and it writes the
corrected file, which `mv` accepts:

```
$ dune exec bench/programmatic.exe
rev: 1400.2 ns, 3000 w
sum: 2888.9 ns, 0 w
{"overall":"pass","machine":"5c1e0a7f3b9d2486","summary":{"wall_time":{"n_improved":0,"n_regressed":0,"n_equivalent":0,"n_inconclusive":2,"geomean_delta":null},"alloc_words":{"n_improved":0,"n_regressed":0,"n_equivalent":0,"n_inconclusive":2,"geomean_delta":null}},"cases":[{"id":"rev","full_name":"rev","overall":"pass","metrics":[{"metric":"wall_time","relation":null,"status":"pass","reason":"missing_baseline","delta":null,"lower_delta":null,"upper_delta":null},{"metric":"alloc_words","relation":null,"status":"pass","reason":"missing_baseline","delta":null,"lower_delta":null,"upper_delta":null}]},{"id":"sum","full_name":"sum","overall":"pass","metrics":[{"metric":"wall_time","relation":null,"status":"pass","reason":"missing_baseline","delta":null,"lower_delta":null,"upper_delta":null},{"metric":"alloc_words","relation":null,"status":"pass","reason":"missing_baseline","delta":null,"lower_delta":null,"upper_delta":null}]}]}
$ mv programmatic.thumper.corrected programmatic.thumper
```

The second run compares both cases with the baseline:

```
$ dune exec bench/programmatic.exe
rev: 1388.0 ns, 3000 w
sum: 3546.8 ns, 0 w
{"overall":"inconclusive","machine":"5c1e0a7f3b9d2486","summary":{"wall_time":{"n_improved":0,"n_regressed":0,"n_equivalent":0,"n_inconclusive":2,"geomean_delta":0.11253177093505529},"alloc_words":{"n_improved":0,"n_regressed":0,"n_equivalent":2,"n_inconclusive":0,"geomean_delta":0}},"cases":[{"id":"rev","full_name":"rev","overall":"inconclusive","metrics":[{"metric":"wall_time","relation":"inconclusive","status":"inconclusive","reason":"environment","confirmed":false,"n":20,"delta":0.0082840018410610308,"lower_delta":-0.0097659712987588371,"upper_delta":0.019792093113173655},{"metric":"alloc_words","relation":"equivalent","status":"pass","reason":null,"exact":true,"delta":0,"lower_delta":null,"upper_delta":null}]},{"id":"sum","full_name":"sum","overall":"inconclusive","metrics":[{"metric":"wall_time","relation":"inconclusive","status":"inconclusive","reason":"environment","confirmed":false,"n":20,"delta":0.22755784985170982,"lower_delta":0.0034913996618063164,"upper_delta":0.78245574521346828},{"metric":"alloc_words","relation":"equivalent","status":"pass","reason":null,"exact":true,"delta":0,"lower_delta":null,"upper_delta":null}]}]}
$ echo $?
0
```

To check part of a suite against a shared baseline, pass `Check.run` that
part. In a current section, its corrected file keeps every row it did not
judge.

## Handling errors

Three kinds of failure reach a program, each in its own form.

- A run that cannot complete raises `Check.Error`.
  ``measure ~filter:(`Id "nope") suite`` raises it, and so do a measurement
  lock that times out, a case that cannot be measured and an invalid suite.
  Uncaught, it prints `Thumper.Check.Error: no case matches the selection`,
  the text of `Check.pp_error`.
- A mistake in the program raises `Invalid_argument`, before anything is
  measured. Each of these raises it:
  - `bench "" f`;
  - `Config.samples 2`;
  - two budgets for one metric in one list;
  - in `Check.run`, a baseline whose header names another suite;
  - in `Check.run`, a `THUMPER_MACHINE` holding a space.
- A baseline file that cannot be used is a `Baseline.error`. `Baseline.read`
  returns it as `Error`, and `Baseline.read_exn`, as in the example, raises
  it as `Baseline.Error`. Uncaught, it prints as
  `Thumper.Baseline.Error: corrupt baseline (line <n>): <reason>`. An absent
  file is no error. `Baseline.read` is then `Ok None`, and `Check.run` with
  no baseline proposes every metric.

Which value raises what is part of each contract in
[`lib/thumper.mli`](../../lib/thumper.mli).

## What the library leaves to the command line

The library has no counterpart for these parts of `Thumper.run`:

- the report, the status line and the notices on stderr;
- `bless`;
- `--wait-quiet`;
- the default baseline path;
- the removal of the rows of cases the suite no longer has;
- the GitHub annotations.

`measure` and `Check.run` print nothing, and a program renders the
verdict itself. `Check.run` samples the load once it holds the
measurement lock, and again before any second trials, and never waits
for a quiet host. A program names its baseline, and a relative name
resolves in its working directory.
