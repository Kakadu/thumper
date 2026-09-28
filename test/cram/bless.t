bless writes a candidate re-recording this machine's
whole section from this run's evidence — intentionally non-monotone — and
prints the same report shape as check: header, a table of proposed rows,
the accept prompt. The baseline itself is never written. Exit 0.

  $ export THUMPER_MACHINE=testkey
  $ mkdir -p locks && export THUMPER_LOCK_DIR="$PWD/locks"
  $ unset INSIDE_DUNE
  $ unset GITHUB_ACTIONS
  $ FIX=./fixture/bench_fixture.exe

Bootstrap a baseline covering only the busy group; bless then re-records
the full suite, proving the section is replaced wholesale rather than
ratcheted per row.

  $ $FIX check --quick -f busy > /dev/null 2>&1
  $ mv fixture.thumper.corrected fixture.thumper
  $ cp fixture.thumper before.thumper

(--wait-quiet rides out ambient load spikes; --force keeps the scenario
deterministic if the host stays loaded — the unforced refusal needs a
reliably loaded host, which no cram test can arrange. Under a quiet gate
--force is a no-op.)

  $ $FIX bless --quick --wait-quiet 5 --force > out.log 2>&1
  $ test -f fixture.thumper.corrected && echo candidate
  candidate
  $ cmp -s fixture.thumper before.thumper && echo baseline-untouched
  baseline-untouched

The report: the bless header, one proposed row per case, the accept
command naming the candidate (unstaged run: the mv spelling, absolute
paths).

  $ grep -c 'fixture — blessed 6 cases for machine testkey' out.log
  1
  $ grep -Ec '^  proposed ' out.log
  6
  $ grep -Eq 'accept:  mv /.*/fixture.thumper.corrected /.*/fixture.thumper' out.log && echo names-candidate
  names-candidate

The candidate is one complete section for this machine.

  $ grep -c '^# machine: testkey$' fixture.thumper.corrected
  1
  $ grep -v '^#' fixture.thumper.corrected | grep -vc '^$'
  12

The dune-promote hint needs both INSIDE_DUNE and a cwd inside the build
tree (a rule action, where diff? stages a promotion — dune exec sets
INSIDE_DUNE but stages nothing and gets the mv hint); cram runs inside
_build, so setting the variable here satisfies both. Wording only — never
behavior.

  $ rm fixture.thumper.corrected
  $ INSIDE_DUNE=1 $FIX bless --quick --wait-quiet 5 --force --color never > out2.log 2>&1
  $ test -f fixture.thumper.corrected && echo candidate
  candidate
  $ grep -q 'accept:  dune promote' out2.log && echo dune-hint
  dune-hint

A filtered bless on a current section re-records the selected cases only:
the section header, its earlier annotations, and every unselected row keep
their bytes, the selected cases' rows are replaced, and the report warns
about nothing, since nothing is dropped. The corrected file's diff is the
review. The committed section gets one earlier annotation of its own (in
place of whatever the full bless recorded), so its survival is visible.

  $ grep -v '^# forced:' fixture.thumper.corrected | awk '{ print } /^# ocaml: / { print "# forced: an earlier note" }' > fixture.thumper
  $ rm fixture.thumper.corrected
  $ $FIX bless --quick --wait-quiet 5 --force --color never -f busy > out3.log 2>&1
  $ grep -c 'fixture — blessed 2 cases for machine testkey' out3.log
  1
  $ grep -c 'unselected' out3.log
  0
  [1]
  $ grep '^# forced:' fixture.thumper.corrected | head -1
  # forced: an earlier note
  $ grep -v '^busy/' fixture.thumper > kept.before
  $ grep -v '^busy/' fixture.thumper.corrected | grep -v '^# forced: blessed ' > kept.after
  $ cmp -s kept.before kept.after && echo unselected-rows-and-header-kept
  unselected-rows-and-header-kept
  $ grep -c '^busy/' fixture.thumper.corrected
  4

On a loaded host, --force appends a forced: line naming the blessed
cases, below the earlier annotation (a quiet host records none).

  $ grep '^# forced:' fixture.thumper.corrected | grep -Ev '^# forced: (an earlier note|blessed busy/spin busy/half under load [0-9.]+ on [0-9]+ cores)$'
  [1]
