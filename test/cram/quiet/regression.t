A confirmed timing regression fails the build. Under slow mode busy/spin
does twice its work against a baseline recorded without it, a shift the
rank test confirms against the 5% budget, and busy/half does half its work,
an improvement.

  $ . ../prelude.sh
  $ mkdir fixture && cp ../fixture/bench_fixture.exe fixture/
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX bless --quick --wait-quiet 60 -f busy > /dev/null 2>&1
  $ cp fixture.thumper before.thumper

A regression alone exits 1 with the rerun line.

  $ THUMPER_FIXTURE_MODE=slow $FIX check --quick --wait-quiet 60 -f busy/spin > out.log 2>&1
  [1]
  $ summary out.log
  1 regressed in DURATION.
  $ grep 'rerun:' out.log
  rerun: ./fixture/bench_fixture.exe --quick -f busy/spin

With the improvement in the same run, the run still fails, the rerun line
names the regression and the accept line the improvement. No run writes
the baseline.

  $ THUMPER_FIXTURE_MODE=slow $FIX check --quick --wait-quiet 60 -f busy > out.log 2>&1
  [1]
  $ grep -e 'rerun:' -e 'accept:' out.log
  rerun: ./fixture/bench_fixture.exe --quick -f busy/spin
  accept: ./fixture/bench_fixture.exe bless --quick -f busy/half
  $ cmp fixture.thumper before.thumper

bless records the improvement from one trial, 11 samples under --quick.

  $ THUMPER_FIXTURE_MODE=slow $FIX bless --quick --wait-quiet 60 -f busy/half > /dev/null 2>&1
  $ grep '^busy/half	wall_time' fixture.thumper | cut -f 1,2,4
  busy/half	wall_time	n=11
