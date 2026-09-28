# The baseline format

A baseline, `<suite>.thumper` by default, is a text file of measured
evidence with one section per machine key. This page specifies the file
for someone reading its diff and for a tool that reads or writes it. What
a machine key and a stale section are is in the Baselines section of
[`lib/thumper.mli`](../../lib/thumper.mli).

## A complete file

This is the baseline of `examples/02-getting-started/` after its first
run was accepted. The transcripts on this page run the example as a
project's `bench/` directory, and their numbers are one run's.

```
$ cat bench/digest.thumper
# thumper baseline v1
# suite: digest

# machine: 5c1e0a7f3b9d2486
# host: laptop · Apple M1 Max · arm64 · macos
# ocaml: 5.5.1 · 64-bit · release

fib/10	alloc_words	exact	0
fib/10	wall_time	batch=1048576	n=20	6.542e-09	6.480e-09 6.485e-09 6.492e-09 6.497e-09 6.497e-09 6.498e-09 6.503e-09 6.507e-09 6.522e-09 6.531e-09 6.553e-09 6.563e-09 6.565e-09 6.566e-09 6.571e-09 6.576e-09 6.576e-09 6.579e-09 6.588e-09 6.590e-09
fib/20	alloc_words	exact	0
fib/20	wall_time	batch=524288	n=20	1.082e-08	1.081e-08 1.081e-08 1.081e-08 1.081e-08 1.081e-08 1.082e-08 1.082e-08 1.082e-08 1.082e-08 1.082e-08 1.082e-08 1.083e-08 1.083e-08 1.083e-08 1.084e-08 1.085e-08 1.086e-08 1.086e-08 1.095e-08 1.119e-08
md5/string-64	alloc_words	exact	4
md5/string-64	wall_time	batch=32768	n=20	1.989e-07	1.930e-07 1.964e-07 1.967e-07 1.968e-07 1.970e-07 1.970e-07 1.977e-07 1.986e-07 1.986e-07 1.987e-07 1.990e-07 1.993e-07 1.996e-07 1.996e-07 2.002e-07 2.009e-07 2.014e-07 2.014e-07 2.017e-07 2.041e-07
```

## Grammar

The file is a sequence of lines, each ended by a line feed (LF, byte
`0x0a`). In the grammar below, `LF`, `TAB` and `SP` are the bytes `0x0a`,
`0x09` and `0x20`, a quoted string stands for its bytes, `*x` is zero or
more `x`, `1*x` one or more, and `[x]` an optional `x`.

```
file        = "" / preamble *section
preamble    = "# thumper baseline v1" LF "# suite: " text LF
section     = LF "# machine: " segment LF
              "# host: " text LF
              "# ocaml: " text LF
              *annotation
              [LF 1*row]
annotation  = "# " [text] LF
row         = exact-row / sampled-row
exact-row   = id TAB metric TAB "exact" TAB count LF
sampled-row = id TAB metric TAB "batch=" count TAB "n=" count TAB
              median TAB sample *(SP sample) LF
id          = segment *("/" segment)
metric      = segment
segment     = 1*(ALPHA / DIGIT / "." / "_" / "-")
count       = 1*DIGIT
median      = ["-"] DIGIT "." 3DIGIT "e" ("+" / "-") 2*DIGIT
sample      = 1*(any byte but TAB, SP and LF)
text        = 1*(any byte but LF)
```

`ALPHA` is `A` to `Z` and `a` to `z`, `DIGIT` is `0` to `9`, and `3DIGIT`
is three of them. A sample is a word that OCaml's `float_of_string` reads
as a finite number. The empty
file, of zero bytes, is the baseline with no suite and no section. A file
with a preamble and no section is valid too.

A file that matches the grammar must also satisfy these rules:
- An annotation's text does not start with `machine:`, `host:`, `ocaml:`
  or `suite:`.
- Sections are in strictly ascending byte order of their machine keys.
- The rows of a section are in strictly ascending byte order of their
  ids, and of their metrics for one id, so no two rows share an id and a
  metric.
- A count is at most 4611686018427387903, OCaml's `max_int` on a 64-bit
  host. A `batch=` count is at least 1, and an `n=` count is at least 3.
- A sampled row holds as many samples as its `n=` count.
- A sample is a finite number, and the samples of a row are in ascending
  order; equal samples may follow each other.
