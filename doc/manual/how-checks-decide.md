# How checks decide

This page explains why a check reads each row as it does: what the baseline
stores, how a change is estimated, when a verdict needs a second trial, and
why a machine, a compiler or a loaded host changes the answer. The rules
themselves are in [`lib/thumper.mli`](../../lib/thumper.mli), and the
statistics' derivations and constants in
[`doc/dev/statistics.md`](../dev/statistics.md).

## Evidence, not conclusions

A baseline stores what was measured: each case's sorted samples and their
batch size, and each exact count. It stores no verdict, no mean and no
threshold. Every check judges this run's trials against that evidence
afresh, so a change to the decision procedure applies to every committed
baseline without re-recording one.

Evidence also keeps its uncertainty. Two sets of samples give an interval
for the change between them. Two stored numbers give a difference, with no
way to tell noise from a change. And a reviewer reads a baseline's diff as
the evidence that changed, row by row.

## Rank statistics and a fixed sample count

Timing noise is skewed to the right, with a heavy tail of slow samples.
Thumper therefore compares ranks and makes no assumption of normality. In
log space, the change is the median of every difference between a sample of
this run and one of the baseline. Its interval comes from the order
statistics of those differences, at 0.005 per side. Two runs over the same
samples give the same interval, bit for bit, since nothing is drawn at
random.

No sample is removed as an outlier. One slow sample barely moves a rank
interval, so the interval tolerates the tail it describes.

A trial takes a fixed number of samples, 20 by default, and never measures
"until the interval is narrow". A loop that checks after every change and
stops when the interval looks good would report false changes far more often
than its level says. A fixed count also keeps the two sides of a comparison
measured the same way.

A relative budget `r` comes with an equivalence band `e`, `min 2.5% (r/2)`,
which the budget derives and no argument sets. A regression needs the
whole interval above `r`, and an improvement needs it below `-e`. The band
makes a shift smaller than `e` count as equivalent, so that a baseline's
own noise never reads as a change. Keeping `e` at most `r` keeps the band
inside what the budget allows.

