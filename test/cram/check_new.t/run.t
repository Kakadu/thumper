A missing baseline is never an error: the run measures, proposes every
row, names the bless command that records them, writes no file and exits
0.

  $ . ../prelude.sh
  $ mkdir fixture && cp ../fixture/bench_fixture.exe fixture/
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX check --quick > out.log 2>&1
  $ grep -o 'no baseline for machine testkey' out.log
  no baseline for machine testkey
  $ grep -c '^  proposed ' out.log
  7
  $ grep 'accept:' out.log
  accept: ./fixture/bench_fixture.exe bless --quick
  $ summary out.log
  7 proposed in DURATION.
  $ test ! -e fixture.thumper && echo no-baseline
  no-baseline

Under --strict a first run fails, and still writes nothing.

  $ $FIX check --quick --strict > out.log 2>&1
  [1]
  $ summary out.log
  7 proposed in DURATION; failed under --strict.
  $ test ! -e fixture.thumper && echo no-baseline
  no-baseline

The dune flow, in a nested workspace whose rule runs the executable with
the baseline as a dependency. The first build passes and proposes;
bless, as its accept line names it, records the baseline; the next build
compares, and an unchanged executable and baseline is then a cache hit,
measured no more; a regression fails the build. The rule measures the
alloc cases alone, so every comparison is of exact counts. The build
directory is _build_sys: a rule action finds its files in its working
directory, whatever that directory is called.

  $ WS=$(mktemp -d "${TMPDIR:-/tmp}/thumper-check-new-XXXXXX")
  $ cp workspace/dune workspace/dune-project "$WS/"
  $ cp ../fixture/bench_fixture.exe "$WS/bench.exe"
  $ mkdir "$WS/locks"
  $ cd "$WS"
  $ export DUNE_BUILD_DIR=_build_sys DUNE_CACHE=disabled
  $ export THUMPER_LOCK_DIR="$WS/locks" THUMPER_FIXTURE_RAN_PATH="$WS/ran.log"

The accept line pastes from the workspace root, where dune ran.

  $ dune build --root . @bench > build.log 2>&1
  $ grep -c '^  proposed ' build.log
  2
  $ grep 'accept:' build.log
  accept: ./_build_sys/default/bench.exe bless --quick -f alloc
  $ wc -l < ran.log | tr -d ' '
  1
  $ test ! -e fixture.thumper && echo no-baseline
  no-baseline

bless writes the baseline beside the rule, in the source tree. --force
keeps the session's outcome off the host's load.

  $ ./_build_sys/default/bench.exe bless --quick -f alloc --force > bless.log 2>&1
  $ summary bless.log | sed "s|$(pwd -P)|WS|"
  2 blessed into WS/fixture.thumper in DURATION.
  $ grep -c '^# machine: testkey$' fixture.thumper
  1

  $ dune build --root . @bench > build.log 2>&1
  $ head -1 build.log
  fixture: 2 cases vs fixture.thumper for machine testkey
  $ summary build.log
  2 passed in DURATION.
  $ wc -l < ran.log | tr -d ' '
  3

  $ dune build --root . @bench
  $ wc -l < ran.log | tr -d ' '
  3

Under alloc_more alloc/list allocates a word more per call. Dune does not
track the variable, so --force reruns the alias.

  $ THUMPER_FIXTURE_MODE=alloc_more dune build --root . @bench --force > build.log 2>&1
  [1]
  $ summary build.log
  1 passed, 1 regressed in DURATION.
  $ grep 'rerun:' build.log
  rerun: ./_build_sys/default/bench.exe --quick -f alloc/list

The workspace is outside the session's directory; remove it.

  $ cd / && rm -rf "$WS"
