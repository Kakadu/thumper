list prints the selected case ids and measures nothing. Under raise mode a
case that ran would fail, so a clean listing shows no case ran; and since
nothing measures, the lock is never taken and its directory stays empty.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

  $ THUMPER_FIXTURE_MODE=raise $FIX list
  busy/spin
  busy/half
  alloc/list
  alloc/array
  err/raise
  err/kill9
  nondet/flip
  $ ls locks
  $ test ! -e fixture.thumper && echo no-baseline
  no-baseline
