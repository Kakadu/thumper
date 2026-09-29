(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let strf = Printf.sprintf

(* Every escape sequence thumper writes starts here: the styles of [styled]
   and the status line's erase. *)
let csi s = "\027[" ^ s

let styled ~color style s =
  if not color then s
  else
    let code =
      match style with
      | `Red -> "31"
      | `Green -> "32"
      | `Yellow -> "33"
      | `Bold -> "1"
      | `Faint -> "2"
    in
    csi (code ^ "m") ^ s ^ csi "0m"

(* The status line *)

let status_line (p : Check.progress) =
  let verb =
    match p.Check.phase with
    | `Measuring -> "measuring"
    | `Confirming -> "confirming"
  in
  strf "thumper: %s %d/%d: %s" verb p.Check.index p.Check.total p.Check.case

(* The carriage return goes back to column 0 and the erase clears what a
   longer previous line left beyond the new one. *)
let status_erase = "\r" ^ csi "K"
let status_redraw p = "\r" ^ status_line p ^ csi "K"

(* Value formatting *)

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

(* Each cell carries the unit of its own magnitude, so a cell reads the same
   whatever the other rows hold. *)

(* A time in seconds: [%.2f] and its unit ("1.40 us", "33.00 ms"). The unit
   is chosen on the value as printed, so a cell never reads [1000.00 ns]. *)
let time_str v =
  let a = Float.abs v in
  let unit, scale =
    if a < 999.995e-9 then ("ns", 1e9)
    else if a < 999.995e-6 then ("us", 1e6)
    else if a < 0.999995 then ("ms", 1e3)
    else ("s", 1.)
  in
  strf "%.2f %s" (v *. scale) unit

(* An exact count prints whole words, grouped ("32,730 w"): an exact count
   never rounds. Sampled allocation is approximate by nature: it prints
   three significant digits in the unit of its magnitude and says so with
   [~] ("~3 kw", "~32.7 kw"), without a ci% of its own; the time ci already
   carries the run's sampling noise. Past [999.5] of the largest unit, where
   [%.3g] would turn to exponent notation, it prints a grouped integer
   ("~2,500 Mw"). *)
let approx_words v =
  let a = Float.abs v in
  let unit, scale =
    if a < 999.5 then ("w", 1.)
    else if a < 999.5e3 then ("kw", 1e-3)
    else ("Mw", 1e-6)
  in
  let v = v *. scale in
  if Float.abs v >= 999.5 then
    "~" ^ group_int (Float.to_int (Float.round v)) ^ " " ^ unit
  else strf "~%.3g %s" v unit

(* A metric's unit in a cell: [w] for the word counters, whose own unit is
   spelled out. *)
let unit_of metric =
  match Metric.kind metric with
  | `Allocation -> "w"
  | `Time | `Other -> Metric.units metric

let exact_str metric n = group_int n ^ " " ^ unit_of metric
let pct e = strf "%+.1f%%" (e *. 100.)
let bound e = strf "%+.1f" (e *. 100.)

(* Verdict classification *)

let case_fails (c : Verdict.case_report) = Verdict.case_overall c = `Fail

let report_proposed (mr : Verdict.metric_report) =
  match mr.verdict with Verdict.Proposed -> true | Verdict.Judged _ -> false

let count p l = List.length (List.filter p l)

let reason_short = function
  | Verdict.Wide_interval -> "wide interval"
  | Verdict.Non_positive -> "non-positive sample"
  | Verdict.Environment -> "environment"
  | Verdict.Unconfirmed -> "unconfirmed"
  | Verdict.Exactness_lost -> "exactness lost"
  | Verdict.Batch_drifted -> "batch drifted"
  | Verdict.Candidate_drifted -> "drifted"

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

type render = {
  color : bool;
  exe : string;
  github : bool;
  baseline_path : string;
  flags : string list;
  patterns : string list;
  strict : bool;
  cpu_model : string;
}

let pad_left s w =
  if String.length s >= w then s else String.make (w - String.length s) ' ' ^ s

(* The table *)

(* One row per case, suite order: status | time | ±ci% | alloc | id, and the
   rest of the verdict cell, when there is any, on an indented line below.
   The status word opens the row and the id closes it, so only an id longer
   than the room left runs a row past 80 columns. The value columns show the
   first time-kind and first allocation-kind metrics; everything else
   surfaces through the cell. Widths are content-derived, and each value
   cell carries its own unit. *)

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
  let cells =
    List.map
      (fun r ->
        let t = match r.time with Some (v, _) -> time_str v | None -> "" in
        let ci =
          match r.time with
          | Some (_, Some p) -> strf "\xc2\xb1%.1f%%" p
          | _ -> ""
        in
        let alloc =
          match r.alloc with
          | Alloc_exact n -> group_int n ^ " w"
          | Alloc_approx v -> approx_words v
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

(* Verdict cells *)

(* Only REGRESSED is capitalized, and only when the metric fails its case. A
   non-time metric's fragment carries the metric's tag after its word; the
   cell holds the case's notable relations, most severe first, joined by
   ["; "], so the row opens on the case's outcome ([check_cell]). *)

let metric_tag m =
  match Metric.kind m with
  | `Allocation -> "alloc"
  | `Time | `Other -> Metric.id m

(* A sampled shift and its interval: [+12.1% [+7.3, +17.5]]. The report's
   cells and the annotations print it, and a relative budget, the same way. *)
let interval (s : Verdict.shift) =
  strf "%s [%s, %s]" (pct s.Verdict.estimate) (bound s.Verdict.lower)
    (bound s.Verdict.upper)

(* An exact count over its absolute cap, as [(count, cap)], when the metric
   fails its case. Under a baseline row the count is [Regressed] and its
   cell prints the pair; with no comparable row the cell prints the cap. *)
let cap_breach (c : Verdict.case_report) (mr : Verdict.metric_report) =
  match
    (Budget.contract mr.budget, Run.Trial.measurement c.trial mr.metric)
  with
  | Budget.Absolute_max cap, Some (Run.Exact n) when Verdict.report_fails c mr
    ->
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
      let f = strf "%.6f" (cap -. whole) in
      let i = ref (String.length f) in
      while !i > 2 && f.[!i - 1] = '0' do
        decr i
      done;
      if !i <= 2 then "" else String.sub f 1 (!i - 1)
  in
  group_int (Float.to_int cap) ^ digits ^ " " ^ unit_of metric

(* The budget a relation was judged under: [budget +5%] or [cap 64 w]. *)
let budget_str (mr : Verdict.metric_report) =
  match Budget.contract mr.budget with
  | Budget.Relative r -> strf "budget +%g%%" (r *. 100.)
  | Budget.Absolute_max v -> "cap " ^ cap_str mr.metric v

(* [(rank, fragment)], the rank ordering fragments most severe first: 0
   REGRESSED, 1 inconclusive, 2 improved, 3 within budget, 4 proposed, 5 the
   exact-equal reassurance. A metric that fails its case ranks 0 and one that
   is inconclusive 1, so the most severe fragment is the case's outcome
   ([Verdict.case_overall]). A regression and a relation within budget name
   the budget that judged them. *)
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
        strf "%s \xe2\x86\x92 %s (exact)" (exact_str m baseline)
          (exact_str m candidate)
  in
  match (mr.verdict, cap_breach c mr) with
  | (Verdict.Proposed | Verdict.Judged (Verdict.Inconclusive _)), Some (n, cap)
    ->
      Some
        ( 0,
          frag ~style:`Red "REGRESSED"
            (tagged
               (strf "%s, over its %s cap (exact)" (exact_str m n)
                  (cap_str m cap))) )
  | Verdict.Proposed, None -> Some (4, frag "proposed" (tagged ""))
  | Verdict.Judged (Verdict.Regressed strong), _ ->
      (* A regression fails its case ([Verdict.report_fails]). *)
      Some
        ( 0,
          frag ~style:`Red "REGRESSED"
            (tagged (strong_detail strong ^ "  " ^ budget_str mr)) )
  | Verdict.Judged (Verdict.Improved strong), _ ->
      Some (2, frag ~style:`Green "improved" (tagged (strong_detail strong)))
  | Verdict.Judged (Verdict.Within_budget s), _ ->
      Some (3, frag "within budget" (tagged (interval s ^ "  " ^ budget_str mr)))
  | Verdict.Judged (Verdict.Changed_within_budget s), _ ->
      Some
        ( 3,
          frag "within budget"
            (tagged (pct s.Verdict.estimate ^ "  " ^ budget_str mr)) )
  | Verdict.Judged (Verdict.Inconclusive { reason; shift }), None ->
      (* Under load the estimate is printed as information. *)
      let reason =
        match shift with
        | Some sh when reason = Verdict.Environment ->
            reason_short reason ^ "  " ^ interval sh
        | Some _ | None -> reason_short reason
      in
      Some
        ( 1,
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
          Some (5, frag "equivalent" (strf "(%s exact)" (metric_tag mr.metric)))
      | Some (Run.Samples _) | None -> None)
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
    let non_pass = List.exists (fun (rank, _) -> rank <= 1) notable in
    let reassure =
      if non_pass then
        List.filter_map
          (fun mr -> reassurance_of ~primary:(is_primary mr) c mr)
          c.reports
      else []
    in
    let ranked =
      List.map snd
        (List.stable_sort
           (fun (a, _) (b, _) -> Int.compare a b)
           (notable @ reassure))
    in
    match ranked with
    | [] -> [ frag ~style:`Faint "equivalent" "" ]
    (* Only a non-time metric is proposed with a detail. Its case passes and
       no compared relation opens the row, so the row reads [equivalent]
       before naming what is proposed. *)
    | ({ word = "proposed"; detail; _ } as f) :: rest when detail <> "" ->
        frag ~style:`Faint "equivalent" "" :: f :: rest
    | ranked -> ranked

(* The report *)

(* The rerun line names at most this many failing cases; past it, it repeats
   the run's own patterns and measures more than failed. The accept line
   records, so it names every case it records. *)
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

(* The [::error::] line of a metric that fails its case, with the row's own
   facts: the id [-f] selects by, then the shift with its interval and
   budget, or the exact counts. *)
let error_line (c : Verdict.case_report) (mr : Verdict.metric_report) =
  if not (Verdict.report_fails c mr) then None
  else
    match mr.verdict with
    | Verdict.Judged (Verdict.Regressed strong) ->
        let detail =
          match strong with
          | Verdict.Confirmed { first; _ } -> interval first
          | Verdict.Exact_change { baseline; candidate } ->
              strf "%d \xe2\x86\x92 %d %s (exact)" baseline candidate
                (unit_of mr.metric)
        in
        let detail = detail ^ ", " ^ budget_str mr in
        Some
          (strf "::error::%s regressed: %s %s" c.id (Metric.id mr.metric) detail)
    | _ -> (
        match cap_breach c mr with
        | Some (n, cap) ->
            Some
              (strf "::error::%s regressed: %s %s, over its %s cap (exact)" c.id
                 (Metric.id mr.metric) (exact_str mr.metric n)
                 (cap_str mr.metric cap))
        | None -> None)

let check r v =
  let color = r.color in
  let cases = Verdict.cases v in
  let n_cases = List.length cases in
  let ident = Verdict.identity v in
  let comparison = Verdict.comparison v in
  let suite = Verdict.suite v in
  (* The load the verdict was judged under, never a reading taken before
     the wait for the lock, which can last minutes. *)
  let load = Verdict.load v in
  let uncompared =
    match comparison with
    | Verdict.No_baseline | Verdict.Stale _ -> true
    | Verdict.Compared -> false
  in
  let header =
    let head =
      match comparison with
      | Verdict.Compared ->
          header_line ~color ~suite
            (strf " — %d case%s vs %s for machine %s" n_cases (plural n_cases)
               r.baseline_path ident.Baseline.machine)
      | Verdict.No_baseline ->
          header_line ~color ~suite
            (strf " — no baseline for machine %s (%s)" ident.Baseline.machine
               r.cpu_model)
      | Verdict.Stale (Verdict.Ocaml_mismatch { section; current }) ->
          (* The recorded identity is text from the file: quoted when it
             holds a control byte, as it could write to the terminal. *)
          let section =
            if String.exists (fun c -> c < ' ' || c = '\x7f') section then
              Baseline.quote section
            else section
          in
          header_line ~color ~suite
            (strf " — stale baseline for machine %s (ocaml %s \xe2\x86\x92 %s)"
               ident.Baseline.machine section current)
    in
    match (comparison, load) with
    | Verdict.Compared, Env.Loaded { load; cores } ->
        [
          head;
          styled ~color `Yellow
            (strf "warning: load %.1f on %d cores; timing verdicts degraded"
               load cores);
        ]
    | _ -> [ head ]
  in
  (* Table rows in suite order, then the warnings. *)
  let cells =
    List.map
      (fun c ->
        (* A proposed case whose count breaks its cap fails even here. *)
        if uncompared && not (case_fails c) then (c, [ frag "proposed" "" ])
        else (c, check_cell c))
      cases
  in
  let rows =
    List.map
      (fun ((c : Verdict.case_report), cell) ->
        {
          row_id = c.id;
          time = time_of_trial c.trial;
          alloc = alloc_of_trial c.trial;
          cell;
        })
      cells
  in
  let warnings =
    List.concat_map
      (fun (c : Verdict.case_report) ->
        List.map
          (fun w -> styled ~color `Yellow (strf "  warning: %s: %s" c.id w))
          c.warnings)
      cases
  in
  let table = table_lines ~color rows @ warnings in
  (* Actions: the rerun of the failing cases, and the bless of the passing
     cases with a proposed or improved metric. *)
  let actions =
    let exe = shell_arg r.exe in
    let hint ~label head ~own = function
      | [] -> []
      | selected ->
          let selection =
            if own then List.map (fun p -> "-f " ^ shell_arg p) r.patterns
            else
              List.map (fun (c : Verdict.case_report) -> "-f " ^ c.id) selected
          in
          wrap_command ~label head (r.flags @ selection)
    in
    let recordable (c : Verdict.case_report) =
      (not (case_fails c))
      && List.exists
           (fun (mr : Verdict.metric_report) ->
             match mr.verdict with
             | Verdict.Proposed | Verdict.Judged (Verdict.Improved _) -> true
             | Verdict.Judged
                 ( Verdict.Regressed _ | Verdict.Equivalent _
                 | Verdict.Changed_within_budget _ | Verdict.Within_budget _
                 | Verdict.Inconclusive _ ) ->
                 false)
           c.reports
    in
    let failing = List.filter case_fails cases in
    let recorded = List.filter recordable cases in
    hint ~label:"  rerun:   " exe ~own:(List.length failing > rerun_cap) failing
    @ hint ~label:"  accept:  " (exe ^ " bless")
        ~own:(List.length recorded = n_cases)
        recorded
  in
  (* Summary, compared runs only. Its color is the outcome's: red iff the run
     exits 1, so a [--strict] run that fails on a proposed case does not end
     on a green line. *)
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
            (fun (c, cell) ->
              Verdict.case_overall c = `Pass
              &&
              match cell with
              | { word = "improved"; _ } :: _ -> true
              | _ -> false)
            cells
        in
        let n_pass = n_cases - n_fail - n_inc - n_prop - n_imp in
        let term n word = if n > 0 then [ strf "%d %s" n word ] else [] in
        let parts =
          [ strf "%d passed" n_pass ]
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
              (strf "%d case%s: %s%s." n_cases (plural n_cases)
                 (String.concat ", " parts) strict_clause);
        ]
  in
  (* The [::error::] lines close the report: CI reads them whatever the
     terminal shows. *)
  let annotations =
    if not r.github then []
    else
      List.concat_map
        (fun (c : Verdict.case_report) ->
          List.filter_map (error_line c) c.reports)
        cases
  in
  report_of_blocks [ header; table; actions; summary; annotations ]

(* The blocks of check's report less the summary, every row [blessed]. *)
let bless ~color ~suite ~machine ~baseline_path ~cases:n ~load run =
  let header =
    [
      header_line ~color ~suite
        (strf " — blessed %d case%s into %s for machine %s" n (plural n)
           baseline_path machine);
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
             cell = [ frag "blessed" "" ];
           })
         (Run.trials run))
    @ List.concat_map
        (fun (id, trial) ->
          List.map
            (fun w -> styled ~color `Yellow (strf "  warning: %s: %s" id w))
            (Run.Trial.warnings trial))
        (Run.trials run)
  in
  let actions =
    match load with
    | Env.Loaded { load; cores } ->
        [
          styled ~color `Yellow
            (strf
               "  warning: blessed under load %.1f on %d cores (--force \
                recorded)"
               load cores);
        ]
    | Env.Quiet -> []
  in
  report_of_blocks [ header; table; actions ]
