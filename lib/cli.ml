(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The dune-release/dune-subst watermark: substituted with the VCS tag,
   without its leading [v], at distribution time, so [-V] and the changelog
   cannot drift apart. In a dev tree the literal stays unsubstituted and
   renders as-is. *)
let version =
  let watermark = "%%VERSION_NUM%%" in
  if String.length watermark > 0 && watermark.[0] = '%' then "dev" else watermark

(* Parsing *)

type subcommand = [ `Check | `Bless | `List ]
type color = [ `Auto | `Always | `Never ]

type options = {
  subcommand : subcommand;
  patterns : string list;
  tags : string list;
  preset : [ `Default | `Quick | `Precise ];
  baseline : string option;
  json : string option;
  strict : bool;
  wait_quiet : float option;
  force : bool;
  color : color;
}

type parsed = Run of options | Help | Version | Usage_error of string

let subcommand_of = function
  | "check" -> Some `Check
  | "bless" -> Some `Bless
  | "list" -> Some `List
  | _ -> None

let subcommand_word = function
  | `Check -> "check"
  | `Bless -> "bless"
  | `List -> "list"

(* The long options that take no value: [--flag=V] on one is refused. *)
let long_flags =
  [ "--help"; "--version"; "--quick"; "--precise"; "--strict"; "--force" ]

(* Expand [--opt=VALUE] into [--opt; VALUE]. Long options only, and only up
   to a ["--"] terminator — everything after it is a pattern and keeps its
   '='. A pattern or a short option's argument keeps its '=' too, and a
   nameless ["--=V"] stays whole so it fails as an unknown option instead of
   silently becoming ["--"] plus a pattern. So does [--flag=V] on a flag
   that takes no value: split, it would read as the flag plus a pattern. *)
let split_eq args =
  let split1 arg =
    if String.length arg > 2 && arg.[0] = '-' && arg.[1] = '-' then
      match String.index_opt arg '=' with
      | Some i when i > 2 && not (List.mem (String.sub arg 0 i) long_flags) ->
          [
            String.sub arg 0 i;
            String.sub arg (i + 1) (String.length arg - i - 1);
          ]
      | Some _ | None -> [ arg ]
    else [ arg ]
  in
  let rec go = function
    | [] -> []
    | "--" :: _ as rest -> rest
    | arg :: rest -> split1 arg @ go rest
  in
  go args

let parse argv =
  let args = match Array.to_list argv with [] -> [] | _ :: rest -> rest in
  (* The first argument names the subcommand; any later occurrence of a
     subcommand word is an ordinary pattern. *)
  let explicit, args =
    match args with
    | a :: rest -> (
        match subcommand_of a with
        | Some _ as s -> (s, rest)
        | None -> (None, args))
    | [] -> (None, args)
  in
  let args = split_eq args in
  let patterns = ref [] in
  let tags = ref [] in
  let quick = ref false in
  let precise = ref false in
  let baseline = ref None in
  let json = ref None in
  let strict = ref false in
  let wait_quiet = ref None in
  let force = ref false in
  let color = ref `Auto in
  let result = ref None in
  let error = ref None in
  (* Every error branch is terminal: the first defect wins. *)
  let fail msg = error := Some msg in
  let missing flag =
    fail (Printf.sprintf "option '%s' requires an argument" flag)
  in
  let rec go = function
    | [] -> ()
    | ("-h" | "--help") :: _ -> result := Some Help
    | ("-V" | "--version") :: _ -> result := Some Version
    | "--" :: rest -> List.iter (fun p -> patterns := p :: !patterns) rest
    | "-f" :: v :: rest ->
        patterns := v :: !patterns;
        go rest
    | [ "-f" ] -> missing "-f"
    | "--tag" :: v :: rest ->
        tags := v :: !tags;
        go rest
    | [ "--tag" ] -> missing "--tag"
    | "--quick" :: rest ->
        quick := true;
        go rest
    | "--precise" :: rest ->
        precise := true;
        go rest
    | "--baseline" :: v :: rest ->
        baseline := Some v;
        go rest
    | [ "--baseline" ] -> missing "--baseline"
    | "--json" :: "-" :: _ ->
        (* No stdout document: the report owns stdout, and a file named [-]
           is never what was meant. *)
        fail "option '--json' requires a file path, got '-'"
    | "--json" :: v :: rest ->
        json := Some v;
        go rest
    | [ "--json" ] -> missing "--json"
    | "--strict" :: rest ->
        strict := true;
        go rest
    | "--wait-quiet" :: v :: rest -> (
        match float_of_string_opt v with
        | Some s when Float.is_finite s && s >= 0. ->
            wait_quiet := Some s;
            go rest
        | Some _ | None ->
            fail
              (Printf.sprintf
                 "option '--wait-quiet' requires a non-negative number of \
                  seconds, got '%s'"
                 v))
    | [ "--wait-quiet" ] -> missing "--wait-quiet"
    | "--force" :: rest ->
        force := true;
        go rest
    | "--color" :: v :: rest -> (
        match v with
        | "auto" ->
            color := `Auto;
            go rest
        | "always" ->
            color := `Always;
            go rest
        | "never" ->
            color := `Never;
            go rest
        | _ ->
            fail
              (Printf.sprintf
                 "option '--color' takes auto, always, or never, got '%s'" v))
    | [ "--color" ] -> missing "--color"
    | a :: _ when String.length a > 1 && a.[0] = '-' -> (
        match String.index_opt a '=' with
        | Some i when List.mem (String.sub a 0 i) long_flags ->
            fail
              (Printf.sprintf "option '%s' takes no argument" (String.sub a 0 i))
        | Some _ | None -> fail (Printf.sprintf "unknown option '%s'" a))
    | a :: rest ->
        (* Bare positionals are [-f] patterns — never swallowed. *)
        patterns := a :: !patterns;
        go rest
  in
  go args;
  let subcommand = Option.value explicit ~default:`Check in
  (* The scoping matrix: a flag accepted where it does nothing would
     misdescribe the run, so it is a usage error naming both sides. *)
  let scoped flag allowed present =
    match !error with
    | Some _ -> ()
    | None ->
        if present && not (List.mem subcommand allowed) then
          let where =
            String.concat " and " (List.map subcommand_word allowed)
          in
          fail
            (Printf.sprintf "option '%s' applies to %s, not %s" flag where
               (subcommand_word subcommand))
  in
  let measuring = [ `Check; `Bless ] in
  scoped "--quick" measuring !quick;
  scoped "--precise" measuring !precise;
  scoped "--baseline" measuring (!baseline <> None);
  scoped "--json" [ `Check ] (!json <> None);
  scoped "--strict" [ `Check ] !strict;
  scoped "--wait-quiet" measuring (!wait_quiet <> None);
  scoped "--force" [ `Bless ] !force;
  match (!result, !error) with
  | Some r, _ -> r
  | None, Some msg -> Usage_error msg
  | None, None ->
      if !quick && !precise then
        Usage_error "--quick and --precise are mutually exclusive"
      else
        let preset =
          if !quick then `Quick else if !precise then `Precise else `Default
        in
        let o : options =
          {
            subcommand;
            patterns = List.rev !patterns;
            tags = List.rev !tags;
            preset;
            baseline = !baseline;
            json = !json;
            strict = !strict;
            wait_quiet = !wait_quiet;
            force = !force;
            color = !color;
          }
        in
        Run o

let filter_of ~patterns ~tags =
  let ids = List.map (fun p -> `Id p) patterns in
  let tag_fs = List.map (fun t -> `Tag t) tags in
  match (ids, tag_fs) with
  | [], [] -> None
  | ids, [] -> Some (`Or ids)
  | [], tag_fs -> Some (`And tag_fs)
  | ids, tag_fs -> Some (`And [ `Or ids; `And tag_fs ])

(* [--quick]/[--precise] refine the caller's config — they set the batch count
   to the preset's, keeping every other knob the caller chose. The CLI never
   flips [fork]: in-process measurement is a different protocol than the
   forked baseline evidence, so forking stays the library/test seam. *)
let config_of ?config (o : options) =
  let c = Option.value config ~default:Config.default in
  match o.preset with
  | `Default -> c
  | `Quick -> Config.samples Config.quick.Config.n c
  | `Precise -> Config.samples Config.precise.Config.n c

(* Color

   [main] resolves the mode once, for stdout; stderr is never styled.
   [--color always] beats NO_COLOR (the no-color.org contract: the variable
   is a default, an explicit request wins); NO_COLOR only dampens Auto; a
   rule action joins Auto because dune captures its output and re-displays
   it in a color-capable terminal. [dune exec] sets INSIDE_DUNE too, but its
   stdout is the user's own: a file there gets no escapes. *)
let use_color mode ~is_tty ~rule_action ~no_color =
  match mode with
  | `Always -> true
  | `Never -> false
  | `Auto -> (is_tty || rule_action) && not no_color

let styled ~color style s =
  if not color then s
  else
    let code =
      match style with
      | `Red -> "31"
      | `Green -> "32"
      | `Yellow -> "33"
      | `Cyan -> "36"
      | `Bold -> "1"
      | `Faint -> "2"
    in
    Printf.sprintf "\027[%sm%s\027[0m" code s

(* The status line *)

let status_line (p : Check.progress) =
  let verb =
    match p.Check.phase with
    | `Measuring -> "measuring"
    | `Confirming -> "confirming"
  in
  Printf.sprintf "thumper: %s %d/%d — %s" verb p.Check.index p.Check.total
    p.Check.case

(* Value formatting

   ASCII units, per-column time scaling, thousands separators in exact
   integers; ANSI styling only when the
   caller decided color is on. *)

let plural n = if n = 1 then "" else "s"

let group_int n =
  let s = string_of_int (abs n) in
  let len = String.length s in
  let buf = Buffer.create (len + (len / 3) + 1) in
  String.iteri
    (fun i c ->
      if i > 0 && (len - i) mod 3 = 0 then Buffer.add_char buf ',';
      Buffer.add_char buf c)
    s;
  (if n < 0 then "-" else "") ^ Buffer.contents buf

let time_unit v =
  let a = Float.abs v in
  if a < 1e-6 then ("ns", 1e9)
  else if a < 1e-3 then ("us", 1e6)
  else if a < 1. then ("ms", 1e3)
  else ("s", 1.)

(* The alloc column scales per column like the time column: the unit is
   picked from the column's smallest positive magnitude, so small counts
   stay exact integers ("54 w", thousands-separated) and a kilo-scale column
   reads "3 kw" / "32.73 kw" (trailing zeros trimmed). Display rounds; the
   gate never does — exact deltas in verdict cells keep full integers via
   [exact_str]. Sampled allocation is approximate by nature: the cell says
   so with [~], without a ci% of its own — one representation; the
   time ci already carries the run's sampling noise. *)
let words_unit v =
  let a = Float.abs v in
  if a < 1e3 then ("w", 1.) else if a < 1e6 then ("kw", 1e-3) else ("Mw", 1e-6)

(* A scaled value prints as a grouped integer, as base-unit counts do, from
   where its [%g] precision would turn to exponent notation ([1.235e+04 kw]):
   [%.4g] at five integer digits for an exact cell, [%.3g] at four for a
   sampled one. Below that, the cell keeps its significant digits. The unit
   stays the column's. *)
let exact_exponent_at = 9999.5
let approx_exponent_at = 999.5

let grouped_scaled v unit =
  group_int (Float.to_int (Float.round v)) ^ " " ^ unit

let exact_words ~unit ~wscale n =
  let v = float_of_int n *. wscale in
  if wscale = 1. then group_int n ^ " w"
  else if Float.abs v >= exact_exponent_at then grouped_scaled v unit
  else Printf.sprintf "%.4g %s" v unit

let approx_words ~unit ~wscale v =
  let v = v *. wscale in
  if Float.abs v >= approx_exponent_at then "~" ^ grouped_scaled v unit
  else Printf.sprintf "~%.3g %s" v unit

let exact_str metric n =
  match Metric.kind metric with
  | `Allocation -> group_int n ^ " w"
  | `Time | `Other -> Printf.sprintf "%s %s" (group_int n) (Metric.units metric)

let pct e = Printf.sprintf "%+.1f%%" (e *. 100.)
let bound e = Printf.sprintf "%+.1f" (e *. 100.)

(* Verdict classification *)

(* The failure/status predicates are [Verdict]'s own — the capitalized
   REGRESSED cells, the summary, and the [::error::] annotations agree with
   [Verdict.exit_code] and the JSON [status] by construction. *)
let case_fails (c : Verdict.case_report) = Verdict.case_overall c = `Fail

let report_proposed (mr : Verdict.metric_report) =
  match mr.verdict with Verdict.Proposed -> true | _ -> false

let count p l = List.length (List.filter p l)

let reason_short = function
  | Verdict.Wide_interval -> "wide interval"
  | Verdict.Non_positive -> "non-positive sample"
  | Verdict.Baseline_unstable -> "baseline unstable"
  | Verdict.Environment -> "environment"
  | Verdict.Unconfirmed -> "unconfirmed"
  | Verdict.Exactness_lost -> "exactness lost"
  | Verdict.Batch_drifted -> "batch drifted"
  | Verdict.Candidate_unstable -> "unstable"
  | Verdict.Candidate_drifted -> "drifted"

(* Path resolution *)

(* [under_dir dir path]: [path] lies strictly under directory [dir]. *)
let under_dir dir path =
  dir <> "" && dir <> "/"
  &&
  let n = String.length dir in
  String.length path > n && String.sub path 0 n = dir && path.[n] = '/'

let has_build_component path =
  String.split_on_char '/' path |> List.exists (fun c -> c = "_build")

(* Where the default [<suite>.thumper] resolves when no [--baseline] was
   given. Three branches, in order:

   - cwd inside a [_build] directory (rule actions, cram sandboxes): the
     cwd — the rule's [diff?] names files there, and a build action must
     never write to the source tree.
   - the executable runs from under a [_build] directory: the benchmark's
     source directory — the committable location, so [dune exec] from
     anywhere proposes the same file the dune rule's [diff?] would. The
     workspace root is the prefix before the last [/_build/]; after it come
     an optional [.sandbox/<hash>], the build context (default or named),
     and the source-relative executable path whose dirname rejoins the
     root. Used iff that directory exists, else the cwd.
   - anything else (an installed or copied binary knows no source tree):
     the cwd.

   Pure — [dir_exists] is its only window on the world — so the mapping
   unit-tests without processes. *)
let default_baseline_dir ~dir_exists ~exe ~cwd ~cwd_in_build =
  if cwd_in_build then cwd
  else
    let exe =
      if Filename.is_relative exe then Filename.concat cwd exe else exe
    in
    let marker = "/_build/" in
    let mlen = String.length marker in
    let n = String.length exe in
    let last_marker =
      let rec go i best =
        if i + mlen > n then best
        else if String.equal (String.sub exe i mlen) marker then
          go (i + 1) (Some i)
        else go (i + 1) best
      in
      go 0 None
    in
    match last_marker with
    | None -> cwd
    | Some i -> (
        let root = String.sub exe 0 i in
        let rest = String.sub exe (i + mlen) (n - i - mlen) in
        let segments =
          match String.split_on_char '/' rest with
          | ".sandbox" :: _hash :: tl -> tl
          | segments -> segments
        in
        match segments with
        | _context :: (_ :: _ as rel) ->
            let rec drop_last = function
              | [] | [ _ ] -> []
              | seg :: tl -> seg :: drop_last tl
            in
            let dir = List.fold_left Filename.concat root (drop_last rel) in
            if dir_exists dir then dir else cwd
        | _ -> cwd)

(* Rendering *)

(* [path] without its [.] segments (and empty ones), so a path prints one
   way however it was reached: [.././x] is [../x], [a/./b] is [a/b]. *)
let without_dot_segments path =
  let absolute = String.length path > 0 && path.[0] = '/' in
  match
    List.filter
      (fun seg -> seg <> "." && seg <> "")
      (String.split_on_char '/' path)
  with
  | [] -> if absolute then "/" else if path = "" then "" else "."
  | segs -> (if absolute then "/" else "") ^ String.concat "/" segs

(* [dune promote] is meaningful only when this process runs as a dune rule
   action: promotion is staged by the rule's [diff?], and actions run with
   their cwd inside the build directory. [dune exec] also sets [INSIDE_DUNE]
   but keeps the invoker's cwd in the source tree, where nothing is staged
   and [dune promote] silently does nothing — the v1-era footgun. The
   distinguisher: [INSIDE_DUNE]'s value is the build-context directory
   (older dunes set ["1"]); an action's cwd — sandboxed or not — lies under
   the build root, an exec'd or directly-run process's does not. *)
let promotion_staged ~inside_dune ~cwd =
  match inside_dune with
  | None -> false
  | Some v ->
      if Filename.is_relative v then has_build_component cwd
      else under_dir (Filename.dirname v) cwd || has_build_component cwd

(* Hint arguments paste into a shell where the command ran: a path that a
   POSIX shell would split or expand is quoted, ordinary paths stay bare so
   transcripts keep reading naturally. *)
let shell_arg s =
  let plain = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' -> true
    | '_' | '.' | '/' | ':' | '@' | '%' | '+' | '=' | ',' | '-' -> true
    | _ -> false
  in
  if s <> "" && String.for_all plain s then s else Filename.quote s

let accept_command ~promotion_staged ~corrected ~baseline =
  if promotion_staged then "dune promote"
  else Printf.sprintf "mv %s %s" (shell_arg corrected) (shell_arg baseline)

type render = {
  color : bool;
  accept : string;
  exe : string option;
  github : bool;
  baseline_path : string;
  corrected_path : string;
  wrote_corrected : bool;
  rerun_flags : string list;
  rerun_patterns : string list;
  strict : bool;
  cpu_model : string;
}

let pad_left s w =
  if String.length s >= w then s else String.make (w - String.length s) ' ' ^ s

(* The table

   One row per case, suite order: status | time | ±ci% | alloc | id, and the
   rest of the verdict cell, when there is any, on an indented line below.
   The status word opens the row and the id closes it, so only an id longer
   than the room left runs a row past 80 columns. The value columns show the
   first time-kind and first allocation-kind metrics; everything else
   surfaces through the cell. Widths are content-derived; the time column is
   unit-scaled per column (the unit of its smallest magnitude), so cells stay
   comparable down the column. *)

(* A cell fragment: its relation word ([REGRESSED], [inconclusive], ...),
   the separator that follows it ([" "], [": "], or [""] without a detail),
   and its detail ([wide interval], [alloc 54 w → 71 w (exact)]). A row
   opens on the first fragment's word; its detail line starts with that
   fragment's detail alone. *)
type frag = {
  word : string;
  sep : string;
  detail : string;
  style : [ `Red | `Green | `Yellow | `Faint ] option;
}

let frag ?style ?(sep = " ") word detail =
  { word; sep = (if detail = "" then "" else sep); detail; style }

type alloc_cell = Alloc_exact of int | Alloc_approx of float | No_alloc

type trow = {
  row_id : string;
  time : (float * float option) option; (* seconds, ci half-width in % *)
  alloc : alloc_cell;
  cell : frag list;
}

let time_of_trial trial =
  List.find_map
    (fun (m, meas) ->
      if Metric.kind m <> `Time then None
      else
        match meas with
        | Run.Samples s ->
            let med = Stats.median_sorted s.Run.sorted in
            let ci = Stats.median_ci_sorted ~alpha:0.05 s.Run.sorted in
            let half = (ci.Stats.upper -. ci.Stats.lower) /. 2. in
            let p = if med = 0. then 0. else Float.abs (half /. med) *. 100. in
            Some (med, Some p)
        | Run.Exact n -> Some (float_of_int n, None))
    (Run.Trial.measurements trial)

let alloc_of_trial trial =
  match
    List.find_map
      (fun (m, meas) -> if Metric.kind m = `Allocation then Some meas else None)
      (Run.Trial.measurements trial)
  with
  | Some (Run.Exact n) -> Alloc_exact n
  | Some (Run.Samples s) -> Alloc_approx (Stats.median_sorted s.Run.sorted)
  | None -> No_alloc

let table_lines ~color rows =
  let unit, scale =
    let min_v =
      List.fold_left
        (fun acc r ->
          match r.time with
          | Some (v, _) when v > 0. -> (
              match acc with None -> Some v | Some m -> Some (Float.min m v))
          | _ -> acc)
        None rows
    in
    match min_v with None -> ("ns", 1e9) | Some v -> time_unit v
  in
  let aunit, ascale =
    let mag = function
      | Alloc_exact n when n <> 0 -> Some (Float.abs (float_of_int n))
      | Alloc_approx v when v <> 0. -> Some (Float.abs v)
      | Alloc_exact _ | Alloc_approx _ | No_alloc -> None
    in
    let min_v =
      List.fold_left
        (fun acc r ->
          match (mag r.alloc, acc) with
          | Some v, None -> Some v
          | Some v, Some m -> Some (Float.min m v)
          | None, acc -> acc)
        None rows
    in
    match min_v with None -> ("w", 1.) | Some v -> words_unit v
  in
  let cells =
    List.map
      (fun r ->
        let t =
          match r.time with
          | Some (v, _) -> Printf.sprintf "%.2f %s" (v *. scale) unit
          | None -> ""
        in
        let ci =
          match r.time with
          | Some (_, Some p) -> Printf.sprintf "\xc2\xb1%.1f%%" p
          | _ -> ""
        in
        let alloc =
          match r.alloc with
          | Alloc_exact n -> exact_words ~unit:aunit ~wscale:ascale n
          | Alloc_approx v -> approx_words ~unit:aunit ~wscale:ascale v
          | No_alloc -> ""
        in
        (r.row_id, t, ci, alloc, r.cell))
      rows
  in
  let width f = List.fold_left (fun acc c -> max acc (String.length (f c))) 0 in
  let status = function f :: _ -> f.word | [] -> "" in
  let sw = width (fun (_, _, _, _, frags) -> status frags) cells in
  let tw = width (fun (_, t, _, _, _) -> t) cells in
  let cw = width (fun (_, _, c, _, _) -> c) cells in
  let aw = width (fun (_, _, _, a, _) -> a) cells in
  let paint style s =
    match style with None -> s | Some st -> styled ~color st s
  in
  List.concat_map
    (fun (id, t, ci, a, frags) ->
      let b = Buffer.create 96 in
      Buffer.add_string b "  ";
      (match frags with
      | f :: _ ->
          Buffer.add_string b (paint f.style f.word);
          Buffer.add_string b (String.make (sw - String.length f.word) ' ')
      | [] -> Buffer.add_string b (String.make sw ' '));
      if tw > 0 then Buffer.add_string b ("  " ^ pad_left t tw);
      if cw > 0 then Buffer.add_string b ("  " ^ pad_left ci cw);
      if aw > 0 then Buffer.add_string b ("  " ^ pad_left a aw);
      Buffer.add_string b ("  " ^ id);
      (* The detail: the status fragment's own detail, plain (its word
         already carries the style), then every other fragment whole. *)
      let detail =
        match frags with
        | [] -> []
        | f :: others ->
            (if f.detail = "" then [] else [ f.detail ])
            @ List.map
                (fun f -> paint f.style (f.word ^ f.sep ^ f.detail))
                others
      in
      match detail with
      | [] -> [ Buffer.contents b ]
      | d -> [ Buffer.contents b; "      " ^ String.concat "; " d ])
    cells

(* Verdict cells

   Only REGRESSED is capitalized, and only when the metric gates the case —
   the same predicate as [Verdict.exit_code]. Fragments of non-time
   metrics carry the metric's tag after the verdict word; the cell holds the
   case's notable relations, most severe first, "; "-joined. *)

let metric_tag m =
  match Metric.kind m with
  | `Allocation -> "alloc"
  | `Time | `Other -> Metric.id m

(* A sampled shift and its interval: [+12.1% [+7.3, +17.5]]. The report's
   cells and the annotations print it, and a relative budget, the same way. *)
let interval (s : Verdict.shift) =
  Printf.sprintf "%s [%s, %s]" (pct s.Verdict.estimate) (bound s.Verdict.lower)
    (bound s.Verdict.upper)

let relative_budget (mr : Verdict.metric_report) =
  match Option.map Budget.contract mr.budget with
  | Some (Budget.Relative { max_regression; _ }) ->
      Some (Printf.sprintf "budget +%g%%" (max_regression *. 100.))
  | Some (Budget.Absolute_max _) | None -> None

(* A proven-exact count over its absolute cap, as [(count, cap)], when the
   report gates on it. Under a baseline row the count is [Regressed] and its
   cell prints the pair; with no comparable row the cell prints the cap. *)
let cap_breach (c : Verdict.case_report) (mr : Verdict.metric_report) =
  match
    ( Option.map Budget.contract mr.budget,
      Run.Trial.measurement c.trial mr.metric )
  with
  | Some (Budget.Absolute_max cap), Some (Run.Exact n)
    when Verdict.report_fails c mr ->
      Some (n, cap)
  | _ -> None

(* A cap in the metric's units, grouped like a count and never in exponent
   notation: an integral cap reads as a count, a fractional one keeps up to
   six decimals ([1,234,567.5 w]). It prints only below a measured count, so
   it is non-negative and fits an int. *)
let cap_str metric cap =
  let whole = Float.of_int (Float.to_int cap) in
  let digits =
    if Float.is_integer cap then ""
    else
      let f = Printf.sprintf "%.6f" (cap -. whole) in
      let i = ref (String.length f) in
      while !i > 2 && f.[!i - 1] = '0' do
        decr i
      done;
      if !i <= 2 then "" else String.sub f 1 (!i - 1)
  in
  let unit =
    match Metric.kind metric with
    | `Allocation -> "w"
    | `Time | `Other -> Metric.units metric
  in
  group_int (Float.to_int cap) ^ digits ^ " " ^ unit

(* (rank, fragment): rank orders fragments most-severe-first — 0 gating
   REGRESSED, 1 demonstrated-but-ungated regression, 2 inconclusive, 3
   improved, 4 within budget, 5 proposed, 6 the exact-equal reassurance. *)
let fragment_of ~primary (c : Verdict.case_report) (mr : Verdict.metric_report)
    =
  let m = mr.metric in
  (* A non-time metric's fragment names it first: [alloc 54 w → 71 w]. *)
  let tagged body =
    if primary then body
    else if body = "" then metric_tag m
    else metric_tag m ^ " " ^ body
  in
  let strong_detail = function
    | Verdict.Confirmed { first; _ } -> interval first
    | Verdict.Exact_change { baseline; candidate } ->
        Printf.sprintf "%s \xe2\x86\x92 %s (exact)" (exact_str m baseline)
          (exact_str m candidate)
  in
  match (mr.verdict, cap_breach c mr) with
  | (Verdict.Proposed | Verdict.Judged (Verdict.Inconclusive _)), Some (n, cap)
    ->
      Some
        ( 0,
          frag ~style:`Red "REGRESSED"
            (tagged
               (Printf.sprintf "%s, over its %s cap (exact)" (exact_str m n)
                  (cap_str m cap))) )
  | Verdict.Proposed, None -> Some (5, frag "proposed" (tagged ""))
  | Verdict.Judged (Verdict.Regressed strong), _ ->
      let fails = Verdict.report_fails c mr in
      let word = if fails then "REGRESSED" else "regressed" in
      let style = if fails then `Red else `Yellow in
      let budget =
        match (strong, relative_budget mr) with
        | Verdict.Confirmed _, Some b -> "  " ^ b
        | _ -> ""
      in
      Some
        ( (if fails then 0 else 1),
          frag ~style word (tagged (strong_detail strong ^ budget)) )
  | Verdict.Judged (Verdict.Improved strong), _ ->
      Some (3, frag ~style:`Green "improved" (tagged (strong_detail strong)))
  | Verdict.Judged (Verdict.Within_budget s), _ ->
      Some (4, frag "within budget" (tagged (pct s.Verdict.estimate)))
  | Verdict.Judged (Verdict.Inconclusive { reason; _ }), None ->
      let reason = reason_short reason in
      Some
        ( 2,
          if primary then frag ~style:`Yellow ~sep:": " "inconclusive" reason
          else frag ~style:`Yellow "inconclusive" (metric_tag m ^ ": " ^ reason)
        )
  | Verdict.Judged (Verdict.Equivalent _), _ -> None

(* The reassurance exception: when the cell is otherwise non-pass, an
   exact-equal metric's earned verdict stays visible. *)
let reassurance_of ~primary (c : Verdict.case_report)
    (mr : Verdict.metric_report) =
  match mr.verdict with
  | Verdict.Judged (Verdict.Equivalent None) when not primary -> (
      match Run.Trial.measurement c.trial mr.metric with
      | Some (Run.Exact _) ->
          Some
            ( 6,
              frag "equivalent"
                (Printf.sprintf "(%s exact)" (metric_tag mr.metric)) )
      | _ -> None)
  | _ -> None

let check_cell (c : Verdict.case_report) =
  let primary_metric =
    match
      List.find_opt
        (fun (mr : Verdict.metric_report) -> Metric.kind mr.metric = `Time)
        c.reports
    with
    | Some mr -> Some mr.metric
    | None -> ( match c.reports with mr :: _ -> Some mr.metric | [] -> None)
  in
  let is_primary (mr : Verdict.metric_report) =
    match primary_metric with
    | Some m -> Metric.equal m mr.metric
    | None -> false
  in
  if
    c.reports <> []
    && List.for_all report_proposed c.reports
    && not (case_fails c)
  then [ frag "proposed" "" ]
  else
    let notable =
      List.filter_map
        (fun mr -> fragment_of ~primary:(is_primary mr) c mr)
        c.reports
    in
    match notable with
    | [] -> [ frag ~style:`Faint "equivalent" "" ]
    | _ -> (
        let non_pass = List.exists (fun (rank, _) -> rank <= 2) notable in
        let reassure =
          if non_pass then
            List.filter_map
              (fun mr -> reassurance_of ~primary:(is_primary mr) c mr)
              c.reports
          else []
        in
        let frags =
          List.stable_sort
            (fun (a, _) (b, _) -> Int.compare a b)
            (notable @ reassure)
          |> List.map snd
        in
        (* Only a non-time metric is proposed: the compared metric was
           equivalent, and the row says so before naming what is proposed. *)
        match frags with
        | { word = "proposed"; detail; _ } :: _ when detail <> "" ->
            frag ~style:`Faint "equivalent" "" :: frags
        | _ -> frags)

(* The report *)

(* The rerun hint names at most this many failing cases; past it, the
   command re-measures the run's own selection. *)
let rerun_cap = 10

(* Display columns of a UTF-8 string: its bytes that start a code point. *)
let columns s =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
  !n

(* One pasteable command over as many lines as it takes to stay within 80
   columns: [label] and [head] open the first line, each item (never split)
   joins the current line or starts the next behind a backslash continuation,
   indented under [head]. *)
let wrap_command ~label head items =
  let indent = String.make (columns label) ' ' in
  let lines, last =
    List.fold_left
      (fun (lines, cur) item ->
        if columns cur + 1 + columns item + 2 > 80 then
          ((cur ^ " \\") :: lines, indent ^ item)
        else (lines, cur ^ " " ^ item))
      ([], label ^ head)
      items
  in
  List.rev (last :: lines)

let report_of_blocks blocks =
  let blocks = List.filter (fun b -> b <> []) blocks in
  String.concat "\n\n" (List.map (String.concat "\n") blocks) ^ "\n"

let header_line ~color ~suite rest =
  styled ~color `Faint "thumper: "
  ^ styled ~color `Bold suite ^ styled ~color `Faint rest

let render_check r v =
  let color = r.color in
  let cases = Verdict.cases v in
  let n_cases = List.length cases in
  let ident = Verdict.identity v in
  let comparison = Verdict.comparison v in
  let suite = Verdict.suite v in
  (* The report's load message agrees with judgment: the gate the verdict
     was decided under, never a pre-lease reading of somebody else's load
     (the lease wait can be minutes long). *)
  let load = Verdict.load v in
  let acceptance =
    match comparison with
    | Verdict.No_baseline | Verdict.Stale _ -> true
    | Verdict.Compared -> false
  in
  (* Header — with the compared run's load warning directly under it; the
     acceptance states put their one load message beside the prompt
     instead. *)
  let header =
    let head =
      match comparison with
      | Verdict.Compared ->
          header_line ~color ~suite
            (Printf.sprintf " — %d case%s vs %s for machine %s" n_cases
               (plural n_cases) r.baseline_path ident.Baseline.machine)
      | Verdict.No_baseline ->
          header_line ~color ~suite
            (Printf.sprintf " — no baseline for machine %s (%s)"
               ident.Baseline.machine r.cpu_model)
      | Verdict.Stale (Verdict.Ocaml_mismatch { section; current }) ->
          (* The recorded identity is text from the file: quoted when it
             holds a control byte, as it could write to the terminal. *)
          let section =
            if String.exists (fun c -> c < ' ' || c = '\x7f') section then
              Baseline.quote section
            else section
          in
          header_line ~color ~suite
            (Printf.sprintf
               " — stale baseline for machine %s (ocaml %s \xe2\x86\x92 %s)"
               ident.Baseline.machine section current)
    in
    match (comparison, load) with
    | Verdict.Compared, Env.Loaded { load; cores } ->
        [
          head;
          styled ~color `Yellow
            (Printf.sprintf
               "warning: load %.1f on %d cores; timing verdicts degraded" load
               cores);
        ]
    | _ -> [ head ]
  in
  (* Table rows in suite order, then the warnings. *)
  let rows =
    List.map
      (fun (c : Verdict.case_report) ->
        (* A proposed case whose count breaks its cap fails even here. *)
        let cell =
          if acceptance && not (case_fails c) then [ frag "proposed" "" ]
          else check_cell c
        in
        {
          row_id = c.id;
          time = time_of_trial c.trial;
          alloc = alloc_of_trial c.trial;
          cell;
        })
      cases
  in
  let warnings =
    List.concat_map
      (fun (c : Verdict.case_report) ->
        List.map
          (fun w ->
            styled ~color `Yellow (Printf.sprintf "  warning: %s: %s" c.id w))
          c.warnings)
      cases
    @ List.map
        (fun w -> styled ~color `Yellow ("  warning: " ^ w))
        (Verdict.warnings v)
  in
  let table = table_lines ~color rows @ warnings in
  (* Actions: the rerun for failures, the accept line for a written
     corrected file, the acceptance-state load message beside it. *)
  let actions =
    let failing = List.filter case_fails cases in
    let rerun =
      match (failing, r.exe) with
      | [], _ | _, None -> []
      | _, Some exe ->
          let selection =
            if List.length failing <= rerun_cap then
              List.map (fun (c : Verdict.case_report) -> "-f " ^ c.id) failing
            else List.map (fun p -> "-f " ^ shell_arg p) r.rerun_patterns
          in
          wrap_command ~label:"  rerun:   " (shell_arg exe)
            (r.rerun_flags @ selection)
    in
    let prompt =
      if r.wrote_corrected then [ Printf.sprintf "  accept:  %s" r.accept ]
      else []
    in
    let load_warning =
      match (acceptance && r.wrote_corrected, load) with
      | true, Env.Loaded { load; cores } ->
          [
            styled ~color `Yellow
              (Printf.sprintf
                 "  warning: load %.1f on %d cores; prefer a quiet host before \
                  accepting"
                 load cores);
          ]
      | _ -> []
    in
    rerun @ prompt @ load_warning
  in
  (* Summary, compared runs only. Its color is the outcome's: red iff the run
     exits 1, so a [--strict] run that fails on inconclusive cases does not
     end on a yellow line. *)
  let summary =
    match comparison with
    | Verdict.No_baseline | Verdict.Stale _ -> []
    | Verdict.Compared ->
        let n_fail = count case_fails cases in
        let n_inc =
          count (fun c -> Verdict.case_overall c = `Inconclusive) cases
        in
        (* Among passing cases, a never-compared one is [proposed] and one
           whose row opens on [improved] is improved: the summary never
           counts as passed what the table does not call a pass. *)
        let passing =
          List.filter (fun c -> Verdict.case_overall c = `Pass) cases
        in
        let n_prop =
          count
            (fun (c : Verdict.case_report) ->
              c.reports <> [] && List.for_all report_proposed c.reports)
            passing
        in
        let n_imp =
          count
            (fun c ->
              match check_cell c with
              | { word = "improved"; _ } :: _ -> true
              | _ -> false)
            passing
        in
        let n_pass = n_cases - n_fail - n_inc - n_prop - n_imp in
        let term n word =
          if n > 0 then [ Printf.sprintf "%d %s" n word ] else []
        in
        let parts =
          [ Printf.sprintf "%d passed" n_pass ]
          @ term n_imp "improved" @ term n_fail "regressed"
          @ term n_inc "inconclusive" @ term n_prop "proposed"
        in
        let code = Verdict.exit_code ~strict:r.strict v in
        (* A run --strict failed says so in words, not in red alone. *)
        let strict_clause =
          if code <> 0 && Verdict.exit_code v = 0 then "; failed under --strict"
          else ""
        in
        let style =
          if code <> 0 then `Red else if n_inc > 0 then `Yellow else `Green
        in
        [
          "  "
          ^ styled ~color style
              (Printf.sprintf "%d case%s: %s%s." n_cases (plural n_cases)
                 (String.concat ", " parts) strict_clause);
        ]
  in
  (* GitHub annotations on gating regressions, closing the report: CI wants
     them whatever the terminal shows, under the same gate predicate. *)
  let annotations =
    if not r.github then []
    else
      List.concat_map
        (fun (c : Verdict.case_report) ->
          List.filter_map
            (fun (mr : Verdict.metric_report) ->
              if not (Verdict.report_fails c mr) then None
              else
                match mr.verdict with
                | Verdict.Judged (Verdict.Regressed strong) ->
                    (* The row's own facts: the id [-f] selects by, the
                       shift with its interval and budget, or the exact
                       integers. *)
                    let detail =
                      match strong with
                      | Verdict.Confirmed { first; _ } -> (
                          match relative_budget mr with
                          | Some b -> interval first ^ ", " ^ b
                          | None -> interval first)
                      | Verdict.Exact_change { baseline; candidate } ->
                          let unit =
                            match Metric.kind mr.metric with
                            | `Allocation -> "w"
                            | `Time | `Other -> Metric.units mr.metric
                          in
                          Printf.sprintf "%d \xe2\x86\x92 %d %s (exact)"
                            baseline candidate unit
                    in
                    Some
                      (Printf.sprintf "::error::%s regressed: %s %s" c.id
                         (Metric.id mr.metric) detail)
                | _ -> (
                    match cap_breach c mr with
                    | Some (n, cap) ->
                        Some
                          (Printf.sprintf
                             "::error::%s regressed: %s %s, over its %s cap \
                              (exact)"
                             c.id (Metric.id mr.metric) (exact_str mr.metric n)
                             (cap_str mr.metric cap))
                    | None -> None))
            c.reports)
        cases
  in
  report_of_blocks [ header; table; actions; summary; annotations ]

(* The effectful adapter *)

exception Exit_with of int

let fail2 fmt =
  Format.kasprintf
    (fun msg ->
      Printf.eprintf "thumper: %s\n%!" msg;
      raise (Exit_with 2))
    fmt

let pp_str pp v = Format.asprintf "%a" pp v

(* Startup unlink of an owned artifact: a leftover candidate or JSON
   target must never survive into this invocation's readers. *)
let unlink_owned path =
  try Unix.unlink path with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | Unix.Unix_error (e, _, _) ->
      fail2 "cannot remove stale artifact %s: %s" path (Unix.error_message e)

(* Pre-flight an artifact target that measurement will write unconditionally
   (the [--json] document; bless's candidate): its directory must exist and be
   writable {e before} minutes of measurement are spent, not after. The check
   is advisory (the world can change under us — the write still handles its
   own failure); what it buys is failing the common defect — a mistyped or
   missing directory — up front, where exit 2 costs nothing. *)
let preflight_target path =
  let dir = Filename.dirname path in
  match (Unix.stat dir).Unix.st_kind with
  | Unix.S_DIR -> (
      try Unix.access dir [ Unix.W_OK; Unix.X_OK ]
      with Unix.Unix_error (e, _, _) ->
        fail2 "cannot write %s: %s: %s" path dir (Unix.error_message e))
  | _ -> fail2 "cannot write %s: %s is not a directory" path dir
  | exception Unix.Unix_error (e, _, _) ->
      fail2 "cannot write %s: %s: %s" path dir (Unix.error_message e)

(* The [--json] document is present iff measurement completed: an atomic
   publish, so no reader sees a partial one. *)
let write_json path doc =
  try Os.write_atomic path doc
  with Unix.Unix_error (e, _, _) ->
    fail2 "cannot write %s: %s" path (Unix.error_message e)

(* All measurement runs under the CLI's lease acquisition so the progress line
   is ours; [Check]'s inner acquisition is reentrant (Env.Lock). *)
let with_lock_progress f =
  let waiting = ref false in
  let on_wait ~owner_changed =
    if not !waiting then begin
      Printf.eprintf
        "thumper: waiting for the measurement lock (another run is measuring) \
         ...\n\
         %!";
      waiting := true
    end
    else if owner_changed then
      Printf.eprintf
        "thumper: the measurement lock changed owner; waiting on the new \
         holder ...\n\
         %!"
  in
  match Env.Lock.with_lock ~on_wait f with
  | Ok v -> v
  | Error e -> fail2 "%s" (pp_str Env.Lock.pp_error e)

let checked f =
  try f () with Check.Error e -> fail2 "%s" (pp_str Check.pp_error e)

(* The status line: stderr, \r-overwritten, erased before anything
   else prints, and emitted only on a TTY — dune, CI, and redirects see zero
   bytes of it. It lives inside [checked] so an operational error erases the
   line before its message prints. *)
let with_status f =
  if not (Unix.isatty Unix.stderr) then f (fun _ -> ())
  else
    let tick p = Printf.eprintf "\r%s\027[K%!" (status_line p) in
    Fun.protect
      ~finally:(fun () -> Printf.eprintf "\r\027[K%!")
      (fun () -> f tick)

(* A malformed THUMPER_MACHINE is a usage error (exit 2), not a crash. *)
let machine_key () =
  try Env.machine_key () with Invalid_argument msg -> fail2 "%s" msg

(* A baseline error as a stop line: a content error is anchored on its file,
   an I/O error names the file itself ([cannot read <path>: <reason>]). *)
let baseline_error path = function
  | Baseline.Io _ as e -> pp_str Baseline.pp_error e
  | Baseline.Corrupt _ as e -> path ^ ": " ^ pp_str Baseline.pp_error e

(* An absent file is the ordinary first-run state, [None]. Io and
   Corrupt are exit 2, never treated as absent. A file whose
   header names another suite is refused the same way cross-machine
   comparison is: judging against the wrong ruler must be loud, not a page
   of NEW proposals. *)
let read_baseline ~suite path =
  match Baseline.read path with
  | Ok (Some f) -> (
      match Baseline.suite f with
      | Some s when not (String.equal s suite) ->
          fail2
            "%s: baseline is for suite %s, not %s; pass this suite's file with \
             --baseline, or update the '# suite:' header if the suite was \
             renamed"
            path (Baseline.quote s) (Baseline.quote suite)
      | _ -> Some f)
  | Ok None -> None
  | Error e -> fail2 "%s" (baseline_error path e)

let write_baseline path file =
  try Baseline.write path file
  with Baseline.Error e -> fail2 "%s" (baseline_error path e)

(* Selection preflight, before the lease: a broken suite or filter must fail
   without waiting on a holder (and [list] is exactly this). The empty
   selection names the unmatched patterns and tags — "bench.exe explore" must
   explain itself, not exit a bare 2. *)
let no_match ~patterns ~tags =
  let quoted l = String.concat ", " (List.map (fun s -> "'" ^ s ^ "'") l) in
  match (patterns, tags) with
  | [], [] -> pp_str Check.pp_error Check.Empty_selection
  | ps, [] -> Printf.sprintf "no case matches %s" (quoted ps)
  | [], ts -> Printf.sprintf "no case matches tag %s" (quoted ts)
  | ps, ts ->
      Printf.sprintf "no case matches %s with tag %s" (quoted ps) (quoted ts)

let selection ~patterns ~tags ~config ~budgets ?filter benches =
  match
    Check.select ?filter ~metrics:config.Config.metrics
      ~budgets:(Option.value budgets ~default:[])
      benches
  with
  | selected -> selected
  | exception Check.Error Check.Empty_selection ->
      fail2 "%s" (no_match ~patterns ~tags)
  | exception Check.Error e -> fail2 "%s" (pp_str Check.pp_error e)

(* [--wait-quiet]: [Some secs] iff the wait expired with the host still
   loaded, for the caller to warn ([check]) or refuse ([bless]). *)
let wait_for_quiet = function
  | None -> None
  | Some secs -> (
      (* A bounded wait must be loud: a silent multi-second pause is
         indistinguishable from a hang. One line when the wait begins (only
         when there is something to wait out). *)
      (match Env.load () with
      | Env.Loaded { load; cores } ->
          Printf.eprintf
            "thumper: waiting up to %gs for a quiet host (load %.1f on %d cores)\n\
             %!"
            secs load cores
      | Env.Quiet -> ());
      match Env.wait_quiet ~timeout_s:secs () with
      | Ok () -> None
      | Error `Timeout -> Some secs)

(* An expired wait on a run that measures anyway: the report's own load
   warning says what that costs. *)
let warn_expired = function
  | None -> ()
  | Some secs ->
      Printf.eprintf
        "thumper: warning: host still loaded after %gs; measuring anyway\n%!"
        secs

let validate_budgets budgets =
  Option.iter (Budget.check_distinct ~fname:"Thumper.run") budgets

(* Subcommands *)

let run_list ~(o : options) ~config ~filter ~budgets benches =
  List.iter
    (fun c -> print_endline (Bench.id c))
    (fst
       (selection ~patterns:o.patterns ~tags:o.tags ~config ~budgets ?filter
          benches));
  0

let run_check ~(o : options) ~name ~config ~filter ~budgets ~baseline_path
    ~corrected_path ~color ~accept ~staged ~exe benches =
  (* [Check.run_with] reads the key before its own lock acquisition, but it
     runs inside this module's [with_lock_progress], so a malformed override
     would raise [Invalid_argument] only after the lock wait: validate it
     first, as a stop, as [bless] does. *)
  ignore (machine_key ());
  ignore
    (selection ~patterns:o.patterns ~tags:o.tags ~config ~budgets ?filter
       benches);
  let file = read_baseline ~suite:name baseline_path in
  (* Without a baseline the corrected file is certain (every row is new), so
     its target is pre-flighted like bless's before minutes of measurement.
     With one, a pass run writes nothing and needs no writable directory. *)
  if Option.is_none file then preflight_target corrected_path;
  warn_expired (wait_for_quiet o.wait_quiet);
  let verdict =
    checked (fun () ->
        with_status (fun tick ->
            with_lock_progress (fun () ->
                Check.run_with ~on_progress:tick ~config ?budgets ?filter
                  ?baseline:file name benches)))
  in
  (* The JSON document first: its contract is "present iff measurement
     completed", and measurement has — a corrected-file write that fails (a
     full disk, or an unwritable directory no pre-flight covered) must not
     take the verdict document down with it. *)
  Option.iter (fun p -> write_json p (Verdict.to_json verdict ^ "\n")) o.json;
  (* A late write failure (a full disk) still prints the report, without
     the accept line of a file that does not exist, then the error. *)
  let written =
    match Verdict.corrected verdict with
    | None -> Ok false
    | Some cand -> (
        match Baseline.write corrected_path cand with
        | () -> Ok true
        | exception Baseline.Error e -> Error e)
  in
  let r =
    {
      color;
      accept;
      (* Under a rule action the hint cannot be pasted: [exe] is relative to
         the action's cwd inside [_build], and the dune user's next step is
         the alias they ran. *)
      exe = (if staged then None else Some exe);
      github = Sys.getenv_opt "GITHUB_ACTIONS" <> None;
      baseline_path;
      corrected_path;
      wrote_corrected = Result.value written ~default:false;
      (* The rerun hint reproduces the invocation, not just the selection: the
         preset, an explicit --baseline and every --tag are carried
         (getting-started's "the exact command"); the default baseline
         re-resolves identically from the exe path, so it stays unspelled. *)
      rerun_flags =
        (match o.preset with
          | `Default -> []
          | `Quick -> [ "--quick" ]
          | `Precise -> [ "--precise" ])
        @ (match o.baseline with
          | Some _ -> [ "--baseline " ^ shell_arg baseline_path ]
          | None -> [])
        @ List.map (fun t -> "--tag " ^ shell_arg t) o.tags;
      rerun_patterns = o.patterns;
      strict = o.strict;
      cpu_model = Env.cpu_model ();
    }
  in
  print_string (render_check r verdict);
  match written with
  | Ok _ -> Verdict.exit_code ~strict:o.strict verdict
  | Error e ->
      (* The report first, on a terminal too, where stderr is unbuffered. *)
      flush stdout;
      fail2 "%s" (baseline_error corrected_path e)

let run_bless ~(o : options) ~name ~config ~filter ~budgets ~baseline_path
    ~corrected_path ~color ~accept benches =
  (* The run's budgets are not bless's business, but a suite [check] refuses
     is refused here too (the selection checks the whole suite): blessing it
     would record a ruler nothing can judge against. *)
  let sel, scope =
    selection ~patterns:o.patterns ~tags:o.tags ~config ~budgets ?filter benches
  in
  let machine = machine_key () in
  let identity =
    {
      Baseline.machine;
      host = Env.host_description ();
      ocaml = Env.ocaml_identity ();
    }
  in
  let file = read_baseline ~suite:name baseline_path in
  (* On bless an expired wait is the refusal itself, unless [--force]. *)
  (match wait_for_quiet o.wait_quiet with
  | Some secs when not o.force -> (
      match Env.load () with
      | Env.Loaded { load; cores } ->
          fail2
            "bless refused: host still loaded after %gs (load %.1f on %d \
             cores); rerun with --force to record it anyway"
            secs load cores
      | Env.Quiet -> ())
  | expired -> warn_expired expired);
  (* The gate refusal is bless's own guard: a noisy bless poisons
     the ruler; [--force] overrides and is recorded in the section header.
     The gate is sampled under the lease, directly before measurement — the
     same principle as check's [Verdict.load]: a lease wait can be minutes long,
     and a decision taken on a pre-lease sample would refuse on somebody
     else's load, or worse, record an unannotated noisy bless after a
     quiet-to-loaded transition. Residual, accepted: [--wait-quiet] still
     waits pre-lease (holding the lease while waiting for quiet would block
     every other process), so a load spike after both waits is refused only
     here, at measurement time. *)
  let forced_under_load = ref None in
  let refuse_or_force () =
    match Env.load () with
    | Env.Quiet -> ()
    | Env.Loaded { load; cores } ->
        if o.force then forced_under_load := Some (load, cores)
        else
          fail2
            "bless refused: load %.1f on %d cores; rerun with --wait-quiet \
             SECS, or with --force to record it anyway"
            load cores
  in
  let run =
    checked (fun () ->
        with_status (fun tick ->
            with_lock_progress (fun () ->
                refuse_or_force ();
                Check.measure ~on_progress:tick ~config ?filter benches)))
  in
  let forced_under_load = !forced_under_load in
  (* The [--force] record in the section header; a partial bless names its
     cases, the rows the load touched. *)
  let annotations =
    match forced_under_load with
    | None -> []
    | Some (load, cores) ->
        let cases =
          match scope with
          | `Full -> ""
          | `Partial -> String.concat " " (List.map Bench.id sel) ^ " "
        in
        [
          Printf.sprintf "forced: blessed %sunder load %.1f on %d cores" cases
            load cores;
        ]
  in
  let file = Option.value file ~default:(Baseline.empty ~suite:name) in
  let corrected, notices =
    Verdict.bless ~annotations ~identity ~suite:name ~selection:scope ~run file
  in
  write_baseline corrected_path corrected;
  (* The bless report is the same shape as check's — header, table of proposed
     rows, actions — and always prints whole. *)
  let n = List.length sel in
  let header =
    [
      header_line ~color ~suite:name
        (Printf.sprintf " — blessed %d case%s for machine %s" n (plural n)
           machine);
    ]
  in
  let table =
    table_lines ~color
      (List.map
         (fun (id, trial) ->
           {
             row_id = id;
             time = time_of_trial trial;
             alloc = alloc_of_trial trial;
             cell = [ frag "proposed" "" ];
           })
         (Run.trials run))
    @ List.concat_map
        (fun (id, trial) ->
          List.map
            (fun w ->
              styled ~color `Yellow (Printf.sprintf "  warning: %s: %s" id w))
            (Run.Trial.warnings trial))
        (Run.trials run)
  in
  let actions =
    (* One load message per run: --force is the only way a bless report exists
       under load, and its warning names the load. *)
    (match forced_under_load with
      | Some (load, cores) ->
          [
            styled ~color `Yellow
              (Printf.sprintf
                 "  warning: blessed under load %.1f on %d cores (--force \
                  recorded)"
                 load cores);
          ]
      | None -> [])
    (* A partial bless over a stale section still re-records it whole; the
       notice says what that drops, next to the prompt, where promotion is
       reviewed. *)
    @ List.map (fun w -> styled ~color `Yellow ("  warning: " ^ w)) notices
    @ [ Printf.sprintf "  accept:  %s" accept ]
  in
  print_string (report_of_blocks [ header; table; actions ]);
  0

(* Help and entry *)

let exe_of argv = if Array.length argv > 0 then argv.(0) else "bench.exe"

let help_text exe =
  let name = Filename.basename exe in
  String.concat "\n"
    [
      Printf.sprintf "%s: thumper benchmark suite (thumper %s)" name version;
      "";
      Printf.sprintf "usage: %s [check|bless|list] [OPTS] [PATTERN...]" name;
      "";
      "subcommands:";
      "  check      measure, compare against the baseline (default)";
      "  bless      propose a re-record of the selected cases for this machine";
      "  list       print the selected case ids; no measurement";
      "";
      "options:";
      "  -f PAT             select cases whose id contains PAT (repeatable,";
      "                     OR'd); bare PATTERN arguments mean the same";
      "  --tag T            select cases tagged T (repeatable, AND'd)";
      "  --quick            quick protocol (fewer samples)";
      "  --precise          precise protocol (more samples)";
      "  --baseline PATH    baseline file (default: <suite>.thumper next to";
      "                     the benchmark's source)";
      "  --json PATH        check: write the verdict document to PATH";
      "  --strict           check: inconclusive, proposed, and stale exit 1";
      "  --wait-quiet SECS  wait up to SECS for a quiet host before measuring";
      "  --force            bless despite a loaded host (recorded)";
      "  --color MODE       color the report: auto (default), always, never";
      "  -h, --help         show this help";
      "  -V, --version      print the version";
      "";
      "environment: THUMPER_MACHINE (machine key), THUMPER_LOCK_DIR (lock";
      "directory), NO_COLOR, GITHUB_ACTIONS (adds ::error:: annotations);";
      "INSIDE_DUNE selects the dune hints and, in a rule action, colour.";
      "";
    ]

let main ?baseline ?config ?budgets ~argv ~name benches =
  Baseline.check_suite ~fname:"Thumper.run" name;
  validate_budgets budgets;
  match parse argv with
  | Help ->
      print_string (help_text (exe_of argv));
      0
  | Version ->
      print_string ("thumper " ^ version ^ "\n");
      0
  | Usage_error msg ->
      Printf.eprintf "thumper: %s\nTry '-h' for usage.\n%!" msg;
      2
  | Run o -> (
      try
        let exe = exe_of argv in
        let cwd = Sys.getcwd () in
        let inside_dune = Sys.getenv_opt "INSIDE_DUNE" in
        let staged = promotion_staged ~inside_dune ~cwd in
        let baseline_path =
          without_dot_segments
          @@
          match (o.baseline, baseline) with
          | Some p, _ | None, Some p ->
              (* An explicit path resolves, and prints, as typed: the hints
                 are pasted where the command ran, and the header, the
                 rerun line and the accept line then spell the file one
                 way. Inside a rule, relative paths are the contract too —
                 they name the same files the rule's [diff?] names. *)
              p
          | None, None ->
              (* The default resolves in [default_baseline_dir]'s directory
                 — the committable location next to the benchmark's source
                 when the executable runs from [_build], the cwd inside a
                 rule action ([diff?]'s contract) and for installed
                 binaries. A mapped source directory under the invoker's
                 cwd renders as the short relative path; everything else
                 keeps the explicit-path rendering above. *)
              let dir =
                let dir_exists d =
                  match Sys.is_directory d with
                  | b -> b
                  | exception Sys_error _ -> false
                in
                default_baseline_dir ~dir_exists ~exe:Sys.executable_name ~cwd
                  ~cwd_in_build:(has_build_component cwd)
              in
              let file = name ^ ".thumper" in
              if String.equal dir cwd then
                if staged then file else Filename.concat cwd file
              else if under_dir cwd dir then
                let rel =
                  let n = String.length cwd in
                  String.sub dir (n + 1) (String.length dir - n - 1)
                in
                Filename.concat rel file
              else Filename.concat dir file
        in
        let corrected_path = baseline_path ^ ".corrected" in
        (* Startup unlinks of both owned artifacts, before anything else can
           fail — for every subcommand, so no non-measuring
           invocation leaves a stale artifact to be read. *)
        unlink_owned corrected_path;
        Option.iter unlink_owned o.json;
        (* Unconditional write targets are pre-flighted here, before any
           measurement can be wasted on a target that can never be written:
           the [--json] document and bless's corrected file (check's is
           conditional; [run_check] pre-flights it once it knows the
           baseline is absent). *)
        Option.iter preflight_target o.json;
        (match o.subcommand with
        | `Bless -> preflight_target corrected_path
        | `Check | `List -> ());
        let filter = filter_of ~patterns:o.patterns ~tags:o.tags in
        let config = config_of ?config o in
        let color =
          use_color o.color ~is_tty:(Unix.isatty Unix.stdout)
            ~rule_action:staged
            ~no_color:
              (match Sys.getenv_opt "NO_COLOR" with
              | Some s when s <> "" -> true
              | Some _ | None -> false)
        in
        let accept =
          accept_command ~promotion_staged:staged ~corrected:corrected_path
            ~baseline:baseline_path
        in
        match o.subcommand with
        | `List -> run_list ~o ~config ~filter ~budgets benches
        | `Check ->
            run_check ~o ~name ~config ~filter ~budgets ~baseline_path
              ~corrected_path ~color ~accept ~staged ~exe benches
        | `Bless ->
            run_bless ~o ~name ~config ~filter ~budgets ~baseline_path
              ~corrected_path ~color ~accept benches
      with Exit_with code -> code)
