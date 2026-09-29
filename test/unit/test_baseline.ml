(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Files are literals, written under the test's own directory where a claim
   needs one on disk. A refused text is pinned by the whole message that
   [pp_error] prints, its line included. The atomic write is [Os]'s, and
   test_os pins it. *)

open Windtrap
module Baseline = Thumper.Private.Baseline

let file lines = String.concat "\n" lines ^ "\n"

(* The complete file of doc/manual/baseline-format.md, with its sample
   vectors. *)
let sample =
  file
    [
      "# thumper baseline v1";
      "# suite: digest";
      "";
      "# machine: 9f3a1c2e8b4d6a07";
      "# host: mbp-tmattio · Apple M1 Max · arm64 · macos";
      "# ocaml: 5.5.0 · 64-bit · release";
      "";
      "sha256/incremental-1mib\talloc_words\texact\t399";
      "sha256/incremental-1mib\twall_time\tbatch=1\tn=20\t5.063e-03\t5.021e-03 \
       5.024e-03 5.028e-03 5.031e-03 5.035e-03 5.039e-03 5.044e-03 5.049e-03 \
       5.054e-03 5.060e-03 5.066e-03 5.073e-03 5.081e-03 5.090e-03 5.101e-03 \
       5.115e-03 5.133e-03 5.158e-03 5.197e-03 5.288e-03";
      "sha256/string-64\talloc_words\texact\t54";
      "sha256/string-64\twall_time\tbatch=8192\tn=20\t6.911e-07\t6.883e-07 \
       6.887e-07 6.888e-07 6.891e-07 6.893e-07 6.898e-07 6.901e-07 6.904e-07 \
       6.907e-07 6.910e-07 6.913e-07 6.917e-07 6.921e-07 6.926e-07 6.930e-07 \
       6.942e-07 6.958e-07 6.977e-07 7.012e-07 7.084e-07";
    ]

let sample_machine = "9f3a1c2e8b4d6a07"
let preamble = [ "# thumper baseline v1"; "# suite: s"; "" ]

(* One section, key [key], with a header and [rows]. *)
let with_rows rows =
  file (preamble @ [ "# machine: key"; "# host: h"; "# ocaml: o"; "" ] @ rows)

let printed = Baseline.to_string
let error_text e = Format.asprintf "%a" Baseline.pp_error e
let parsed text = require_ok ~pp:Baseline.pp_error (Baseline.of_string text)
let reprinted text = printed (parsed text)

let refused text =
  error_text
    (require_error
       ~pp:(fun ppf t -> Format.fprintf ppf "%S" (printed t))
       (Baseline.of_string text))

let section t key = require_some (Baseline.section t key)

let identity key =
  {
    Baseline.machine = key;
    host = "mbp-test · Apple M1 · arm64 · macos";
    ocaml = "5.5.0 · 64-bit · release";
  }

let empty = Baseline.empty ~suite:"s"
let with_section key rows t = Baseline.set_section t (identity key) rows
let exact ?(metric = "m") id n = Baseline.exact_row ~id ~metric n

let sampled ?(metric = "m") ?(k = 1) id samples =
  Baseline.sampled_row ~id ~metric ~k ~samples

(* Evidence as the file writes it, the samples in hexadecimal, so two print
   alike only when they are equal. *)
let evidence =
  Testable.contramap
    (function
      | Baseline.Exact_int n -> Printf.sprintf "exact %d" n
      | Baseline.Sampled { k; samples } ->
          Printf.sprintf "batch=%d %s" k
            (String.concat " "
               (List.map (Printf.sprintf "%h") (Array.to_list samples))))
    string

let key r = (Baseline.row_id r, Baseline.row_metric r)
let keys s = List.map key (Baseline.rows s)

let row =
  Testable.contramap
    (fun r -> (key r, Baseline.row_evidence r))
    (pair (pair string string) evidence)

