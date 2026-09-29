A worker that dies is an operational failure, not a verdict: exit 2, a
line naming the case, and no file left behind.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

kill9 mode kills the measuring worker with SIGKILL. The run publishes
nothing: no JSON document, no temporary file.

  $ THUMPER_FIXTURE_MODE=kill9 $FIX check --quick -f err/kill9 --json out.json 2> err.log
  [2]
  $ cat err.log
  thumper: worker for err/kill9 died: killed by SIGKILL
  $ ls -a | grep -e thumper -e json -e '\.tmp$'
  [1]

A case that raises is caught in its worker and named, never a crash of the
run.

  $ THUMPER_FIXTURE_MODE=raise $FIX check --quick -f err/raise 2> err.log
  [2]
  $ cat err.log
  thumper: case err/raise raised: Failure("fixture raise mode")

A case that never returns: under hang mode err/raise spins forever, and
the parent kills its worker at the case's 1 s deadline. The deadline is a
cap on damage, not a timing claim; the session asserts that the run ends,
and how.

  $ THUMPER_FIXTURE_MODE=hang $FIX check --quick -f err/raise 2> err.log
  [2]
  $ cat err.log
  thumper: case err/raise exceeded its deadline of 1s
  $ ls -a | grep -e thumper -e '\.tmp$'
  [1]
