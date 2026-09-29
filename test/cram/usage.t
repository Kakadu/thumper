A usage error exits 2 with its reason and the usage line on stderr, and
nothing on stdout. A mistyped option names the nearest one, and windtrap's
-l and -u name the subcommands that do their work here. -h and -V print on
stdout and exit 0. Which flags are refused where is test_cli's; this
session pins the streams and the codes.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX --nope > /dev/null
  thumper: unknown option '--nope'
  usage: bench_fixture.exe [check|bless|list] [OPTIONS] [PATTERN...]
  [2]
  $ $FIX --quik > /dev/null
  thumper: unknown option '--quik'; did you mean '--quick'?
  usage: bench_fixture.exe [check|bless|list] [OPTIONS] [PATTERN...]
  [2]
  $ $FIX -l > /dev/null
  thumper: unknown option '-l'; did you mean 'list'?
  usage: bench_fixture.exe [check|bless|list] [OPTIONS] [PATTERN...]
  [2]
  $ $FIX -u > /dev/null
  thumper: unknown option '-u'; did you mean 'bless'?
  usage: bench_fixture.exe [check|bless|list] [OPTIONS] [PATTERN...]
  [2]
  $ $FIX --nope 2> /dev/null
  [2]

  $ $FIX -h > help.txt
  $ grep '^usage:' help.txt
  usage: bench_fixture.exe [check|bless|list] [OPTIONS] [PATTERN...]
  $ $FIX -V | sed -E 's/^thumper [0-9a-z.~+-]+$/thumper VERSION/'
  thumper VERSION

No usage error leaves a file: the command line is read before anything
touches the filesystem.

  $ test ! -e fixture.thumper && echo no-baseline
  no-baseline
