A baseline whose header names another suite stops the run with exit 2, as
a baseline of another machine is never compared: judging against the wrong
file must be loud, never a page of first-run rows. A file with sections
and no '# suite:' header breaks the format and is corrupt.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX check --quick -f busy/spin > /dev/null 2>&1
  $ mv fixture.thumper.corrected fixture.thumper
  $ sed 's/^# suite: fixture$/# suite: other/' fixture.thumper > renamed
  $ mv renamed fixture.thumper

check stops before measuring, names both suites and the remedy, and writes
nothing. bless stops the same way: recording the section under the wrong
name would commit the wrong file.

  $ $FIX check --quick 2> err.log
  [2]
  $ cat err.log
  thumper: $TESTCASE_ROOT/fixture.thumper: baseline is for suite 'other', not 'fixture'; pass this suite's file with --baseline, or update the '# suite:' header if the suite was renamed
  $ test ! -e fixture.thumper.corrected && echo no-corrected-file
  no-corrected-file
  $ $FIX bless --force --quick 2> err.log
  [2]
  $ cat err.log
  thumper: $TESTCASE_ROOT/fixture.thumper: baseline is for suite 'other', not 'fixture'; pass this suite's file with --baseline, or update the '# suite:' header if the suite was renamed
  $ test ! -e fixture.thumper.corrected && echo no-corrected-file
  no-corrected-file

Without its '# suite:' header the file is corrupt at its second line.

  $ grep -v '^# suite: other$' fixture.thumper > headless
  $ mv headless fixture.thumper
  $ $FIX check --quick 2> err.log
  [2]
  $ cat err.log
  thumper: $TESTCASE_ROOT/fixture.thumper: corrupt baseline (line 2): expected a '# suite:' line
