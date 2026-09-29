A matching baseline passes: exit 0, and the baseline is left as it was.
The alloc cases are judged on exact counts, so the outcome holds under any
load.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX bless --quick --force -f alloc > /dev/null 2>&1
  $ cp fixture.thumper before.thumper

  $ $FIX check --quick -f alloc > out.log 2>&1
  $ cmp fixture.thumper before.thumper

Outside a rule action the header names the baseline by its absolute path,
and the summary counts every case passed.

  $ head -1 out.log
  thumper: fixture — 2 cases vs $TESTCASE_ROOT/fixture.thumper for machine testkey
  $ grep -o '2 cases: .*' out.log
  2 cases: 2 passed.

The status line is for a terminal: a redirected run carries none of it.

  $ grep -c 'thumper: measuring \|thumper: confirming ' out.log
  0
  [1]

--baseline PATH replaces the default file: the run judges PATH, and an
absent PATH is a first run, which writes nothing.

  $ $FIX check --quick -f alloc --baseline alt.thumper > alt.log 2>&1
  $ grep -o 'no baseline for machine testkey' alt.log
  no baseline for machine testkey
  $ test ! -e alt.thumper && echo no-file
  no-file
  $ cmp fixture.thumper before.thumper
