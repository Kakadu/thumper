A usage error exits 2 with its reason and a pointer to -h on stderr, and
nothing on stdout. -h and -V print on stdout and exit 0. Which flags are
refused where is test_cli's; this session pins the streams and the codes.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX --nope > /dev/null
  thumper: unknown option '--nope'
  Try '-h' for usage.
  [2]
  $ $FIX --nope 2> /dev/null
  [2]

  $ $FIX -h > help.txt
  $ grep '^usage:' help.txt
  usage: bench_fixture.exe [check|bless|list] [OPTS] [PATTERN...]
  $ $FIX -V | sed -E 's/^thumper [0-9a-z.~+-]+$/thumper VERSION/'
  thumper VERSION

No usage error leaves a file: the command line is read before anything
touches the filesystem.

  $ test ! -e fixture.thumper && echo no-baseline
  no-baseline
