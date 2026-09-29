A corrupt baseline stops the run with exit 2; it is never read as absent.
A row's stored median must equal the one its samples give, as text, so one
changed digit is corruption.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX bless --quick --force -f busy/spin > /dev/null 2>&1

Drop the line a loaded host's forced bless adds, so the row's line number
is the same on any host, and change the leading digit of the first sampled
row's stored median.

  $ awk 'BEGIN { FS = OFS = "\t" }
  >      $3 ~ /^batch=/ && !done {
  >        $5 = ((substr($5, 1, 1) == "9") ? "8" : "9") substr($5, 2)
  >        done = 1
  >      }
  >      !/^# forced: / { print }' fixture.thumper > doctored
  $ mv doctored fixture.thumper
  $ cp fixture.thumper before.thumper

check stops before measuring: the line names the file and the row, and
nothing reads as a first run.

  $ $FIX check --quick 2> err.log
  [2]
  $ sed -E "s/stored median [^ ]+/stored median M/; s/re-derived '[^']*'/re-derived 'R'/" err.log
  thumper: $TESTCASE_ROOT/fixture.thumper: corrupt baseline (line 9): stored median M does not match its samples (re-derived 'R')

bless reads the same file, since it keeps the other machines' sections
byte for byte, so it stops the same way and leaves the file as it was:
read as absent, a forced bless would write a file without them.

  $ $FIX bless --force --quick 2> err.log
  [2]
  $ sed -E "s/stored median [^ ]+/stored median M/; s/re-derived '[^']*'/re-derived 'R'/" err.log
  thumper: $TESTCASE_ROOT/fixture.thumper: corrupt baseline (line 9): stored median M does not match its samples (re-derived 'R')
  $ cmp fixture.thumper before.thumper
