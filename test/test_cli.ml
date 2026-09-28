(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Tests for [Cli]: the argv grammar (subcommands,
   positionals-as-patterns, repeatable flags, the flag-scoping matrix, usage
   errors — including the deleted spellings [explore], [-v], [--no-fork],
   [--no-color], and the v1 aliases), filter composition, the config policy
   ([config_of]: presets only — the CLI never flips [fork]), color
   resolution ([use_color]), the status-line formatter, the INSIDE_DUNE hint
   fork, the block-report rendering goldens over synthetic verdicts —
   including terminal/exit-code agreement on the absolute-cap case,
   per-column time unit scaling, and thousands separators — the
   startup-unlink and write-target-preflight policy through [main]
   on non-measuring paths, and fast end-to-end runs (the NEW check flow, a
   partial bless) under a millisecond protocol. Everything that measures at
   protocol scale is cram's job. [Cli] is a private module of the library,
   reached — with its dependencies — through the facade's [Thumper.Private]
   re-export. *)

open Windtrap
module Baseline = Thumper.Private.Baseline
module Bench = Thumper.Private.Bench
module Budget = Thumper.Private.Budget
module Check = Thumper.Private.Check
module Cli = Thumper.Private.Cli
module Config = Thumper.Private.Config
module Env = Thumper.Private.Env
module Metric = Thumper.Private.Metric
module Run = Thumper.Private.Run
module Verdict = Thumper.Private.Verdict

(* Helpers *)

let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec go i =
    i + m <= n && (String.equal (String.sub s i m) sub || go (i + 1))
  in
  go 0

let assert_contains ?msg s sub =
  if not (contains s sub) then
    failf "%s: %S not found in output:\n%s"
      (Option.value msg ~default:"missing")
      sub s

let write_file path s =
  let oc = open_out_bin path in
  output_string oc s;
  close_out oc

let temp_dir () =
  let base = Filename.get_temp_dir_name () in
  let rec go i =
    let d =
      Filename.concat base
        (Printf.sprintf "thumper-cli-test-%d-%d" (Unix.getpid ()) i)
    in
    match Unix.mkdir d 0o700 with
    | () -> d
    | exception Unix.Unix_error (Unix.EEXIST, _, _) -> go (i + 1)
  in
  go 0

(* [main] reports errors, hints, and progress on stderr; keep the test run
   readable by sending that to /dev/null around effectful invocations. *)
let with_quiet_stderr f =
  let saved = Unix.dup Unix.stderr in
  let devnull = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  Unix.dup2 devnull Unix.stderr;
  Unix.close devnull;
  Fun.protect
    ~finally:(fun () ->
      Unix.dup2 saved Unix.stderr;
      Unix.close saved)
    f

(* [f ()] with stderr sent to a file, and what it wrote there. *)
let capturing_stderr f =
  let path = Filename.temp_file "thumper-test" ".err" in
  let saved = Unix.dup Unix.stderr in
  let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0 in
  Unix.dup2 fd Unix.stderr;
  Unix.close fd;
  let v =
    Fun.protect
      ~finally:(fun () ->
        flush stderr;
        Unix.dup2 saved Unix.stderr;
        Unix.close saved)
      f
  in
  let err = In_channel.with_open_bin path In_channel.input_all in
  Sys.remove path;
  (v, err)

(* Fixtures *)

let m_wall = Metric.wall_time
let m_alloc = Metric.alloc_words

let ident =
  {
    Baseline.machine = "testkey";
    host = "test-host";
    ocaml = "5.5.0 · 64-bit · release";
  }

let ties n v = Array.make n v
let sam sorted = Run.sampled ~sorted ~drifted:false

let trial ?(k = 8) ?(alloc = Some 54) wall =
  let ms = [ (m_wall, Run.Samples (sam wall)) ] in
  let ms =
    match alloc with Some n -> ms @ [ (m_alloc, Run.Exact n) ] | None -> ms
  in
  Run.Trial.make ~k ms

let wall_row ?(k = 8) id samples =
  Baseline.sampled_row ~id ~metric:"wall_time" ~k ~samples

let alloc_row id n = Baseline.exact_row ~id ~metric:"alloc_words" n

let file_of rows =
  Baseline.set_section (Baseline.empty ~suite:"digest") ident rows

let section_of file = Option.get (Baseline.section file "testkey")

let bcase id =
  match Bench.resolve [ Bench.bench id (fun () -> ()) ] with
  | Ok [ c ] -> c
  | _ -> assert false

let bcase_budgeted ~budgets id =
  match Bench.resolve [ Bench.bench ~budgets id (fun () -> ()) ] with
  | Ok [ c ] -> c
  | _ -> assert false

let benches =
  [
    Bench.bench "alpha" (fun () -> ());
    Bench.group "g" [ Bench.bench ~tags:[ "lab" ] "beta" (fun () -> ()) ];
  ]

(* Judge cases against [rows], confirm with [confirm] (a trial per queued
   id), decide under [decide_load]. *)
let empty_file = Result.get_ok (Baseline.of_string "")

let verdict_of_cases ?(load = Env.Quiet) ?(decide_load = Env.Quiet)
    ?(file = empty_file) ?(confirm = fun _ -> None) cases =
  let p =
    Verdict.judge ~identity:ident ~suite:"digest" ~load ~selection:`Full
      ~budgets:[] ~file ~cases
  in
  let confirmations =
    List.filter_map
      (fun id -> Option.map (fun t -> (id, t)) (confirm id))
      (Verdict.confirmations p)
  in
  Verdict.decide ~load:decide_load ~confirmations p

let verdict_of ?load ?decide_load ?file ?confirm case_trial =
  verdict_of_cases ?load ?decide_load ?file ?confirm [ case_trial ]

(* A confirmed wall-time regression (1 us -> 2 us) with an unchanged exact
   allocation, judged against a committed section. *)
let fail_fixture () =
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  verdict_of ~file
    ~confirm:(fun _ -> Some (trial (ties 5 2e-6)))
    (bcase "alpha", trial (ties 5 2e-6))

(* A confirmed wall-time improvement (2 us -> 1 us). *)
let improved_fixture () =
  let file = file_of [ wall_row "alpha" (ties 5 2e-6); alloc_row "alpha" 54 ] in
  verdict_of ~file
    ~confirm:(fun _ -> Some (trial (ties 5 1e-6)))
    (bcase "alpha", trial (ties 5 1e-6))

let new_fixture () = verdict_of (bcase "alpha", trial (ties 5 1e-6))

(* A confirmed sampled-allocation regression (100 w -> 200 w) whose only
   alloc budget is an absolute cap: the relation is reported, but an
   [Absolute_max] contract gates proven exact evidence only — the case
   passes and exits 0. Sampled alloc (a failed exactness probe) is the one
   way sampled evidence meets a cap now that [at_most] refuses never-exact
   metrics at construction. *)
let absolute_cap_fixture () =
  let file =
    file_of
      [
        wall_row "alpha" (ties 5 1e-6);
        Baseline.sampled_row ~id:"alpha" ~metric:"alloc_words" ~k:8
          ~samples:(ties 5 100.0);
      ]
  in
  let alloc_sampled wall alloc =
    Run.Trial.make ~k:8
      [
        (m_wall, Run.Samples (sam wall));
        (m_alloc, Run.Samples (sam (ties 5 alloc)));
      ]
  in
  let case =
    bcase_budgeted ~budgets:[ Budget.at_most ~metric:m_alloc 150. ] "alpha"
  in
  verdict_of ~file
    ~confirm:(fun _ -> Some (alloc_sampled (ties 5 1e-6) 200.0))
    (case, alloc_sampled (ties 5 1e-6) 200.0)

(* An exact allocation regression (54 w -> 71 w) under the zero pin, with
   equivalent timing: the case fails on the alloc side alone. *)
let exact_alloc_fail_fixture () =
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  let case =
    bcase_budgeted ~budgets:[ Budget.no_more_alloc_than 0.0 ] "alpha"
  in
  verdict_of ~file
    (case, trial ~alloc:(Some 71) (ties 5 1e-6))

(* A protocol small enough for in-process end-to-end runs through [main]:
   3 batches at a 0.1 ms floor with a token warmup — per case, milliseconds.
   What these runs pin is file effects, prompts, and exit codes, never
   timings. The CLI keeps the caller's fork knob ([config_of]), so the
   in-process seam flows through. *)
let fast_config =
  Config.(default |> samples 3 |> batch_floor 1e-4 |> warmup 1e-3 |> fork false)

(* End-to-end runs measure for real: pin the machine key and isolate the
   lease so a concurrent thumper on this host cannot serialize the test. *)
let e2e_env dir =
  Unix.putenv "THUMPER_MACHINE" "testkey";
  Unix.putenv "THUMPER_LOCK_DIR" dir

let ctx ?(color = false) ?(accept = "dune promote") ?(exe = Some "bench.exe")
    ?(github = false) ?(baseline = "digest.thumper") ?(wrote = false)
    ?(rerun_flags = []) ?(rerun_patterns = []) ?(strict = false)
    ?(cpu_model = "Test CPU") () =
  {
    Cli.color;
    accept;
    exe;
    github;
    baseline_path = baseline;
    corrected_path = baseline ^ ".corrected";
    wrote_corrected = wrote;
    rerun_flags;
    rerun_patterns;
    strict;
    cpu_model;
  }

(* Parsing *)

let sub_name = function
  | `Check -> "check"
  | `Bless -> "bless"
  | `List -> "list"

let preset_name = function
  | `Default -> "default"
  | `Quick -> "quick"
  | `Precise -> "precise"

let color_name = function
  | `Auto -> "auto"
  | `Always -> "always"
  | `Never -> "never"

