bless records the selected cases in this machine's section of the
baseline, improved or not, and is the only subcommand that writes it.
Exit 0.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

--force records on a loaded host too and says so in the file; on a quiet
host it changes nothing. The refusal it overrides needs a loaded host,
which no session can arrange. A first bless of the busy cases records
their rows alone.

  $ $FIX bless --quick --force -f busy > out.log 2>&1
  $ head -1 out.log
  thumper: fixture — blessed 2 cases into $TESTCASE_ROOT/fixture.thumper for machine testkey
  $ grep -c 'accept:' out.log
  0
  [1]
  $ grep -v '^#' fixture.thumper | grep -v '^$' | cut -f 1,2
  busy/half	alloc_words
  busy/half	wall_time
  busy/spin	alloc_words
  busy/spin	wall_time

A bless of every case replaces the section whole, one section for this
machine with every case's rows.

  $ $FIX bless --quick --force > out.log 2>&1
  $ head -1 out.log
  thumper: fixture — blessed 7 cases into $TESTCASE_ROOT/fixture.thumper for machine testkey
  $ grep -c '^# machine: ' fixture.thumper
  1
  $ grep -v '^#' fixture.thumper | grep -v '^$' | cut -f 1,2
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

A filtered bless re-records the selected cases only: the section's header,
its earlier annotations and every unselected row keep their bytes, the row
of a case the suite no longer has (zz/lost) included. The section gets an
earlier annotation of its own, so its survival shows.

  $ grep -v '^# forced:' fixture.thumper | sed 's/^nondet\/flip/zz\/lost/' | awk '{ print } /^# ocaml: / { print "# forced: an earlier note" }' > edited
  $ mv edited fixture.thumper
  $ grep -v '^busy/' fixture.thumper > kept.before
  $ $FIX bless --quick --force -f busy > out.log 2>&1
  $ head -1 out.log
  thumper: fixture — blessed 2 cases into $TESTCASE_ROOT/fixture.thumper for machine testkey
  $ grep '^# forced:' fixture.thumper | head -1
  # forced: an earlier note
  $ grep -v '^busy/' fixture.thumper | grep -v '^# forced: blessed ' > kept.after
  $ cmp kept.before kept.after
  $ grep '^busy/' fixture.thumper | cut -f 1,2
  busy/half	alloc_words
  busy/half	wall_time
  busy/spin	alloc_words
  busy/spin	wall_time

On a loaded host --force adds a forced: line naming the blessed cases, below
the earlier annotation; a quiet host records none. No other line appears.

  $ grep '^# forced:' fixture.thumper | grep -Ev '^# forced: (an earlier note|blessed busy/spin busy/half under load [0-9.]+ on [0-9]+ cores)$'
  [1]

A bless of every case replaces the section, so the rows of the case the
suite lost are removed with the earlier annotation.

  $ $FIX bless --quick --force > /dev/null 2>&1
  $ grep -c -e '^zz/lost' -e 'an earlier note' fixture.thumper
  0
  [1]
