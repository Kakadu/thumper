An inconclusive case cannot fail the build, and the baseline is left as it
was. Under alloc_grow, alloc/list allocates more on each call than on the
one before, so the exactness probe fails and the run's sampled count cannot
be compared with the baseline's exact one: exactness lost, whatever the load.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX bless --quick --force -f alloc/list > /dev/null 2>&1
  $ cp fixture.thumper before.thumper

Inconclusive exits 0, the reason is named, and the summary counts it.

  $ THUMPER_FIXTURE_MODE=alloc_grow $FIX check --quick -f alloc/list > out.log 2>&1
  $ grep -o 'exactness lost' out.log
  exactness lost
  $ grep -o '1 case: .*' out.log
  1 case: 0 passed, 1 inconclusive.
  $ cmp fixture.thumper before.thumper

--strict fails a proposed metric only, so an inconclusive case still
exits 0.

  $ THUMPER_FIXTURE_MODE=alloc_grow $FIX check --quick -f alloc/list --strict > out.log 2>&1
