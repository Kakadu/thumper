Checks judged on exact allocation counts. The alloc cases collect alloc_words alone, and
the fixture's modes change their counts by whole words: alloc_more adds a
cons cell to each call of alloc/list, alloc_less takes a word from each call
of alloc/array. Every verdict below compares integers, so no load can move
it.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX bless --quick --force -f alloc > /dev/null 2>&1
  $ cp fixture.thumper before.thumper

The recorded rows are exact counts, not sampled vectors.

  $ grep '^alloc/' fixture.thumper | cut -f 1-3
  alloc/array	alloc_words	exact
  alloc/list	alloc_words	exact

An exact regression fails the run with exit 1, and names no bless command:
nothing improved.

  $ THUMPER_FIXTURE_MODE=alloc_more $FIX check --quick -f alloc > out.log 2>&1
  [1]
  $ grep -o '[0-9]* w → [0-9]* w (exact)' out.log
  300 w → 303 w (exact)
  $ grep -o '2 cases: .*' out.log
  2 cases: 1 passed, 1 regressed.
  $ grep -c 'accept:' out.log
  0
  [1]

An exact improvement passes, and the accept line names the bless command
that records it. One run can regress and improve: it fails, the rerun line
names the failing case and the accept line the improved one. Neither run
writes the baseline.

  $ THUMPER_FIXTURE_MODE=alloc_less $FIX check --quick -f alloc > out.log 2>&1
  $ grep -o '2 cases: .*' out.log
  2 cases: 1 passed, 1 improved.
  $ THUMPER_FIXTURE_MODE=alloc_more,alloc_less $FIX check --quick -f alloc > out.log 2>&1
  [1]
  $ grep -e 'rerun:' -e 'accept:' out.log
    rerun:   ./fixture/bench_fixture.exe --quick -f alloc/list
    accept:  ./fixture/bench_fixture.exe bless --quick -f alloc/array
  $ cmp fixture.thumper before.thumper

bless records the improvement, that one row.

  $ THUMPER_FIXTURE_MODE=alloc_less $FIX bless --quick --force -f alloc/array > /dev/null 2>&1
  $ diff -u before.thumper fixture.thumper | grep '^[-+][^-+#]'
  -alloc/array	alloc_words	exact	101
  +alloc/array	alloc_words	exact	100
  $ mv before.thumper fixture.thumper

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
tree, as a cram session's is) names the executable from the workspace
root that DUNE_SOURCEROOT names, or absolute without one. The session runs
in dune's sandbox, which is gone after it, so the hint names the
executable's place in the build context.

  $ ROOT=$(dirname "$(dirname "$CONTEXT")")
  $ INSIDE_DUNE="$CONTEXT" DUNE_SOURCEROOT="$ROOT" THUMPER_FIXTURE_MODE=alloc_more $FIX check --quick --baseline alt.thumper -f alloc/list > out.log 2>&1
  [1]
  $ grep -o 'rerun: *[^ ]*' out.log | sed "s|${CONTEXT#$ROOT/}|CONTEXT|"
  rerun:   ./CONTEXT/test/cram/fixture/bench_fixture.exe
  $ INSIDE_DUNE="$CONTEXT" THUMPER_FIXTURE_MODE=alloc_more $FIX check --quick --baseline alt.thumper -f alloc/list > out.log 2>&1
  [1]
  $ grep -o 'rerun: *[^ ]*' out.log | sed "s|$CONTEXT|CONTEXT|"
  rerun:   CONTEXT/test/cram/fixture/bench_fixture.exe
