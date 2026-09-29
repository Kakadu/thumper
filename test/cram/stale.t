A stale section: its '# ocaml:' identity is not the running compiler's.
The run compares nothing, proposes every row and exits 0, so a compiler
upgrade is re-recorded by a bless, never by a check that fails on noise.
Under --strict, stale is a failure.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX bless --quick --force > /dev/null 2>&1
  $ sed 's/^# ocaml: .*/# ocaml: 9.9.9 · 64-bit · release/' fixture.thumper > doctored
  $ mv doctored fixture.thumper
  $ cp fixture.thumper before.thumper

  $ $FIX check --quick > out.log 2>&1
  $ head -1 out.log | sed 's/→ .*)$/→ OCAML)/'
  fixture: stale baseline for machine testkey (ocaml 9.9.9 · 64-bit · release → OCAML)
  $ grep 'accept:' out.log
  accept: ./fixture/bench_fixture.exe bless --quick
  $ summary out.log
  7 proposed in DURATION.
  $ cmp fixture.thumper before.thumper

  $ $FIX check --quick --strict > out.log 2>&1
  [1]

A filtered check's accept line names its selection, and a bless of it
records the section whole, with the running compiler's identity and the
selected case's rows alone.

  $ $FIX check --quick -f busy/spin > out.log 2>&1
  $ grep 'accept:' out.log
  accept: ./fixture/bench_fixture.exe bless --quick -f busy/spin
  $ $FIX bless --quick --force -f busy/spin > /dev/null 2>&1
  $ grep -c '9\.9\.9' fixture.thumper
  0
  [1]
  $ grep -c '^# ocaml: ' fixture.thumper
  1
  $ grep -v '^#' fixture.thumper | grep -v '^$' | cut -f 1,2
  busy/spin	alloc_words
  busy/spin	wall_time
