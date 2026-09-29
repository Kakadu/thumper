# Command line

A benchmark executable reads a subcommand, flags and patterns. This page
shows its help, how it selects cases and how it reads its arguments. The
exit codes, the files and the environment are `run`'s contract in
[`lib/thumper.mli`](../../lib/thumper.mli).

## Synopsis

`-h` prints the subcommands, every flag and the environment variables. The
transcripts on this page run examples from `examples/` as a project's
`bench/` directory, where `dune exec` passes the arguments after its own
`--` to the executable:

```
$ dune exec bench/bench_hello.exe -- -h
bench_hello.exe: thumper benchmark suite (thumper dev)

usage: bench_hello.exe [check|bless|list] [OPTS] [PATTERN...]

subcommands:
  check      measure, compare against the baseline (default)
  bless      propose a re-record of the selected cases for this machine
  list       print the selected case ids; no measurement

options:
  -f PAT             select cases whose id contains PAT (repeatable,
                     OR'd); bare PATTERN arguments mean the same
  --tag T            select cases tagged T (repeatable, AND'd)
  --quick            quick protocol (fewer samples)
  --precise          precise protocol (more samples)
  --baseline PATH    baseline file (default: <suite>.thumper next to
                     the benchmark's source)
  --json PATH        check: write the verdict document to PATH
  --strict           check: inconclusive, proposed, and stale exit 1
  --wait-quiet SECS  wait up to SECS for a quiet host before measuring
  --force            bless despite a loaded host (recorded)
  --color MODE       color the report: auto (default), always, never
  -h, --help         show this help
  -V, --version      print the version

environment: THUMPER_MACHINE (machine key), THUMPER_LOCK_DIR (lock
directory), NO_COLOR, GITHUB_ACTIONS (adds ::error:: annotations);
INSIDE_DUNE selects the dune hints and, in a rule action, colour.
```

## Subcommands

The first argument names the subcommand, and a run that names none is
`check`. A subcommand word in any other position is a pattern: `list
bless` lists the cases whose id contains `bless`.

What each subcommand does, and which flags it takes, is under Running
benchmarks in [`lib/thumper.mli`](../../lib/thumper.mli). A flag given to
a subcommand that does not take it is a usage error ([errors](#errors)).

## Selecting cases

`-f PAT` and a bare `PAT` select the cases whose id contains `PAT`,
case-sensitively, and a case matching any of several patterns is selected.
The ids of `examples/05-tags` are listed first, then those containing
`256` or `md5/4`:

```
$ dune exec bench/bench_tags.exe -- list
scan/4-KiB
scan/256-KiB
md5/4-KiB
md5/256-KiB
$ dune exec bench/bench_tags.exe -- list 256 -f md5/4
scan/256-KiB
md5/4-KiB
md5/256-KiB
```

`--tag T` selects the cases tagged `T`, and with several tags a case needs
every one. Given both patterns and tags, a case is selected when it
matches some pattern and carries every tag. In the example, the `md5`
group's tag `digest` reaches both its cases:

```
$ dune exec bench/bench_tags.exe -- list --tag digest --tag large
md5/256-KiB
$ dune exec bench/bench_tags.exe -- list scan --tag large
scan/256-KiB
```

Every subcommand selects the same way. A selection that matches no case
stops the run with exit 2:

```
$ dune exec bench/bench_tags.exe -- list nope
thumper: no case matches 'nope'
$ echo $?
2
```

## Syntax

- Flags and patterns may come in any order after the subcommand.
- `--` ends the flags, and every argument after it is a pattern.
- A long flag that takes a value accepts it after `=`, as
  `--baseline=bench/digest.thumper`. On a flag that takes none, as
  `--strict=no`, the `=` is a usage error.
- A flag that takes a value keeps its last one when given twice, while
  `-f` and `--tag` accumulate.
- An argument that starts with `-` and names no flag is a usage error. A
  lone `-` is a pattern.
- `--wait-quiet` takes a number of seconds, zero or more, and `--json -` is
  a usage error.
- `-h` and `-V` ignore the arguments that follow them. They also override
  the usage errors of a flag given to the wrong subcommand and of `--quick`
  with `--precise`, but not an unknown flag or a missing or malformed value
  before them.

## Errors

A usage error prints the problem and a pointer to `-h` on stderr, and exits
2 before measuring or touching a file:

```
$ dune exec bench/bench_hello.exe -- bless --json v.json
thumper: option '--json' applies to check, not bless
Try '-h' for usage.
$ echo $?
2
```

A run that stops for another reason prints its one `thumper:` line
([stderr](report.md#stderr)).

## Version

`-V` prints the version of thumper the executable was built with:

```
$ dune exec bench/bench_hello.exe -- -V
thumper dev
```
