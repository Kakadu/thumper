(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Tests for [Cli]: the argv grammar (subcommands,
   positionals-as-patterns, repeatable flags, the flag-scoping matrix, usage
   errors — including the deleted spellings [explore], [-v], [--no-fork],
   [--no-color], and the v1 aliases), filter composition, the config policy
   ([config_of]: presets only — the CLI never flips [fork]), color
   resolution ([use_color]), the INSIDE_DUNE hint fork, the
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
module Cli = Thumper.Private.Cli
module Config = Thumper.Private.Config
module Env = Thumper.Private.Env

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

let ident =
  {
    Baseline.machine = "testkey";
    host = "test-host";
    ocaml = "5.5.0 · 64-bit · release";
  }

let ties n v = Array.make n v

let wall_row ?(k = 8) id samples =
  Baseline.sampled_row ~id ~metric:"wall_time" ~k ~samples

let alloc_row id n = Baseline.exact_row ~id ~metric:"alloc_words" n
let section_of file = Option.get (Baseline.section file "testkey")

let benches =
  [
    Bench.bench "alpha" (fun () -> ());
    Bench.group "g" [ Bench.bench ~tags:[ "lab" ] "beta" (fun () -> ()) ];
  ]

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

(* The default baseline path

   The pure mapping behind the default [<suite>.thumper] location: [dir_exists]
   is a set-membership test, so every branch runs without processes or a
   filesystem. *)

let map ?(dirs = []) ?(cwd = "/ws") ?inside_dune ?source_root exe =
  Cli.default_baseline_dir
    ~dir_exists:(fun d -> List.mem d dirs)
    ~inside_dune ~source_root ~exe ~cwd

let dune_map ?dirs ?cwd ?(context = "/ws/_build_sys/default") exe =
  map ?dirs ?cwd ~inside_dune:context ~source_root:"/ws" exe

let default_dir_follows_dunes_environment () =
  (* Under dune ([INSIDE_DUNE] the context's directory, [DUNE_SOURCEROOT] the
     workspace root), the executable's path in the context maps into the
     source tree, whatever the build directory is called. *)
  equal ~msg:"DUNE_BUILD_DIR=_build_sys dune exec" string "/ws/bench"
    (dune_map ~dirs:[ "/ws/bench" ] "/ws/_build_sys/default/bench/b.exe");
  equal ~msg:"a named context" string "/ws/bench"
    (dune_map ~dirs:[ "/ws/bench" ] ~context:"/ws/_out/musl"
       "/ws/_out/musl/bench/b.exe");
  equal ~msg:"an exe at the workspace root" string "/ws"
    (dune_map ~dirs:[ "/ws" ] "/ws/_build_sys/default/b.exe");
  equal ~msg:"a relative exe resolves against the cwd" string "/ws/bench"
    (dune_map ~dirs:[ "/ws/bench" ] "_build_sys/default/bench/b.exe");
  (* [cd test/cram && dune exec --root ../.. ./test/cram/x.exe]: the exe's
     path runs through [..] segments. *)
  equal ~msg:"an exe path through .. segments" string "/ws/test/cram/fixture"
    (dune_map
       ~dirs:[ "/ws/test/cram/fixture" ]
       ~cwd:"/ws/test/cram"
       "/ws/test/cram/../../_build_sys/default/test/cram/fixture/x.exe");
  equal ~msg:"a relative exe path through .. segments" string "/ws/bench"
    (dune_map ~dirs:[ "/ws/bench" ] ~cwd:"/ws/test/cram"
       "../../_build_sys/default/./bench/b.exe");
  equal ~msg:"the invoker's cwd does not steer the mapping" string "/ws/bench"
    (dune_map ~dirs:[ "/ws/bench" ] ~cwd:"/somewhere/else"
       "/ws/_build_sys/default/bench/b.exe");
  (* A rule action runs inside the build directory, sandboxed or not, and
     resolves in its cwd: the [diff?] contract. *)
  equal ~msg:"a rule action" string "/ws/_build_sys/default/bench"
    (dune_map ~dirs:[ "/ws/bench" ] ~cwd:"/ws/_build_sys/default/bench"
       "/ws/_build_sys/default/bench/b.exe");
  equal ~msg:"a sandboxed rule action" string
    "/ws/_build_sys/.sandbox/0f/default/bench"
    (dune_map ~dirs:[ "/ws/bench" ]
       ~cwd:"/ws/_build_sys/.sandbox/0f/default/bench"
       "/ws/_build_sys/.sandbox/0f/default/bench/b.exe");
  equal ~msg:"an exe outside the context, as an installed one" string "/ws"
    (dune_map ~dirs:[ "/ws/bin" ] "/ws/_build_sys/install/default/bin/b");
  equal ~msg:"a missing source directory" string "/ws"
    (dune_map "/ws/_build_sys/default/gen/b.exe");
  (* One variable alone is no contract, and no layout is guessed. *)
  equal ~msg:"INSIDE_DUNE alone" string "/ws"
    (map ~dirs:[ "/ws/bench" ] ~inside_dune:"1" "/ws/_build/default/bench/b.exe");
  equal ~msg:"DUNE_SOURCEROOT alone" string "/ws"
    (map ~dirs:[ "/ws/bench" ] ~source_root:"/ws"
       "/ws/_build/default/bench/b.exe")

(* Without dune's environment, a run by hand recognises dune's [_build]. *)

let default_dir_maps_exe_to_its_source_directory () =
  equal ~msg:"a hand run from the workspace root" string "/ws/examples/01"
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
  (* A cwd inside [_build] resolves in the cwd, as a rule action does: a
     build action must never write to the source tree. *)
  equal string "/ws/_build/default/bench"
    (map ~cwd:"/ws/_build/default/bench" ~dirs:[ "/ws/bench" ]
       "/ws/_build/default/bench/b.exe")

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
    "partial selection on a stale section: the corrected file re-records this \
     machine's whole section and drops the rows of the 1 unselected case";
  is_true ~msg:"unselected rows dropped (wholesale re-record)"
    (not (contains (corrected ()) "g/beta"))

(* The command line holds the whole suite, so a check of every case prunes
   the rows of a case the suite no longer has. *)
let check_prunes_a_vanished_case () =
  let dir = temp_dir () in
  e2e_env dir;
  let bl = Filename.concat dir "digest.thumper" in
  let current = { ident with Baseline.ocaml = Env.ocaml_identity () } in
  Baseline.write bl
    (Baseline.set_section
       (Baseline.empty ~suite:"digest")
       current
       [ wall_row "alpha" (ties 5 1e-6); wall_row "dead" (ties 5 1e-6) ]);
  let (_ : int) =
    with_quiet_stderr (fun () ->
        Cli.main ~config:fast_config
          ~argv:[| "bench.exe"; "check"; "--baseline"; bl |]
          ~name:"digest" benches)
  in
  assert_contains ~msg:"the prune notice" (output ())
    "case dead no longer exists in this binary; its rows will be pruned from \
     the corrected file";
  let corrected =
    In_channel.with_open_bin (bl ^ ".corrected") In_channel.input_all
  in
  is_true ~msg:"the row is pruned" (not (contains corrected "dead\t"))

(* The rerun line names the executable as the shell that ran it can paste
   it: a bare name, found on PATH, as typed; a path under the working
   directory as [./<rel>]; any other path absolute. *)
let rerun_names_the_executable_from_the_cwd () =
  let start_cwd = Sys.getcwd () in
  let dir = Unix.realpath (temp_dir ()) in
  e2e_env dir;
  Unix.mkdir (Filename.concat dir "sub") 0o700;
  let bl = Filename.concat dir "digest.thumper" in
  let current = { ident with Baseline.ocaml = Env.ocaml_identity () } in
  Baseline.write bl
    (Baseline.set_section
       (Baseline.empty ~suite:"digest")
       current
       [ alloc_row "alloc" 0 ]);
  let allocating =
    [ Bench.bench "alloc" (fun () -> ignore (Sys.opaque_identity (ref 0))) ]
  in
  let rerun_exe argv0 =
    let (_ : int) =
      with_quiet_stderr (fun () ->
          Cli.main ~config:fast_config
            ~budgets:[ Budget.no_more_alloc_than 0.0 ]
            ~argv:[| argv0; "check"; "--baseline"; bl |]
            ~name:"digest" allocating)
    in
    let label = "  rerun:   " in
    let n = String.length label in
    match
      List.find_opt
        (fun l -> String.length l > n && String.equal (String.sub l 0 n) label)
        (String.split_on_char '\n' (output ()))
    with
    | None -> failf "no rerun line for %s" argv0
    | Some l ->
        List.hd
          (String.split_on_char ' ' (String.sub l n (String.length l - n)))
  in
  Fun.protect
    ~finally:(fun () -> Unix.chdir start_cwd)
    (fun () ->
      Unix.chdir dir;
      equal ~msg:"a bare name" string "bench.exe" (rerun_exe "bench.exe");
      equal ~msg:"an absolute path under the cwd" string "./sub/b.exe"
        (rerun_exe (Filename.concat dir "sub/b.exe"));
      equal ~msg:"a relative path, resolved" string "./sub/b.exe"
        (rerun_exe "sub/../sub/b.exe");
      equal ~msg:"a path outside the cwd" string "/nonexistent/b.exe"
        (rerun_exe "/nonexistent/b.exe");
      Unix.chdir (Filename.concat dir "sub");
      equal ~msg:"a relative path outside the cwd" string
        (Filename.concat dir "b.exe")
        (rerun_exe "../b.exe"))

(* The real fixture executable, invoked through its build path from a
   scratch cwd, in the environment dune gave this test: the candidate must
   land next to the fixture's {e source} directory (test/cram/fixture — the
   committable location), whatever the build directory is called, and an
   explicit [--baseline] must bypass the mapping entirely. The single write
   into the repo source tree is removed again before the test returns. *)
