--json PATH writes the verdict document when measurement completes, whether
the run passes or fails, and leaves nothing behind otherwise. The document's
fields are test_verdict's; this session pins the file, and that the
document's overall outcome, its first field, and its machine are this
run's.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX check --quick -f alloc > /dev/null 2>&1
  $ mv fixture.thumper.corrected fixture.thumper

A passing run writes the document: one line, ended by a newline, published
whole through a temporary file that does not survive.

  $ $FIX check --quick -f alloc --json out.json > /dev/null 2>&1
  $ wc -l < out.json | tr -d ' '
  1
  $ grep -o '^{"overall":"[a-z]*"' out.json
  {"overall":"pass"
  $ grep -o '"machine":"[a-z]*"' out.json
  "machine":"testkey"
  $ ls -a | grep -c '\.tmp$'
  0
  [1]

A failing run completed its measurement, so it writes the document too.

  $ rm out.json
  $ THUMPER_FIXTURE_MODE=alloc_more $FIX check --quick -f alloc --json out.json > /dev/null 2>&1
  [1]
  $ grep -o '^{"overall":"[a-z]*"' out.json
  {"overall":"fail"

A run that stops before measuring removes the document at startup, so no
stale one is read after an exit 2.

  $ echo '{"stale": true}' > out.json
  $ $FIX check --quick --tag nope --json out.json > /dev/null 2>&1
  [2]
  $ test ! -e out.json && echo removed
  removed
