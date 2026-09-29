A missing baseline is never an error: the run measures, proposes the whole
baseline as a corrected file, prints how to accept it, and exits 0.
Accepting it is the review.

  $ . ../prelude.sh
  $ FIX=../fixture/bench_fixture.exe

INSIDE_DUNE with the working directory in the build tree is a rule
action's environment, so the accept line is dune promote.

  $ INSIDE_DUNE="$CONTEXT" $FIX check --quick > out.log 2>&1
  $ grep -o 'no baseline for machine testkey' out.log
  no baseline for machine testkey
  $ grep 'accept:' out.log
    accept:  dune promote

The corrected file is complete: the format and suite headers, this
machine's section, and one row per case and metric, in id then metric
order. The busy cases allocate nothing, and their rows say so exactly.

  $ grep '^#' fixture.thumper.corrected | grep -v '^# host: \|^# ocaml: '
  # thumper baseline v1
  # suite: fixture
  # machine: testkey
  $ grep -c '^# host: \|^# ocaml: ' fixture.thumper.corrected
  2
  $ grep -v '^#' fixture.thumper.corrected | grep -v '^$' | cut -f 1,2
  alloc/array	alloc_words
  alloc/list	alloc_words
  busy/half	alloc_words
  busy/half	wall_time
  busy/spin	alloc_words
  busy/spin	wall_time
  err/kill9	alloc_words
  err/kill9	wall_time
  err/raise	alloc_words
  err/raise	wall_time
  nondet/flip	alloc_words
  nondet/flip	wall_time
  $ grep '^busy/spin	alloc_words' fixture.thumper.corrected
  busy/spin	alloc_words	exact	0

Under --strict a first run fails, since its evidence is unreviewed, but it
still proposes the corrected file: the exit code comes from the verdicts
alone.

  $ rm fixture.thumper.corrected
  $ $FIX check --quick --strict > out.log 2>&1
  [1]
  $ test -f fixture.thumper.corrected && echo corrected-file
  corrected-file

The dune flow, in a nested workspace whose rule measures and then hands
dune the corrected file to diff. The first build proposes the whole file
and fails until someone promotes; promotion turns the next build green; an
unchanged executable and baseline is a cache hit, measured no more. The
rule measures the alloc cases alone, so the second build compares exact
counts. The build directory is _build_sys: a rule action finds its files in
its working directory, whatever that directory is called.

  $ WS=$(mktemp -d "${TMPDIR:-/tmp}/thumper-check-new-XXXXXX")
  $ cp workspace/dune workspace/dune-project "$WS/"
  $ cp ../fixture/bench_fixture.exe "$WS/bench.exe"
  $ mkdir "$WS/locks"
  $ cd "$WS"
  $ export DUNE_BUILD_DIR=_build_sys DUNE_CACHE=disabled
  $ export THUMPER_LOCK_DIR="$WS/locks" THUMPER_FIXTURE_RAN_PATH="$WS/ran.log"

  $ dune build --root . @bench > build.log 2>&1
  [1]
  $ grep -c '^  proposed ' build.log
  2
  $ wc -l < ran.log | tr -d ' '
  1
  $ test ! -e fixture.thumper && echo no-baseline
  no-baseline
  $ dune promotion apply --root .
  Promoting _build_sys/default/fixture.thumper.corrected to fixture.thumper.
  $ grep -c '^# machine: testkey$' fixture.thumper
  1

  $ dune build --root . @bench > build.log 2>&1
  $ head -1 build.log
  thumper: fixture — 2 cases vs fixture.thumper for machine testkey
  $ grep -o '2 cases: .*' build.log
  2 cases: 2 passed.
  $ wc -l < ran.log | tr -d ' '
  2
  $ dune promotion diff --root .

  $ dune build --root . @bench
  $ wc -l < ran.log | tr -d ' '
  2

The workspace is outside the session's directory; remove it.

  $ cd / && rm -rf "$WS"
