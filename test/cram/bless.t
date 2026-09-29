bless writes a corrected file that records this machine's whole section
anew from this run's evidence, improved or not, and never writes the
baseline itself. Exit 0.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

The baseline covers the busy cases alone, and bless records every case:
the section is replaced whole, not advanced row by row.

  $ $FIX check --quick -f busy > /dev/null 2>&1
  $ mv fixture.thumper.corrected fixture.thumper
  $ cp fixture.thumper before.thumper

--force records the section on a loaded host too, and says so in the file;
on a quiet host it changes nothing. The refusal it overrides needs a loaded
host, which no session can arrange.

  $ $FIX bless --quick --force > out.log 2>&1
  $ cmp fixture.thumper before.thumper
  $ head -1 out.log
  thumper: fixture — blessed 7 cases for machine testkey
  $ grep 'accept:' out.log
    accept:  mv $TESTCASE_ROOT/fixture.thumper.corrected $TESTCASE_ROOT/fixture.thumper

The corrected file is one section for this machine, with every case's rows.

  $ grep -c '^# machine: ' fixture.thumper.corrected
  1
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

In a rule action (INSIDE_DUNE set, the working directory in the build tree,
as a cram session's is) the accept line is dune promote.

  $ rm fixture.thumper.corrected
  $ INSIDE_DUNE="$CONTEXT" $FIX bless --quick --force --color never > out.log 2>&1
  $ grep 'accept:' out.log
    accept:  dune promote

A filtered bless re-records the selected cases only: the section's header,
its earlier annotations and every unselected row keep their bytes, and the
report warns about nothing, since nothing is dropped. The section gets an
earlier annotation of its own, so its survival shows.

  $ grep -v '^# forced:' fixture.thumper.corrected | awk '{ print } /^# ocaml: / { print "# forced: an earlier note" }' > fixture.thumper
  $ rm fixture.thumper.corrected
  $ $FIX bless --quick --force -f busy > out.log 2>&1
  $ head -1 out.log
  thumper: fixture — blessed 2 cases for machine testkey
  $ grep -c 'unselected' out.log
  0
  [1]
  $ grep '^# forced:' fixture.thumper.corrected | head -1
  # forced: an earlier note
  $ grep -v '^busy/' fixture.thumper > kept.before
  $ grep -v '^busy/' fixture.thumper.corrected | grep -v '^# forced: blessed ' > kept.after
  $ cmp kept.before kept.after
  $ grep '^busy/' fixture.thumper.corrected | cut -f 1,2
  busy/half	alloc_words
  busy/half	wall_time
  busy/spin	alloc_words
  busy/spin	wall_time

On a loaded host --force adds a forced: line naming the blessed cases, below
the earlier annotation; a quiet host records none. No other line appears.

  $ grep '^# forced:' fixture.thumper.corrected | grep -Ev '^# forced: (an earlier note|blessed busy/spin busy/half under load [0-9.]+ on [0-9]+ cores)$'
  [1]
