(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* [Cli.main] is driven through its argv, in process, and observed through
   what it prints, its exit code and the files it leaves. Most claims are
   reached through a stop, which [main] makes before it measures anything:
   the parse through the usage errors and through [list], the baseline path
   through the pre-flight stop of a directory that does not exist. The report
   is [test_report]'s; here a report is read only for the variant [main]
   chose, and those runs measure for real, on a millisecond protocol, in
   process, reading nothing a timing moves: they are [slow]. Every test states
   its environment and runs in its own directory. *)

open Windtrap
module Baseline = Thumper.Private.Baseline
module Bench = Thumper.Private.Bench
module Budget = Thumper.Private.Budget
module Cli = Thumper.Private.Cli
module Config = Thumper.Private.Config
module Env = Thumper.Private.Env
module Metric = Thumper.Private.Metric

(* The stated environment: the machine key is given, the lock lives in the
   test's own directory, nothing else the command line reads is inherited, and
   the test runs in a fresh directory, which is returned, symbolic links
   resolved as [Sys.getcwd] resolves them. *)
let state_env () =
  let dir = Unix.realpath (temp_dir ~prefix:"cli" ()) in
  setenv "THUMPER_MACHINE" (Some "testkey");
  setenv "THUMPER_LOCK_DIR" (Some (temp_dir ~prefix:"lock" ()));
  List.iter
    (fun v -> setenv v None)
    [
      "INSIDE_DUNE";
      "DUNE_SOURCEROOT";
      "CI";
      "GITHUB_ACTIONS";
      "NO_COLOR";
      "TERM";
    ];
  chdir dir;
  dir

let write_file path s =
  Out_channel.with_open_bin path (fun oc -> output_string oc s)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let rec mkdirs path =
  if not (Sys.file_exists path) then begin
    mkdirs (Filename.dirname path);
    Unix.mkdir path 0o700
  end

(* [s] with every [sub] replaced by [by]. *)
let replace ~sub ~by s =
  let n = String.length sub and len = String.length s in
  let b = Buffer.create len in
  let rec go i =
    if i > len - n then Buffer.add_substring b s i (len - i)
    else if String.equal (String.sub s i n) sub then begin
      Buffer.add_string b by;
      go (i + n)
    end
    else begin
      Buffer.add_char b s.[i];
      go (i + 1)
    end
  in
  go 0;
  Buffer.contents b

(* The build context this executable runs in, as [INSIDE_DUNE] names it:
   [test/unit/test_cli.exe] lies under it. *)
let exe_context =
  Filename.dirname (Filename.dirname (Filename.dirname Sys.executable_name))

(* The workspace, when the build directory is [_build]. *)
let workspace =
  let build = Filename.dirname exe_context in
  if String.equal (Filename.basename build) "_build" then
    Some (Filename.dirname build)
  else None

