On a quiet host an unchanged suite passes, and noise cannot fail it.

  $ . ../prelude.sh
  $ mkdir fixture && cp ../fixture/bench_fixture.exe fixture/
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX bless --quick --wait-quiet 60 > /dev/null 2>&1

A run of every case against its own baseline exits 0 with no regression,
and its JSON document reads pass.

  $ $FIX check --quick --wait-quiet 60 --json out.json > out.log 2>&1
  $ grep -c 'REGRESSED' out.log
  0
  [1]
  $ grep -o '"overall":"[a-z]*"' out.json
  "overall":"pass"

Under nondet mode nondet/flip alternates between two costs every 20 ms, so
its samples never settle: the case is inconclusive, exit 0, and no accept
line names it.

  $ THUMPER_FIXTURE_MODE=nondet $FIX check --quick --wait-quiet 60 -f nondet > out.log 2>&1
  $ grep -o '1 case: .*' out.log
  1 case: 0 passed, 1 inconclusive.
  $ grep -c 'accept:' out.log
  0
  [1]
