The exact allocation gate: alloc_more mode allocates
one extra cons cell per call in alloc/list — an exact-integer regression
against the suite's no_more_alloc_than 0.0 pin — while the case's timing,
dominated by fixed busy work, stays equivalent. The exact gate fails the
build even when time passes; determinism owes nothing to load.

  $ export THUMPER_MACHINE=testkey
  $ mkdir -p locks && export THUMPER_LOCK_DIR="$PWD/locks"
  $ unset INSIDE_DUNE
  $ unset GITHUB_ACTIONS
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX check --quick -f alloc > /dev/null 2>&1
  $ mv fixture.thumper.corrected fixture.thumper

The bootstrapped row is proven exact evidence, not a sampled vector.

  $ awk -F'\t' '$1 == "alloc/list" && $2 == "alloc_words" { print $3 }' fixture.thumper
  exact

  $ THUMPER_FIXTURE_MODE=alloc_more $FIX check --quick -f alloc > out.log 2>&1
  [1]
  $ grep -Eq 'alloc/list .*REGRESSED alloc' out.log && echo alloc-gated
  alloc-gated
  $ grep -q '(exact)' out.log && echo integer-compared
  integer-compared
  $ grep -c '1 case: 0 passed, 1 regressed.' out.log
  1
  $ test ! -e fixture.thumper.corrected && echo no-candidate
  no-candidate

The mirror image ratchets, equally load-immune: fast mode against an
alloc_more baseline is an exact allocation improvement, confirmed by
integers alone (no CI, no confirmation pass), and the candidate
advances exactly that one row.

  $ rm fixture.thumper
  $ THUMPER_FIXTURE_MODE=alloc_more $FIX check --quick -f alloc > /dev/null 2>&1
  $ mv fixture.thumper.corrected fixture.thumper
  $ $FIX check --quick -f alloc > out2.log 2>&1
  $ test -f fixture.thumper.corrected && echo candidate
  candidate
  $ diff fixture.thumper fixture.thumper.corrected | grep '^[<>]' | cut -f1,2 | sed 's/^[<>] //' | sort -u | tr '\t' ' '
  alloc/list alloc_words

The rerun hint is the exact command (getting-started): the preset and an
explicit --baseline are reproduced, so the pasted command measures under
the same protocol and judges the same ruler — without --baseline, a rerun
from the same shell would resolve the default path and judge a different
file.

  $ mv fixture.thumper.corrected alt.thumper
  $ THUMPER_FIXTURE_MODE=alloc_more $FIX check --quick --baseline alt.thumper -f alloc > out4.log 2>&1
  [1]
  $ grep -q 'rerun:.*bench_fixture.exe --quick --baseline alt.thumper -f alloc/list$' out4.log && echo hint-carries-preset-and-baseline
  hint-carries-preset-and-baseline

Under a dune rule action (INSIDE_DUNE set and the cwd in the build tree,
as cram's is) there is no rerun line: its exe path is relative to the
action's cwd and could not be pasted. The failing id stays in the table.

  $ INSIDE_DUNE=1 THUMPER_FIXTURE_MODE=alloc_more $FIX check --quick --baseline alt.thumper -f alloc > out5.log 2>&1
  [1]
  $ grep -c 'rerun:' out5.log
  0
  [1]
  $ grep -Eq 'alloc/list .*REGRESSED alloc' out5.log && echo failing-id-in-table
  failing-id-in-table
