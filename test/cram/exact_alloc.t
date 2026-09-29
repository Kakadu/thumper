Checks judged on exact allocation counts. The alloc cases collect alloc_words alone, and
the fixture's modes change their counts by whole words: alloc_more adds a
cons cell to each call of alloc/list, alloc_less takes a word from each call
of alloc/array. Every verdict below compares integers, so no load can move
it.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX check --quick -f alloc > /dev/null 2>&1
  $ mv fixture.thumper.corrected fixture.thumper
  $ cp fixture.thumper fast.thumper

The recorded rows are exact counts, not sampled vectors.

  $ grep '^alloc/' fixture.thumper | cut -f 1-3
  alloc/array	alloc_words	exact
  alloc/list	alloc_words	exact

An exact regression fails the run with exit 1 and writes no corrected file:
nothing improved, so there is nothing to propose.

  $ THUMPER_FIXTURE_MODE=alloc_more $FIX check --quick -f alloc > out.log 2>&1
  [1]
  $ grep -o '[0-9]* w → [0-9]* w (exact)' out.log
  300 w → 303 w (exact)
  $ grep -o '2 cases: .*' out.log
  2 cases: 1 passed, 1 regressed.
  $ test ! -e fixture.thumper.corrected && echo no-corrected-file
  no-corrected-file

An exact improvement passes, and the corrected file advances that one row.

  $ cp fixture.thumper before.thumper
  $ THUMPER_FIXTURE_MODE=alloc_less $FIX check --quick -f alloc > out.log 2>&1
  $ grep -o '2 cases: .*' out.log
  2 cases: 1 passed, 1 improved.
  $ diff -u fixture.thumper fixture.thumper.corrected | grep '^[-+][^-+]'
  -alloc/array	alloc_words	exact	101
  +alloc/array	alloc_words	exact	100
  $ cmp fixture.thumper before.thumper
  $ rm fixture.thumper.corrected

One run can regress and improve. It fails, and the corrected file still
advances the improved row alone, since a regressed row cannot enter it. The
rerun line names the failing case; the accept line names the corrected file.

  $ THUMPER_FIXTURE_MODE=alloc_more,alloc_less $FIX check --quick -f alloc > out.log 2>&1
  [1]
  $ diff -u fixture.thumper fixture.thumper.corrected | grep '^[-+][^-+]'
  -alloc/array	alloc_words	exact	101
  +alloc/array	alloc_words	exact	100
  $ grep -e 'rerun:' -e 'accept:' out.log
    rerun:   ./fixture/bench_fixture.exe --quick -f alloc/list
    accept:  mv $TESTCASE_ROOT/fixture.thumper.corrected $TESTCASE_ROOT/fixture.thumper
  $ rm fixture.thumper.corrected

The rerun line is the command to paste: it carries the preset and an
explicit --baseline, and names the executable relative to the working
directory when it lies under it, absolute otherwise.

  $ mv fixture.thumper alt.thumper
  $ THUMPER_FIXTURE_MODE=alloc_more $FIX check --quick --baseline alt.thumper -f alloc/list > out.log 2>&1
  [1]
  $ grep -A1 'rerun:' out.log
    rerun:   ./fixture/bench_fixture.exe --quick --baseline alt.thumper \
             -f alloc/list
  $ THUMPER_FIXTURE_MODE=alloc_more "$(pwd -P)/fixture/bench_fixture.exe" check --quick --baseline alt.thumper -f alloc/list > out.log 2>&1
  [1]
  $ grep -o 'rerun: *[^ ]*' out.log
  rerun:   ./fixture/bench_fixture.exe
  $ mkdir sub && cd sub
  $ THUMPER_FIXTURE_MODE=alloc_more ../fixture/bench_fixture.exe check --quick --baseline ../alt.thumper -f alloc/list > ../out.log 2>&1
  [1]
  $ cd ..
  $ grep -o 'rerun: *[^ ]*' out.log
  rerun:   $TESTCASE_ROOT/fixture/bench_fixture.exe

A dune rule action (INSIDE_DUNE set and the working directory in the build
tree, as a cram session's is) gets no rerun line: the executable's path is
relative to the action's directory and could not be pasted.

  $ INSIDE_DUNE="$CONTEXT" THUMPER_FIXTURE_MODE=alloc_more $FIX check --quick --baseline alt.thumper -f alloc/list > out.log 2>&1
  [1]
  $ grep -c 'rerun:' out.log
  0
  [1]
