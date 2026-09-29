The measurement lock: every measuring run, check and bless, holds a lockf
lock on THUMPER_LOCK_DIR/thumper-<euid>.lock. The file is created 0600 and
kept between runs, since unlinking a lock file lets two holders in, and a
lock that cannot be used stops the run with exit 2.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe
  $ EUID_LOCK="locks/thumper-$(id -u).lock"

A measuring run creates the lock file, mode 0600, named by the effective
uid. A second run takes it again: the forked workers inherited the
descriptor, not the lock.

  $ $FIX check --quick -f busy/spin > /dev/null 2>&1
  $ ls locks | sed "s/-$(id -u)\./-EUID./"
  thumper-EUID.lock
  $ ls -l "$EUID_LOCK" | cut -c 1-10
  -rw-------
  $ $FIX check --quick -f busy/spin > /dev/null 2>&1

A lock file whose mode is broader than 0600 is refused on stderr.

  $ chmod 0666 "$EUID_LOCK"
  $ $FIX check --quick -f busy/spin 2> err.log
  [2]
  $ sed "s/-$(id -u)\./-EUID./" err.log
  thumper: measurement lock unusable: $TESTCASE_ROOT/locks/thumper-EUID.lock permissions are broader than 0600

So is a directory at the lock's path.

  $ rm "$EUID_LOCK"
  $ mkdir "$EUID_LOCK"
  $ $FIX check --quick -f busy/spin 2> err.log
  [2]
  $ sed "s/-$(id -u)\./-EUID./" err.log
  thumper: measurement lock unusable: cannot open $TESTCASE_ROOT/locks/thumper-EUID.lock: Is a directory

So is a symbolic link, and nothing is created through it: in a shared lock
directory, a planted link must not create a file of the planter's choice.

  $ rmdir "$EUID_LOCK"
  $ ln -s "$PWD/elsewhere" "$EUID_LOCK"
  $ $FIX check --quick -f busy/spin 2> err.log
  [2]
  $ sed "s/-$(id -u)\./-EUID./" err.log
  thumper: measurement lock unusable: cannot open $TESTCASE_ROOT/locks/thumper-EUID.lock: File exists
  $ test ! -e elsewhere && echo not-created-through
  not-created-through

Contention: while another process holds the lock, a run waits and says so.
The holder creates held once it holds the lock and releases it when release
appears, so the waiter starts only after the lock is taken, and the holder
lets go only after the waiter has printed its line.

  $ rm "$EUID_LOCK"
  $ ./fixture/hold_lock.exe held release &
  $ HOLDER=$!
  $ wait_for test -e held
  $ $FIX check --quick -f busy/spin > /dev/null 2> err.log &
  $ WAITER=$!
  $ wait_for grep -qs 'waiting for the measurement lock' err.log
  $ touch release
  $ wait $HOLDER
  $ wait $WAITER
  $ grep 'measurement lock' err.log
  thumper: waiting for the measurement lock (another run is measuring) ...
