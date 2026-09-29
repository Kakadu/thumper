A corrupt baseline stops the run with exit 2; it is never read as absent.
A row's stored median must equal the one its samples give, as text, so one
changed digit is corruption.

  $ . ./prelude.sh
  $ FIX=./fixture/bench_fixture.exe

  $ $FIX check --quick -f busy/spin > /dev/null 2>&1
  $ mv fixture.thumper.corrected fixture.thumper

Change the leading digit of the first sampled row's stored median.

  $ awk 'BEGIN { FS = OFS = "\t" }
  >      $3 ~ /^batch=/ && !done {
  >        $5 = ((substr($5, 1, 1) == "9") ? "8" : "9") substr($5, 2)
  >        done = 1
  >      }
  >      { print }' fixture.thumper > doctored
  $ mv doctored fixture.thumper

check stops before measuring: the line names the file and the row, nothing
reads as a first run, and no corrected file is written.

  $ $FIX check --quick 2> err.log
  [2]
  $ sed -E "s/stored median [^ ]+/stored median M/; s/re-derived '[^']*'/re-derived 'R'/" err.log
  thumper: $TESTCASE_ROOT/fixture.thumper: corrupt baseline (line 9): stored median M does not match its samples (re-derived 'R')
  $ test ! -e fixture.thumper.corrected && echo no-corrected-file
  no-corrected-file

bless reads the same file, since it keeps the other machines' sections
byte for byte, so it stops the same way: read as absent, a forced bless
would propose a file without them.

  $ $FIX bless --force --quick 2> err.log
  [2]
  $ sed -E "s/stored median [^ ]+/stored median M/; s/re-derived '[^']*'/re-derived 'R'/" err.log
  thumper: $TESTCASE_ROOT/fixture.thumper: corrupt baseline (line 9): stored median M does not match its samples (re-derived 'R')
  $ test ! -e fixture.thumper.corrected && echo no-corrected-file
  no-corrected-file