let pargs l = Cli.parse (Array.of_list ("bench.exe" :: l))

let opts l =
  match pargs l with
  | Cli.Run o -> o
  | Cli.Help -> failf "expected Run, got Help"
  | Cli.Version -> failf "expected Run, got Version"
  | Cli.Usage_error m -> failf "expected Run, got Usage_error %S" m

let usage_error l =
  match pargs l with
  | Cli.Usage_error m -> m
  | Cli.Run _ -> failf "expected Usage_error, got Run"
  | Cli.Help -> failf "expected Usage_error, got Help"
  | Cli.Version -> failf "expected Usage_error, got Version"

let defaults_are_check_with_nothing_set () =
  let o = opts [] in
  equal ~msg:"subcommand" string "check" (sub_name o.Cli.subcommand);
  equal ~msg:"patterns" (list string) [] o.Cli.patterns;
  equal ~msg:"tags" (list string) [] o.Cli.tags;
  equal ~msg:"preset" string "default" (preset_name o.Cli.preset);
  equal ~msg:"baseline" (option string) None o.Cli.baseline;
  equal ~msg:"json" (option string) None o.Cli.json;
  is_true ~msg:"strict" (not o.Cli.strict);
  equal ~msg:"wait_quiet" (option float_exact) None o.Cli.wait_quiet;
  is_true ~msg:"force" (not o.Cli.force);
  equal ~msg:"color" string "auto" (color_name o.Cli.color)

let first_argument_names_the_subcommand () =
  List.iter
    (fun w -> equal ~msg:w string w (sub_name (opts [ w ]).Cli.subcommand))
    [ "check"; "bless"; "list" ]

let explore_is_a_pattern () =
  (* The explore subcommand is deleted: the
     word parses as an ordinary selection pattern and fails loudly at
     selection, never silently as a subcommand. *)
  let o = opts [ "explore" ] in
  equal ~msg:"subcommand" string "check" (sub_name o.Cli.subcommand);
  equal ~msg:"patterns" (list string) [ "explore" ] o.Cli.patterns

let later_subcommand_word_is_a_pattern () =
  let o = opts [ "check"; "bless" ] in
  equal ~msg:"subcommand" string "check" (sub_name o.Cli.subcommand);
  equal ~msg:"patterns" (list string) [ "bless" ] o.Cli.patterns

let bare_positionals_are_patterns () =
  let o = opts [ "foo"; "bar" ] in
  equal string "check" (sub_name o.Cli.subcommand);
  equal (list string) [ "foo"; "bar" ] o.Cli.patterns

let repeatable_flags_keep_encounter_order () =
  let o = opts [ "-f"; "a"; "b"; "-f"; "c"; "--tag"; "lab"; "--tag"; "ci" ] in
  equal ~msg:"patterns" (list string) [ "a"; "b"; "c" ] o.Cli.patterns;
  equal ~msg:"tags" (list string) [ "lab"; "ci" ] o.Cli.tags

let long_options_accept_equals_form () =
  let o = opts [ "--tag=lab"; "--baseline=b.thumper"; "--wait-quiet=2.5" ] in
  equal ~msg:"tag" (list string) [ "lab" ] o.Cli.tags;
  equal ~msg:"baseline" (option string) (Some "b.thumper") o.Cli.baseline;
  equal ~msg:"wait" (option float_exact) (Some 2.5) o.Cli.wait_quiet

let a_flag_refuses_an_equals_value () =
  (* A flag that takes no value is never split: [--strict=no] must not read
     as [--strict] plus the pattern [no]. *)
  equal ~msg:"--strict=no" string "option '--strict' takes no argument"
    (usage_error [ "--strict=no" ]);
  equal ~msg:"--quick=1" string "option '--quick' takes no argument"
    (usage_error [ "--quick=1" ]);
  equal ~msg:"--nope" string "unknown option '--nope'"
    (usage_error [ "--nope" ]);
  equal ~msg:"--nope=1" string "unknown option '--nope'"
    (usage_error [ "--nope=1" ])

let value_flags_parse () =
  let o =
    opts
      [
        "--baseline";
        "p.thumper";
        "--json";
        "v.json";
        "--wait-quiet";
        "0";
        "--strict";
        "--quick";
      ]
  in
  equal (option string) (Some "p.thumper") o.Cli.baseline;
  equal (option string) (Some "v.json") o.Cli.json;
  equal (option float_exact) (Some 0.) o.Cli.wait_quiet;
  is_true o.Cli.strict;
  equal string "quick" (preset_name o.Cli.preset);
  is_true ~msg:"--force on bless" (opts [ "bless"; "--force" ]).Cli.force

let precise_preset_parses () =
  equal string "precise" (preset_name (opts [ "--precise" ]).Cli.preset)

let color_parses () =
  equal ~msg:"always" string "always"
    (color_name (opts [ "--color"; "always" ]).Cli.color);
  equal ~msg:"never" string "never"
    (color_name (opts [ "--color"; "never" ]).Cli.color);
  equal ~msg:"auto" string "auto"
    (color_name (opts [ "--color"; "auto" ]).Cli.color);
  equal ~msg:"equals form" string "never"
    (color_name (opts [ "--color=never" ]).Cli.color);
  equal ~msg:"on list" string "never"
    (color_name (opts [ "list"; "--color"; "never" ]).Cli.color);
  assert_contains ~msg:"bad value"
    (usage_error [ "--color"; "sometimes" ])
    "--color";
  assert_contains ~msg:"missing value" (usage_error [ "--color" ]) "--color"

let quick_and_precise_conflict () =
  assert_contains ~msg:"conflict named"
    (usage_error [ "--quick"; "--precise" ])
    "mutually exclusive"

let missing_option_arguments_are_usage_errors () =
  List.iter
    (fun flag -> assert_contains ~msg:flag (usage_error [ flag ]) flag)
    [ "-f"; "--tag"; "--baseline"; "--json"; "--wait-quiet"; "--color" ]

let json_dash_is_a_usage_error () =
  equal string "option '--json' requires a file path, got '-'"
    (usage_error [ "--json"; "-" ]);
  equal ~msg:"equals form" string
    "option '--json' requires a file path, got '-'"
    (usage_error [ "--json=-" ])

let malformed_wait_quiet_is_a_usage_error () =
  List.iter
    (fun v ->
      assert_contains ~msg:v (usage_error [ "--wait-quiet"; v ]) "--wait-quiet")
    [ "abc"; "-1"; "nan"; "inf" ]

let unknown_options_are_usage_errors () =
  assert_contains (usage_error [ "--bogus" ]) "--bogus";
  assert_contains (usage_error [ "-x" ]) "-x";
  (* A nameless [--=V] must not split into ["--"] plus a pattern. *)
  assert_contains (usage_error [ "--=x" ]) "--=x"

let help_and_version_win () =
  is_true ~msg:"-h" (pargs [ "-h" ] = Cli.Help);
  is_true ~msg:"--help" (pargs [ "--help" ] = Cli.Help);
  is_true ~msg:"-h after flags" (pargs [ "-f"; "x"; "-h" ] = Cli.Help);
  is_true ~msg:"-V" (pargs [ "-V" ] = Cli.Version);
  is_true ~msg:"--version" (pargs [ "--version" ] = Cli.Version)

(* The pristine-CLI pins: [-v]/[--verbose],
   [--no-fork], [--no-color], [-q], and v1's flag aliases are deleted
   outright — ordinary unknown options, no deprecation window. *)
let deleted_spellings_are_unknown_options () =
  List.iter
    (fun flag ->
      assert_contains ~msg:flag (usage_error [ flag ]) "unknown option";
      assert_contains ~msg:flag (usage_error [ flag ]) flag)
    [
      "-v";
      "--verbose";
      "--no-fork";
      "--no-color";
      "-q";
      "--explore";
      "--bless";
      "-l";
    ]

(* The scoping matrix: a flag accepted where
   it does nothing misdescribes the run. *)
let flag_scoping_matrix () =
  let refused args flag where =
    let m = usage_error args in
    assert_contains ~msg:(String.concat " " args) m
      (Printf.sprintf "option '%s' applies to %s" flag where)
  in
  refused [ "bless"; "--json"; "x" ] "--json" "check, not bless";
  refused [ "list"; "--json"; "x" ] "--json" "check, not list";
  refused [ "bless"; "--strict" ] "--strict" "check, not bless";
  refused [ "list"; "--strict" ] "--strict" "check, not list";
  refused [ "--force" ] "--force" "bless, not check";
  refused [ "check"; "--force" ] "--force" "bless, not check";
  refused [ "list"; "--force" ] "--force" "bless, not list";
  refused [ "list"; "--baseline"; "b" ] "--baseline" "check and bless, not list";
  refused [ "list"; "--quick" ] "--quick" "check and bless, not list";
  refused [ "list"; "--precise" ] "--precise" "check and bless, not list";
  refused
    [ "list"; "--wait-quiet"; "1" ]
    "--wait-quiet" "check and bless, not list"

let double_dash_ends_options () =
  let o = opts [ "--"; "-f"; "--strict" ] in
  equal (list string) [ "-f"; "--strict" ] o.Cli.patterns;
  is_true (not o.Cli.strict);
  (* The --opt=VALUE expansion stops at the terminator too: after [--] an
     argument keeps its '=' and stays one pattern. *)
  let o = opts [ "--"; "--tag=x" ] in
  equal ~msg:"'=' kept after --" (list string) [ "--tag=x" ] o.Cli.patterns;
  equal ~msg:"no tag parsed after --" (list string) [] o.Cli.tags

let lone_dash_is_a_pattern () =
  equal (list string) [ "-" ] (opts [ "-" ]).Cli.patterns

(* Filter composition *)