let default_path_lands_next_to_the_source () =
  let start_cwd = Sys.getcwd () in
  let exe = Filename.concat start_cwd "../cram/fixture/bench_fixture.exe" in
  match (Sys.getenv_opt "INSIDE_DUNE", Sys.getenv_opt "DUNE_SOURCEROOT") with
  | None, _ | _, None -> skip ~reason:"not run by dune" ()
  | Some context, Some root ->
      let src_dir = Filename.concat root "test/cram/fixture" in
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
          (* Where the dotted run would propose without the mapping. *)
          let stray =
            Filename.concat root "test/cram/fixture.thumper.corrected"
          in
          if Sys.file_exists stray then Sys.remove stray;
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
          (* [cd test/cram && dune exec --root ../.. ./test/cram/...]: from
             a source subdirectory, the executable path runs through [..]
             segments, and maps the same way. *)
          let context_rel =
            let n = String.length root in
            String.sub context (n + 1) (String.length context - n - 1)
          in
          Unix.chdir (Filename.concat root "test/cram");
          let dotted =
            String.concat "/"
              [ ".."; ".."; context_rel; "test/cram/fixture/bench_fixture.exe" ]
          in
          equal ~msg:"a dotted exe path exits 0" int 0
            (Sys.command
               (Printf.sprintf "%s check --quick -f busy/spin > %s 2>/dev/null"
                  (Filename.quote dotted) (Filename.quote log)));
          is_true ~msg:"a dotted exe path lands next to the fixture source"
            (Sys.file_exists candidate);
          Sys.remove candidate;
          Unix.chdir scratch;
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
      group "hints"
        [
          test "promotion is staged only in a rule action"
            promotion_staged_predicate;
          test "accept command forks on staging" accept_command_fork;
          test "accept command quotes hostile paths"
            accept_command_quotes_hostile_paths;
        ];
      group "baseline path"
        [
          test "follows dune's environment"
            default_dir_follows_dunes_environment;
          test "by hand, maps an exe under _build to its source directory"
            default_dir_maps_exe_to_its_source_directory;
          test "falls back to the cwd (installed exe, missing directory)"
            default_dir_falls_back_to_the_cwd;
          test "a build-directory cwd resolves in the cwd"
            default_dir_stays_in_a_build_cwd;
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
          test "check prunes a vanished case" check_prunes_a_vanished_case;
          test "rerun names the executable from the cwd"
            rerun_names_the_executable_from_the_cwd;
          test "default path lands next to the benchmark source"
            default_path_lands_next_to_the_source;
        ];
    ]
  |> exit
