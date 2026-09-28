A budget on a metric its scope does not collect is a contradiction in the
suite, not a measurement outcome: check, bless and list refuse it with exit 2
before the lease, so a held lease cannot delay the refusal.

  $ export THUMPER_MACHINE=testkey
  $ mkdir -p locks && export THUMPER_LOCK_DIR="$PWD/locks"
  $ unset INSIDE_DUNE
  $ unset GITHUB_ACTIONS
  $ export THUMPER_FIXTURE_MODE=uncollected
  $ FIX=./fixture/bench_fixture.exe

Another process holds the lease. A watchdog releases it after a minute, so a
refusal that waited for the lease would print the waiting notice below
instead of hanging the session.

  $ ./fixture/hold_lease.exe held release &
  $ while [ ! -e held ]; do sleep 0.02; done
  $ (sleep 60; touch release) > /dev/null 2>&1 &
  $ WATCHDOG=$!

  $ $FIX check --quick
  thumper: 'cpu' has a budget on wall_time but does not collect it (add it to ~metrics or drop the budget)
  [2]
  $ $FIX bless --quick
  thumper: 'cpu' has a budget on wall_time but does not collect it (add it to ~metrics or drop the budget)
  [2]
  $ $FIX list
  thumper: 'cpu' has a budget on wall_time but does not collect it (add it to ~metrics or drop the budget)
  [2]

Nothing was measured and no candidate was written.

  $ test ! -e fixture.thumper.corrected && echo no-candidate
  no-candidate

  $ kill $WATCHDOG; wait $WATCHDOG 2> /dev/null
  [143]
  $ touch release
  $ wait
