# Changes

## v0.1.0 YYYY-MM-DD

First release.

Thumper benchmarks OCaml code and checks it against a committed baseline.
A benchmark is an executable; a dune rule runs it, and a regression beyond
a case's budget fails the build. Thumper depends on the `unix` library
alone and is distributed under the ISC license.

- Benchmarks declared with `bench`, `bench_with_setup` and `group`, and a
  command line from `Thumper.run` with the subcommands `check` (the
  default), `bless` and `list`.
- A baseline file per suite, committed with the code, that stores what was
  measured (sorted samples and exact counts) in one section per machine.
- A default baseline path beside the benchmark's source, which a dune rule
  and `dune exec` resolve to the same file through dune's environment,
  whatever the build directory is called.
- A corrected file, `<baseline>.corrected`, that adds the run's proposed
  rows, advances its improved ones and, after a `check` of every case,
  drops the rows of cases the suite no longer has; a run never writes the
  baseline itself.
- An `accept:` line in the report that names the command accepting the
  corrected file: `dune promote` in a dune rule action, `mv` otherwise.
- Budgets per metric, bounding the change from the baseline
  (`no_slower_than`, `no_more_alloc_than`, `relative`) or the measured
  value (`at_most`).
- Sampled evidence compared by rank statistics, where a regression or
  improvement counts only when a second trial of the case reproduces it.
- A sampled comparison that passes as `within budget` when its interval
  ends within the budget; `inconclusive: wide interval` means the noise
  exceeds the budget.
- Exact allocation counts, compared as integers when a probe proves that a
  case allocates the same number of words on every call; the probe runs at
  the baseline's batch size.
- Exact comparisons that ignore the host's load, so an allocation budget
  can fail the build on a hosted CI runner.
- Each case measured in its own forked process, within a deadline, at the
  batch size its baseline recorded unless the case's speed has changed
  enough to recalibrate.
- Sampled comparisons on a loaded host reported as `inconclusive:
  environment` with the change this run measured, and `--wait-quiet` to
  wait for a quiet host.
- A per-user measurement lock that keeps two measurements on one host from
  overlapping.
- `--json` for a JSON document of the verdict, `--strict` to fail on
  inconclusive and proposed rows, and GitHub annotations under
  `GITHUB_ACTIONS`.
- `measure`, which collects measurements without files, and `Check.run`,
  `Verdict.corrected` and `Verdict.to_json`, which build a check in OCaml.