- A sampled row's median is the one its samples derive
  ([The median](#the-median)).

A reader ignores one carriage return (CR, byte `0x0d`) before each LF, so
a file with CRLF line endings reads as the same file with LF endings.
Thumper writes LF endings only.

## Sections

A section holds the evidence of one machine. Its three header lines are:
- `# machine:`, the machine key;
- `# host:`, a description of the host that recorded the section;
- `# ocaml:`, the identity of the compiler that built the benchmark.

The machine key is the `THUMPER_MACHINE` value, or 16 lowercase
hexadecimal digits derived as `Baseline.machine_key` in
[`lib/thumper.mli`](../../lib/thumper.mli) says.

The `# host:` line reads `<hostname> · <cpu> · <arch> · <os>`, where each
separator is a space, the middle dot U+00B7 (bytes `0xc2 0xb7`) and a
space. Its fields are:
- `<hostname>`, the host's name;
- `<cpu>`, the CPU model;
- `<arch>`, the output of `uname -m`;
- `<os>`, the output of `uname -s` in lowercase, with `darwin` written
  `macos`.

`<cpu>`, `<arch>` and `<os>` read `unknown` when they cannot be detected,
and a byte below `0x20` in any field is written as a space. Thumper
compares this line with nothing.

The `# ocaml:` line reads `<version> · <bits>-bit · <profile>`. Its fields
are:
- `<version>`, OCaml's version string;
- `<bits>`, the word size;
- `<profile>`, the runtime variant of native code: `release`, `debug` or
  `instrumented`. Bytecode reads `bytecode`, or `bytecode+<variant>` for
  another variant than `release`.

Thumper compares this line byte for byte with the running program's
identity, and a difference makes the section stale.

Other header lines are annotations. Thumper writes one kind, the
`# forced:` line of a `bless --force` on a loaded host. It has two forms:
- `# forced: blessed under load <load> on <cores> cores`, when every case
  was re-recorded;
- `# forced: blessed <id> … under load <load> on <cores> cores`, naming
  the re-recorded cases separated by spaces, when the selection was
  partial.

`<load>` is the load average with one decimal and `<cores>` the host's
core count. Here a forced `bless` re-records this machine's section of a
baseline that also holds a section for the key `ci-macos`:

```
$ dune exec bench/bench_digest.exe -- bless --force
thumper: digest — blessed 3 cases for machine 5c1e0a7f3b9d2486

  proposed  204.70 ns  ±1.9%  4 w  md5/string-64
  proposed    6.57 ns  ±1.9%  0 w  fib/10
  proposed   10.84 ns  ±1.9%  0 w  fib/20

  warning: blessed under load 32.2 on 10 cores (--force recorded)
  accept:  mv bench/digest.thumper.corrected bench/digest.thumper
$ mv bench/digest.thumper.corrected bench/digest.thumper
```

```
$ cat bench/digest.thumper
# thumper baseline v1
# suite: digest

# machine: 5c1e0a7f3b9d2486
# host: laptop · Apple M1 Max · arm64 · macos
# ocaml: 5.5.1 · 64-bit · release
# forced: blessed under load 32.2 on 10 cores

fib/10	alloc_words	exact	0
fib/10	wall_time	batch=1048576	n=20	6.569e-09	6.478e-09 6.480e-09 6.481e-09 6.482e-09 6.484e-09 6.493e-09 6.496e-09 6.497e-09 6.505e-09 6.507e-09 6.632e-09 6.727e-09 6.733e-09 6.734e-09 6.740e-09 6.744e-09 6.745e-09 6.745e-09 6.748e-09 6.773e-09
fib/20	alloc_words	exact	0
fib/20	wall_time	batch=524288	n=20	1.084e-08	1.080e-08 1.081e-08 1.081e-08 1.082e-08 1.082e-08 1.082e-08 1.082e-08 1.083e-08 1.083e-08 1.084e-08 1.084e-08 1.085e-08 1.088e-08 1.098e-08 1.123e-08 1.123e-08 1.123e-08 1.126e-08 1.127e-08 1.132e-08
md5/string-64	alloc_words	exact	4
md5/string-64	wall_time	batch=32768	n=20	2.047e-07	1.967e-07 1.969e-07 1.970e-07 1.970e-07 1.972e-07 1.973e-07 1.979e-07 2.018e-07 2.038e-07 2.047e-07 2.047e-07 2.048e-07 2.048e-07 2.048e-07 2.050e-07 2.050e-07 2.053e-07 2.054e-07 2.058e-07 2.068e-07

# machine: ci-macos
# host: laptop · Apple M1 Max · arm64 · macos
# ocaml: 5.5.1 · 64-bit · release

fib/10	alloc_words	exact	0
fib/10	wall_time	batch=1048576	n=20	6.581e-09	6.560e-09 6.560e-09 6.561e-09 6.562e-09 6.563e-09 6.569e-09 6.570e-09 6.571e-09 6.572e-09 6.580e-09 6.581e-09 6.605e-09 6.610e-09 6.620e-09 6.672e-09 6.684e-09 6.718e-09 6.766e-09 6.775e-09 6.831e-09
fib/20	alloc_words	exact	0
fib/20	wall_time	batch=524288	n=20	1.115e-08	1.086e-08 1.091e-08 1.095e-08 1.095e-08 1.097e-08 1.097e-08 1.102e-08 1.103e-08 1.113e-08 1.115e-08 1.116e-08 1.117e-08 1.117e-08 1.117e-08 1.122e-08 1.126e-08 1.126e-08 1.139e-08 1.144e-08 1.146e-08
md5/string-64	alloc_words	exact	4
md5/string-64	wall_time	batch=32768	n=20	2.013e-07	1.959e-07 1.962e-07 1.963e-07 1.963e-07 1.990e-07 1.993e-07 1.993e-07 1.993e-07 1.994e-07 2.012e-07 2.014e-07 2.031e-07 2.043e-07 2.051e-07 2.054e-07 2.055e-07 2.056e-07 2.058e-07 2.060e-07 2.061e-07
```

A full `bless`, and any write that records a missing or stale section,
replaces the section and drops its annotations. A partial `bless` on a
current section appends its `# forced:` line after them, and `check`
keeps them. The reader accepts any other annotation, and
writes keep it by the same rules.

## Rows

A row holds the evidence of one metric of one case. Its first two fields
are the case id and the metric id, such as `wall_time` or `alloc_words`.

An exact row, `<id> TAB <metric> TAB exact TAB <count>`, holds the
metric's count per call, which the trial proved constant. Only a counter
metric has exact rows; a time metric's rows are always sampled.

A sampled row, `<id> TAB <metric> TAB batch=<k> TAB n=<n> TAB <median>
TAB <samples>`, holds:
- `k`, the batch size: the number of consecutive calls each sample
  timed;
- `n`, the number of samples;
- the median ([The median](#the-median));
- the `n` per-call samples in ascending order, in the metric's unit:
  seconds for a time metric, words for an allocation metric, and a count
  for a collection metric. A sample may be zero or negative.

A row that a confirmed improvement advanced reads `n=40` under
`Config.default` ([`Verdict.corrected`](../../lib/thumper.mli)). A `bless`
writes all of a case's rows at one batch size. The sampled rows of one
case hold different batch sizes when one of them was later advanced at
another.

## The median

The median field is a checksum of the row's samples. For an odd `n` it
is the middle sample; for an even `n` it is `a/2 + b/2`, computed in
double precision, where `a` and `b` are the two middle samples. Both are
printed with C's `%.3e`: a `-` for a negative value, one digit, a point,
three digits, `e`, the exponent's sign and at least two exponent digits,
as in `2.073e-07`.

The reader derives the median from the values of the stored samples and
compares it with the field byte for byte. A difference makes the file
corrupt ([Reading outcomes](#reading-outcomes)).

## Layout

The writer prints the canonical layout: the grammar's lines, counts in
decimal with no leading zero, and each sample printed `%.3e`. The reader
is lenient on counts and samples. It accepts leading zeros in a count,
and any finite sample that OCaml's `float_of_string` reads.

A write keeps every line it does not replace byte for byte, number
spellings included, except that a CR before the line's LF is dropped. The
diff between a baseline and its corrected file therefore shows only the
rows and sections that changed. Which rows a check advances, adds or
removes is `Verdict.corrected`'s contract in
[`lib/thumper.mli`](../../lib/thumper.mli).

## Reading outcomes

| the file at the baseline's path | the run |
| --- | --- |
| is absent | has no section to judge against, and every metric is proposed |
| is empty, or its `# suite:` line names the suite | judges against this machine's section, if the file has one |
| names another suite | stops with exit 2 |
| breaks the format | stops with exit 2, naming the line |
| cannot be read | stops with exit 2, naming the reason |

A file that cannot be read or breaks the format is never taken for an
absent one. Here a median was edited by hand:

```
$ dune exec bench/bench_digest.exe
thumper: bench/digest.thumper: corrupt baseline (line 10): stored median '9.999e-01' does not match its samples (re-derived '6.569e-09')
$ echo $?
2
```

## What tools may build on

A tool may rely on:
- the grammar and rules above, for every file whose first line is
  `# thumper baseline v1`;
- the fields of the header lines, of which thumper reads only the
  machine key and `# ocaml:`;
- the ascending order of samples, rows and sections, and the median rule;
- a write keeping every line it does not replace byte for byte, less a
  CR before its LF.

Which files thumper writes, and when, is under Files in
[`lib/thumper.mli`](../../lib/thumper.mli).
