A stale section: its '# ocaml:' identity is not the running compiler's.
The run compares nothing, proposes every row of the section and exits 0,
so a compiler upgrade is re-recorded by accepting a file, never by a check
that fails on noise. Under --strict, stale is a failure.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX check --quick > /dev/null 2>&1
  $ mv fixture.thumper.corrected fixture.thumper
  $ sed 's/^# ocaml: .*/# ocaml: 9.9.9 · 64-bit · release/' fixture.thumper > doctored
  $ mv doctored fixture.thumper

  $ $FIX check --quick > out.log 2>&1
  $ head -1 out.log | sed 's/→ .*)$/→ OCAML)/'
  thumper: fixture — stale baseline for machine testkey (ocaml 9.9.9 · 64-bit · release → OCAML)
  $ grep 'accept:' out.log
    accept:  mv $TESTCASE_ROOT/fixture.thumper.corrected $TESTCASE_ROOT/fixture.thumper

The corrected file records this machine's section anew from this run: the
running compiler's identity and every case's rows.

  $ grep -c '9\.9\.9' fixture.thumper.corrected
  0
  [1]
  $ grep -c '^# ocaml: ' fixture.thumper.corrected
  1
  $ grep -v '^#' fixture.thumper.corrected | grep -vc '^$'
  12

  $ rm fixture.thumper.corrected
  $ $FIX check --quick --strict > out.log 2>&1
  [1]

A filtered check on a stale section still records the section whole, so
the corrected file holds the selected case's rows alone, and the report
says what it drops; a filtered bless does the same, in the same words.

  $ $FIX check --quick -f busy/spin > out.log 2>&1
  $ grep -o 'warning: partial selection on a stale section.*' out.log
  warning: partial selection on a stale section: the corrected file re-records this machine's whole section and drops the rows of the 6 unselected cases
  $ grep -v '^#' fixture.thumper.corrected | grep -v '^$' | cut -f 1,2
  busy/spin	alloc_words
  busy/spin	wall_time
  $ rm fixture.thumper.corrected

  $ $FIX bless --quick --force -f busy/spin > out.log 2>&1
  $ grep -o 'warning: partial selection on a stale section.*' out.log
  warning: partial selection on a stale section: the corrected file re-records this machine's whole section and drops the rows of the 6 unselected cases
  $ grep -v '^#' fixture.thumper.corrected | grep -v '^$' | cut -f 1,2
  busy/spin	alloc_words
  busy/spin	wall_time