let rec filter_str = function
  | `Id s -> "id:" ^ s
  | `Tag s -> "tag:" ^ s
  | `And fs -> "and[" ^ String.concat "," (List.map filter_str fs) ^ "]"
  | `Or fs -> "or[" ^ String.concat "," (List.map filter_str fs) ^ "]"

let filter_opt_str = function None -> "none" | Some f -> filter_str f

let filter_composition () =
  let f ~patterns ~tags = filter_opt_str (Cli.filter_of ~patterns ~tags) in
  equal ~msg:"empty" string "none" (f ~patterns:[] ~tags:[]);
  equal ~msg:"ids or'd" string "or[id:a,id:b]"
    (f ~patterns:[ "a"; "b" ] ~tags:[]);
  equal ~msg:"tags and'd" string "and[tag:x,tag:y]"
    (f ~patterns:[] ~tags:[ "x"; "y" ]);
  equal ~msg:"both" string "and[or[id:a],and[tag:x]]"
    (f ~patterns:[ "a" ] ~tags:[ "x" ])

(* The config policy *)

let config_of_refines_presets_only () =
  let quick = Cli.config_of (opts [ "--quick" ]) in
  equal ~msg:"--quick sets the preset's n" int Config.quick.Config.n
    quick.Config.n;
  is_true ~msg:"--quick still forks" quick.Config.fork;
  equal ~msg:"--precise sets the preset's n" int Config.precise.Config.n
    (Cli.config_of (opts [ "--precise" ])).Config.n;
  is_true ~msg:"default forks" (Cli.config_of (opts [])).Config.fork

let config_of_keeps_the_callers_knobs () =
  let base = Config.(default |> deadline 60.) in
  let c = Cli.config_of ~config:base (opts [ "--quick" ]) in
  equal ~msg:"caller's deadline kept" float_exact 60. c.Config.deadline;
  equal ~msg:"preset n applied over it" int Config.quick.Config.n c.Config.n;
  (* The CLI never flips the fork seam: the caller's in-process protocol
     flows through untouched. *)
  let inproc = Config.(default |> fork false) in
  is_true ~msg:"caller's fork kept"
    (not (Cli.config_of ~config:inproc (opts [ "--quick" ])).Config.fork)

(* Color resolution *)

