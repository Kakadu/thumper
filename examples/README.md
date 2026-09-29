# Examples

Each numbered directory is one benchmark executable, whose files and
output the manual shows.

- `01-first-benchmark`: a suite of one case that ends in `Thumper.run`,
  for the [README](../README.md)'s quick start.
- `02-getting-started`: a suite with budgets and the `@bench` rule that
  runs it with its baseline as a dependency, for
  [Getting started](../doc/manual/getting-started.md) and
  [Running checks](../doc/manual/running-checks.md).
- `03-budgets`: budgets on the suite, a group and a case, and an absolute
  allocation cap, for
  [Writing benchmarks](../doc/manual/writing-benchmarks.md).
- `04-fixtures`: fixtures outside the timed region with
  `bench_with_setup` and a teardown, and a family of sizes, for
  [Writing benchmarks](../doc/manual/writing-benchmarks.md).
- `05-tags`: tags on groups and cases, which `--tag` selects, for
  [Writing benchmarks](../doc/manual/writing-benchmarks.md).
- `06-protocol`: the protocol as a value, with a preset refined by
  setters and the metrics a suite and a case collect, for
  [Writing benchmarks](../doc/manual/writing-benchmarks.md).
- `07-programmatic`: `measure`, `Check.run` and `Baseline.record`
  without the command line, for
  [Programmatic use](../doc/manual/programmatic.md).

`dune build` compiles every example, and none measures under
`dune runtest`. To run one, pass its executable to `dune exec`, as in
`dune exec examples/01-first-benchmark/bench_hello.exe`, with its flags
after `--` ([Command line](../doc/manual/command-line.md)).
