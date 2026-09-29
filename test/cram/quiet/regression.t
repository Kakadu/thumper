A confirmed timing regression fails the build. Under slow mode busy/spin
does twice its work against a baseline recorded without it, a shift the
rank test confirms against the 5% budget, and busy/half does half its work,
an improvement.

  $ . ../prelude.sh
  $ mkdir fixture && cp ../fixture/bench_fixture.exe fixture/
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX check --quick --wait-quiet 60 -f busy > /dev/null 2>&1
  $ mv fixture.thumper.corrected fixture.thumper
  $ cp fixture.thumper before.thumper

A regression alone exits 1 with the rerun line and writes no corrected
file.

  $ THUMPER_FIXTURE_MODE=slow $FIX check --quick --wait-quiet 60 -f busy/spin > out.log 2>&1
  [1]
  $ grep -o '1 case: .*' out.log
  1 case: 0 passed, 1 regressed.
  $ grep 'rerun:' out.log
    rerun:   ./fixture/bench_fixture.exe --quick -f busy/spin
  $ test ! -e fixture.thumper.corrected && echo no-corrected-file
  no-corrected-file
  $ cmp fixture.thumper before.thumper

With the improvement in the same run, the run still fails, and the
corrected file advances busy/half's wall_time row alone, pooling the
samples of the first sweep and the confirmation sweep, 11 each under
--quick.

  $ THUMPER_FIXTURE_MODE=slow $FIX check --quick --wait-quiet 60 -f busy > out.log 2>&1
  [1]
  $ diff fixture.thumper fixture.thumper.corrected | grep '^[<>]' | cut -f 1,2,4
  < busy/half	wall_time	n=11
  > busy/half	wall_time	n=22
  $ grep -e 'rerun:' -e 'accept:' out.log
    rerun:   ./fixture/bench_fixture.exe --quick -f busy/spin
    accept:  mv $TESTCASE_ROOT/fixture.thumper.corrected $TESTCASE_ROOT/fixture.thumper