let use_color_resolution () =
  let auto = Cli.use_color `Auto in
  is_true ~msg:"auto: tty"
    (auto ~is_tty:true ~rule_action:false ~no_color:false);
  is_true ~msg:"auto: pipe"
    (not (auto ~is_tty:false ~rule_action:false ~no_color:false));
  is_true ~msg:"auto: dune re-displays a rule action's output"
    (auto ~is_tty:false ~rule_action:true ~no_color:false);
  is_true ~msg:"auto: NO_COLOR dampens"
    (not (auto ~is_tty:true ~rule_action:true ~no_color:true));
  is_true ~msg:"always beats NO_COLOR (no-color.org)"
    (Cli.use_color `Always ~is_tty:false ~rule_action:false ~no_color:true);
  is_true ~msg:"never beats a tty"
    (not (Cli.use_color `Never ~is_tty:true ~rule_action:false ~no_color:false))

(* The status line *)

let status_line_formats () =
  equal ~msg:"measuring" string "thumper: measuring 3/6 — busy/spin"
    (Cli.status_line
       { Check.phase = `Measuring; index = 3; total = 6; case = "busy/spin" });
  equal ~msg:"confirming" string "thumper: confirming 1/2 — alloc/list"
    (Cli.status_line
       { Check.phase = `Confirming; index = 1; total = 2; case = "alloc/list" })

(* The acceptance-hint fork *)

let promotion_staged_predicate () =
  let staged = Cli.promotion_staged in
  (* A rule action: INSIDE_DUNE is the build-context path and cwd is under
     the build root (sandboxed or not). *)
  is_true ~msg:"action cwd"
    (staged ~inside_dune:(Some "/repo/_build/default")
       ~cwd:"/repo/_build/default/examples/01");
  is_true ~msg:"sandboxed action cwd"
    (staged ~inside_dune:(Some "/repo/_build/default")
       ~cwd:"/repo/_build/.sandbox/abc123/default/test/cram/bless.t");
  (* dune exec: INSIDE_DUNE is set but cwd stays in the source tree — the
     v1-era footgun; dune promote would silently do nothing. *)
  is_false ~msg:"dune exec from the source tree"
    (staged ~inside_dune:(Some "/repo/_build/default") ~cwd:"/repo");
  is_false ~msg:"dune exec from a subdir"
    (staged ~inside_dune:(Some "/repo/_build/default")
       ~cwd:"/repo/examples/01-first-benchmark");
  (* Older dunes set "1": fall back to the _build component heuristic. *)
  is_true ~msg:"legacy value inside _build"
    (staged ~inside_dune:(Some "1") ~cwd:"/repo/_build/default/bench");
  is_false ~msg:"legacy value outside _build"
    (staged ~inside_dune:(Some "1") ~cwd:"/repo/bench");
  (* Direct invocation: no INSIDE_DUNE at all — cwd is irrelevant. *)
  is_false ~msg:"unset" (staged ~inside_dune:None ~cwd:"/repo/_build/default")

let accept_command_fork () =
  equal ~msg:"promotion staged" string "dune promote"
    (Cli.accept_command ~promotion_staged:true ~corrected:"d.thumper.corrected"
       ~baseline:"d.thumper");
  equal ~msg:"not staged" string "mv d.thumper.corrected d.thumper"
    (Cli.accept_command ~promotion_staged:false ~corrected:"d.thumper.corrected"
       ~baseline:"d.thumper")

let accept_command_quotes_hostile_paths () =
  (* Copy-pasteable from anywhere (.mli): a path a shell would split is
     quoted; ordinary paths stay bare so transcripts read naturally. *)
  equal ~msg:"space quoted" string
    "mv 'My Projects/d.thumper.corrected' 'My Projects/d.thumper'"
    (Cli.accept_command ~promotion_staged:false
       ~corrected:"My Projects/d.thumper.corrected"
       ~baseline:"My Projects/d.thumper")

let rerun_hint_reproduces_the_invocation () =
  (* The rerun line is "the exact command" (getting-started): the preset,
     an explicit --baseline and every --tag are carried; a hostile exe path
     is quoted. Under a rule action (no exe) there is no rerun line. *)
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  let v =
    verdict_of ~file
      ( bcase_budgeted ~budgets:[ Budget.no_more_alloc_than 0.0 ] "alpha",
        trial ~alloc:(Some 71) (ties 5 1e-6) )
  in
  let out =
    Cli.render_check
      (ctx ~exe:(Some "my dir/bench.exe") ~baseline:"alt/base.thumper"
         ~rerun_flags:[ "--quick"; "--baseline alt/base.thumper"; "--tag lab" ]
         ())
      v
  in
  assert_contains out
    "rerun:   'my dir/bench.exe' --quick --baseline alt/base.thumper --tag lab \
     \\\n\
    \           -f alpha\n";
  let staged = Cli.render_check (ctx ~exe:None ()) v in
  is_true ~msg:"no rerun line under a rule action"
    (not (contains staged "rerun:"));
  assert_contains ~msg:"the failing id stays in the table" staged
    "REGRESSED  1.00 us  \xc2\xb10.0%  71 w  alpha"

(* [n] cases failing on their exact allocation, ids [case-01]... *)
let failing_cases n =
  let ids = List.init n (fun i -> Printf.sprintf "case-%02d" (i + 1)) in
  let file =
    file_of
      (List.concat_map
         (fun id -> [ wall_row id (ties 5 1e-6); alloc_row id 54 ])
         ids)
  in
  verdict_of_cases ~file
    (List.map
       (fun id ->
         ( bcase_budgeted ~budgets:[ Budget.no_more_alloc_than 0.0 ] id,
           trial ~alloc:(Some 71) (ties 5 1e-6) ))
       ids)

let rerun_hint_wraps_within_80_columns () =
  (* One pasteable command: an item that would pass column 80 starts the
     next line behind a backslash, indented under the executable. *)
  let out =
    Cli.render_check
      (ctx ~exe:(Some "./_build/default/bench/bench_digest.exe")
         ~rerun_flags:[ "--quick"; "--baseline bench/digest.thumper" ]
         ())
      (failing_cases 4)
  in
  assert_contains out
    "  rerun:   ./_build/default/bench/bench_digest.exe --quick \\\n\
    \           --baseline bench/digest.thumper -f case-01 -f case-02 -f \
     case-03 \\\n\
    \           -f case-04\n"

let rerun_hint_wraps_at_exactly_80_columns () =
  (* The bound counts the continuation: an item that ends the line at column
     80, backslash included, stays; one column more moves it down. *)
  let exe n = "./" ^ String.make n 'x' in
  let first_line n =
    let out = Cli.render_check (ctx ~exe:(Some (exe n)) ()) (failing_cases 2) in
    List.find (fun l -> contains l "rerun:") (String.split_on_char '\n' out)
  in
  equal ~msg:"80 columns: the item stays" string
    ("  rerun:   " ^ exe 54 ^ " -f case-01 \\")
    (first_line 54);
  equal ~msg:"81 columns: the item moves" string
    ("  rerun:   " ^ exe 55 ^ " \\")
    (first_line 55)

let rerun_hint_names_at_most_ten_cases () =
  (* Ten failing cases are named; an eleventh turns the hint into the run's
     own selection. *)
  let ten = Cli.render_check (ctx ()) (failing_cases 10) in
  assert_contains ~msg:"ten named" ten "-f case-10\n";
  let eleven =
    Cli.render_check
      (ctx ~rerun_patterns:[ "case"; "my case" ] ())
      (failing_cases 11)
  in
  assert_contains ~msg:"the run's own selection" eleven
    "  rerun:   bench.exe -f case -f 'my case'\n";
  is_true ~msg:"no failing id named" (not (contains eleven "-f case-01"))

(* The default baseline path

   The pure mapping behind the default [<suite>.thumper] location: [dir_exists] is a set-membership test, so every
   branch runs without processes or a filesystem. *)

let map ?(dirs = []) ?(cwd = "/ws") ?(cwd_in_build = false) exe =
  Cli.default_baseline_dir
    ~dir_exists:(fun d -> List.mem d dirs)
    ~exe ~cwd ~cwd_in_build

let default_dir_maps_exe_to_its_source_directory () =
  equal ~msg:"dune exec from the workspace root" string "/ws/examples/01"
    (map ~dirs:[ "/ws/examples/01" ] "/ws/_build/default/examples/01/b.exe");
  equal ~msg:"the invoker's cwd does not steer the mapping" string "/ws/bench"
    (map ~dirs:[ "/ws/bench" ] ~cwd:"/somewhere/else"
       "/ws/_build/default/bench/b.exe");
  equal ~msg:"named build context" string "/ws/bench"
    (map ~dirs:[ "/ws/bench" ] "/ws/_build/musl/bench/b.exe");
  equal ~msg:".sandbox/<hash> is skipped before the context" string "/ws/bench"
    (map ~dirs:[ "/ws/bench" ]
       "/ws/_build/.sandbox/d41d8cd98f00b204/default/bench/b.exe");
  equal ~msg:"the last /_build/ names the workspace root" string
    "/a/_build/ws/bench"
    (map ~dirs:[ "/a/_build/ws/bench" ]
       "/a/_build/ws/_build/default/bench/b.exe");
  equal ~msg:"an exe at the workspace root maps to the root" string "/ws"
    (map ~dirs:[ "/ws" ] "/ws/_build/default/b.exe");
  equal ~msg:"a relative exe resolves against the cwd" string "/ws/bench"
    (map ~dirs:[ "/ws/bench" ] "_build/default/bench/b.exe")

let default_dir_falls_back_to_the_cwd () =
  equal ~msg:"exe outside _build (installed or copied binary)" string "/ws"
    (map "/usr/local/bin/b.exe");
  equal ~msg:"mapped source directory missing" string "/ws"
    (map "/elsewhere/_build/default/bench/b.exe");
  equal ~msg:"no context segment after _build (exe directly inside it)" string
    "/ws"
    (map ~dirs:[ "/proj" ] "/proj/_build/b.exe")

let default_dir_stays_in_a_build_cwd () =
  (* Branch 1 keys on the cwd alone (no INSIDE_DUNE): rule actions and cram
     sandboxes resolve in the cwd — the [diff?] contract, and a build action
     must never write to the source tree — whatever the executable path
     could map to. *)
  equal string "/ws/_build/default/bench"
    (map ~cwd:"/ws/_build/default/bench" ~cwd_in_build:true
       ~dirs:[ "/ws/bench" ] "/ws/_build/default/bench/b.exe")

(* Check rendering

   The block report: header / table /
   actions / summary, blank-line separated, empty blocks omitted, printed
   always. *)

let mixed_run_renders_all_four_blocks () =
  (* One confirmed regression, one confirmed improvement, one equivalent:
     the specimen shape — header, table, actions (rerun + accept),
     summary. *)
  let file =
    file_of
      [
        wall_row "alpha" (ties 5 1e-6);
        alloc_row "alpha" 54;
        wall_row "beta" (ties 5 2e-6);
        alloc_row "beta" 2100;
        wall_row "gamma" (ties 5 1e-6);
        alloc_row "gamma" 3000;
      ]
  in
  let trial_for = function
    | "alpha" -> trial (ties 5 2e-6)
    | "beta" -> trial ~alloc:(Some 2100) (ties 5 1e-6)
    | _ -> trial ~alloc:(Some 3000) (ties 5 1e-6)
  in
  let v =
    verdict_of_cases ~file
      ~confirm:(fun id -> Some (trial_for id))
      [
        (bcase "alpha", trial_for "alpha");
        (bcase "beta", trial_for "beta");
        (bcase "gamma", trial_for "gamma");
      ]
  in
  expect (Cli.render_check (ctx ~wrote:true ()) v)
  @@ __POS_OF__
       {|
thumper: digest — 3 cases vs digest.thumper for machine testkey

  REGRESSED   2.00 us  ±0.0%     54 w  alpha
      +100.0% [+100.0, +100.0]  budget +5%; equivalent (alloc exact)
  improved    1.00 us  ±0.0%  2,100 w  beta
      -50.0% [-50.0, -50.0]
  equivalent  1.00 us  ±0.0%  3,000 w  gamma

  rerun:   bench.exe -f alpha
  accept:  dune promote

  3 cases: 1 passed, 1 improved, 1 regressed.
|}

let pass_run_renders_header_table_summary () =
  (* The report always prints — the silence-on-pass era is over. *)
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  let v =
    verdict_of ~file (bcase "alpha", trial (ties 5 1e-6))
  in
  expect (Cli.render_check (ctx ()) v)
  @@ __POS_OF__
       {|
thumper: digest — 1 case vs digest.thumper for machine testkey

  equivalent  1.00 us  ±0.0%  54 w  alpha

  1 case: 1 passed.
|}

let new_run_renders_proposed_rows_and_the_accept_prompt () =
  let v = new_fixture () in
  expect (Cli.render_check (ctx ~wrote:true ()) v)
  @@ __POS_OF__
       {|
thumper: digest — no baseline for machine testkey (Test CPU)

  proposed  1.00 us  ±0.0%  54 w  alpha

  accept:  dune promote
|}

let a_proposed_metric_reads_as_proposed () =
  (* The time compared equivalent; the allocation has no baseline row yet:
     the row opens on the compared metric's word and the detail names what
     is proposed. *)
  let file = file_of [ wall_row "alpha" (ties 5 1e-6) ] in
  let v = verdict_of ~file (bcase "alpha", trial (ties 5 1e-6)) in
  expect (Cli.render_check (ctx ~wrote:true ()) v)
  @@ __POS_OF__
       {|
thumper: digest — 1 case vs digest.thumper for machine testkey

  equivalent  1.00 us  ±0.0%  54 w  alpha
      proposed alloc

  accept:  dune promote

  1 case: 1 passed.
|}

let mv_hint_replaces_promote_outside_dune () =
  let v = new_fixture () in
  let out =
    Cli.render_check
      (ctx ~wrote:true ~accept:"mv digest.thumper.corrected digest.thumper" ())
      v
  in
  assert_contains out "accept:  mv digest.thumper.corrected digest.thumper"

let loaded_run_warns_under_the_header () =
  (* The compared run's one load message: a yellow line directly under the
     header; the sampled verdict degrades to inconclusive (environment) while
     the exact alloc verdict stays visible. *)
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  let loaded = Env.Loaded { load = 7.9; cores = 8 } in
  let v =
    verdict_of ~load:loaded ~decide_load:loaded ~file
      (bcase "alpha", trial (ties 5 2e-6))
  in
  expect (Cli.render_check (ctx ()) v)
  @@ __POS_OF__
       {|
thumper: digest — 1 case vs digest.thumper for machine testkey
warning: load 7.9 on 8 cores; timing verdicts degraded

  inconclusive  2.00 us  ±0.0%  54 w  alpha
      environment; equivalent (alloc exact)

  1 case: 0 passed, 1 inconclusive.
|}

let loaded_new_run_warns_beside_the_prompt () =
  (* Acceptance states put the run's one load message in the actions block
     instead — never two load messages. *)
  let loaded = Env.Loaded { load = 7.9; cores = 8 } in
  let v =
    verdict_of ~load:loaded ~decide_load:loaded
      (bcase "alpha", trial (ties 5 1e-6))
  in
  let out = Cli.render_check (ctx ~wrote:true ()) v in
  assert_contains ~msg:"prompt kept" out "accept:  dune promote";
  assert_contains ~msg:"load message beside the prompt" out
    "  warning: load 7.9 on 8 cores; prefer a quiet host before accepting";
  is_true ~msg:"no header-side load warning"
    (not (contains out "timing verdicts degraded"))

let improvement_only_renders_the_accept_line () =
  let v = improved_fixture () in
  expect (Cli.render_check (ctx ~wrote:true ()) v)
  @@ __POS_OF__
       {|
thumper: digest — 1 case vs digest.thumper for machine testkey

  improved  1.00 us  ±0.0%  54 w  alpha
      -50.0% [-50.0, -50.0]

  accept:  dune promote

  1 case: 0 passed, 1 improved.
|}

let within_budget_prints_its_interval () =
  (* A noisy row whose interval ends within the budget passes within budget
     and prints its interval, which shows no change; a demonstrated change
     within budget prints its estimate. *)
  let file =
    file_of
      [
        wall_row "alpha" (ties 5 1e-6);
        alloc_row "alpha" 54;
        wall_row "beta" (ties 5 1e-6);
        alloc_row "beta" 54;
      ]
  in
  let v =
    verdict_of_cases ~file
      [
        (bcase "alpha", trial [| 0.9e-6; 0.95e-6; 1e-6; 1.03e-6; 1.04e-6 |]);
        (bcase "beta", trial (ties 5 1.03e-6));
      ]
  in
  expect (Cli.render_check (ctx ()) v)
  @@ __POS_OF__
       {|
thumper: digest — 2 cases vs digest.thumper for machine testkey

  within budget  1.00 us  ±7.0%  54 w  alpha
      +0.0% [-10.0, +4.0]
  within budget  1.03 us  ±0.0%  54 w  beta
      +3.0%

  2 cases: 2 passed.
|}

let unconfirmed_inconclusive_names_the_reason_in_the_cell () =
  (* The provisional regression is never confirmed: decide folds an empty
     confirmation list in, and the cell names the reason — there is no -v. *)
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  let v =
    verdict_of ~file (bcase "alpha", trial (ties 5 2e-6))
  in
  expect (Cli.render_check (ctx ()) v)
  @@ __POS_OF__
       {|
thumper: digest — 1 case vs digest.thumper for machine testkey

  inconclusive  2.00 us  ±0.0%  54 w  alpha
      unconfirmed; equivalent (alloc exact)

  1 case: 0 passed, 1 inconclusive.
|}

let exact_alloc_failure_names_the_alloc_side () =
  (* A case failing on alloc alone: the alloc-side detail carries the cell
     (the "REGRESSED alloc" form), integers with no interval. *)
  let v = exact_alloc_fail_fixture () in
  expect (Cli.render_check (ctx ()) v)
  @@ __POS_OF__
       {|
thumper: digest — 1 case vs digest.thumper for machine testkey

  REGRESSED  1.00 us  ±0.0%  71 w  alpha
      alloc 54 w → 71 w (exact)

  rerun:   bench.exe -f alpha

  1 case: 0 passed, 1 regressed.
|}

let per_column_time_unit_scaling () =
  (* A column holding 1.4 us and 33 ms renders at one unit — the smallest
     magnitude's — so cells stay comparable down the column. *)
  let file =
    file_of
      [
        wall_row "fast" (ties 5 1.4e-6);
        alloc_row "fast" 54;
        wall_row "slow" (ties 5 3.3e-2);
        alloc_row "slow" 54;
      ]
  in
  let v =
    verdict_of_cases ~file
      [
        (bcase "fast", trial (ties 5 1.4e-6));
        (bcase "slow", trial ~k:1 (ties 5 3.3e-2));
      ]
  in
  let out = Cli.render_check (ctx ()) v in
  assert_contains ~msg:"fast cell in us" out "1.40 us";
  assert_contains ~msg:"slow cell in the same unit" out "33000.00 us";
  is_true ~msg:"no ms cell" (not (contains out " ms"))

let alloc_column_scales_per_column () =
  (* The alloc column scales like the time column, from the column's
     smallest positive magnitude. A
     kilo-scale column renders scaled with trailing zeros trimmed... *)
  let v =
    verdict_of_cases
      [
        (bcase "alpha", trial ~alloc:(Some 3000) (ties 5 1e-6));
        (bcase "beta", trial ~alloc:(Some 32730) (ties 5 1e-6));
      ]
  in
  let out = Cli.render_check (ctx ~wrote:true ()) v in
  assert_contains ~msg:"trailing zeros trimmed" out "3 kw";
  assert_contains ~msg:"kilo scaling" out "32.73 kw";
  (* ...while a column whose smallest value is sub-kilo keeps exact
     integers with thousands separators: small counts stay exact. *)
  let v =
    verdict_of_cases
      [
        (bcase "alpha", trial ~alloc:(Some 54) (ties 5 1e-6));
        (bcase "beta", trial ~alloc:(Some 32730) (ties 5 1e-6));
      ]
  in
  let out = Cli.render_check (ctx ~wrote:true ()) v in
  assert_contains ~msg:"small counts exact" out "54 w";
  assert_contains ~msg:"separators at the base unit" out "32,730 w"

let large_alloc_cells_never_print_an_exponent () =
  (* Where [%.4g] (exact) or [%.3g] (sampled) would turn to exponent
     notation, a cell prints a grouped integer: a 12 Mw count in a kilo
     column, and a sampled 1,234.5 w beside a 54 w row. Exact cells below
     that keep their four significant digits. *)
  let sampled v =
    Run.Trial.make ~k:8
      [
        (m_wall, Run.Samples (sam (ties 5 1e-6)));
        (m_alloc, Run.Samples (sam (ties 5 v)));
      ]
  in
  let v =
    verdict_of_cases
      [
        (bcase "a", trial ~alloc:(Some 3000) (ties 5 1e-6));
        (bcase "b", trial ~alloc:(Some 12_345_678) (ties 5 1e-6));
        (bcase "c", sampled 2_345_678.);
        (bcase "d", trial ~alloc:(Some 999_600) (ties 5 1e-6));
        (bcase "e", trial ~alloc:(Some 1_234_500) (ties 5 1e-6));
        (bcase "f", trial ~alloc:(Some 9_999_500) (ties 5 1e-6));
        (bcase "g", sampled 999_500.);
      ]
  in
  expect (Cli.render_check (ctx ~wrote:true ()) v)
  @@ __POS_OF__
       {|
thumper: digest — no baseline for machine testkey (Test CPU)

  proposed  1.00 us  ±0.0%       3 kw  a
  proposed  1.00 us  ±0.0%  12,346 kw  b
  proposed  1.00 us  ±0.0%  ~2,346 kw  c
  proposed  1.00 us  ±0.0%   999.6 kw  d
  proposed  1.00 us  ±0.0%    1234 kw  e
  proposed  1.00 us  ±0.0%  10,000 kw  f
  proposed  1.00 us  ±0.0%  ~1,000 kw  g

  accept:  dune promote
|};
  let v =
    verdict_of_cases
      [
        (bcase "a", trial ~alloc:(Some 54) (ties 5 1e-6));
        (bcase "b", sampled 1234.5);
      ]
  in
  expect (Cli.render_check (ctx ~wrote:true ()) v)
  @@ __POS_OF__
       {|
thumper: digest — no baseline for machine testkey (Test CPU)

  proposed  1.00 us  ±0.0%      54 w  a
  proposed  1.00 us  ±0.0%  ~1,235 w  b

  accept:  dune promote
|}

let sampled_alloc_renders_approximate () =
  (* A failed exactness probe leaves sampled allocation evidence: the cell
     says so with the ~ marker, scaled, without a ci% of its own — one
     representation (the time ci already carries the run's sampling noise). *)
  let t =
    Run.Trial.make ~k:8
      [
        (m_wall, Run.Samples (sam (ties 5 1e-6)));
        (m_alloc, Run.Samples (sam (ties 5 2100.)));
      ]
  in
  let v = verdict_of (bcase "alpha", t) in
  let out = Cli.render_check (ctx ~wrote:true ()) v in
  assert_contains ~msg:"approximate, scaled" out "~2.1 kw";
  is_true ~msg:"no alloc-side ci%" (not (contains out "kw \xc2\xb1"))

let measurement_warnings_render_after_the_table () =
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  let warned =
    Run.Trial.make ~k:8
      ~warnings:[ "possibly folded: wrap the input in black_box" ]
      [ (m_wall, Run.Samples (sam (ties 5 1e-6))); (m_alloc, Run.Exact 54) ]
  in
  let v = verdict_of ~file (bcase "alpha", warned) in
  expect (Cli.render_check (ctx ()) v)
  @@ __POS_OF__
       {|
thumper: digest — 1 case vs digest.thumper for machine testkey

  equivalent  1.00 us  ±0.0%  54 w  alpha
  warning: alpha: possibly folded: wrap the input in black_box

  1 case: 1 passed.
|}

let absent_columns_leave_no_gap () =
  (* A column no case fills is left out whole, its separator included. *)
  let wall_only =
    Run.Trial.make ~k:8 [ (m_wall, Run.Samples (sam (ties 5 1e-6))) ]
  in
  let alloc_only = Run.Trial.make ~k:8 [ (m_alloc, Run.Exact 54) ] in
  assert_contains ~msg:"no alloc column"
    (Cli.render_check (ctx ()) (verdict_of (bcase "alpha", wall_only)))
    "\n  proposed  1.00 us  \xc2\xb10.0%  alpha\n";
  assert_contains ~msg:"no time column"
    (Cli.render_check (ctx ()) (verdict_of (bcase "alpha", alloc_only)))
    "\n  proposed  54 w  alpha\n"

let github_annotations_on_confirmed_regressions () =
  let v = fail_fixture () in
  let out = Cli.render_check (ctx ~github:true ()) v in
  assert_contains out
    "::error::alpha regressed: wall_time +100.0% [+100.0, +100.0], budget +5%\n";
  assert_contains ~msg:"exact"
    (Cli.render_check (ctx ~github:true ()) (exact_alloc_fail_fixture ()))
    "::error::alpha regressed: alloc_words 54 \xe2\x86\x92 71 w (exact)\n"

let absolute_cap_on_sampled_evidence_agrees_with_the_exit_code () =
  let v = absolute_cap_fixture () in
  (* Sanity: the fixture really reaches the dangerous state — a confirmed
     regressed relation, reported to JSON, on the only budgeted metric. *)
  assert_contains ~msg:"relation reported" (Verdict.to_json v)
    "\"relation\":\"regressed\"";
  equal ~msg:"exit code is 0 (absolute caps gate exact evidence only)" int 0
    (Verdict.exit_code v);
  let out = Cli.render_check (ctx ~github:true ()) v in
  is_true ~msg:"no capital REGRESSED on an exit-0 run"
    (not (contains out "REGRESSED"));
  assert_contains ~msg:"the demonstrated relation stays visible" out
    "regressed  1.00 us  \xc2\xb10.0%  ~200 w  alpha\n      alloc +100.0%";
  is_true ~msg:"no ::error:: annotation" (not (contains out "::error"));
  assert_contains ~msg:"summary agrees" out "1 case: 1 passed."

(* A 71-word exact count under a 64-word cap, with no baseline row for it:
   on a first run ([file] empty), or beside a compared time row. *)
let cap_without_a_row_fixture ?file ?(cap = 64.) ?(count = 71) () =
  let case =
    bcase_budgeted ~budgets:[ Budget.at_most ~metric:m_alloc cap ] "alpha"
  in
  verdict_of ?file (case, trial ~alloc:(Some count) (ties 5 1e-6))

let a_cap_fails_a_first_run () =
  let v = cap_without_a_row_fixture () in
  expect (Cli.render_check (ctx ~wrote:true ~github:true ()) v)
  @@ __POS_OF__
       {|
thumper: digest — no baseline for machine testkey (Test CPU)

  REGRESSED  1.00 us  ±0.0%  71 w  alpha
      alloc 71 w, over its 64 w cap (exact); proposed

  rerun:   bench.exe -f alpha
  accept:  dune promote

::error::alpha regressed: alloc_words 71 w, over its 64 w cap (exact)
|};
  equal ~msg:"exit 1" int 1 (Verdict.exit_code v)

let a_cap_fails_a_new_row () =
  let file = file_of [ wall_row "alpha" (ties 5 1e-6) ] in
  let v = cap_without_a_row_fixture ~file () in
  expect (Cli.render_check (ctx ~wrote:true ()) v)
  @@ __POS_OF__
       {|
thumper: digest — 1 case vs digest.thumper for machine testkey

  REGRESSED  1.00 us  ±0.0%  71 w  alpha
      alloc 71 w, over its 64 w cap (exact)

  rerun:   bench.exe -f alpha
  accept:  dune promote

  1 case: 0 passed, 1 regressed.
|};
  equal ~msg:"exit 1" int 1 (Verdict.exit_code v);
  assert_contains ~msg:"a fractional cap"
    (Cli.render_check (ctx ()) (cap_without_a_row_fixture ~file ~cap:64.5 ()))
    "alloc 71 w, over its 64.5 w cap (exact)";
  assert_contains ~msg:"a fraction below six decimals"
    (Cli.render_check (ctx ())
       (cap_without_a_row_fixture ~file ~cap:64.0000001 ()))
    "alloc 71 w, over its 64 w cap (exact)";
  (* Large counts and caps print grouped, never in exponent notation. *)
  let big cap = cap_without_a_row_fixture ~file ~cap ~count:1_234_568 () in
  let out = Cli.render_check (ctx ~github:true ()) (big 1e6) in
  assert_contains ~msg:"cell, integral cap" out
    "alloc 1,234,568 w, over its 1,000,000 w cap (exact)";
  assert_contains ~msg:"annotation, integral cap" out
    "::error::alpha regressed: alloc_words 1,234,568 w, over its 1,000,000 w \
     cap (exact)";
  let out = Cli.render_check (ctx ~github:true ()) (big 1234567.5) in
  assert_contains ~msg:"cell, fractional cap" out
    "alloc 1,234,568 w, over its 1,234,567.5 w cap (exact)";
  assert_contains ~msg:"annotation, fractional cap" out
    "::error::alpha regressed: alloc_words 1,234,568 w, over its 1,234,567.5 w \
     cap (exact)"

let color_uses_ansi_only_when_enabled () =
  let v = fail_fixture () in
  let plain = Cli.render_check (ctx ()) v in
  let colored = Cli.render_check (ctx ~color:true ()) v in
  is_true ~msg:"no escapes when off" (not (contains plain "\027["));
  assert_contains ~msg:"red REGRESSED when on" colored "\027[31m";
  assert_contains ~msg:"red summary line" colored "\027[31m1 case:";
  (* The cell styles: equivalent is faint. *)
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  let pass =
    verdict_of ~file (bcase "alpha", trial (ties 5 1e-6))
  in
  assert_contains ~msg:"faint equivalent cell when on"
    (Cli.render_check (ctx ~color:true ()) pass)
    "\027[2mequivalent\027[0m"

let summary_color_follows_the_exit_code () =
  (* An inconclusive run exits 0 and ends yellow; under --strict it exits 1,
     and its summary is red like any failing run's. The words stay. *)
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  let loaded = Env.Loaded { load = 7.9; cores = 8 } in
  let v =
    verdict_of ~load:loaded ~decide_load:loaded ~file
      (bcase "alpha", trial (ties 5 2e-6))
  in
  equal ~msg:"strict exits 1" int 1 (Verdict.exit_code ~strict:true v);
  let pass = verdict_of ~file (bcase "alpha", trial (ties 5 1e-6)) in
  assert_contains ~msg:"green when every case passes"
    (Cli.render_check (ctx ~color:true ()) pass)
    "\027[32m1 case: 1 passed.\027[0m";
  assert_contains ~msg:"yellow without --strict"
    (Cli.render_check (ctx ~color:true ()) v)
    "\027[33m1 case: 0 passed, 1 inconclusive.\027[0m";
  assert_contains ~msg:"red under --strict, which the words say"
    (Cli.render_check (ctx ~color:true ~strict:true ()) v)
    "\027[31m1 case: 0 passed, 1 inconclusive; failed under --strict.\027[0m"

let summary_counts_proposed_cases () =
  (* A case with no baseline row was never compared: proposed, not passed.
     Under --strict the run fails on it, and the summary says so. *)
  let file = file_of [ wall_row "alpha" (ties 5 1e-6); alloc_row "alpha" 54 ] in
  let v =
    verdict_of_cases ~file
      [
        (bcase "alpha", trial (ties 5 1e-6)); (bcase "beta", trial (ties 5 1e-6));
      ]
  in
  assert_contains
    (Cli.render_check (ctx ()) v)
    "  2 cases: 1 passed, 1 proposed.\n";
  assert_contains ~msg:"strict"
    (Cli.render_check (ctx ~strict:true ()) v)
    "  2 cases: 1 passed, 1 proposed; failed under --strict.\n"

(* Main: validation, unlinks, list, exits *)

let rejects_a_bad_suite_name () =
  raises_match
    (function Invalid_argument _ -> true | _ -> false)
    (fun () -> Cli.main ~argv:[| "bench.exe"; "list" |] ~name:"" benches)

let rejects_duplicate_suite_budgets () =
  raises
    (Invalid_argument
       "Thumper.run: two budgets for metric wall_time in one ~budgets list")
    (fun () ->
      Cli.main
        ~budgets:[ Budget.no_slower_than 0.05; Budget.no_slower_than 0.1 ]
        ~argv:[| "bench.exe"; "list" |] ~name:"digest" benches)

let help_exits_zero () =
  let code = Cli.main ~argv:[| "bench.exe"; "-h" |] ~name:"digest" benches in
  let out = output () in
  equal int 0 code;
  assert_contains out "usage:";
  assert_contains ~msg:"grammar names the three subcommands" out
    "[check|bless|list]";
  is_true ~msg:"help never names explore" (not (contains out "explore"))

let version_exits_zero () =
  let code = Cli.main ~argv:[| "bench.exe"; "-V" |] ~name:"digest" benches in
  let out = output () in
  equal int 0 code;
  (* "dev" in a working tree; the release tag after dune-subst watermarking —
     either way the line leads with the product name. *)
  assert_contains out "thumper "

let usage_errors_exit_2 () =
  let code =
    with_quiet_stderr (fun () ->
        Cli.main ~argv:[| "bench.exe"; "--bogus" |] ~name:"digest" benches)
  in
  equal int 2 code

let list_prints_resolved_ids () =
  let code = Cli.main ~argv:[| "bench.exe"; "list" |] ~name:"digest" benches in
  equal int 0 code;
  expect (output ()) @@ __POS_OF__ {|
alpha
g/beta
|}

let list_honors_the_selection () =
  let code =
    Cli.main
      ~argv:[| "bench.exe"; "list"; "--tag"; "lab" |]
      ~name:"digest" benches
  in
  equal int 0 code;
  expect (output ()) @@ __POS_OF__ {| g/beta |}

let empty_selection_exits_2 () =
  let code =
    with_quiet_stderr (fun () ->
        Cli.main
          ~argv:[| "bench.exe"; "list"; "-f"; "zzz" |]
          ~name:"digest" benches)
  in
  equal int 2 code

let a_wrong_suite_name_is_quoted () =
  (* The file's suite name is text from disk: a control byte in it prints
     escaped, never raw to the terminal. *)
  Unix.putenv "THUMPER_MACHINE" "testkey";
  let dir = temp_dir () in
  let bl = Filename.concat dir "digest.thumper" in
  write_file bl "# thumper baseline v1\n# suite: x\027]0;owned\007\n";
  let code, err =
    capturing_stderr (fun () ->
        Cli.main
          ~argv:[| "bench.exe"; "check"; "--baseline"; bl |]
          ~name:"digest" benches)
  in
  equal ~msg:"refused" int 2 code;
  is_true ~msg:"no raw escape" (not (String.contains err '\027'));
  assert_contains err
    "baseline is for suite 'x\\x1b]0;owned\\x07', not 'digest'"

let a_stale_identity_with_a_control_byte_is_quoted () =
  let header recorded =
    let file =
      Baseline.set_section
        (Baseline.empty ~suite:"digest")
        { ident with Baseline.ocaml = recorded }
        [ wall_row "alpha" (ties 5 1e-6) ]
    in
    let v = verdict_of ~file (bcase "alpha", trial (ties 5 1e-6)) in
    List.hd (String.split_on_char '\n' (Cli.render_check (ctx ()) v))
  in
  let current = ident.Baseline.ocaml in
  equal ~msg:"an escape" string
    ("thumper: digest — stale baseline for machine testkey (ocaml \
      '5.4.0\\x1b[2J' \xe2\x86\x92 " ^ current ^ ")")
    (header "5.4.0\027[2J");
  equal ~msg:"a DEL byte" string
    ("thumper: digest — stale baseline for machine testkey (ocaml '5.4\\x7f' \
      \xe2\x86\x92 " ^ current ^ ")")
    (header "5.4\127");
  equal ~msg:"plain text stays bare" string
    ("thumper: digest — stale baseline for machine testkey (ocaml 5.4.0 · \
      64-bit \xe2\x86\x92 " ^ current ^ ")")
    (header "5.4.0 · 64-bit")

let startup_unlinks_both_owned_artifacts () =
  let dir = temp_dir () in
  let bl = Filename.concat dir "digest.thumper" in
  let corrected = bl ^ ".corrected" in
  let json = Filename.concat dir "verdict.json" in
  write_file corrected "stale candidate";
  write_file json "stale verdict";
  (* The unlinks precede selection: an exit-2 empty selection still removes
     both owned artifacts. *)
  let code =
    with_quiet_stderr (fun () ->
        Cli.main
          ~argv:
            [|
              "bench.exe";
              "check";
              "--baseline";
              bl;
              "--json";
              json;
              "-f";
              "zzz";
            |]
          ~name:"digest" benches)
  in
  equal ~msg:"empty selection is exit 2" int 2 code;
  is_true ~msg:"corrected removed" (not (Sys.file_exists corrected));
  is_true ~msg:"json target removed" (not (Sys.file_exists json))

let unlinks_precede_the_failing_baseline_read () =
  Unix.putenv "THUMPER_MACHINE" "testkey";
  let dir = temp_dir () in
  let bl = Filename.concat dir "digest.thumper" in
  write_file bl "not a thumper baseline\n";
  let corrected = bl ^ ".corrected" in
  write_file corrected "stale candidate";
  let code =
    with_quiet_stderr (fun () ->
        Cli.main
          ~argv:[| "bench.exe"; "check"; "--baseline"; bl |]
          ~name:"digest" benches)
  in
  equal ~msg:"corrupt baseline is exit 2, never absent" int 2 code;
  is_true ~msg:"stale candidate removed before the read failed"
    (not (Sys.file_exists corrected))

let unconditional_targets_are_preflighted () =
  let dir = temp_dir () in
  let bl = Filename.concat dir "digest.thumper" in
  let missing = Filename.concat dir "nope" in
  (* A --json target in a missing directory could never be written: exit 2
     up front, before selection or measurement. *)
  let code =
    with_quiet_stderr (fun () ->
        Cli.main
          ~argv:
            [|
              "bench.exe";
              "check";
              "--baseline";
              bl;
              "--json";
              Filename.concat missing "v.json";
            |]
          ~name:"digest" benches)
  in
  equal ~msg:"missing --json directory is exit 2" int 2 code;
  (* bless writes its candidate unconditionally: same preflight. *)
  let code =
    with_quiet_stderr (fun () ->
        Cli.main
          ~argv:
            [|
              "bench.exe";
              "bless";
              "--baseline";
              Filename.concat missing "d.thumper";
            |]
          ~name:"digest" benches)
  in
  equal ~msg:"missing bless candidate directory is exit 2" int 2 code

(* Without a baseline every row is new, so the corrected file is certain and
   its target is pre-flighted: a missing directory is exit 2 before the lease
   is ever taken (no lock file) and before anything is measured. *)
let absent_baseline_preflights_the_corrected_file () =
  let dir = temp_dir () in
  e2e_env dir;
  let bl = Filename.concat (Filename.concat dir "nope") "digest.thumper" in
  let code =
    with_quiet_stderr (fun () ->
        Cli.main ~config:fast_config
          ~argv:[| "bench.exe"; "check"; "--baseline"; bl |]
          ~name:"digest" benches)
  in
  equal ~msg:"unwritable corrected file is exit 2" int 2 code;
  equal ~msg:"no report" string "" (output ());
  is_true ~msg:"refused before the lease"
    (not
       (Sys.file_exists
          (Filename.concat dir
             (Printf.sprintf "thumper-%d.lock" (Unix.geteuid ())))))

(* A baseline without this machine's section is read, so nothing is
   pre-flighted; when the corrected file then cannot be written (its
   directory vanishes during measurement), the report still prints whole,
   without an accept line, and the run exits 2. *)
let late_write_failure_prints_the_report () =
  let dir = temp_dir () in
  e2e_env dir;
  let sub = Filename.concat dir "gone" in
  Unix.mkdir sub 0o700;
  let bl = Filename.concat sub "digest.thumper" in
  Baseline.write bl
    (Baseline.set_section
       (Baseline.empty ~suite:"digest")
       { ident with Baseline.machine = "otherkey" }
       [ wall_row "alpha" (ties 5 1e-6) ]);
  let vanish () =
    if Sys.file_exists sub then begin
      Sys.remove bl;
      Sys.rmdir sub
    end
  in
  let code =
    with_quiet_stderr (fun () ->
        Cli.main ~config:fast_config
          ~argv:[| "bench.exe"; "check"; "--baseline"; bl |]
          ~name:"digest"
          [ Bench.bench "alpha" vanish ])
  in
  let out = output () in
  equal ~msg:"failed write is exit 2" int 2 code;
  assert_contains ~msg:"the report printed" out
    "no baseline for machine testkey";
  assert_contains ~msg:"its rows" out "proposed";
  is_true ~msg:"no accept line for a file that does not exist"
    (not (contains out "accept:"))

(* Main: fast end-to-end flows *)

let check_new_flow_end_to_end () =
  let dir = temp_dir () in
  e2e_env dir;
  let bl = Filename.concat dir "digest.thumper" in
  let json = Filename.concat dir "verdict.json" in
  let code =
    with_quiet_stderr (fun () ->
        Cli.main ~config:fast_config
          ~argv:[| "bench.exe"; "check"; "--baseline"; bl; "--json"; json |]
          ~name:"digest" benches)
  in
  let out = output () in
  equal ~msg:"NEW flow exits 0" int 0 code;
  is_true ~msg:"candidate written" (Sys.file_exists (bl ^ ".corrected"));
  is_true ~msg:"json written" (Sys.file_exists json);
  assert_contains ~msg:"NEW header" out "no baseline for machine testkey";
  assert_contains ~msg:"proposed rows" out "proposed";
  assert_contains ~msg:"acceptance prompt" out "accept:  ";
  let doc = In_channel.with_open_bin json In_channel.input_all in
  assert_contains ~msg:"NEW rows in the document" doc "missing_baseline";
  assert_contains ~msg:"NEW is a pass, not a verdict" doc "\"overall\":\"pass\""

let strict_turns_new_into_exit_1 () =
  let dir = temp_dir () in
  e2e_env dir;
  let bl = Filename.concat dir "digest.thumper" in
  let code =
    with_quiet_stderr (fun () ->
        Cli.main ~config:fast_config
          ~argv:[| "bench.exe"; "check"; "--strict"; "--baseline"; bl |]
          ~name:"digest" benches)
  in
  let _ = output () in
  equal ~msg:"NEW under --strict exits 1" int 1 code

let partial_bless_rerecords_the_selected_cases_only () =
  let dir = temp_dir () in
  e2e_env dir;
  let bl = Filename.concat dir "digest.thumper" in
  let current = { ident with Baseline.ocaml = Env.ocaml_identity () } in
  let beta = [ wall_row "g/beta" (ties 5 1e-6); alloc_row "g/beta" 54 ] in
  Baseline.write bl
    (Baseline.set_section (Baseline.empty ~suite:"digest") current beta);
  (* --force keeps the run deterministic on a loaded host (the gate refusal
     needs a reliably loaded host, which no test can arrange); under a quiet
     gate it is a no-op. *)
  let bless () =
    with_quiet_stderr (fun () ->
        Cli.main ~config:fast_config
          ~argv:
            [|
              "bench.exe"; "bless"; "--baseline"; bl; "-f"; "alpha"; "--force";
            |]
          ~name:"digest" benches)
  in
  let code = bless () in
  let out = output () in
  equal ~msg:"bless exits 0" int 0 code;
  assert_contains ~msg:"bless header" out "blessed 1 case for machine testkey";
  assert_contains ~msg:"acceptance prompt" out "accept:  ";
  is_true ~msg:"nothing dropped, no notice" (not (contains out "unselected"));
  let corrected () =
    In_channel.with_open_bin (bl ^ ".corrected") In_channel.input_all
  in
  let cand = corrected () in
  assert_contains ~msg:"selected case recorded" cand "alpha\t";
  List.iter
    (fun row ->
      let line = Baseline.row_id row ^ "\t" ^ Baseline.row_metric row in
      assert_contains ~msg:"unselected rows kept" cand line)
    beta;
  if contains cand "# forced:" then
    assert_contains ~msg:"a partial forced bless names its cases" cand
      "# forced: blessed alpha under load ";
  (* Over a stale section the bless is wholesale again, and says what it
     drops. *)
  Baseline.write bl
    (Baseline.set_section (Baseline.empty ~suite:"digest") ident beta);
  let code = bless () in
  let out = output () in
  equal ~msg:"stale bless exits 0" int 0 code;
  assert_contains ~msg:"the drop is noticed" out
    "partial selection on a stale section — the corrected file re-records this \
     machine's whole section and drops the rows of the 1 unselected case";
  is_true ~msg:"unselected rows dropped (wholesale re-record)"
    (not (contains (corrected ()) "g/beta"))

(* The real fixture executable, invoked through its [_build] path from a
   scratch cwd: the candidate must land next to the fixture's {e source}
   directory (test/cram/fixture — the committable location), and an explicit
   [--baseline] must bypass the mapping entirely. The single write into the
   repo source tree is removed again before the test returns. *)
let default_path_lands_next_to_the_source () =
  let start_cwd = Sys.getcwd () in
  let exe = Filename.concat start_cwd "cram/fixture/bench_fixture.exe" in
  let last_build_marker s =
    let marker = "/_build/" in
    let n = String.length s and m = String.length marker in
    let rec go i best =
      if i + m > n then best
      else if String.equal (String.sub s i m) marker then go (i + 1) (Some i)
      else go (i + 1) best
    in
    go 0 None
  in
  match last_build_marker start_cwd with
  | None -> skip ~reason:"test cwd is not under _build" ()
  | Some i ->
      let src_dir =
        Filename.concat (String.sub start_cwd 0 i) "test/cram/fixture"
      in
      is_true ~msg:"derived the fixture's real source directory"
        (Sys.file_exists (Filename.concat src_dir "bench_fixture.ml"));
      is_true ~msg:"no stray baseline in the fixture source directory"
        (not (Sys.file_exists (Filename.concat src_dir "fixture.thumper")));
      let candidate = Filename.concat src_dir "fixture.thumper.corrected" in
      let scratch = temp_dir () in
      e2e_env scratch;
      let log = Filename.concat scratch "out.log" in
      let run args =
        Sys.command
          (Printf.sprintf "%s %s > %s 2>/dev/null" (Filename.quote exe) args
             (Filename.quote log))
      in
      Fun.protect
        ~finally:(fun () ->
          if Sys.file_exists candidate then Sys.remove candidate;
          Unix.chdir start_cwd)
        (fun () ->
          Unix.chdir scratch;
          equal ~msg:"NEW flow exits 0" int 0 (run "check --quick -f busy/spin");
          is_true ~msg:"candidate lands next to the fixture source"
            (Sys.file_exists candidate);
          is_true ~msg:"nothing lands in the invoker's cwd"
            (not
               (Sys.file_exists
                  (Filename.concat scratch "fixture.thumper.corrected")));
          let out = In_channel.with_open_bin log In_channel.input_all in
          assert_contains ~msg:"the accept hint names the source-dir path" out
            ("accept:  mv " ^ candidate);
          Sys.remove candidate;
          (* --baseline always wins over the mapping. *)
          let bl = Filename.concat scratch "explicit.thumper" in
          equal ~msg:"explicit --baseline exits 0" int 0
            (run
               (Printf.sprintf "check --quick -f busy/spin --baseline %s"
                  (Filename.quote bl)));
          is_true ~msg:"candidate lands beside the explicit path"
            (Sys.file_exists (bl ^ ".corrected"));
          is_true ~msg:"the mapping is bypassed"
            (not (Sys.file_exists candidate));
          (* A relative path prints as typed, without its [.] segments. *)
          equal ~msg:"relative --baseline exits 0" int 0
            (run "check --quick -f busy/spin --baseline ./typed.thumper");
          let out = In_channel.with_open_bin log In_channel.input_all in
          assert_contains ~msg:"the accept hint names the path as typed" out
            "accept:  mv typed.thumper.corrected typed.thumper\n")

(* Suite *)

let () =
  run "cli"
    [
      group "parse"
        [
          test "defaults: check, nothing set"
            defaults_are_check_with_nothing_set;
          test "first argument names the subcommand"
            first_argument_names_the_subcommand;
          test "explore is a selection pattern, not a subcommand"
            explore_is_a_pattern;
          test "later subcommand word is a pattern"
            later_subcommand_word_is_a_pattern;
          test "bare positionals are -f patterns" bare_positionals_are_patterns;
          test "repeatable flags keep encounter order"
            repeatable_flags_keep_encounter_order;
          test "long options accept --opt=value" long_options_accept_equals_form;
          test "a flag refuses an equals value" a_flag_refuses_an_equals_value;
          test "value and boolean flags parse" value_flags_parse;
          test "--precise parses" precise_preset_parses;
          test "--color parses auto, always, never" color_parses;
          test "--quick with --precise is a usage error"
            quick_and_precise_conflict;
          test "missing option arguments are usage errors"
            missing_option_arguments_are_usage_errors;
          test "malformed --wait-quiet is a usage error"
            malformed_wait_quiet_is_a_usage_error;
          test "--json - is a usage error" json_dash_is_a_usage_error;
          test "unknown options are usage errors"
            unknown_options_are_usage_errors;
          test "-h and -V win" help_and_version_win;
          test "-v, --no-fork, --no-color, and the v1 aliases are deleted"
            deleted_spellings_are_unknown_options;
          test "the flag-scoping matrix refuses out-of-scope flags"
            flag_scoping_matrix;
          test "-- ends option parsing" double_dash_ends_options;
          test "a lone dash is a pattern" lone_dash_is_a_pattern;
        ];
      group "filters"
        [ test "ids OR'd, tags AND'd, empty sides omitted" filter_composition ];
      group "config"
        [
          test "presets refine n; the CLI never flips fork"
            config_of_refines_presets_only;
          test "the caller's other knobs are kept"
            config_of_keeps_the_callers_knobs;
        ];
      group "color"
        [
          test "per-stream resolution: auto, always, never" use_color_resolution;
        ];
      group "status"
        [ test "the status line formats both sweeps" status_line_formats ];
      group "hints"
        [
          test "promotion is staged only in a rule action"
            promotion_staged_predicate;
          test "accept command forks on staging" accept_command_fork;
          test "accept command quotes hostile paths"
            accept_command_quotes_hostile_paths;
          test "rerun hint reproduces the invocation"
            rerun_hint_reproduces_the_invocation;
          test "rerun hint wraps within 80 columns"
            rerun_hint_wraps_within_80_columns;
          test "rerun hint wraps at exactly 80 columns"
            rerun_hint_wraps_at_exactly_80_columns;
          test "rerun hint names at most ten cases"
            rerun_hint_names_at_most_ten_cases;
        ];
      group "baseline path"
        [
          test "maps an exe under _build to its source directory"
            default_dir_maps_exe_to_its_source_directory;
          test "falls back to the cwd (installed exe, missing directory)"
            default_dir_falls_back_to_the_cwd;
          test "a build-directory cwd resolves in the cwd"
            default_dir_stays_in_a_build_cwd;
        ];
      group "render check"
        [
          test "mixed run: header, table, actions, summary"
            mixed_run_renders_all_four_blocks;
          test "pass run: header, table, summary (never silent)"
            pass_run_renders_header_table_summary;
          test "NEW run: proposed rows and the accept prompt"
            new_run_renders_proposed_rows_and_the_accept_prompt;
          test "mv hint replaces promote outside dune"
            mv_hint_replaces_promote_outside_dune;
          test "loaded compared run warns directly under the header"
            loaded_run_warns_under_the_header;
          test "loaded NEW run warns beside the prompt (one load message)"
            loaded_new_run_warns_beside_the_prompt;
          test "improvement-only run renders the accept line"
            improvement_only_renders_the_accept_line;
          test "within budget prints its interval"
            within_budget_prints_its_interval;
          test "unconfirmed inconclusive names the reason in the cell"
            unconfirmed_inconclusive_names_the_reason_in_the_cell;
          test "exact alloc failure names the alloc side"
            exact_alloc_failure_names_the_alloc_side;
          test "per-column time unit scaling never mixes units"
            per_column_time_unit_scaling;
          test "alloc column scales per column" alloc_column_scales_per_column;
          test "sampled alloc renders approximate with the ~ marker"
            sampled_alloc_renders_approximate;
          test "large alloc cells never print an exponent"
            large_alloc_cells_never_print_an_exponent;
          test "measurement warnings render after the table"
            measurement_warnings_render_after_the_table;
          test "an absent column leaves no gap" absent_columns_leave_no_gap;
          test "a proposed metric reads as proposed"
            a_proposed_metric_reads_as_proposed;
          test "GitHub annotations on confirmed regressions"
            github_annotations_on_confirmed_regressions;
          test "an absolute cap on sampled evidence agrees with the exit code"
            absolute_cap_on_sampled_evidence_agrees_with_the_exit_code;
          test "a cap fails a first run" a_cap_fails_a_first_run;
          test "a cap fails a new row" a_cap_fails_a_new_row;
          test "ANSI color only when enabled" color_uses_ansi_only_when_enabled;
          test "the summary counts proposed cases" summary_counts_proposed_cases;
          test "the summary's color follows the exit code"
            summary_color_follows_the_exit_code;
        ];
      group "main"
        [
          test "rejects an empty suite name" rejects_a_bad_suite_name;
          test "rejects duplicate suite budgets" rejects_duplicate_suite_budgets;
          test "-h exits 0 with usage" help_exits_zero;
          test "-V exits 0 with the version" version_exits_zero;
          test "usage errors exit 2" usage_errors_exit_2;
          test "list prints resolved ids" list_prints_resolved_ids;
          test "list honors the selection" list_honors_the_selection;
          test "a wrong suite name is quoted" a_wrong_suite_name_is_quoted;
          test "a stale identity with a control byte is quoted"
            a_stale_identity_with_a_control_byte_is_quoted;
          test "empty selection exits 2" empty_selection_exits_2;
          test "startup unlinks both owned artifacts"
            startup_unlinks_both_owned_artifacts;
          test "unlinks precede the failing baseline read"
            unlinks_precede_the_failing_baseline_read;
          test "unconditional write targets are pre-flighted"
            unconditional_targets_are_preflighted;
          test "an absent baseline pre-flights the corrected file"
            absent_baseline_preflights_the_corrected_file;
          test "a late write failure prints the report, then exits 2"
            late_write_failure_prints_the_report;
        ];
      group "end-to-end"
        [
          test "check NEW flow: exit 0, candidate, json, prompt"
            check_new_flow_end_to_end;
          test "--strict turns NEW into exit 1" strict_turns_new_into_exit_1;
          test "a partial bless re-records the selected cases only"
            partial_bless_rerecords_the_selected_cases_only;
          test "default path lands next to the benchmark source"
            default_path_lands_next_to_the_source;
        ];
    ]
  |> exit
