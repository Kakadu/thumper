A budget on a metric its case does not collect is a contradiction in the
suite, not a measurement outcome: check, bless and list refuse it with exit
2 before they take the lock.

  $ . ./prelude.sh
  $ export THUMPER_FIXTURE_MODE=uncollected
  $ FIX=./fixture/bench_fixture.exe

Another process holds the lock. A refusal that waited for it would print
the waiting line and wait until the holder gives up, after 60 s.

  $ ./fixture/hold_lock.exe held release &
  $ HOLDER=$!
  $ wait_for test -e held

  $ $FIX check --quick
  thumper: 'cpu' has a budget on wall_time but does not collect it (add it to ~metrics or drop the budget)
  [2]
  $ $FIX bless --quick
  thumper: 'cpu' has a budget on wall_time but does not collect it (add it to ~metrics or drop the budget)
  [2]
  $ $FIX list
  thumper: 'cpu' has a budget on wall_time but does not collect it (add it to ~metrics or drop the budget)
  [2]

Nothing was measured and no baseline was written.

  $ test ! -e fixture.thumper && echo no-baseline
  no-baseline

  $ touch release
  $ wait $HOLDER