(* The text after the last line break of [text]'s body: its last row. *)
let last_line text =
  List.nth
    (String.split_on_char '\n' text)
    (List.length (String.split_on_char '\n' text) - 2)

(* Generators *)

let gen_segment =
  Gen.string_of ~size:(Gen.int_range 1 5)
    (Gen.of_list [ 'a'; 'b'; 'z'; 'A'; '0'; '9'; '.'; '_'; '-' ])

let gen_id =
  Gen.map (String.concat "/") (Gen.list ~size:(Gen.int_range 1 3) gen_segment)

let gen_key =
  Gen.string_of ~size:(Gen.int_range 1 16)
    (Gen.of_list [ '0'; '1'; '9'; 'a'; 'f' ])

let gen_samples =
  Gen.map
    (fun l ->
      let a = Array.of_list l in
      Array.sort Float.compare a;
      a)
    (Gen.list ~size:(Gen.int_range 3 12) (Gen.float_range 1e-9 1.0))

let gen_row =
  let open Gen in
  let* id = gen_id in
  let* metric = of_list [ "wall_time"; "cpu_time"; "alloc_words" ] in
  let* is_exact = bool in
  if is_exact then
    let+ n = int_range 0 1_000_000 in
    exact ~metric id n
  else
    let* k = int_range 1 10_000 in
    let+ samples = gen_samples in
    sampled ~metric ~k id samples

(* The first row of each (id, metric). *)
let distinct rows =
  List.rev
    (List.fold_left
       (fun acc r ->
         if List.exists (fun r' -> key r' = key r) acc then acc else r :: acc)
       [] rows)

let gen_section =
  let open Gen in
  let* host = of_list [ "mbp · Apple M1 · arm64 · macos"; "ci x86_64"; "h" ] in
  let* ocaml = of_list [ "5.5.0 · 64-bit · release"; "5.4.0 · 32-bit" ] in
  let* annotations =
    list ~size:(int_range 0 2) (of_list [ "forced"; "note x" ])
  in
  let+ rows = list ~size:(int_range 0 6) gen_row in
  fun key t ->
    Baseline.set_section ~annotations t
      { Baseline.machine = key; host; ocaml }
      (distinct rows)

let gen_baseline =
  let open Gen in
  let* suite = of_list [ "digest"; "suite-x"; "s" ] in
  let* keys = list ~size:(int_range 0 4) gen_key in
  let keys = List.sort_uniq String.compare keys in
  let+ sections = list ~size:(constant (List.length keys)) gen_section in
  List.fold_left2
    (fun t key add -> add key t)
    (Baseline.empty ~suite) keys sections

let baseline_t =
  Gen.with_pp (fun ppf t -> Format.fprintf ppf "%S" (printed t)) gen_baseline

(* Types, errors and quoting *)

let types =
  group "Types, errors and quoting"
    [
      cases "pp_error prints" ~name:fst
        [
          ( "a corrupt file's line and reason",
            ( Baseline.Corrupt { line = 3; reason = "boom" },
              "corrupt baseline (line 3): boom" ) );
          ( "an Io message as it is",
            (Baseline.Io "cannot read p: boom", "cannot read p: boom") );
        ]
        (fun (_, (e, text)) -> equal string text (error_text e));
      test "an uncaught Error prints its text" (fun () ->
          equal string "Thumper.Baseline.Error: corrupt baseline (line 3): boom"
            (Printexc.to_string
               (Baseline.Error (Baseline.Corrupt { line = 3; reason = "boom" }))));
      cases "quote" ~name:fst
        [
          ("an empty string", ("", "''"));
          ("a plain string", ("a b/c", "'a b/c'"));
          ( "control bytes and DEL as \\xNN",
            ( "\027]0;x\007\r\n\t\031\127",
              {|'\x1b]0;x\x07\x0d\x0a\x09\x1f\x7f'|} ) );
          ( "UTF-8 as it is",
            ("\xc2\xb1 \xe2\x80\x94", "'\xc2\xb1 \xe2\x80\x94'") );
        ]
        (fun (_, (s, quoted)) -> equal string quoted (Baseline.quote s));
    ]

(* Identifiers *)

let identifiers =
  group "Identifiers"
    [
      test "is_id_char accepts [A-Za-z0-9._-] and nothing else" (fun () ->
          equal string
            "-.0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz"
            (String.of_seq
               (Seq.filter Baseline.is_id_char
                  (String.to_seq (String.init 256 Char.chr)))));
      cases "valid_segment" ~name:fst
        [
          ("a run of id characters", ("a.B-9_", true));
          ("the empty string", ("", false));
          ("a slash", ("a/b", false));
          ("a space", ("a b", false));
        ]
        (fun (_, (s, valid)) -> equal bool valid (Baseline.valid_segment s));
      cases "check_suite accepts" ~name:fst
        [ ("a name", "digest"); ("a tab and a carriage return", "a\tb\r") ]
        (fun (_, name) -> Baseline.check_suite ~fname:"f" name);
      cases "check_suite refuses, naming fname" ~name:fst
        [ ("an empty name", ""); ("a newline", "two\nlines") ]
        (fun (_, name) ->
          raises
            (Invalid_argument
               "f: suite name must be non-empty and single-line (it heads \
                fresh baselines)") (fun () ->
              Baseline.check_suite ~fname:"f" name));
    ]

(* Reading and printing *)

let the_sample_parses () =
  let t = parsed sample in
  equal (option string) (Some "digest") (Baseline.suite t);
  equal (list string) [ sample_machine ] (Baseline.machines t);
  equal
    (list (pair string string))
    [
      ("sha256/incremental-1mib", "alloc_words");
      ("sha256/incremental-1mib", "wall_time");
      ("sha256/string-64", "alloc_words");
      ("sha256/string-64", "wall_time");
    ]
    (keys (section t sample_machine))

let the_empty_string_has_no_suite_and_no_section () =
  let t = parsed "" in
  equal (option string) None (Baseline.suite t);
  equal (list string) [] (Baseline.machines t)

let accepted =
  [
    ("the manual's file", sample);
    ("the empty string", "");
    ("a section of one row", with_rows [ "a\tm\texact\t1" ]);
    ( "a section without rows",
      file (preamble @ [ "# machine: key"; "# host: h"; "# ocaml: o" ]) );
    ( "a section without rows before another",
      file
        (preamble
        @ [
            "# machine: a";
            "# host: h";
            "# ocaml: o";
            "";
            "# machine: b";
            "# host: h";
            "# ocaml: o";
            "";
            "a\tm\texact\t1";
          ]) );
    ( "annotations",
      file
        (preamble
        @ [
            "# machine: key";
            "# host: h";
            "# ocaml: o";
            "# forced: load 7.9/8";
            "# another note";
            "";
            "a\tm\texact\t1";
          ]) );
    ( "an even count's median, the midpoint of the central samples",
      with_rows
        [
          "a\tm\tbatch=1\tn=4\t2.500e+00\t1.000e+00 2.000e+00 3.000e+00 \
           4.000e+00";
        ] );
    ( "an odd count's median, the central sample",
      with_rows
        [ "a\tm\tbatch=1\tn=3\t2.000e+00\t1.000e+00 2.000e+00 3.000e+00" ] );
    ( "two-digit exponents down at 1e-10",
      with_rows
        [ "a\tm\tbatch=1\tn=3\t2.000e-10\t1.000e-10 2.000e-10 3.000e-10" ] );
    ( "samples spelled other than %.3e",
      with_rows [ "a\tm\tbatch=1\tn=3\t2.000e+00\t1e0 2e0 3e0" ] );
    ( "counts with leading zeros",
      with_rows
        [
          "a\tm\texact\t007";
          "b\tm\tbatch=08\tn=03\t2.000e+00\t1.000e+00 2.000e+00 3.000e+00";
        ] );
  ]

(* A sampled row of [n] samples at batch size 1. *)
let samples_row n median samples =
  Printf.sprintf "a\tm\tbatch=1\tn=%d\t%s\t%s" n median samples

let two_sections a b =
  file
    (preamble
    @ [ "# machine: " ^ a; "# host: h"; "# ocaml: o"; ""; "# machine: " ^ b ])

let header lines = file (preamble @ [ "# machine: k" ] @ lines)

(* The manual's file with its first stored median one digit off. *)
let sample_flipped =
  String.concat "\n"
    (List.map
       (fun line ->
         match String.split_on_char '\t' line with
         | [ id; metric; batch; n; "5.063e-03"; samples ] ->
             String.concat "\t" [ id; metric; batch; n; "5.064e-03"; samples ]
         | _ -> line)
       (String.split_on_char '\n' sample))

let refusals =
  [
    ( "a misspelt format line",
      file [ "# thumper baselin v1"; ""; "# machine: k"; "# host: h" ],
      __POS_OF__
        {| corrupt baseline (line 1): expected '# thumper baseline v1' on the first line |}
    );
    ( "a text that is no baseline",
      "not a baseline\n",
      __POS_OF__
        {| corrupt baseline (line 1): expected '# thumper baseline v1' on the first line |}
    );
    ( "CRLF line endings",
      "# thumper baseline v1\r\n# suite: s\r\n",
      __POS_OF__
        {| corrupt baseline (line 1): expected '# thumper baseline v1' on the first line |}
    );
    ( "the format line alone",
      file [ "# thumper baseline v1" ],
      __POS_OF__ {| corrupt baseline (line 2): expected a '# suite:' line |} );
    ( "no final newline",
      "# thumper baseline v1\n# suite: s",
      __POS_OF__
        {| corrupt baseline (line 2): truncated file: missing final newline |}
    );
    ( "the manual's file without its final newline",
      String.sub sample 0 (String.length sample - 1),
      __POS_OF__
        {| corrupt baseline (line 11): truncated file: missing final newline |}
    );
    ( "an empty suite name",
      file [ "# thumper baseline v1"; "# suite: " ],
      __POS_OF__ {| corrupt baseline (line 2): empty suite name |} );
    ( "a section before the suite line",
      file [ "# thumper baseline v1"; ""; "# machine: k" ],
      __POS_OF__ {| corrupt baseline (line 2): expected a '# suite:' line |} );
    ( "junk for the suite line",
      file [ "# thumper baseline v1"; "junk" ],
      __POS_OF__ {| corrupt baseline (line 2): expected a '# suite:' line |} );
    ( "a row right after the preamble",
      file [ "# thumper baseline v1"; "# suite: s"; "a\tm\texact\t1" ],
      __POS_OF__
        {| corrupt baseline (line 3): expected a blank line before a '# machine:' section |}
    );
    ( "a blank line ending the preamble",
      file preamble,
      __POS_OF__
        {| corrupt baseline (line 3): trailing blank line at end of file |} );
    ( "a blank line ending a section's header",
      file (preamble @ [ "# machine: k"; "# host: h"; "# ocaml: o"; "" ]),
      __POS_OF__
        {| corrupt baseline (line 7): trailing blank line at end of file |} );
    ( "two blank lines before the rows",
      file
        (preamble
        @ [
            "# machine: k"; "# host: h"; "# ocaml: o"; ""; ""; "a\tm\texact\t1";
          ]),
      __POS_OF__ {| corrupt baseline (line 8): unexpected blank line |} );
    ( "a blank line between rows",
      with_rows [ "a\tm\texact\t1"; ""; "b\tm\texact\t2" ],
      __POS_OF__
        {| corrupt baseline (line 10): expected a '# machine:' section header |}
    );
    ( "a comment among rows",
      with_rows [ "a\tm\texact\t1"; "# note" ],
      __POS_OF__ {| corrupt baseline (line 9): unexpected comment among rows |}
    );
    ( "rows right after the header",
      file
        (preamble
        @ [ "# machine: k"; "# host: h"; "# ocaml: o"; "a\tm\texact\t1" ]),
      __POS_OF__
        {| corrupt baseline (line 7): expected a blank line before the section's rows |}
    );
    ( "a machine key with a space",
      file (preamble @ [ "# machine: has space" ]),
      __POS_OF__
        {| corrupt baseline (line 4): invalid machine key 'has space' (must be [A-Za-z0-9._-]+) |}
    );
    ( "an empty machine key",
      file (preamble @ [ "# machine: " ]),
      __POS_OF__
        {| corrupt baseline (line 4): invalid machine key '' (must be [A-Za-z0-9._-]+) |}
    );
    ( "a machine key holding control bytes",
      file
        (preamble
        @ [
            "# machine: \027]0;x\007\027[2K\rthumper: 6 cases: 6 \
             passed.\127\xc2\xb1";
          ]),
      __POS_OF__
        {| corrupt baseline (line 4): invalid machine key '\x1b]0;x\x07\x1b[2K\x0dthumper: 6 cases: 6 passed.\x7f±' (must be [A-Za-z0-9._-]+) |}
    );
    ( "a machine line right after another",
      file (preamble @ [ "# machine: a"; "# machine: b" ]),
      __POS_OF__
        {| corrupt baseline (line 5): expected a blank line before the next '# machine:' section |}
    );
    ( "two sections for one key",
      two_sections "k" "k",
      __POS_OF__
        {| corrupt baseline (line 8): duplicate section for machine k |} );
    ( "sections out of key order",
      two_sections "kb" "ka",
      __POS_OF__
        {| corrupt baseline (line 8): sections are not sorted by machine key (ka after kb) |}
    );
    ( "two host lines",
      header [ "# host: a"; "# host: b" ],
      __POS_OF__ {| corrupt baseline (line 6): duplicate '# host:' line |} );
    ( "a host line after the ocaml line",
      header [ "# ocaml: o"; "# host: a" ],
      __POS_OF__ {| corrupt baseline (line 6): misplaced '# host:' line |} );
    ( "two ocaml lines",
      header [ "# ocaml: a"; "# ocaml: b" ],
      __POS_OF__ {| corrupt baseline (line 6): duplicate '# ocaml:' line |} );
    ( "an ocaml line after an annotation",
      header [ "# note"; "# ocaml: o" ],
      __POS_OF__ {| corrupt baseline (line 6): misplaced '# ocaml:' line |} );
    ( "a comment without a space",
      header [ "#bare" ],
      __POS_OF__ {| corrupt baseline (line 5): malformed comment line '#bare' |}
    );
    ( "an annotation spelling a suite line",
      header [ "# suite: nested" ],
      __POS_OF__
        {| corrupt baseline (line 5): malformed section comment '# suite: nested' |}
    );
    ( "an annotation spelling a machine line",
      header [ "# machine:nospace" ],
      __POS_OF__
        {| corrupt baseline (line 5): malformed section comment '# machine:nospace' |}
    );
    ( "no host line",
      header [ "# ocaml: o" ],
      __POS_OF__
        {| corrupt baseline (line 5): section for machine k is missing its '# host:' line |}
    );
    ( "no ocaml line",
      header [ "# host: h" ],
      __POS_OF__
        {| corrupt baseline (line 5): section for machine k is missing its '# ocaml:' line |}
    );
    ( "an empty host",
      header [ "# host: " ],
      __POS_OF__ {| corrupt baseline (line 5): empty '# host:' value |} );
    ( "an empty ocaml",
      header [ "# host: h"; "# ocaml: " ],
      __POS_OF__ {| corrupt baseline (line 6): empty '# ocaml:' value |} );
    ( "an exact row without its count",
      with_rows [ "a\tm\texact" ],
      __POS_OF__
        {| corrupt baseline (line 8): malformed row: expected 'id\tmetric\texact\tcount' or 'id\tmetric\tbatch=K\tn=N\tmedian\tsamples' |}
    );
    ( "a row with a field too many",
      with_rows [ "a\tm\texact\t1\textra" ],
      __POS_OF__
        {| corrupt baseline (line 8): malformed row: expected 'id\tmetric\texact\tcount' or 'id\tmetric\tbatch=K\tn=N\tmedian\tsamples' |}
    );
    ( "a count that is no number",
      with_rows [ "a\tm\texact\tx12" ],
      __POS_OF__
        {| corrupt baseline (line 8): exact count must be a decimal integer, got 'x12' |}
    );
    ( "a negative count",
      with_rows [ "a\tm\texact\t-1" ],
      __POS_OF__
        {| corrupt baseline (line 8): exact count must be a decimal integer, got '-1' |}
    );
    ( "a count past max_int",
      with_rows [ "a\tm\texact\t99999999999999999999" ],
      __POS_OF__
        {| corrupt baseline (line 8): exact count is out of range: '99999999999999999999' |}
    );
    ( "a case id with a space",
      with_rows [ "a b\tm\texact\t1" ],
      __POS_OF__ {| corrupt baseline (line 8): invalid case id 'a b' |} );
    ( "a case id with an empty segment",
      with_rows [ "a//b\tm\texact\t1" ],
      __POS_OF__ {| corrupt baseline (line 8): invalid case id 'a//b' |} );
    ( "a metric id with a space",
      with_rows [ "a\tw t\texact\t1" ],
      __POS_OF__ {| corrupt baseline (line 8): invalid metric id 'w t' |} );
    ( "k= for batch=",
      with_rows [ "a\tm\tk=2\tn=3\t2.000e+00\t1.000e+00 2.000e+00 3.000e+00" ],
      __POS_OF__
        {| corrupt baseline (line 8): malformed row: expected 'batch=K', got 'k=2' |}
    );
    ( "a batch size of 0",
      with_rows
        [ "a\tm\tbatch=0\tn=3\t2.000e+00\t1.000e+00 2.000e+00 3.000e+00" ],
      __POS_OF__ {| corrupt baseline (line 8): batch size must be at least 1 |}
    );
    ( "a sample count without n=",
      with_rows [ "a\tm\tbatch=1\t3\t2.000e+00\t1.000e+00 2.000e+00 3.000e+00" ],
      __POS_OF__
        {| corrupt baseline (line 8): malformed row: expected 'n=N', got '3' |}
    );
    ( "two samples",
      with_rows [ samples_row 2 "1.500e+00" "1.000e+00 2.000e+00" ],
      __POS_OF__
        {| corrupt baseline (line 8): sample count n=2 is below the minimum of 3 |}
    );
    ( "n=3 over two samples",
      with_rows [ samples_row 3 "1.500e+00" "1.000e+00 2.000e+00" ],
      __POS_OF__ {| corrupt baseline (line 8): n=3 but 2 samples are stored |}
    );
    ( "a NaN sample",
      with_rows [ samples_row 3 "2.000e+00" "1.000e+00 nan 3.000e+00" ],
      __POS_OF__
        {| corrupt baseline (line 8): sample is not a finite number: 'nan' |} );
    ( "samples in descending order",
      with_rows [ samples_row 3 "2.000e+00" "3.000e+00 2.000e+00 1.000e+00" ],
      __POS_OF__
        {| corrupt baseline (line 8): samples are not sorted ascending |} );
    ( "two rows for one case and metric",
      with_rows [ "a\tm\texact\t1"; "a\tm\texact\t2" ],
      __POS_OF__ {| corrupt baseline (line 9): duplicate row for a m |} );
    ( "rows out of id order",
      with_rows [ "b\tm\texact\t1"; "a\tm\texact\t2" ],
      __POS_OF__
        {| corrupt baseline (line 9): rows are not sorted by (id, metric) |} );
    ( "rows out of metric order",
      with_rows [ "a\tz\texact\t1"; "a\tm\texact\t2" ],
      __POS_OF__
        {| corrupt baseline (line 9): rows are not sorted by (id, metric) |} );
    ( "a space after the format line",
      file [ "# thumper baseline v1 "; "# suite: s"; ""; "# machine: k" ],
      __POS_OF__
        {| corrupt baseline (line 1): expected '# thumper baseline v1' on the first line |}
    );
    ( "a space after the machine key",
      file (preamble @ [ "# machine: k " ]),
      __POS_OF__
        {| corrupt baseline (line 4): invalid machine key 'k ' (must be [A-Za-z0-9._-]+) |}
    );
    ( "a space after a count",
      with_rows [ "a\tm\texact\t1 " ],
      __POS_OF__
        {| corrupt baseline (line 8): exact count must be a decimal integer, got '1 ' |}
    );
    ( "a space after the samples",
      with_rows [ samples_row 3 "2.000e+00" "1.000e+00 2.000e+00 3.000e+00 " ],
      __POS_OF__ {| corrupt baseline (line 8): n=3 but 4 samples are stored |}
    );
    ( "an even count's median off the midpoint",
      with_rows
        [ samples_row 4 "2.000e+00" "1.000e+00 2.000e+00 3.000e+00 4.000e+00" ],
      __POS_OF__
        {| corrupt baseline (line 8): stored median '2.000e+00' does not match its samples (re-derived '2.500e+00') |}
    );
    ( "an odd count's median off the central sample",
      with_rows [ samples_row 3 "2.001e+00" "1.000e+00 2.000e+00 3.000e+00" ],
      __POS_OF__
        {| corrupt baseline (line 8): stored median '2.001e+00' does not match its samples (re-derived '2.000e+00') |}
    );
    ( "a median with a one-digit exponent",
      with_rows [ samples_row 3 "2.000e+0" "1.000e+00 2.000e+00 3.000e+00" ],
      __POS_OF__
        {| corrupt baseline (line 8): stored median '2.000e+0' does not match its samples (re-derived '2.000e+00') |}
    );
    ( "a median with a capital E",
      with_rows [ samples_row 3 "2.000E+00" "1.000e+00 2.000e+00 3.000e+00" ],
      __POS_OF__
        {| corrupt baseline (line 8): stored median '2.000E+00' does not match its samples (re-derived '2.000e+00') |}
    );
    ( "the manual's file with a median one digit off",
      sample_flipped,
      __POS_OF__
        {| corrupt baseline (line 9): stored median '5.064e-03' does not match its samples (re-derived '5.063e-03') |}
    );
  ]

(* The rows of the file [t] prints, each as (id, metric, evidence), per
   section with its key and its [# ocaml:] line. *)
let structure =
  Testable.contramap
    (fun t ->
      ( Baseline.suite t,
        List.map
          (fun key ->
            let s = section t key in
            (key, Baseline.ocaml_of s, Baseline.rows s))
          (Baseline.machines t) ))
    (pair (option string) (list (triple string string (list row))))

(* Adding 1 modulo 10 to a digit always changes it. *)
let flip_first_digit median =
  let d = Char.code median.[0] - Char.code '0' in
  String.make 1 (Char.chr (((d + 1) mod 10) + Char.code '0'))
  ^ String.sub median 1 (String.length median - 1)

let a_median_one_digit_off_is_refused (id, k) =
  let r =
    sampled ~metric:"wall_time" ~k id [| 1.234e-3; 2.5e-3; 3.75e-3; 9.5e-3 |]
  in
  let line =
    String.split_on_char '\t'
      (last_line (printed (with_section "key" [ r ] empty)))
    |> List.mapi (fun i field ->
        if i = 4 then flip_first_digit field else field)
    |> String.concat "\t"
  in
  let line_no, reason =
    require_match
      (function
        | Error (Baseline.Corrupt { line; reason }) -> Some (line, reason)
        | Ok _ | Error (Baseline.Io _) -> None)
      (Baseline.of_string (with_rows [ line ]))
  in
  equal int 8 line_no;
  starts_with ~affix:"stored median '" reason

(* What [read] makes of the file at [path]. *)
let read_outcome path =
  match Baseline.read path with
  | Ok None -> "absent"
  | Ok (Some t) -> "file " ^ printed t
  | Error e -> "error " ^ error_text e

let written text =
  let path = Filename.concat (temp_dir ()) "suite.thumper" in
  Out_channel.with_open_bin path (fun oc -> output_string oc text);
  path

let a_permission_denied_file_is_io () =
  if Sys.win32 || Unix.geteuid () = 0 then
    skip ~reason:"file modes not enforced" ()
  else
    let path = written sample in
    Unix.chmod path 0o000;
    equal string
      ("error cannot read " ^ path ^ ": Permission denied")
      (read_outcome path)

(* A FIFO this test holds open for writing never ends, so [read] blocks until
   the alarm's handler raises. *)
let read_closes_its_descriptor_on_any_exception () =
  if Sys.win32 then skip ~reason:"no FIFO" ()
  else
    let path = Filename.concat (temp_dir ()) "fifo.thumper" in
    Unix.mkfifo path 0o600;
    let writer = Unix.openfile path [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
    let open_fds () =
      List.sort String.compare (Array.to_list (Sys.readdir "/dev/fd"))
    in
    let before = open_fds () in
    let previous =
      Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> raise Exit))
    in
    let timer v = { Unix.it_interval = 0.; it_value = v } in
    Fun.protect
      ~finally:(fun () ->
        ignore (Unix.setitimer Unix.ITIMER_REAL (timer 0.));
        Sys.set_signal Sys.sigalrm previous;
        Unix.close writer)
      (fun () ->
        ignore (Unix.setitimer Unix.ITIMER_REAL (timer 0.1));
        raises Exit (fun () -> Baseline.read path);
        equal (list string) before (open_fds ()))

let reading =
  group "Reading and printing"
    [
      test "the manual's file parses to its suite, machine and rows"
        the_sample_parses;
      test "the empty string has no suite and no section"
        the_empty_string_has_no_suite_and_no_section;
      cases "an accepted text prints back as itself" ~name:fst accepted
        (fun (_, text) -> equal string text (reprinted text));
      prop "of_string reads back what to_string printed"
        ~examples:[ parsed sample ]
        baseline_t
        (fun t -> equal string (printed t) (reprinted (printed t)));
      prop "a printed file parses to the rows it was built from" baseline_t
        (fun t -> equal structure t (parsed (printed t)));
      cases "of_string refuses"
        ~name:(fun (name, _, _) -> name)
        refusals
        (fun (_, text, pos) -> expect (refused text) pos);
      prop "a stored median one digit off is refused"
        (Gen.with_pp
           (fun ppf (id, k) -> Format.fprintf ppf "(%s, %d)" id k)
           Gen.(pair gen_id (int_range 1 10_000)))
        a_median_one_digit_off_is_refused;
      cases "read" ~name:fst
        [
          ( "a file is its parsed text",
            fun () -> ("file " ^ sample, read_outcome (written sample)) );
          ( "an empty file is the file with no section",
            fun () -> ("file ", read_outcome (written "")) );
          ( "a missing file is absent",
            fun () ->
              ("absent", read_outcome (Filename.concat (temp_dir ()) "f")) );
          ( "a file in a missing directory is absent",
            fun () ->
              ( "absent",
                read_outcome
                  (Filename.concat (Filename.concat (temp_dir ()) "d") "f") ) );
          ( "a directory is Io",
            fun () ->
              let dir = temp_dir () in
              ("error cannot read " ^ dir ^ ": Is a directory", read_outcome dir)
          );
          ( "a corrupt file is Corrupt",
            fun () ->
              ( "error corrupt baseline (line 1): expected '# thumper baseline \
                 v1' on the first line",
                read_outcome (written "junk\n") ) );
        ]
        (fun (_, outcome) ->
          let expected, actual = outcome () in
          equal string expected actual);
      test "a permission-denied file is Io" a_permission_denied_file_is_io;
      test "read closes its descriptor on any exception"
        read_closes_its_descriptor_on_any_exception;
      test "read_exn is read without its errors" (fun () ->
          equal (option string) (Some sample)
            (Option.map printed (Baseline.read_exn (written sample)));
          equal (option string) None
            (Option.map printed
               (Baseline.read_exn (Filename.concat (temp_dir ()) "f")));
          raises
            (Baseline.Error
               (Baseline.Corrupt
                  {
                    line = 1;
                    reason =
                      "expected '# thumper baseline v1' on the first line";
                  }))
            (fun () -> Baseline.read_exn (written "junk\n")));
    ]

(* Writing *)

let a_read_only_directory dir =
  if Sys.win32 || Unix.geteuid () = 0 then
    skip ~reason:"file modes not enforced" ()
  else
    let sub = Filename.concat dir "ro" in
    Unix.mkdir sub 0o500;
    (sub, "Permission denied")

let writing =
  group "Writing"
    [
      test "write writes to_string t" (fun () ->
          let path = Filename.concat (temp_dir ()) "suite.thumper" in
          let t = parsed sample in
          Baseline.write path t;
          equal string sample
            (In_channel.with_open_bin path In_channel.input_all));
      cases "a failed write is Io, naming the path" ~name:fst
        [
          ( "a missing directory",
            fun dir ->
              (Filename.concat dir "missing", "No such file or directory") );
          ("a read-only directory", a_read_only_directory);
        ]
        (fun (_, make) ->
          let dir, problem = make (temp_dir ()) in
          let path = Filename.concat dir "suite.thumper" in
          raises
            (Baseline.Error
               (Baseline.Io (Printf.sprintf "cannot write %s: %s" path problem)))
            (fun () -> Baseline.write path empty));
    ]

(* Files *)

let files =
  group "Files"
    [
      test "empty ~suite is the two-line preamble" (fun () ->
          let t = Baseline.empty ~suite:"digest" in
          equal string "# thumper baseline v1\n# suite: digest\n" (printed t);
          equal (option string) (Some "digest") (Baseline.suite t));
      cases "empty refuses what check_suite refuses" ~name:fst
        [ ("an empty name", ""); ("a newline", "two\nlines") ]
        (fun (_, suite) ->
          raises
            (Invalid_argument
               "Baseline.empty: suite name must be non-empty and single-line \
                (it heads fresh baselines)") (fun () -> Baseline.empty ~suite));
      test "section finds a key's section and no other" (fun () ->
          let t = parsed sample in
          equal (option string) (Some "5.5.0 · 64-bit · release")
            (Option.map Baseline.ocaml_of (Baseline.section t sample_machine));
          equal (option string) None
            (Option.map Baseline.ocaml_of (Baseline.section t "other")));
    ]

(* Section observers *)

let frozen_ks =
  [
    ( "the first sampled row decides",
      [
        exact ~metric:"alloc_words" "a" 7;
        sampled ~metric:"cpu_time" ~k:2 "a" [| 1.; 2.; 3. |];
        sampled ~metric:"wall_time" ~k:8 "a" [| 1.; 2.; 3. |];
      ],
      Some 2 );
    ("exact rows alone give none", [ exact ~metric:"alloc_words" "a" 7 ], None);
    ( "another case's rows give none",
      [ sampled ~k:4 "b" [| 1.; 2.; 3. |] ],
      None );
    ( "the rows of an earlier case are skipped",
      [ sampled ~k:4 "0" [| 1.; 2.; 3. |]; sampled ~k:8 "a" [| 1.; 2.; 3. |] ],
      Some 8 );
  ]

let section_observers =
  group "Section observers"
    [
      test "ocaml_of reads the section's header" (fun () ->
          let s = section (parsed sample) sample_machine in
          equal string "5.5.0 · 64-bit · release" (Baseline.ocaml_of s));
      test "find_row finds a case and metric's row and no other" (fun () ->
          let s = section (parsed sample) sample_machine in
          let found metric =
            Option.map Baseline.row_evidence
              (Baseline.find_row s ~id:"sha256/string-64" ~metric)
          in
          equal (option evidence) (Some (Baseline.Exact_int 54))
            (found "alloc_words");
          equal (option evidence) None (found "cpu_time"));
      cases "case_frozen_k"
        ~name:(fun (name, _, _) -> name)
        frozen_ks
        (fun (_, rows, k) ->
          equal (option int) k
            (Baseline.case_frozen_k
               (section (with_section "key" rows empty) "key")
               ~id:"a"));
    ]

(* Row observers *)

(* The samples of the manual's [line], as the file stores them. *)
let stored_samples line =
  List.nth (String.split_on_char '\t' line) 5
  |> String.split_on_char ' ' |> List.map float_of_string |> Array.of_list

let the_rows_hold_their_evidence () =
  let s = section (parsed sample) sample_machine in
  let lines = String.split_on_char '\n' sample in
  equal (list evidence)
    [
      Baseline.Exact_int 399;
      Baseline.Sampled { k = 1; samples = stored_samples (List.nth lines 8) };
      Baseline.Exact_int 54;
      Baseline.Sampled
        { k = 8192; samples = stored_samples (List.nth lines 10) };
    ]
    (List.map Baseline.row_evidence (Baseline.rows s))

let row_observers =
  group "Row observers"
    [
      test "the manual's rows hold their evidence" the_rows_hold_their_evidence;
      test "row_evidence's samples are a copy" (fun () ->
          let r = sampled "a" [| 1.0; 2.0; 3.0 |] in
          let samples =
            require_match
              (function
                | Baseline.Sampled { samples; _ } -> Some samples
                | Baseline.Exact_int _ -> None)
              (Baseline.row_evidence r)
          in
          samples.(0) <- 99.0;
          equal evidence
            (Baseline.Sampled { k = 1; samples = [| 1.0; 2.0; 3.0 |] })
            (Baseline.row_evidence r));
    ]

(* Building files *)

let row_refusals =
  let samples = [| 1.0; 2.0; 3.0 |] in
  [
    ( "an id with a space",
      (fun () -> exact "a b" 1),
      {|Baseline.exact_row: invalid id "a b" ('/'-separated segments of [A-Za-z0-9._-])|}
    );
    ( "an empty id",
      (fun () -> exact "" 1),
      {|Baseline.exact_row: invalid id "" ('/'-separated segments of [A-Za-z0-9._-])|}
    );
    ( "an id with an empty segment",
      (fun () -> exact "a//b" 1),
      {|Baseline.exact_row: invalid id "a//b" ('/'-separated segments of [A-Za-z0-9._-])|}
    );
    ( "an id ending in a slash",
      (fun () -> exact "a/" 1),
      {|Baseline.exact_row: invalid id "a/" ('/'-separated segments of [A-Za-z0-9._-])|}
    );
    ( "a metric with a space",
      (fun () -> exact ~metric:"w t" "a" 1),
      {|Baseline.exact_row: invalid metric id "w t" (must be [A-Za-z0-9._-]+)|}
    );
    ( "a metric with a slash",
      (fun () -> exact ~metric:"a/b" "a" 1),
      {|Baseline.exact_row: invalid metric id "a/b" (must be [A-Za-z0-9._-]+)|}
    );
    ( "a negative count",
      (fun () -> exact "a" (-1)),
      "Baseline.exact_row: negative count -1" );
    ( "a sampled row's invalid id",
      (fun () -> sampled "a b" samples),
      {|Baseline.sampled_row: invalid id "a b" ('/'-separated segments of [A-Za-z0-9._-])|}
    );
    ( "a batch size of 0",
      (fun () -> sampled ~k:0 "a" samples),
      "Baseline.sampled_row: batch size 0 < 1" );
    ( "two samples",
      (fun () -> sampled "a" [| 1.0; 2.0 |]),
      "Baseline.sampled_row: 2 samples (at least 3 required)" );
    ( "samples out of order",
      (fun () -> sampled "a" [| 2.0; 1.0; 3.0 |]),
      "Baseline.sampled_row: samples are not sorted ascending" );
    ( "a NaN sample",
      (fun () -> sampled "a" [| 1.0; Float.nan; 3.0 |]),
      "Baseline.sampled_row: non-finite sample nan" );
    ( "an infinite sample",
      (fun () -> sampled "a" [| 1.0; 2.0; Float.infinity |]),
      "Baseline.sampled_row: non-finite sample infinity" );
  ]

(* The samples' texts are what the row stores, so its median is derived from
   them and not from the floats it was given. *)
let sampled_lines =
  [
    ( "a sample rounds to its %.3e text",
      [| 1.23456e-3; 2.0e-3; 3.0e-3 |],
      "a\tm\tbatch=1\tn=3\t2.000e-03\t1.235e-03 2.000e-03 3.000e-03" );
    ( "the median of the stored samples, not of the given ones",
      [| 1.0e-3; 1.0e-3; 1.00049e-2; 1.00049e-2 |],
      "a\tm\tbatch=1\tn=4\t5.500e-03\t1.000e-03 1.000e-03 1.000e-02 1.000e-02"
    );
    ( "an even count's median stays finite near max_float",
      [| 1.7e308; 1.7e308; 1.7e308; 1.7e308 |],
      "a\tm\tbatch=1\tn=4\t1.700e+308\t1.700e+308 1.700e+308 1.700e+308 \
       1.700e+308" );
    ( "two-digit exponents down at 1e-10",
      [| 1e-10; 2e-10; 3e-10 |],
      "a\tm\tbatch=1\tn=3\t2.000e-10\t1.000e-10 2.000e-10 3.000e-10" );
  ]

let a_built_file_prints_in_the_print_format () =
  let t =
    Baseline.set_section
      (Baseline.empty ~suite:"digest")
      (identity "testkey")
      [
        exact ~metric:"alloc_words" "z/case" 54;
        sampled ~metric:"wall_time" ~k:2 "a/case" [| 1e-3; 2e-3; 3e-3; 4e-3 |];
      ]
  in
  equal string
    (file
       [
         "# thumper baseline v1";
         "# suite: digest";
         "";
         "# machine: testkey";
         "# host: mbp-test · Apple M1 · arm64 · macos";
         "# ocaml: 5.5.0 · 64-bit · release";
         "";
         "a/case\twall_time\tbatch=2\tn=4\t2.500e-03\t1.000e-03 2.000e-03 \
          3.000e-03 4.000e-03";
         "z/case\talloc_words\texact\t54";
       ])
    (printed t)

(* Canonical files hold "\n\n# machine: " before each section, so splitting
   on it gives the preamble, then one chunk per section, starting with its
   key. *)
let chunks text =
  let sep = "\n\n# machine: " in
  let ls = String.length sep in
  let rec go start acc i =
    if i + ls > String.length text then
      List.rev (String.sub text start (String.length text - start) :: acc)
    else if String.equal (String.sub text i ls) sep then
      go (i + ls) (String.sub text start (i - start) :: acc) (i + ls)
    else go start acc (i + 1)
  in
  go 0 [] 0

let set_section_keeps_every_other_section () =
  let t =
    empty
    |> with_section "aa" [ exact "a" 1 ]
    |> with_section "zz" [ exact "z" 9 ]
  in
  let t' = with_section "mm" [ exact "n" 5 ] t in
  equal (list string)
    (chunks (printed t))
    (List.filteri (fun i _ -> i <> 2) (chunks (printed t')))

let set_section_refusals =
  let row = exact "a" 1 in
  let set ?annotations ?(t = empty) id rows () =
    Baseline.set_section ?annotations t id rows
  in
  let ok = identity "key" in
  [
    ( "a file without a suite header",
      set ~t:(parsed "") ok [ row ],
      "Baseline.set_section: baseline has no suite header; start from \
       Baseline.empty ~suite" );
    ( "a machine key with a space",
      set (identity "no space") [ row ],
      {|Baseline.set_section: invalid machine key "no space" (must be [A-Za-z0-9._-]+)|}
    );
    ( "an empty host",
      set { ok with Baseline.host = "" } [ row ],
      "Baseline.set_section: empty host" );
    ( "an empty ocaml",
      set { ok with Baseline.ocaml = "" } [ row ],
      "Baseline.set_section: empty ocaml" );
    ( "a host of two lines",
      set { ok with Baseline.host = "a\nb" } [ row ],
      {|Baseline.set_section: newline in host "a\nb"|} );
    ( "an ocaml of two lines",
      set { ok with Baseline.ocaml = "a\nb" } [ row ],
      {|Baseline.set_section: newline in ocaml "a\nb"|} );
    ( "an annotation of two lines",
      set ~annotations:[ "two\nlines" ] ok [ row ],
      {|Baseline.set_section: multi-line annotation "two\nlines"|} );
    ( "an annotation spelling machine:",
      set ~annotations:[ "machine: fake" ] ok [ row ],
      {|Baseline.set_section: annotation "machine: fake" starts with a reserved header word|}
    );
    ( "an annotation spelling host:",
      set ~annotations:[ "host:x" ] ok [ row ],
      {|Baseline.set_section: annotation "host:x" starts with a reserved header word|}
    );
    ( "an annotation spelling ocaml:",
      set ~annotations:[ "ocaml: x" ] ok [ row ],
      {|Baseline.set_section: annotation "ocaml: x" starts with a reserved header word|}
    );
    ( "an annotation spelling suite:",
      set ~annotations:[ "suite: x" ] ok [ row ],
      {|Baseline.set_section: annotation "suite: x" starts with a reserved header word|}
    );
    ( "two rows for one case and metric",
      set ok [ row; row ],
      "Baseline.set_section: duplicate row for a m" );
  ]

let two_rows = with_section "key" [ exact "a" 1; exact "b" 2 ] empty

let update_rows_refusals =
  let row = exact "a" 5 in
  let update ?annotations ?(machine = "key") ?(advance = []) ?(prune = []) () =
    Baseline.update_rows ?annotations two_rows ~machine ~advance ~prune
  in
  [
    ( "a machine without a section",
      (fun () -> update ~machine:"missing" ()),
      {|Baseline.update_rows: no section for machine "missing"|} );
    ( "two advanced rows for one case and metric",
      (fun () -> update ~advance:[ row; row ] ()),
      "Baseline.update_rows: duplicate row for a m" );
    ( "a row both advanced and pruned",
      (fun () -> update ~advance:[ row ] ~prune:[ ("a", "m") ] ()),
      "Baseline.update_rows: a m is both advanced and pruned" );
    ( "an annotation spelling machine:",
      (fun () -> update ~annotations:[ "machine: x" ] ()),
      {|Baseline.update_rows: annotation "machine: x" starts with a reserved header word|}
    );
    ( "an annotation of two lines",
      (fun () -> update ~annotations:[ "two\nlines" ] ()),
      {|Baseline.update_rows: multi-line annotation "two\nlines"|} );
  ]

(* Three sections, and a row that replaces one of the middle section's rows
   or is new to it. *)
let gen_update =
  let open Gen in
  let* sections = list ~size:(constant 3) gen_section in
  let* fresh = gen_row in
  let+ replace = bool in
  let t =
    List.fold_left2
      (fun t key add -> add key t)
      empty [ "aaa1"; "bbb2"; "ccc3" ] sections
  in
  let advance =
    match Baseline.rows (section t "bbb2") with
    | existing :: _ when replace ->
        exact
          ~metric:(Baseline.row_metric existing)
          (Baseline.row_id existing) 424242
    | _ -> fresh
  in
  (t, advance)

let update_t =
  Gen.with_pp
    (fun ppf (t, r) ->
      Format.fprintf ppf "(%S, %s %s)" (printed t) (Baseline.row_id r)
        (Baseline.row_metric r))
    gen_update

(* Every line of the file but the blank ones and the advanced row's, in
   order: a row inserted into a section without rows brings a blank line. *)
let other_lines r text =
  let prefix = Baseline.row_id r ^ "\t" ^ Baseline.row_metric r ^ "\t" in
  List.filter
    (fun line -> line <> "" && not (String.starts_with ~prefix line))
    (String.split_on_char '\n' text)

let update_rows_keeps_every_other_byte (t, advance) =
  let t' =
    Baseline.update_rows t ~machine:"bbb2" ~advance:[ advance ] ~prune:[]
  in
  equal (list string)
    (other_lines advance (printed t))
    (other_lines advance (printed t'))

let building =
  group "Building files"
    [
      cases "a row constructor refuses"
        ~name:(fun (name, _, _) -> name)
        row_refusals
        (fun (_, make, message) -> raises (Invalid_argument message) make);
      cases "sampled_row prints"
        ~name:(fun (name, _, _) -> name)
        sampled_lines
        (fun (_, samples, line) ->
          let text =
            printed (with_section "key" [ sampled "a" samples ] empty)
          in
          equal string line (last_line text);
          equal string text (reprinted text));
      test "sampled_row stores what its line holds" (fun () ->
          equal evidence
            (Baseline.Sampled
               {
                 k = 1;
                 samples = [| float_of_string "1.235e-03"; 2e-3; 3e-3 |];
               })
            (Baseline.row_evidence (sampled "a" [| 1.23456e-3; 2e-3; 3e-3 |])));
      test "a built file prints in the print format"
        a_built_file_prints_in_the_print_format;
      test "set_section places sections in key order and replaces one whole"
        (fun () ->
          let t =
            empty
            |> with_section "mm" [ exact "a" 1 ]
            |> with_section "zz" [] |> with_section "aa" []
          in
          equal (list string) [ "aa"; "mm"; "zz" ] (Baseline.machines t);
          equal
            (list (pair string string))
            [ ("b", "m") ]
            (keys (section (with_section "mm" [ exact "b" 2 ] t) "mm")));
      test "set_section sorts the rows" (fun () ->
          equal
            (list (pair string string))
            [ ("a", "m"); ("a", "z"); ("b", "m") ]
            (keys
               (section
                  (with_section "key"
                     [ exact "b" 1; exact ~metric:"z" "a" 1; exact "a" 1 ]
                     empty)
                  "key")));
      test "set_section keeps every other section's bytes"
        set_section_keeps_every_other_section;
      test "set_section writes annotations below the header" (fun () ->
          let t =
            Baseline.set_section ~annotations:[ "forced: load 7.9/8" ] empty
              { Baseline.machine = "key"; host = "h"; ocaml = "o" }
              [ exact "a" 1 ]
          in
          equal string
            (file
               (preamble
               @ [
                   "# machine: key";
                   "# host: h";
                   "# ocaml: o";
                   "# forced: load 7.9/8";
                   "";
                   "a\tm\texact\t1";
                 ]))
            (printed t));
      cases "set_section refuses"
        ~name:(fun (name, _, _) -> name)
        set_section_refusals
        (fun (_, set, message) -> raises (Invalid_argument message) set);
      test "update_rows replaces and inserts rows in order" (fun () ->
          let t =
            Baseline.update_rows two_rows ~machine:"key"
              ~advance:[ exact "b" 3; exact "aa" 9 ]
              ~prune:[]
          in
          equal (list row)
            [ exact "a" 1; exact "aa" 9; exact "b" 3 ]
            (Baseline.rows (section t "key")));
      test "update_rows prunes a present row and ignores an absent one"
        (fun () ->
          let t =
            Baseline.update_rows two_rows ~machine:"key" ~advance:[]
              ~prune:[ ("b", "m"); ("ghost", "m") ]
          in
          equal
            (list (pair string string))
            [ ("a", "m") ]
            (keys (section t "key")));
      test "update_rows keeps a row's text, however spelled" (fun () ->
          let text =
            with_rows [ "a\tm\tbatch=1\tn=3\t2.000e+00\t1e0 2e0 3e0" ]
          in
          let t =
            Baseline.update_rows (parsed text) ~machine:"key"
              ~advance:[ exact "b" 1 ]
              ~prune:[]
          in
          equal string (text ^ "b\tm\texact\t1\n") (printed t));
      test "update_rows appends annotations to the section's" (fun () ->
          let t =
            Baseline.set_section ~annotations:[ "first" ] empty
              { Baseline.machine = "key"; host = "h"; ocaml = "o" }
              [ exact "a" 1 ]
          in
          equal string
            (file
               (preamble
               @ [
                   "# machine: key";
                   "# host: h";
                   "# ocaml: o";
                   "# first";
                   "# second";
                   "";
                   "a\tm\texact\t1";
                 ]))
            (printed
               (Baseline.update_rows ~annotations:[ "second" ] t ~machine:"key"
                  ~advance:[] ~prune:[])));
      cases "update_rows refuses"
        ~name:(fun (name, _, _) -> name)
        update_rows_refusals
        (fun (_, update, message) -> raises (Invalid_argument message) update);
      prop "update_rows keeps every line but the advanced row's" update_t
        update_rows_keeps_every_other_byte;
    ]

let () =
  exit
    (run "baseline"
       [
         types;
         identifiers;
         reading;
         writing;
         files;
         section_observers;
         row_observers;
         building;
       ])
