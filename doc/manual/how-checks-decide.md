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
way to tell noise from a change. And a reviewer reads a corrected file's
diff as the evidence that changed, row by row.

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

A relative budget `r` comes with an equivalence band `e`, by default
`min 2.5% (r/2)`. A regression needs the whole interval above `r`, and an
improvement needs it below `-e`. The band makes a shift smaller than `e`
count as equivalent, so a baseline does not move by the width of its own
noise. Keeping `e` at most `r` keeps the band inside what the budget allows.

For an unchanged case, the first trial's interval lies wholly above zero at
most one time in two hundred, if the samples are exchangeable. That is a
statement about one case and one trial, and it gives no rate of false
failure for a whole check ([Confirming a
regression](#confirming-a-regression)).

## Passing within the budget

A timing row whose interval ends at or under its budget, `U <= r`, passes as
`within budget` when it is neither improved nor equivalent. The budget is the claim a
check makes, that the case is no slower than its baseline by more than `r`.
An interval that ends under `r` shows that claim at the first trial's level.

The rule turns only inconclusive rows into passes. A regression needs its
interval's lower end above `r`, so its upper end is above `r` too, and it
never passes. A slowdown a little over the budget passes only when its
interval's upper end falls under `r` by chance, which the level of 0.005
makes rare.

A pass needs no second trial. A confirmation guards against a false failure,
and a pass cannot be one. An improvement that its second trial does not
confirm passes as `within budget` when its interval ends under `r`.

`within budget` is not `equivalent`, which claims the change lies within
`±e`. A row whose noise is wider than the band and narrower than the budget
passes without that claim. A row whose noise is wider than the budget stays
`inconclusive: wide interval`. Its trial cannot check the budget, and more
samples or a looser budget can.

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

A second trial measured at another batch size is never pooled with the
first, since one baseline row never mixes two batch sizes. It counts as a
second trial that did not reproduce the first.

## Unstable, drifted and recalibrated trials

Three conditions make a trial's small changes untrustworthy:

- its samples, or the baseline row's, have severe outliers (`unstable`,
  `baseline unstable`);
- its first and second halves differ, as when a host warms up during the
  trial (`drifted`);
- the run calibrated another batch size than the baseline row's
  (`batch drifted`), which can move the per-call time by the loop's
  overhead.

Each can make or hide a change of the band's size, and none explains a large
one. A change beyond `2e` of zero is therefore judged on any trial, and a
case five times slower is regressed whatever its outliers. Within `2e`, an
unstable trial claims no direction, and can still read `equivalent` or pass
`within budget`. A drifted or recalibrated trial yields no verdict within
`2e`.

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
`inconclusive: exactness lost`. So is a sampled counter under a budget of
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

- Splitting too much, as renaming a Linux host does, costs a new section. Every row
  reads `proposed`, and one accept records it.
- Splitting too little puts two machines' timings in one section. A slower
  machine then reads as a regression, confirmed, since both trials run on
  it.

The first is visible and cheap and the second is silent, so the key splits
eagerly. `THUMPER_MACHINE` replaces the key with a name the user chooses,
which claims that every host using it times alike.

## Stale sections

A section records the compiler it was measured under: the OCaml version, the
word size, and the backend and runtime variant. Another compiler generates
other code, so a comparison across compilers would report the compiler's
changes as the code's. A stale section is therefore not judged. Every
row reads `proposed`, the corrected file replaces the section, and only a
count over its cap can fail.

Flambda and other configure-time options are not part of the identity, since
the standard library does not report them to a running program. A move to
flambda under the same version keeps the section, and its rows must be
re-recorded by hand ([running
checks](running-checks.md#upgrading-the-compiler)).

## Loaded hosts

A host is loaded when its one-minute load average per core is at least 0.5.
Other processes then compete for the cores, and a slowdown can come from
them. Samples taken this way are no longer interchangeable, which the rank
interval assumes. So on a loaded host every sampled comparison reads
`inconclusive: environment`, and nothing is confirmed or advanced. The row
still shows the change it measured, for information.

The run samples the load when it holds the measurement lock, and again
before the second trials. Exact counts are judged whatever the load.

A check waits for a quiet host only when asked, with `--wait-quiet`. Without
it, a check on a loaded host answers at once and leaves the timing
undecided. `bless` refuses a loaded host unless forced. A section recorded
under load holds slow rows. Later quiet runs would read as improvements
against them, and hide a regression of up to the difference. A first `check`
on a loaded host still records the missing section, with a warning, since
its diff is reviewed before it is accepted.

The load average counts the whole host. Inside a container it is the host's,
and a container's own CPU limit does not show in it.

## What the corrected file may change

Against a current section, the corrected file changes the baseline in one
direction. An improved row advances, to the samples of both trials or to the
new exact count, and a proposed row is added. No other row changes. A
regression, a slowdown within the budget, and an inconclusive or unconfirmed
change leave their rows as they were. After a check of the whole suite, the
command line also removes the rows of cases the suite no longer has.

So accepting a corrected file never makes a baseline slower. Slowdowns that
each stay within the budget are all measured against the same row, and they
add up until one of them fails. An improvement fails the build too, under
`diff?`, until it is accepted, since the new row is a change to review.

A missing or a stale section has nothing to protect. The corrected file
records the whole section from this run, whatever its relations and the
host's load. A proposed row is recorded whatever its outcome as well, a
count over its cap included. The cap is absolute, so accepting that row does
not hide the failure, and the next run fails the same way.

Only `bless` records a slower row, as a command of its own with a diff to
review.

## Why benchmarks run on `@bench`

Under the default protocol, a trial takes 20 samples of at least 5 ms each
and 100 ms of warmup: 0.2 s per case at the least. A change adds a second
trial, and every run of one user measures in turn, under the measurement
lock. A suite of a hundred cases takes 20 s or more.

`dune runtest` also runs its actions while dune compiles on every core, on
the loaded host that turns timing rows inconclusive. Benchmarks get their
own alias, run when performance is the question. Dune caches that alias like
any other, and an unchanged executable and baseline measure nothing again.
