Selection: -f patterns are id substrings, OR'd; --tag is
exact tag membership, AND'd; the two compose as AND of (OR ids) and tags.
An empty selection is exit 2 — a broken filter must not silently pass.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

list prints the selected case ids without measuring.

  $ $FIX list
  busy/spin
  busy/half
  alloc/list
  alloc/array
  err/raise
  err/kill9
  nondet/flip

-f substrings are OR'd.

  $ $FIX list -f spin -f flip
  busy/spin
  nondet/flip

--tag is exact membership; repeated tags are a conjunction. busy/half
carries both the group's "cpu" tag and its own "lab" tag.

  $ $FIX list --tag lab
  busy/half
  alloc/list
  alloc/array
  $ $FIX list --tag lab --tag cpu
  busy/half

-f and --tag compose: (spin OR half) AND lab.

  $ $FIX list -f spin -f half --tag lab
  busy/half

An empty selection exits 2 wherever it lands, with the reason on stderr,
and writes no baseline.

  $ $FIX check --quick --tag nope > /dev/null
  thumper: no case selected: tag 'nope' matched none of 7 cases
  [2]
  $ $FIX list --tag nope > /dev/null
  thumper: no case selected: tag 'nope' matched none of 7 cases
  [2]
  $ $FIX bless --quick --force --tag nope > /dev/null
  thumper: no case selected: tag 'nope' matched none of 7 cases
  [2]
  $ test ! -e fixture.thumper && echo no-baseline
  no-baseline
