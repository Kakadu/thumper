THUMPER_MACHINE names the baseline's section, as given. A run under a new
key proposes a section of its own, and a bless under it records that
section and leaves every other section as it was, byte for byte.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX bless --quick --force -f busy/spin > /dev/null 2>&1
  $ cp fixture.thumper before.thumper

  $ THUMPER_MACHINE=otherkey $FIX check --quick -f busy/spin > out.log 2>&1
  $ grep -o 'no baseline for machine otherkey' out.log
  no baseline for machine otherkey
  $ THUMPER_MACHINE=otherkey $FIX bless --quick --force -f busy/spin > /dev/null 2>&1

The file holds both sections, sorted by key, and the first machine's
section ("testkey" sorts after "otherkey", so it runs to the end of the
file) is the one recorded before.

  $ grep '^# machine: ' fixture.thumper
  # machine: otherkey
  # machine: testkey
  $ grep -v '^#' fixture.thumper | grep -vc '^$'
  4
  $ sed -n '/^# machine: testkey$/,$p' before.thumper > before.section
  $ sed -n '/^# machine: testkey$/,$p' fixture.thumper > after.section
  $ cmp before.section after.section

An invalid key is refused in one line, exit 2, never measured under: the
key's characters keep the header's grammar free of escapes.

  $ THUMPER_MACHINE='bad key!' $FIX check --quick
  thumper: THUMPER_MACHINE: 'bad key!' (need a non-empty key over [A-Za-z0-9._-])
  [2]
  $ THUMPER_MACHINE='bad key!' $FIX bless --quick
  thumper: THUMPER_MACHINE: 'bad key!' (need a non-empty key over [A-Za-z0-9._-])
  [2]

The key is refused before the lock is taken: with the lock file unusable,
the key is still the error named.

  $ chmod 0666 "locks/thumper-$(id -u).lock"
  $ THUMPER_MACHINE='bad key!' $FIX check --quick
  thumper: THUMPER_MACHINE: 'bad key!' (need a non-empty key over [A-Za-z0-9._-])
  [2]
