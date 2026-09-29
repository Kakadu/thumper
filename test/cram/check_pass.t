A matching baseline passes: exit 0 and no corrected file, since an
equivalent run changes nothing. The alloc cases are judged on exact counts,
so the outcome holds under any load.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX check --quick -f alloc > /dev/null 2>&1
  $ mv fixture.thumper.corrected fixture.thumper
  $ cp fixture.thumper before.thumper

A corrected file left by an interrupted run is removed at startup, so no
stale file survives a run that proposes nothing.

  $ echo stale > fixture.thumper.corrected
  $ $FIX check --quick -f alloc > out.log 2>&1
  $ test ! -e fixture.thumper.corrected && echo no-corrected-file
  no-corrected-file
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

--baseline PATH replaces the default file: the run judges PATH and writes
PATH.corrected, and an absent PATH is a first run.

  $ $FIX check --quick -f alloc --baseline alt.thumper > alt.log 2>&1
  $ test -f alt.thumper.corrected && echo alt-corrected-file
  alt-corrected-file
  $ test ! -e fixture.thumper.corrected && echo no-corrected-file
  no-corrected-file
  $ grep -o 'no baseline for machine testkey' alt.log
  no baseline for machine testkey
