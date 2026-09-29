# The report

`check` and `bless` print a report on stdout, and the program's notices go
to stderr. This page shows every line of both, and what to do about an
inconclusive row. When each block prints, what `REGRESSED` means and how
the summary counts are the report's contract, under The report in
[`lib/thumper.mli`](../../lib/thumper.mli).

The transcripts run `examples/02-getting-started` as a project's `bench/`
directory, after its baseline is accepted, and their numbers are one run's.

## The blocks

A report is a header, a table, the actions and a summary, separated by
blank lines; a block with nothing to print is left out, and the
[annotations](#github-annotations) close it on GitHub. After an edit that
makes `fib/20` slower and `fib/10` faster, `check` prints all four:

```
$ dune exec bench/bench_digest.exe
thumper: digest — 3 cases vs bench/digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 83.1 on 10 cores; timing verdicts degraded

  inconclusive  206.93 ns    ±1.3%  4 w  md5/string-64
      environment  +2.6% [+0.5, +7.5]; equivalent (alloc exact)
  inconclusive    3.05 ns  ±497.3%  0 w  fib/10
      environment  -55.5% [-56.2, +313.7]; equivalent (alloc exact)
  inconclusive   20.62 ns    ±3.4%  0 w  fib/20
      environment  +79.4% [+78.5, +90.3]; equivalent (alloc exact)

  3 cases: 0 passed, 3 inconclusive.
```

## The header

The header names the suite and the machine key, then the state of this
machine's section:

| header | when |
| --- | --- |
| `thumper: <suite> — <n> cases vs <baseline> for machine <key>` | `check` compared the cases with a current section |
| `thumper: <suite> — no baseline for machine <key> (<cpu>)` | `check` found no baseline file, or no section for this machine |
| `thumper: <suite> — stale baseline for machine <key> (ocaml <recorded> → <current>)` | `check` found a section recorded under another compiler |
| `thumper: <suite> — blessed <n> cases for machine <key>` | `bless` re-recorded the cases |

`<baseline>` is printed as the Files subsection of
[`lib/thumper.mli`](../../lib/thumper.mli) states, and `1 case` takes no
plural. The first run of the [tutorial](getting-started.md#the-first-run)
shows the `no baseline` header. A stale section prints every row
`proposed`:

```
$ dune exec bench/bench_digest.exe
thumper: digest — stale baseline for machine 5c1e0a7f3b9d2486 (ocaml 5.2.0 · 64-bit · release → 5.5.1 · 64-bit · release)

  proposed  205.78 ns  ±0.7%  4 w  md5/string-64
  proposed    6.81 ns  ±0.9%  0 w  fib/10
  proposed   11.41 ns  ±3.1%  0 w  fib/20

  accept:  mv bench/digest.thumper.corrected bench/digest.thumper
  warning: load 83.1 on 10 cores; prefer a quiet host before accepting
```

`bless` records its cases in the corrected file, and the baseline takes
them only when that file is accepted, so the rows under a `blessed` header
read `proposed`. `bless -f fib/20` re-records one case:

```
$ dune exec bench/bench_digest.exe -- bless -f fib/20
thumper: bless refused: load 83.1 on 10 cores; rerun with --wait-quiet SECS, or with --force to record it anyway
```

When `check` compared the cases on a loaded host, the line under the header
is `warning: load <load> on <n> cores; timing verdicts degraded`. Each
timing row then reads `inconclusive: environment`, followed by the change
the run measured, when it measured one; a row with a zero or negative
sample reads `inconclusive: non-positive sample` instead, and exact counts
are still judged:

```
$ dune exec bench/bench_digest.exe
thumper: digest — 3 cases vs bench/digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 83.1 on 10 cores; timing verdicts degraded

  inconclusive  205.63 ns  ±0.5%  4 w  md5/string-64
      environment  -0.4% [-2.6, +1.1]; equivalent (alloc exact)
  inconclusive    6.78 ns  ±0.5%  0 w  fib/10
      environment  -0.5% [-1.7, +0.8]; equivalent (alloc exact)
  inconclusive   11.34 ns  ±0.4%  0 w  fib/20
      environment  -0.5% [-4.9, +1.6]; equivalent (alloc exact)

  3 cases: 0 passed, 3 inconclusive.
```

## The table

A row is its status word, the time, the `±` interval, the allocation and
the case id, two spaces apart, in suite order. The status word is padded
to the widest in the table and the three value columns are right-aligned.

- **Time.** The time that The report in
  [`lib/thumper.mli`](../../lib/thumper.mli) defines, with two decimals in
  the column's unit: `ns`, `us`, `ms` or `s`, whichever fits the smallest
  time in the column.
- **`±`.** The interval that The report defines, with one decimal and a
  `%`. The interval's ends are two of the trial's samples and need not sit
  evenly around the median. A `±` past 100% puts its upper end above twice
  the median, as on a loaded host.
- **Allocation.** The case's first metric that counts words (`alloc_words`
  by default; `minor_alloc_words`, `major_alloc_words` or
  `promoted_words` when it collects one of those instead). An exact count
  prints in whole words, grouped by thousands, as `12,346 w`. A sampled
  count prints after `~`, in `w`, `kw` or `Mw` by the smallest sampled
  count in the column, with three significant digits and grouped from a
  thousand up, never in exponent notation.

A column that no case fills is left out. The cells are rounded for
display, and the check judges the unrounded values.

A case's verdict is a list of fragments, one per notable relation, most
severe first: `REGRESSED`, `regressed`, `inconclusive`, `improved`,
`within budget`, `proposed`, `equivalent`. The row opens on the first
fragment's word. When there is more, a detail line follows, indented six
spaces: the rest of the first fragment, then every other fragment whole,
joined by `; `. A row with nothing notable reads `equivalent` and has no
detail line. The fragments are:

| fragment | meaning |
| --- | --- |
| `REGRESSED <change> [<lower>, <upper>]  budget +<r>%` | a confirmed sampled regression that fails the case: the first trial's estimate and interval, and its relative budget |
| `regressed <change> [<lower>, <upper>]` | a confirmed sampled regression that fails nothing |
| `improved <change> [<lower>, <upper>]` | a confirmed sampled improvement |
| `within budget <change> [<lower>, <upper>]` | an interval that ends within the budget |
| `within budget <change>` | a slowdown the run demonstrated and the budget allows, or an exact growth the budget allows |
| `REGRESSED alloc <baseline> w → <count> w (exact)` | an exact count that grew past its budget; `regressed` and `improved` take the same form |
| `REGRESSED alloc <count> w, over its <cap> w cap (exact)` | an exact count over its `at_most` cap, with no row to compare or against a sampled row |
| `inconclusive: <reason>` | a time comparison that was not judged ([reasons](#inconclusive-reasons)) |
| `inconclusive: environment  <change> [<lower>, <upper>]` | a time comparison on a loaded host, and the change it measured |
| `inconclusive alloc: <reason>` | an allocation comparison that was not judged |
| `equivalent (alloc exact)` | an exact count equal to its row, shown when the row also holds a `REGRESSED`, `regressed` or `inconclusive` fragment |
| `proposed alloc` | an allocation with no row to compare, after a time that compared |
| `proposed` | a case with no row to compare |

A fragment of a metric other than time names the metric after its word:
`alloc` for a metric that counts words, its id otherwise, and a count
prints in the metric's unit. A change is a signed percentage with one
decimal, and its bounds carry no `%`.

## The warnings

The table block ends with its warnings, each indented two spaces:

- `warning: <id>: <text>` for each warning of a case's trials, the second
  trial's included: a median under 1 ns (possibly folded), an exactness
  probe that failed, a GC parameter the case changed;
- `warning: <text>` for the run: a case the suite no longer has, whose
  rows `check` prunes from the corrected file, and a partial selection on
  a stale section, whose other rows the corrected file drops.

## The actions

The actions block holds, in this order:

- `rerun:   <executable> <flags> -f <id> …`, when a case fails outside a
  dune rule action. It names at most 10 failing cases; past that, it
  repeats the run's own patterns. A line that would pass 80 columns ends in
  ` \` and continues under the executable. The flags it repeats are
  listed under The report in [`lib/thumper.mli`](../../lib/thumper.mli).
- `accept:  <command>`, when the corrected file was written: `dune
  promote` in a dune rule action, else `mv <corrected> <baseline>`, a path
  quoted for the shell when it holds other characters than letters,
  digits and `_./:@%+=,-`.
- a load warning:
  `warning: load <load> on <n> cores; prefer a quiet host before accepting`
  when `check` recorded a missing or stale section on a loaded host, and
  `warning: blessed under load <load> on <n> cores (--force recorded)`
  when `bless --force` recorded one.

`bless` prints its load warning first, then the partial-selection notice,
then `accept:`:

```
$ dune exec bench/bench_digest.exe -- bless --force
thumper: digest — blessed 3 cases for machine 5c1e0a7f3b9d2486

  proposed  293.25 ns  ±175.7%  4 w  md5/string-64
  proposed    6.83 ns    ±2.5%  0 w  fib/10
  proposed   11.38 ns  ±150.1%  0 w  fib/20

  warning: blessed under load 79.8 on 10 cores (--force recorded)
  accept:  mv bench/digest.thumper.corrected bench/digest.thumper
```

## The summary

The summary is one line, `<n> cases: <p> passed`, then `<i> improved`,
`<r> regressed`, `<x> inconclusive` and `<y> proposed` for each count that
is not zero, joined by `, `. It ends in `; failed under --strict` when
`--strict` alone made the run exit 1, and in a period.

## Inconclusive reasons

An inconclusive row names its reason after `inconclusive:`. The reason's
JSON spelling is in [the JSON document](json.md#reasons).

| reason | what happened | what to do |
| --- | --- | --- |
| `wide interval` | the interval reaches past the budget: the noise exceeds what the budget can check | measure with `--precise` or on a quiet host, or widen the budget |
| `non-positive sample` | a sample on either side is zero or negative, as a `cpu_time` sample is when the clock does not tick within a batch | budget `wall_time` in place of `cpu_time`, or raise `Config.batch_floor` |
| `baseline unstable` | the baseline row's samples have severe outliers, and the change is small | re-record the row on a quiet host with `bless -f <id>`, then accept it |
| `environment` | the host was loaded when the run sampled its load | run on a quiet host, or pass `--wait-quiet SECS` |
| `unconfirmed` | the second trial did not reproduce the first trial's regression | measure the case again with `-f <id>` ([Measuring one case while iterating](running-checks.md#measuring-one-case-while-iterating)) |
| `exactness lost` | one side is an exact count and the other sampled, or both are sampled under a budget of `0` | find why the case allocates differently from batch to batch; when the baseline row is the sampled side, re-record it with `bless -f <id>` |
| `batch drifted` | the batch size moved from the baseline row's, and the change is small or the exact count changed | when the change is intended, re-record the case with `bless -f <id>` |
| `unstable` | this run's samples have severe outliers, and the change is small | measure again on a quiet host |
| `drifted` | this run's samples trend within the trial, and the change is small | measure again on a quiet host |

## Colour

When colour is on (Streams and environment in
[`lib/thumper.mli`](../../lib/thumper.mli)), the report styles these words
and nothing else:

| text | style |
| --- | --- |
| `REGRESSED`, the summary of a run that exits 1 | red |
| `regressed`, `inconclusive`, each `warning:` line, the summary of an inconclusive run | yellow |
| `improved`, the summary of a passing run | green |
| a bare `equivalent`, the header's `thumper:` and the text after the suite | faint |
| the suite name in the header | bold |

A relation in the detail line keeps its word's colour; the status word's
own detail is plain. Stderr is never coloured.

## GitHub annotations

With `GITHUB_ACTIONS` set, the report ends with a block of one line per
metric that fails its case, naming the metric by its id:

- `::error::<id> regressed: <metric> <change> [<lower>, <upper>], budget +<r>%`
  for a confirmed sampled regression;
- `::error::<id> regressed: <metric> <baseline> → <count> <unit> (exact)`
  for an exact regression;
- `::error::<id> regressed: <metric> <count> <unit>, over its <cap> <unit> cap (exact)`
  for an exact count over its cap with no row to compare.

After the edit of the tutorial's [regression](getting-started.md#a-regression)
and a second one that makes `md5/string-64` copy its input:

```
$ GITHUB_ACTIONS=true dune exec bench/bench_digest.exe
thumper: digest — 3 cases vs bench/digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 79.8 on 10 cores; timing verdicts degraded

  REGRESSED     216.67 ns  ±74.7%  14 w  md5/string-64
      alloc 4 w → 14 w (exact); inconclusive: environment  +8.9% [+4.1, +162.8]
  inconclusive   11.54 ns   ±0.7%   0 w  fib/10
      environment  +70.1% [+67.6, +74.4]; equivalent (alloc exact)
  inconclusive   94.43 ns  ±31.5%   0 w  fib/20
      environment  +707.6% [+410.0, +1041.9]; equivalent (alloc exact)

  rerun:   ./_build/default/bench/bench_digest.exe -f md5/string-64

  3 cases: 0 passed, 1 regressed, 2 inconclusive.

::error::md5/string-64 regressed: alloc_words 4 → 14 w (exact)
```

## Stderr

Stderr carries every line that is not the report:

- while measuring on a terminal, the status line
  `thumper: measuring <i>/<n>: <id>`, or `confirming` for a second trial,
  rewritten in place and erased before anything else prints;
- `thumper: waiting for the measurement lock (another run is measuring) ...`
  when another run holds the lock, and
  `thumper: the measurement lock changed owner; waiting on the new holder ...`
  each time it passes to another run;
- `thumper: waiting up to <s>s for a quiet host (load <load> on <n> cores)`
  when `--wait-quiet` starts on a loaded host, and
  `thumper: warning: host still loaded after <s>s; measuring anyway` when
  the wait expires and the run measures anyway;
- `thumper: <reason>` when the run stops, followed by `Try '-h' for usage.`
  after a [usage error](command-line.md#errors).

A run that waits for the lock:

```
$ dune exec bench/bench_digest.exe -- -f fib/10 --quick
thumper: waiting for the measurement lock (another run is measuring) ...
thumper: digest — 1 case vs bench/digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 82.7 on 10 cores; timing verdicts degraded

  inconclusive  6.85 ns  ±129.3%  0 w  fib/10
      environment  +2.3% [-0.4, +204.0]; equivalent (alloc exact)

  1 case: 0 passed, 1 inconclusive.
```

A run that waits for a quiet host, on a host that stays loaded:

```
$ dune exec bench/bench_digest.exe -- -f fib/10 --quick --wait-quiet 10
thumper: waiting up to 10s for a quiet host (load 83.7 on 10 cores)
thumper: warning: host still loaded after 10s; measuring anyway
thumper: digest — 1 case vs bench/digest.thumper for machine 5c1e0a7f3b9d2486
warning: load 83.5 on 10 cores; timing verdicts degraded

  inconclusive  6.79 ns  ±371.5%  0 w  fib/10
      environment  +1.7% [-1.1, +625.9]; equivalent (alloc exact)

  1 case: 0 passed, 1 inconclusive.
```