For an unchanged case, the first trial's interval lies wholly above zero at
most one time in two hundred, if the samples are exchangeable. That is a
statement about one case and one trial, and it gives no rate of false
failure for a whole check ([Confirming a
regression](#confirming-a-regression)).

## Every metric has a budget

Every metric a case collects is judged. A metric that no scope budgets has
the default, a relative budget of 5%, and a budget stated for one metric
replaces the default for that metric alone. A collected metric that failed
nothing would print numbers no check reads. A default that any stated
budget replaced would let a budget on allocation leave the time unjudged,
silently. A metric the user collects
on request, such as `minor_collections`, is therefore judged like the
others, and can fail a case.

## Passing within the budget

A timing comparison whose interval ends at or under its budget, `U <= r`,
is within budget when it is neither improved nor equivalent, and its row
reads `passed`. The budget is the claim a check makes, that the case is no
slower than its baseline by more than `r`. An interval that ends under `r`
shows that claim at the first trial's level.

The rule turns only inconclusive rows into passes. A regression needs its
interval's lower end above `r`, so its upper end is above `r` too, and it
never passes. A slowdown a little over the budget passes only when its
interval's upper end falls under `r` by chance, which the level of 0.005
makes rare.

A pass needs no second trial. A confirmation guards against a false failure,
and a pass cannot be one. An improvement that its second trial does not
confirm is within budget, since its interval ends under `r`.

Within budget is not equivalent, which claims the change lies within `±e`,
and the report prints `passed` for both. A comparison whose noise is wider
than the band and narrower than the budget passes without that claim, and
its detail line names the budget. One whose noise is wider than the budget
stays inconclusive for `wide interval`. Its trial cannot check the budget,
and more samples or a looser budget can.

## Confirming a regression

A sampled improvement or regression at the first trial is provisional. The
run measures the case again after every case's first trial, in a new worker,
with a new warmup, at the first trial's batch size. The relation stands only
if this second trial alone reproduces it, at 0.05 per side, against the same
baseline samples.

The spacing makes the second trial's noise independent of the first's, so a
chance extreme rarely happens twice. The second trial's looser level keeps a
true change detected, since it asks for less evidence than the first trial
already showed.

A second trial cannot see noise that both trials share: a baseline recorded
on a lucky run, a host that is hot for the whole check, a code layout that
this build happens to have. That noise is why this page gives no rate for
a whole check. Measuring a failing case again later, with its `rerun:`
line, is the defence against it.

A second trial that calibrated another batch size than the first measured
another protocol. It counts as a second trial that did not reproduce the
first.

## Unstable, drifted and recalibrated trials

Three conditions make a trial's small changes untrustworthy:

- its samples, or the baseline row's, have severe outliers;
- its first and second halves differ, as when a host warms up during the
  trial (`drifted`);
- the run calibrated another batch size than the baseline row's
  (`batch drifted`), which can move the per-call time by the loop's
  overhead.

Each can make or hide a change of the band's size, and none explains a large
one. A change beyond `2e` of zero is therefore judged on any trial, and a
case five times slower is regressed whatever its outliers. Within `2e`,
outliers leave no direction to claim. Since `2e <= r`, such a change ends
within the budget, and it passes within budget, or equivalent when it is.
A drifted or recalibrated trial yields no verdict within `2e`.

Drift is read only on a quiet host, where load does not explain it.

## Exact counts

Many OCaml functions allocate the same number of words on every call. The
run's probe reads the GC's counters around one batch of `k` calls and one of
`2k`. Their difference is the count of `k` calls, free of the harness's
constant cost. A whole count per call that both batches agree on is exact.
The probe runs on every trial, and a count it cannot prove stays sampled,
with a warning.

An exact count compares as an integer, with no interval, no second trial and
no look at the load. Counting does not depend on the clock or on the
neighbours, so one word more is a change, and `no_more_alloc_than 0.` allows
none. The count is the same on any CPU, which makes it the check that holds
on hosted CI runners ([running
checks](running-checks.md#checking-on-hosted-ci-runners)).

Some allocators amortise, as a buffer that doubles does, and allocate a
different count per call at another batch size. The probe therefore runs at
the baseline row's batch size, even when the timing calibrated another, so
an exact count compares like for like. The probe keeps the baseline's batch
size while it is at most 16 times the run's. A case slower than that shows
its regression in time, and a probe at the old size would cost more than 48
of its batches. Beyond the bound, a changed count reads `batch drifted`.

An `at_most` cap is absolute. An exact count over it fails its case on any
run, with a baseline or without one. A sampled count never fails a cap,
since an estimate that crosses a line does not prove the count did. A count
that is exact on one side and sampled on the other is
inconclusive for `exactness lost`. So is a sampled counter under a budget of
`0`, since no interval can show that not one word was added.

## One section per machine

A timing means something only on the machine that took it. A baseline keeps
one section per machine key, and a run judges only against its own machine's
section. Every other section stays as it is, byte for byte. Thumper never
scales one machine's numbers to another's, since any conversion would add
its own noise and bias to every comparison.

The key hashes the host, its operating system and its CPU model, as
`Baseline.machine_key` in [`lib/thumper.mli`](../../lib/thumper.mli) says.
Two ways to get the key wrong cost differently:

- Splitting too much, as renaming a Linux host does, costs a new section.
  Every row reads `proposed`, and one `bless` records it.
- Splitting too little puts two machines' timings in one section. A slower
  machine then reads as a regression, confirmed, since both trials run on
  it.

The first is visible and cheap and the second is silent, so the key splits
eagerly. `THUMPER_MACHINE` replaces the key with a name the user chooses,
which claims that every host using it times alike.

## Proposed rows pass

A metric with no row to compare with is proposed, and passes: a first run,
a new case, a new machine and a compiler upgrade all pass. None of them is
a regression, and failing them would turn every contributor's first build
red. A run on a machine with no section therefore compares nothing, and
exits 0 unless an exact count is over its `at_most` cap.

Thumper cannot tell a machine that is new from a CI runner that was meant
to compare. The user who runs the check knows, and says so with
`--strict`, which fails a run with a proposed metric and nothing more. An
inconclusive comparison passes under `--strict` too, since noise is not a
regression.

## Stale sections

A section records the compiler it was measured under: the OCaml version, the
word size, and the backend and runtime variant. Another compiler generates
other code, so a comparison across compilers would report the compiler's
changes as the code's. A stale section is therefore not judged. Every
row reads `proposed`, `bless` records the section again, and only a count
over its cap can fail.

Flambda and other configure-time options are not part of the identity, since
the standard library does not report them to a running program. A move to
flambda under the same version keeps the section, and its rows must be
re-recorded by hand ([running
checks](running-checks.md#upgrading-the-compiler)).

## Loaded hosts

A host is loaded when its one-minute load average per core is at least 0.5.
Other processes then compete for the cores, and a slowdown can come from
them. Samples taken this way are no longer interchangeable, which the rank
interval assumes. So on a loaded host every sampled comparison is
inconclusive for `environment`, and nothing is confirmed. The row still
shows the change it measured, for information.

The run samples the load when it holds the measurement lock, and again
before the second trials. Exact counts are judged whatever the load.

A check waits for a quiet host only when asked, with `--wait-quiet`. Without
it, a check on a loaded host answers at once and leaves the timing
undecided. `bless` refuses a loaded host unless forced. A section recorded
under load holds slow rows. Later quiet runs would read as improvements
against them, and hide a regression of up to the difference.

The load average counts the whole host. Inside a container it is the host's,
and a container's own CPU limit does not show in it.

## Only `bless` records

`check` judges and writes no baseline, and `bless` alone records. A failing
check then means a confirmed regression, a count over its cap, or a
proposed row under `--strict`. A first run, a new case, a new machine and
an improvement all pass, and none of them writes a file.

Recording is a decision about what later runs compare with. A run that
recorded as it checked would make a noisy or loaded moment the reference.
As a command of its own, `bless` refuses a loaded host and prints the rows
it records, and `git diff` shows what changed before the commit.

The cost is that an improvement stays unrecorded until someone runs
`bless`. An improvement that
nobody records leaves its old row in place, so a later slowdown back to
the old speed passes. The `accept:` line names the improved cases on every
run until they are recorded.

A `bless` of every case replaces this machine's section, so the rows of
cases the suite no longer has go with it. A `bless` of some cases replaces
their rows and keeps the others, unless the section is missing or stale,
when the selection alone makes the new section.

## Why benchmarks run on `@bench`

Under the default protocol, a trial takes 20 samples of at least 5 ms each
and 100 ms of warmup: 0.2 s per case at the least. A change adds a second
trial, and every run of one user measures in turn, under the measurement
lock. A suite of a hundred cases takes 20 s or more.

`dune runtest` also runs its actions while dune compiles on every core, on
the loaded host that turns timing rows inconclusive. Benchmarks get their
own alias, run when performance is the question. Dune caches that alias like
any other, and an unchanged executable and baseline measure nothing again.

The rule depends on its baseline through `(deps (glob_files *.thumper))`.
Dune gives an action only the files its rule declares, so a rule without
the dependency never sees the baseline, and every run would be a first
run. A glob accepts a file that does not exist yet, which a first run
needs, and dune reruns the rule when the file changes.