(* What the test printed, its directory written [$D], the workspace [$WS] and
   the lock file's user [$UID]. *)
let printed dir =
  let s = replace ~sub:dir ~by:"$D" (output ()) in
  let s =
    match workspace with Some ws -> replace ~sub:ws ~by:"$WS" s | None -> s
  in
  replace
    ~sub:(Printf.sprintf "thumper-%d.lock" (Unix.geteuid ()))
    ~by:"thumper-$UID.lock" s

let benches =
  [
    Bench.bench "alpha" (fun () -> ());
    Bench.group "g"
      [
        Bench.bench ~tags:[ "lab" ] "beta" (fun () -> ());
        Bench.bench ~tags:[ "lab"; "ci" ] "gamma" (fun () -> ());
      ];
  ]

(* [main args] runs the command line [bench.exe args] on the suite [digest]
   of [benches], its baseline [digest.thumper] in the working directory unless
   [baseline] says otherwise. *)
let main ?(exe = "bench.exe") ?(name = "digest")
    ?(baseline = Some "digest.thumper") ?config ?budgets ?(benches = benches)
    args =
  Cli.main ?baseline ?config ?budgets
    ~argv:(Array.of_list (exe :: args))
    ~name benches

(* A protocol small enough for in-process runs through [main]: three batches
   at a 10 us floor, no warmup, in process, collecting the allocation count
   alone, so no timed value enters a verdict. *)
let fast_config =
  Config.(
    default |> samples 3 |> batch_floor 1e-5 |> warmup 0. |> fork false
    |> metrics [ Metric.alloc_words ])

let allocates () = ignore (Sys.opaque_identity (ref 0))

(* A case over its allocation cap and a case with no row: without a baseline,
   the run fails, proposes both rows and writes the corrected file, so its
   report has both actions. *)
let failing =
  [
    Bench.bench ~tags:[ "t" ]
      ~budgets:[ Budget.at_most ~metric:Metric.alloc_words 0. ]
      "alloc" allocates;
    Bench.bench "fresh" (fun () -> ());
  ]

let current_identity () =
  {
    Baseline.machine = "testkey";
    host = "test-host";
    ocaml = Env.ocaml_identity ();
  }

let write_baseline ?(identity = current_identity ()) path rows =
  Baseline.write path
    (Baseline.set_section (Baseline.empty ~suite:"digest") identity rows)

let alloc_row id n = Baseline.exact_row ~id ~metric:"alloc_words" n

(* A usage error, a stop or a listing: the exit code and what was printed. *)
type outcome = { args : string list; code : int; expected : pos * string }

let row ?(code = 2) name args expected = (name, { args; code; expected })

let check_outcome dir o code =
  equal ~msg:"exit code" int o.code code;
  expect (printed dir) o.expected

(* A usage error prints its message, then where to find the usage. *)
let refuses (_, o) =
  let dir = state_env () in
  equal ~msg:"exit code" int 2 (main o.args);
  let out = printed dir in
  let nl = String.index out '\n' in
  equal ~msg:"the second line" string "Try '-h' for usage.\n"
    (String.sub out (nl + 1) (String.length out - nl - 1));
  expect (String.sub out 0 nl) o.expected

(* Command lines and options *)

let usage_errors =
  [
    row "an unknown option" [ "--bogus" ]
    @@ __POS_OF__ {| thumper: unknown option '--bogus' |};
    row "an unknown short option" [ "-x" ]
    @@ __POS_OF__ {| thumper: unknown option '-x' |};
    row "a nameless --=V" [ "--=x" ]
    @@ __POS_OF__ {| thumper: unknown option '--=x' |};
    row "an unknown option given a value" [ "--nope=1" ]
    @@ __POS_OF__ {| thumper: unknown option '--nope' |};
    row "--strict=no" [ "--strict=no" ]
    @@ __POS_OF__ {| thumper: option '--strict' takes no argument |};
    row "--quick=1" [ "--quick=1" ]
    @@ __POS_OF__ {| thumper: option '--quick' takes no argument |};
    row "-f without its argument" [ "-f" ]
    @@ __POS_OF__ {| thumper: option '-f' requires an argument |};
    row "--tag without its argument" [ "--tag" ]
    @@ __POS_OF__ {| thumper: option '--tag' requires an argument |};
    row "--baseline without its argument" [ "--baseline" ]
    @@ __POS_OF__ {| thumper: option '--baseline' requires an argument |};
    row "--json without its argument" [ "--json" ]
    @@ __POS_OF__ {| thumper: option '--json' requires an argument |};
    row "--wait-quiet without its argument" [ "--wait-quiet" ]
    @@ __POS_OF__ {| thumper: option '--wait-quiet' requires an argument |};
    row "--color without its argument" [ "--color" ]
    @@ __POS_OF__ {| thumper: option '--color' requires an argument |};
    row "--json -" [ "--json"; "-" ]
    @@ __POS_OF__ {| thumper: option '--json' requires a file path, got '-' |};
    row "--json=-" [ "--json=-" ]
    @@ __POS_OF__ {| thumper: option '--json' requires a file path, got '-' |};
    row "--wait-quiet abc" [ "--wait-quiet"; "abc" ]
    @@ __POS_OF__
         {| thumper: option '--wait-quiet' requires a non-negative number of seconds, got 'abc' |};
    row "--wait-quiet -1" [ "--wait-quiet"; "-1" ]
    @@ __POS_OF__
         {| thumper: option '--wait-quiet' requires a non-negative number of seconds, got '-1' |};
    row "--wait-quiet nan" [ "--wait-quiet"; "nan" ]
    @@ __POS_OF__
         {| thumper: option '--wait-quiet' requires a non-negative number of seconds, got 'nan' |};
    row "--wait-quiet inf" [ "--wait-quiet"; "inf" ]
    @@ __POS_OF__
         {| thumper: option '--wait-quiet' requires a non-negative number of seconds, got 'inf' |};
    row "--wait-quiet=abc" [ "--wait-quiet=abc" ]
    @@ __POS_OF__
         {| thumper: option '--wait-quiet' requires a non-negative number of seconds, got 'abc' |};
    row "--color sometimes" [ "--color"; "sometimes" ]
    @@ __POS_OF__
         {| thumper: option '--color' takes auto, always, or never, got 'sometimes' |};
    row "--quick with --precise" [ "--quick"; "--precise" ]
    @@ __POS_OF__ {| thumper: --quick and --precise are mutually exclusive |};
    row "--force without a subcommand" [ "--force" ]
    @@ __POS_OF__ {| thumper: option '--force' applies to bless, not check |};
    row "check --force" [ "check"; "--force" ]
    @@ __POS_OF__ {| thumper: option '--force' applies to bless, not check |};
    row "bless --json" [ "bless"; "--json"; "x" ]
    @@ __POS_OF__ {| thumper: option '--json' applies to check, not bless |};
    row "bless --strict" [ "bless"; "--strict" ]
    @@ __POS_OF__ {| thumper: option '--strict' applies to check, not bless |};
    row "list --json" [ "list"; "--json"; "x" ]
    @@ __POS_OF__ {| thumper: option '--json' applies to check, not list |};
    row "list --strict" [ "list"; "--strict" ]
    @@ __POS_OF__ {| thumper: option '--strict' applies to check, not list |};
    row "list --force" [ "list"; "--force" ]
    @@ __POS_OF__ {| thumper: option '--force' applies to bless, not list |};
    row "list --baseline" [ "list"; "--baseline"; "b" ]
    @@ __POS_OF__
         {| thumper: option '--baseline' applies to check and bless, not list |};
    row "list --quick" [ "list"; "--quick" ]
    @@ __POS_OF__
         {| thumper: option '--quick' applies to check and bless, not list |};
    row "list --precise" [ "list"; "--precise" ]
    @@ __POS_OF__
         {| thumper: option '--precise' applies to check and bless, not list |};
    row "list --wait-quiet" [ "list"; "--wait-quiet"; "1" ]
    @@ __POS_OF__
         {| thumper: option '--wait-quiet' applies to check and bless, not list |};
    row "list --wait-quiet=2.5" [ "list"; "--wait-quiet=2.5" ]
    @@ __POS_OF__
         {| thumper: option '--wait-quiet' applies to check and bless, not list |};
    row "list --wait-quiet 0" [ "list"; "--wait-quiet"; "0" ]
    @@ __POS_OF__
         {| thumper: option '--wait-quiet' applies to check and bless, not list |};
    row "a misplaced flag before a conflict" [ "list"; "--quick"; "--precise" ]
    @@ __POS_OF__
         {| thumper: option '--quick' applies to check and bless, not list |};
    row "the first defect ends the reading" [ "--bogus"; "-h" ]
    @@ __POS_OF__ {| thumper: unknown option '--bogus' |};
    row "a defect before a misplaced flag" [ "list"; "--strict"; "--nope" ]
    @@ __POS_OF__ {| thumper: unknown option '--nope' |};
  ]

(* The cases [list] selects, or the stop of a selection that selects none. *)
let listings =
  [
    row ~code:0 "no pattern selects every case" [ "list" ]
    @@ __POS_OF__ {|
      alpha
      g/beta
      g/gamma
      |};
    row ~code:0 "a bare argument is a pattern" [ "list"; "alpha" ]
    @@ __POS_OF__ {| alpha |};
    row ~code:0 "a pattern is a substring of the id" [ "list"; "-f"; "g/" ]
    @@ __POS_OF__ {|
      g/beta
      g/gamma
      |};
    row ~code:0 "patterns select any case one of them matches"
      [ "list"; "-f"; "alpha"; "beta" ]
    @@ __POS_OF__ {|
      alpha
      g/beta
      |};
    row ~code:0 "tags select the cases carrying every one"
      [ "list"; "--tag"; "lab"; "--tag"; "ci" ]
    @@ __POS_OF__ {| g/gamma |};
    row ~code:0 "--tag=T reads as --tag T" [ "list"; "--tag=lab" ]
    @@ __POS_OF__ {|
      g/beta
      g/gamma
      |};
    row ~code:0 "a case must match a pattern and carry the tags"
      [ "list"; "-f"; "alpha"; "-f"; "beta"; "--tag"; "lab" ]
    @@ __POS_OF__ {| g/beta |};
    row ~code:0 "--color applies to list" [ "list"; "--color"; "never" ]
    @@ __POS_OF__ {|
      alpha
      g/beta
      g/gamma
      |};
    row "a pattern that matches nothing" [ "list"; "-f"; "zzz" ]
    @@ __POS_OF__ {| thumper: no case matches 'zzz' |};
    row "patterns and tags keep their order"
      [ "list"; "-f"; "x"; "y"; "-f"; "z"; "--tag"; "lab"; "--tag"; "ci" ]
    @@ __POS_OF__
         {| thumper: no case matches 'x', 'y', 'z' with tag 'lab', 'ci' |};
    row "a tag that matches nothing" [ "list"; "--tag"; "nope" ]
    @@ __POS_OF__ {| thumper: no case matches tag 'nope' |};
    row "a later subcommand word is a pattern" [ "list"; "check" ]
    @@ __POS_OF__ {| thumper: no case matches 'check' |};
    row "every argument after -- is a pattern"
      [ "list"; "--"; "-f"; "--strict" ]
    @@ __POS_OF__ {| thumper: no case matches '-f', '--strict' |};
    row "an argument after -- keeps its =" [ "list"; "--"; "--tag=x" ]
    @@ __POS_OF__ {| thumper: no case matches '--tag=x' |};
    row "a lone dash is a pattern" [ "list"; "-" ]
    @@ __POS_OF__ {| thumper: no case matches '-' |};
    row "a first argument that names no subcommand is a pattern of check"
      [ "explore" ]
    @@ __POS_OF__ {| thumper: no case matches 'explore' |};
  ]

(* The version [-V] prints, which a release substitutes for [dev]. *)
let version () =
  let (_ : int) = main [ "-V" ] in
  require_match
    (fun l ->
      if String.starts_with ~prefix:"thumper " l then
        Some (String.trim (String.sub l 8 (String.length l - 8)))
      else None)
    (output ())

let help_prints_every_flag () =
  let dir = state_env () in
  let v = version () in
  equal ~msg:"exit code" int 0 (main [ "-h" ]);
  expect
    (replace ~sub:("(thumper " ^ v ^ ")") ~by:"(thumper VERSION)" (printed dir))
  @@ __POS_OF__
       {|
    bench.exe: thumper benchmark suite (thumper VERSION)

    usage: bench.exe [check|bless|list] [OPTS] [PATTERN...]

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
    |}

let help = "bench.exe: thumper benchmark suite (thumper "

let ends_the_reading =
  [
    ("-h", [ "-h" ], help);
    ("--help", [ "--help" ], help);
    ("-h after a flag", [ "-f"; "x"; "-h" ], help);
    ("-h before a defect", [ "-h"; "--bogus" ], help);
    ("-h after a subcommand", [ "list"; "-h" ], help);
    ("-V", [ "-V" ], "thumper ");
    ("--version", [ "--version" ], "thumper ");
    ("-V before -h", [ "-V"; "-h" ], "thumper ");
  ]

let the_help_names_the_program () =
  let (_ : string) = state_env () in
  equal ~msg:"exit code" int 0 (main ~exe:"/a/b/my_bench.exe" [ "-h" ]);
  contains ~sub:"\nusage: my_bench.exe [check|bless|list] [OPTS] [PATTERN...]\n"
    (output ())

let command_lines =
  group "Command lines and options"
    [
      cases "a usage error" ~name:fst usage_errors refuses;
      cases "list selects" ~name:fst listings (fun (_, o) ->
          let dir = state_env () in
          check_outcome dir o (main o.args));
      test "-h prints every flag" help_prints_every_flag;
      cases "-h and -V end the reading"
        ~name:(fun (n, _, _) -> n)
        ends_the_reading
        (fun (_, args, line) ->
          let (_ : string) = state_env () in
          equal ~msg:"exit code" int 0 (main args);
          starts_with ~affix:line (output ()));
      test "the help names the program by its file name"
        the_help_names_the_program;
    ]

(* Terminal output and the report's variants

   A run of [failing] under each environment: the report is [test_report]'s,
   and these assert only which variant [main] chose. *)

let enter dir =
  mkdirs dir;
  chdir dir

let dune_env ~context ~root =
  setenv "INSIDE_DUNE" (Some context);
  setenv "DUNE_SOURCEROOT" (Some root)

(* A dune rule action: the working directory lies in the build context. *)
let rule_action d =
  dune_env ~context:(d ^ "/_b/default") ~root:d;
  enter (d ^ "/_b/default/bench")

let esc = "\027["
let rerun = "  rerun:   bench.exe"
let mv = "  accept:  mv digest.thumper.corrected digest.thumper"
let promote = "  accept:  dune promote"

let variants =
  [
    ( "outside dune: the rerun line and mv, unstyled",
      (fun _ -> []),
      [ rerun; mv ],
      [ esc; "::error::"; promote ] );
    ( "a rule action: dune promote and no rerun line, styled",
      (fun d ->
        rule_action d;
        []),
      [ promote; esc ],
      [ "rerun:"; mv ] );
    ( "NO_COLOR unstyles a rule action",
      (fun d ->
        rule_action d;
        setenv "NO_COLOR" (Some "1");
        []),
      [ promote ],
      [ esc ] );
    ( "an empty NO_COLOR does not",
      (fun d ->
        rule_action d;
        setenv "NO_COLOR" (Some "");
        []),
      [ esc ],
      [] );
    ( "--color never unstyles a rule action",
      (fun d ->
        rule_action d;
        [ "--color"; "never" ]),
      [ promote ],
      [ esc ] );
    ( "--color always styles a pipe",
      (fun _ -> [ "--color"; "always" ]),
      [ esc ],
      [] );
    ( "--color=always beats NO_COLOR",
      (fun _ ->
        setenv "NO_COLOR" (Some "1");
        [ "--color=always" ]),
      [ esc ],
      [] );
    ( "--color auto leaves a pipe unstyled",
      (fun _ -> [ "--color"; "auto" ]),
      [],
      [ esc ] );
    ( "GITHUB_ACTIONS adds the ::error:: lines",
      (fun _ ->
        setenv "GITHUB_ACTIONS" (Some "true");
        []),
      [ "::error::" ],
      [] );
    ( "a baseline path a shell would split is quoted",
      (fun d ->
        mkdirs (d ^ "/My Projects");
        [ "--baseline"; "My Projects/d.thumper" ]),
      [
        "  accept:  mv 'My Projects/d.thumper.corrected' 'My \
         Projects/d.thumper'";
        "--baseline 'My Projects/d.thumper'";
      ],
      [] );
  ]

let report_variant (_, setup, present, absent) =
  let dir = state_env () in
  let args = setup dir in
  equal ~msg:"exit code" int 1
    (main ~config:fast_config ~benches:failing ("check" :: args));
  let out = printed dir in
  List.iter (fun sub -> contains ~sub out) present;
  List.iter (fun sub -> not_contains ~sub out) absent

let terminal =
  group "Terminal output"
    [
      cases ~tags:[ "slow" ] ~timeout:60. "the report a failing run prints"
        ~name:(fun (n, _, _, _) -> n)
        variants report_variant;
    ]

(* Paths and dune rule actions *)

type place = {
  setup : string -> string list;
  baseline : string option;
  expected : pos * string;
}

let place ?baseline name setup expected = (name, { setup; baseline; expected })

(* Where [bless] resolves the corrected file of the suite [absent/digest]: its
   directory [absent] exists nowhere, so the pre-flight stop names the path
   before anything is measured or written. *)
let places =
  [
    place "a rule action resolves in its working directory" (fun d ->
        rule_action d;
        [])
    @@ __POS_OF__
         {| thumper: cannot write absent/digest.thumper.corrected: absent: No such file or directory |};
    place "a sandboxed rule action too" (fun d ->
        dune_env ~context:(d ^ "/_b/default") ~root:d;
        enter (d ^ "/_b/.sandbox/0f/default/bench");
        [])
    @@ __POS_OF__
         {| thumper: cannot write absent/digest.thumper.corrected: absent: No such file or directory |};
    place "dune exec maps the executable into the source tree" (fun d ->
        mkdirs (d ^ "/src/test/unit");
        dune_env ~context:exe_context ~root:(d ^ "/src");
        enter (d ^ "/elsewhere");
        [])
    @@ __POS_OF__
         {| thumper: cannot write $D/src/test/unit/absent/digest.thumper.corrected: $D/src/test/unit/absent: No such file or directory |};
    place "a mapped directory under the working directory prints relative"
      (fun d ->
        mkdirs (d ^ "/src/test/unit");
        dune_env ~context:exe_context ~root:(d ^ "/src");
        enter (d ^ "/src");
        [])
    @@ __POS_OF__
         {| thumper: cannot write test/unit/absent/digest.thumper.corrected: test/unit/absent: No such file or directory |};
    place "a mapped directory that does not exist is not used" (fun d ->
        dune_env ~context:exe_context ~root:(d ^ "/src");
        [])
    @@ __POS_OF__
         {| thumper: cannot write $D/absent/digest.thumper.corrected: $D/absent: No such file or directory |};
    place "an executable outside the build context is not mapped" (fun d ->
        mkdirs (d ^ "/test/unit");
        dune_env ~context:(d ^ "/_b/default") ~root:d;
        [])
    @@ __POS_OF__
         {| thumper: cannot write $D/absent/digest.thumper.corrected: $D/absent: No such file or directory |};
    place "INSIDE_DUNE alone maps nothing" (fun _ ->
        setenv "INSIDE_DUNE" (Some exe_context);
        [])
    @@ __POS_OF__
         {| thumper: cannot write $D/absent/digest.thumper.corrected: $D/absent: No such file or directory |};
    place "DUNE_SOURCEROOT alone maps nothing" (fun d ->
        mkdirs (d ^ "/test/unit");
        setenv "DUNE_SOURCEROOT" (Some d);
        [])
    @@ __POS_OF__
         {| thumper: cannot write $D/absent/digest.thumper.corrected: $D/absent: No such file or directory |};
    place "an older dune's INSIDE_DUNE=1 maps nothing" (fun d ->
        mkdirs (d ^ "/test/unit");
        setenv "INSIDE_DUNE" (Some "1");
        setenv "DUNE_SOURCEROOT" (Some d);
        [])
    @@ __POS_OF__
         {| thumper: cannot write $D/absent/digest.thumper.corrected: $D/absent: No such file or directory |};
    place "an older dune's INSIDE_DUNE=1 in a build directory is a rule action"
      (fun d ->
        setenv "INSIDE_DUNE" (Some "1");
        enter (d ^ "/_build/default/bench");
        [])
    @@ __POS_OF__
         {| thumper: cannot write absent/digest.thumper.corrected: absent: No such file or directory |};
    place "by hand, a working directory in a build directory is used" (fun d ->
        enter (d ^ "/_build/default/bench");
        [])
    @@ __POS_OF__
         {| thumper: cannot write $D/_build/default/bench/absent/digest.thumper.corrected: $D/_build/default/bench/absent: No such file or directory |};
    place "by hand, the executable maps to its source directory" (fun _ ->
        if Option.is_none workspace then
          skip ~reason:"the executable was not built under _build" ();
        [])
    @@ __POS_OF__
         {| thumper: cannot write $WS/test/unit/absent/digest.thumper.corrected: $WS/test/unit/absent: No such file or directory |};
    place "--baseline is read as typed, less its . segments" (fun d ->
        dune_env ~context:exe_context ~root:d;
        [ "--baseline"; "./x/./typed.thumper" ])
    @@ __POS_OF__
         {| thumper: cannot write x/typed.thumper.corrected: x: No such file or directory |};
    place "--baseline=PATH reads as --baseline PATH" (fun _ ->
        [ "--baseline=x/typed.thumper" ])
    @@ __POS_OF__
         {| thumper: cannot write x/typed.thumper.corrected: x: No such file or directory |};
    place ~baseline:"caller/d.thumper"
      "the baseline argument, without --baseline" (fun _ -> [])
    @@ __POS_OF__
         {| thumper: cannot write caller/d.thumper.corrected: caller: No such file or directory |};
    place ~baseline:"caller/d.thumper" "--baseline, over the baseline argument"
      (fun _ -> [ "--baseline"; "flag/d.thumper" ])
    @@ __POS_OF__
         {| thumper: cannot write flag/d.thumper.corrected: flag: No such file or directory |};
  ]

let resolves (_, p) =
  let dir = state_env () in
  let args = p.setup dir in
  equal ~msg:"exit code" int 2
    (main ~name:"absent/digest" ~baseline:p.baseline ("bless" :: args));
  expect (printed dir) p.expected

(* [main] passes [Sys.executable_name], which a test cannot choose, so the
   layouts of other executables are mapped by the function itself. *)
let layouts =
  [
    ( "under dune, a relative executable resolves against the working directory",
      `Dune,
      "/ws",
      "_build_sys/default/bench/b.exe",
      [ "/ws/bench" ],
      "/ws/bench" );
    ( "under dune, an executable path through .. segments",
      `Dune,
      "/ws/test/cram",
      "/ws/test/cram/../../_build_sys/default/test/cram/fixture/x.exe",
      [ "/ws/test/cram/fixture" ],
      "/ws/test/cram/fixture" );
    ( "under dune, a relative executable path through .. segments",
      `Dune,
      "/ws/test/cram",
      "../../_build_sys/default/./bench/b.exe",
      [ "/ws/bench" ],
      "/ws/bench" );
    ( "under dune, an executable at the context's root",
      `Dune,
      "/ws",
      "/ws/_build_sys/default/b.exe",
      [ "/ws" ],
      "/ws" );
    ( "by hand, a named build context",
      `Hand,
      "/ws",
      "/ws/_build/musl/bench/b.exe",
      [ "/ws/bench" ],
      "/ws/bench" );
    ( "by hand, .sandbox/<hash> before the context",
      `Hand,
      "/ws",
      "/ws/_build/.sandbox/d41d8cd98f00b204/default/bench/b.exe",
      [ "/ws/bench" ],
      "/ws/bench" );
    ( "by hand, the last /_build/ names the workspace",
      `Hand,
      "/ws",
      "/a/_build/ws/_build/default/bench/b.exe",
      [ "/a/_build/ws/bench" ],
      "/a/_build/ws/bench" );
    ( "by hand, an executable at the context's root",
      `Hand,
      "/ws",
      "/ws/_build/default/b.exe",
      [ "/ws" ],
      "/ws" );
    ( "by hand, a relative executable resolves against the working directory",
      `Hand,
      "/ws",
      "_build/default/bench/b.exe",
      [ "/ws/bench" ],
      "/ws/bench" );
    ( "by hand, a path through .. names the directory without it",
      `Hand,
      "/ws/bench",
      "../_build/default/bench/b.exe",
      [ "/ws/bench"; "/ws/bench/../bench" ],
      "/ws/bench" );
    ( "by hand, an executable outside _build",
      `Hand,
      "/ws",
      "/usr/local/bin/b.exe",
      [],
      "/ws" );
    ( "by hand, a source directory that does not exist",
      `Hand,
      "/ws",
      "/elsewhere/_build/default/bench/b.exe",
      [],
      "/ws" );
    ( "by hand, an executable directly in _build",
      `Hand,
      "/ws",
      "/proj/_build/b.exe",
      [ "/proj" ],
      "/ws" );
  ]

let maps_layout (_, env, cwd, exe, dirs, expected) =
  let inside_dune, source_root =
    match env with
    | `Dune -> (Some "/ws/_build_sys/default", Some "/ws")
    | `Hand -> (None, None)
  in
  equal string expected
    (Cli.default_baseline_dir
       ~dir_exists:(fun d -> List.mem d dirs)
       ~inside_dune ~source_root ~exe ~cwd)

let paths =
  group "Paths and dune rule actions"
    [
      cases "bless's pre-flight names the path" ~name:fst places resolves;
      cases "default_baseline_dir maps an executable's layout"
        ~name:(fun (n, _, _, _, _, _) -> n)
        layouts maps_layout;
    ]

(* Running a command line *)

let suite_name_refusal =
  Invalid_argument
    "Thumper.run: suite name must be non-empty and single-line (it heads fresh \
     baselines)"

let refusals =
  [
    ("an empty suite name", "", [], [ "list" ], suite_name_refusal);
    ( "a suite name over two lines, whatever argv holds",
      "a\nb",
      [],
      [ "-h" ],
      suite_name_refusal );
    ( "two budgets for one metric, whatever argv holds",
      "digest",
      [ Budget.no_slower_than 0.05; Budget.no_slower_than 0.1 ],
      [ "-h" ],
      Invalid_argument
        "Thumper.run: two budgets for metric wall_time in one ~budgets list" );
  ]

type stop = {
  setup : string -> string list;
  suite : Bench.t list;
  expected : pos * string;
}

let stop ?(suite = benches) name setup expected =
  (name, { setup; suite; expected })

(* A directory the test may not write to. *)
let read_only d name =
  if Unix.geteuid () = 0 then
    skip ~reason:"a read-only directory does not stop root" ();
  let p = Filename.concat d name in
  mkdirs p;
  Unix.chmod p 0o500;
  p

let with_baseline args =
  write_baseline "digest.thumper" [];
  args

(* The measurement lock's file, made a directory. *)
let unusable_lock d =
  let lock = Filename.concat d "lock" in
  mkdirs
    (Filename.concat lock (Printf.sprintf "thumper-%d.lock" (Unix.geteuid ())));
  setenv "THUMPER_LOCK_DIR" (Some lock)

let raises_boom () = failwith "boom"

let stops =
  [
    stop ~suite:[] "a suite without a case" (fun _ -> [ "list" ])
    @@ __POS_OF__ {| thumper: no case matches the selection |};
    stop
      ~suite:[ Bench.bench "alpha" ignore; Bench.bench "alpha" ignore ]
      "a suite with two cases of one id"
      (fun _ -> [ "list" ])
    @@ __POS_OF__
         {| thumper: duplicate case id 'alpha' (rename the case or pass ~id) |};
    stop
      ~suite:[ Bench.bench "alpha" ignore; Bench.bench "alpha" ignore ]
      "a suite with two cases of one id, under bless"
      (fun _ -> [ "bless" ])
    @@ __POS_OF__
         {| thumper: duplicate case id 'alpha' (rename the case or pass ~id) |};
    stop "a malformed THUMPER_MACHINE, without a subcommand" (fun _ ->
        setenv "THUMPER_MACHINE" (Some "bad key");
        [])
    @@ __POS_OF__
         {| thumper: THUMPER_MACHINE: 'bad key' (need a non-empty key over [A-Za-z0-9._-]) |};
    stop "a malformed THUMPER_MACHINE under bless" (fun _ ->
        setenv "THUMPER_MACHINE" (Some "bad key");
        [ "bless" ])
    @@ __POS_OF__
         {| thumper: THUMPER_MACHINE: 'bad key' (need a non-empty key over [A-Za-z0-9._-]) |};
    stop "a baseline for another suite, its name quoted" (fun _ ->
        write_file "digest.thumper"
          "# thumper baseline v1\n# suite: x\027]0;owned\007\n";
        [ "check" ])
    @@ __POS_OF__
         {| thumper: digest.thumper: baseline is for suite 'x\x1b]0;owned\x07', not 'digest'; pass this suite's file with --baseline, or update the '# suite:' header if the suite was renamed |};
    stop "a corrupt baseline" (fun _ ->
        write_file "digest.thumper" "not a thumper baseline\n";
        [ "check" ])
    @@ __POS_OF__
         {| thumper: digest.thumper: corrupt baseline (line 1): expected '# thumper baseline v1' on the first line |};
    stop "a baseline that cannot be read" (fun _ ->
        Unix.mkdir "digest.thumper" 0o700;
        [ "check" ])
    @@ __POS_OF__ {| thumper: cannot read digest.thumper: Is a directory |};
    stop "--json in a directory that does not exist" (fun _ ->
        [ "check"; "--json"; "nope/v.json" ])
    @@ __POS_OF__
         {| thumper: cannot write nope/v.json: nope: No such file or directory |};
    stop "--json in a read-only directory" (fun d ->
        let (_ : string) = read_only d "ro" in
        [ "check"; "--json"; "ro/v.json" ])
    @@ __POS_OF__ {| thumper: cannot write ro/v.json: ro: Permission denied |};
    stop "bless's corrected file in a directory that does not exist" (fun _ ->
        [ "bless"; "--baseline"; "nope/d.thumper" ])
    @@ __POS_OF__
         {| thumper: cannot write nope/d.thumper.corrected: nope: No such file or directory |};
    stop "bless's corrected file in a read-only directory" (fun d ->
        let (_ : string) = read_only d "ro" in
        [ "bless"; "--baseline"; "ro/d.thumper" ])
    @@ __POS_OF__
         {| thumper: cannot write ro/d.thumper.corrected: ro: Permission denied |};
    stop
      "check without a baseline, its corrected file in a directory that does \
       not exist" (fun _ -> [ "check"; "--baseline"; "nope/d.thumper" ])
    @@ __POS_OF__
         {| thumper: cannot write nope/d.thumper.corrected: nope: No such file or directory |};
    stop "a stale corrected file that cannot be removed" (fun d ->
        mkdirs (d ^ "/ro");
        write_file "ro/d.thumper.corrected" "stale";
        let (_ : string) = read_only d "ro" in
        [ "check"; "--baseline"; "ro/d.thumper" ])
    @@ __POS_OF__
         {| thumper: cannot remove stale artifact ro/d.thumper.corrected: Permission denied |};
    stop "a stale --json file that cannot be removed" (fun d ->
        mkdirs (d ^ "/ro");
        write_file "ro/v.json" "stale";
        let (_ : string) = read_only d "ro" in
        [ "check"; "--json"; "ro/v.json" ])
    @@ __POS_OF__
         {| thumper: cannot remove stale artifact ro/v.json: Permission denied |};
    stop "an unusable measurement lock under check" (fun d ->
        unusable_lock d;
        with_baseline [ "check" ])
    @@ __POS_OF__
         {| thumper: measurement lock unusable: cannot open $D/lock/thumper-$UID.lock: Is a directory |};
    stop "an unusable measurement lock under bless" (fun d ->
        unusable_lock d;
        [ "bless" ])
    @@ __POS_OF__
         {| thumper: measurement lock unusable: cannot open $D/lock/thumper-$UID.lock: Is a directory |};
    stop "--color always leaves a stop unstyled" (fun _ ->
        [ "list"; "--color"; "always"; "-f"; "zzz" ])
    @@ __POS_OF__ {| thumper: no case matches 'zzz' |};
  ]

(* The case runs, so the run takes the lock and measures until it raises. *)
let a_raising_case =
  stop
    ~suite:[ Bench.bench "boom" raises_boom ]
    "a case that raises stops the run"
    (fun _ -> [ "check" ])
  @@ __POS_OF__ {| thumper: case boom raised: Failure("boom") |}

let stops_the_run (_, s) =
  let dir = state_env () in
  let args = s.setup dir in
  equal ~msg:"exit code" int 2 (main ~config:fast_config ~benches:s.suite args);
  expect (printed dir) s.expected

(* [main] removes the stale [--json] file before the pre-flight, and removing
   a path under a regular file fails with [ENOTDIR], so the run stops on a
   stale file that does not exist instead of naming the directory that is not
   one. *)
let a_json_path_under_a_file () =
  let (_ : string) = state_env () in
  write_file "file" "";
  equal ~msg:"exit code" int 2 (main [ "check"; "--json"; "file/v.json" ]);
  equal string "thumper: cannot write file/v.json: file is not a directory\n"
    (output ())

let list_reads_no_baseline_and_no_key () =
  let (_ : string) = state_env () in
  setenv "THUMPER_MACHINE" (Some "bad key");
  write_file "digest.thumper" "not a thumper baseline\n";
  equal ~msg:"exit code" int 0 (main [ "list"; "alpha" ]);
  equal string "alpha\n" (output ())

let stale = [ "digest.thumper.corrected"; "v.json" ]

let first_removals =
  [
    ("list", fun () -> [ "list"; "-f"; "zzz" ]);
    ("check", fun () -> [ "check"; "--json"; "v.json"; "-f"; "zzz" ]);
    ("bless", fun () -> [ "bless"; "-f"; "zzz" ]);
    ( "check, before a corrupt baseline is read",
      fun () ->
        write_file "digest.thumper" "not a thumper baseline\n";
        [ "check"; "--json"; "v.json" ] );
  ]

let removes_the_stale_files (_, args) =
  let (_ : string) = state_env () in
  List.iter (fun f -> write_file f "stale") stale;
  let args = args () in
  equal ~msg:"exit code" int 2 (main args);
  let left = List.filter Sys.file_exists stale in
  equal (list string) (if List.mem "--json" args then [] else [ "v.json" ]) left

let keeps_the_stale_files (_, args) =
  let (_ : string) = state_env () in
  List.iter (fun f -> write_file f "stale") stale;
  let (_ : int) = main args in
  equal (list string) stale (List.filter Sys.file_exists stale)

let stops_before_the_lock () =
  let (_ : string) = state_env () in
  equal ~msg:"exit code" int 2
    (main [ "check"; "--baseline"; "nope/d.thumper" ]);
  equal (list string) []
    (Array.to_list (Sys.readdir (Sys.getenv "THUMPER_LOCK_DIR")))

(* Runs that measure *)

let corrected_rows path =
  let file = require_some (require_ok (Baseline.read path)) in
  let section = require_some (Baseline.section file "testkey") in
  List.map
    (fun r -> Baseline.row_id r ^ " " ^ Baseline.row_metric r)
    (Baseline.rows section)

let presets =
  [
    ("without a preset, the caller's", [], 3);
    ("--quick, the quick preset's", [ "--quick" ], Config.quick.Config.n);
    ("--precise, the precise preset's", [ "--precise" ], Config.precise.Config.n);
  ]

(* The caller's configuration reaches the run with its samples replaced: its
   metric and its in-process protocol are kept. *)
let samples_of_a_preset (_, args, n) =
  let (_ : string) = state_env () in
  let calls = ref 0 in
  let config = Config.metrics [ Metric.wall_time ] fast_config in
  equal ~msg:"exit code" int 0
    (main ~config
       ~benches:[ Bench.bench "alpha" (fun () -> incr calls) ]
       ("check" :: args));
  at_least ~msg:"calls in this process" int ~than:1 !calls;
  let file =
    require_some (require_ok (Baseline.read "digest.thumper.corrected"))
  in
  let rows = Baseline.rows (require_some (Baseline.section file "testkey")) in
  equal
    (list (pair string int))
    [ ("alpha wall_time", n) ]
    (List.map
       (fun r ->
         ( Baseline.row_id r ^ " " ^ Baseline.row_metric r,
           require_match
             (function
               | Baseline.Sampled { samples; _ } -> Some (Array.length samples)
               | Baseline.Exact_int _ -> None)
             (Baseline.row_evidence r) ))
       rows)

let alpha = [ Bench.bench "alpha" ignore ]

let without_a_baseline () =
  let (_ : string) = state_env () in
  equal ~msg:"exit code" int 0
    (main ~config:fast_config ~benches:alpha [ "check"; "--json"; "v.json" ]);
  contains ~sub:"testkey" (output ());
  equal ~msg:"the corrected file" (list string) [ "alpha alloc_words" ]
    (corrected_rows "digest.thumper.corrected");
  ends_with ~msg:"the --json document" ~affix:"}\n" (read_file "v.json")

let strict_fails_a_proposal () =
  let (_ : string) = state_env () in
  equal ~msg:"exit code" int 1
    (main ~config:fast_config ~benches:alpha [ "check"; "--strict" ])

(* A wait of 0 s never sleeps, and both subcommands then measure whatever the
   load is, bless because of [--force]. What they print on stderr depends on
   the host's load, so only the exit codes are read. *)
let wait_quiet_zero () =
  let (_ : string) = state_env () in
  equal ~msg:"check's exit code" int 0
    (main ~config:fast_config ~benches:alpha [ "check"; "--wait-quiet"; "0" ]);
  equal ~msg:"bless's exit code" int 0
    (main ~config:fast_config ~benches:alpha
       [ "bless"; "--force"; "--wait-quiet"; "0" ])

(* A case that removes its baseline's directory while it is measured, so the
   corrected file cannot be written after the measurement. *)
let vanishing dir =
  [
    Bench.bench "alpha" (fun () ->
        let bl = Filename.concat dir "digest.thumper" in
        if Sys.file_exists dir then begin
          if Sys.file_exists bl then Sys.remove bl;
          Sys.rmdir dir
        end);
  ]

let a_late_write_failure_under_check () =
  let dir = state_env () in
  let gone = Filename.concat dir "gone" in
  mkdirs gone;
  write_baseline
    ~identity:{ (current_identity ()) with Baseline.machine = "otherkey" }
    "gone/digest.thumper" [];
  equal ~msg:"exit code" int 2
    (main ~config:fast_config ~benches:(vanishing gone)
       [ "check"; "--baseline"; "gone/digest.thumper" ]);
  let out = printed dir in
  contains ~msg:"the report" ~sub:"proposed" out;
  not_contains ~msg:"no accept line" ~sub:"accept:" out;
  ends_with ~msg:"the stop, after the report"
    ~affix:
      "\n\
       thumper: cannot write gone/digest.thumper.corrected: No such file or \
       directory\n"
    out

let a_late_write_failure_under_bless () =
  let dir = state_env () in
  let gone = Filename.concat dir "gone" in
  mkdirs gone;
  equal ~msg:"exit code" int 2
    (main ~config:fast_config ~benches:(vanishing gone)
       [ "bless"; "--force"; "--baseline"; "gone/digest.thumper" ]);
  expect (printed dir)
  @@ __POS_OF__
       {| thumper: cannot write gone/digest.thumper.corrected: No such file or directory |}

let a_partial_bless () =
  let (_ : string) = state_env () in
  write_baseline "digest.thumper" [ alloc_row "g/beta" 54 ];
  equal ~msg:"exit code" int 0
    (main ~config:fast_config [ "bless"; "-f"; "alpha"; "--force" ]);
  let out = output () in
  contains ~sub:"blessed 1 case for machine testkey" out;
  contains ~sub:"\n  accept:  mv digest.thumper.corrected digest.thumper\n" out;
  not_contains ~msg:"nothing dropped" ~sub:"unselected" out;
  equal ~msg:"the selected case's rows beside the others" (list string)
    [ "alpha alloc_words"; "g/beta alloc_words" ]
    (corrected_rows "digest.thumper.corrected")

let a_partial_bless_of_a_stale_section () =
  let (_ : string) = state_env () in
  write_baseline
    ~identity:{ (current_identity ()) with Baseline.ocaml = "4.14.0" }
    "digest.thumper"
    [ alloc_row "g/beta" 54 ];
  equal ~msg:"exit code" int 0
    (main ~config:fast_config [ "bless"; "-f"; "alpha"; "--force" ]);
  contains
    ~sub:
      "partial selection on a stale section: the corrected file re-records \
       this machine's whole section and drops the rows of the 1 unselected \
       case"
    (output ())

let pruned =
  "case dead no longer exists in this binary; its rows will be pruned from the \
   corrected file"

let a_full_check_prunes () =
  let (_ : string) = state_env () in
  write_baseline "digest.thumper" [ alloc_row "alpha" 0; alloc_row "dead" 0 ];
  equal ~msg:"exit code" int 0
    (main ~config:fast_config ~benches:alpha [ "check" ]);
  contains ~sub:pruned (output ());
  equal (list string) [ "alpha alloc_words" ]
    (corrected_rows "digest.thumper.corrected")

let a_partial_check_prunes_nothing () =
  let (_ : string) = state_env () in
  write_baseline "digest.thumper" [ alloc_row "alpha" 0; alloc_row "dead" 0 ];
  equal ~msg:"exit code" int 0
    (main ~config:fast_config
       ~benches:(alpha @ [ Bench.bench "beta" ignore ])
       [ "check"; "-f"; "alpha" ]);
  not_contains ~sub:"no longer exists" (output ());
  equal ~msg:"no corrected file" bool false
    (Sys.file_exists "digest.thumper.corrected")

(* The first word of the rerun line: the executable as [argv.(0)] names it,
   seen from the working directory. *)
let rerun_exe dir =
  let label = "  rerun:   " in
  require_match
    (fun l ->
      if String.starts_with ~prefix:label l then
        let rest =
          String.sub l (String.length label)
            (String.length l - String.length label)
        in
        Some (List.hd (String.split_on_char ' ' rest))
      else None)
    (List.find_opt
       (String.starts_with ~prefix:label)
       (String.split_on_char '\n' (printed dir))
    |> Option.value ~default:"")

let executables =
  [
    ("a bare name, as typed", ".", (fun _ -> "bench.exe"), "bench.exe");
    ( "a path under the working directory",
      ".",
      (fun d -> d ^ "/sub/b.exe"),
      "./sub/b.exe" );
    ( "a relative path, resolved",
      ".",
      (fun _ -> "sub/../sub/b.exe"),
      "./sub/b.exe" );
    ( "a path outside the working directory",
      ".",
      (fun _ -> "/nonexistent/b.exe"),
      "/nonexistent/b.exe" );
    ( "a relative path outside the working directory",
      "sub",
      (fun _ -> "../b.exe"),
      "$D/b.exe" );
  ]

let names_the_executable (_, cwd, exe, expected) =
  let dir = state_env () in
  mkdirs (dir ^ "/sub");
  chdir (Filename.concat dir cwd);
  equal ~msg:"exit code" int 1
    (main ~exe:(exe dir)
       ~baseline:(Some (dir ^ "/digest.thumper"))
       ~config:fast_config ~benches:failing [ "check" ]);
  equal string expected (rerun_exe dir)

let the_rerun_line_repeats_the_flags () =
  let dir = state_env () in
  equal ~msg:"exit code" int 1
    (main ~config:fast_config ~benches:failing
       [ "check"; "--quick"; "--baseline"; "digest.thumper"; "--tag"; "t" ]);
  contains
    ~sub:
      "\n\
      \  rerun:   bench.exe --quick --baseline digest.thumper --tag t -f alloc\n"
    (printed dir)

let running =
  group "Running a command line"
    [
      cases "raises before reading argv"
        ~name:(fun (n, _, _, _, _) -> n)
        refusals
        (fun (_, name, budgets, args, exn) ->
          raises exn (fun () -> main ~name ~budgets args));
      cases "a stop" ~name:fst stops stops_the_run;
      test ~timeout:60. (fst a_raising_case) (fun () ->
          stops_the_run a_raising_case);
      test "a --json path under a file stops as not a directory"
        a_json_path_under_a_file;
      test "list reads neither the baseline nor THUMPER_MACHINE"
        list_reads_no_baseline_and_no_key;
      cases "every subcommand first removes the stale files" ~name:fst
        first_removals removes_the_stale_files;
      cases "-h, -V and a usage error keep the stale files" ~name:fst
        [
          ("-h", [ "-h" ]);
          ("-V", [ "-V" ]);
          ("a usage error", [ "--json"; "v.json"; "--bogus" ]);
        ]
        keeps_the_stale_files;
      test "check without a baseline stops before it takes the lock"
        stops_before_the_lock;
      cases ~tags:[ "slow" ] ~timeout:60. "a preset sets the samples"
        ~name:(fun (n, _, _) -> n)
        presets samples_of_a_preset;
      slow ~timeout:60.
        "check without a baseline writes the corrected file and --json"
        without_a_baseline;
      slow ~timeout:60. "--strict fails a run that proposes"
        strict_fails_a_proposal;
      slow ~timeout:60. "check and bless --force measure after --wait-quiet 0"
        wait_quiet_zero;
      slow ~timeout:60.
        "a corrected file check cannot write stops after the report"
        a_late_write_failure_under_check;
      slow ~timeout:60.
        "a corrected file bless cannot write stops before the report"
        a_late_write_failure_under_bless;
      slow ~timeout:60. "a partial bless re-records the selected cases"
        a_partial_bless;
      slow ~timeout:60. "a partial bless of a stale section says what it drops"
        a_partial_bless_of_a_stale_section;
      slow ~timeout:60. "a full check prunes the rows of a case the suite lost"
        a_full_check_prunes;
      slow ~timeout:60. "a partial check prunes nothing"
        a_partial_check_prunes_nothing;
      cases ~tags:[ "slow" ] ~timeout:60. "the rerun line names the executable"
        ~name:(fun (n, _, _, _) -> n)
        executables names_the_executable;
      slow ~timeout:60. "the rerun line repeats --quick, --baseline and --tag"
        the_rerun_line_repeats_the_flags;
    ]

let () = exit (run "cli" [ command_lines; terminal; paths; running ])
