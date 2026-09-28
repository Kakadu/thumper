(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Rows and header comments keep their verbatim text, and the layout (blank
   lines, order) is part of the grammar rather than reconstructed, so every
   file the parser accepts prints back byte for byte. *)

let strf = Printf.sprintf

type evidence =
  | Exact_int of int
  | Sampled of { k : int; samples : float array }

type row = {
  r_id : string;
  r_metric : string;
  r_evidence : evidence;
  r_text : string; (* verbatim line, no newline; canonical for fresh rows *)
}

type section = {
  s_machine : string;
  s_host : string; (* grammar-required; never empty *)
  s_ocaml : string; (* grammar-required; never empty *)
  s_annotations : string list; (* comment texts, without the "# " prefix *)
  s_rows : row list; (* ascending (id, metric) *)
}

type t = {
  t_suite : string option; (* [None] only for the empty-file baseline *)
  t_sections : section list; (* ascending machine key *)
}

type error = Corrupt of { line : int; reason : string } | Io of string

exception Error of error

let pp_error ppf = function
  | Corrupt { line; reason } ->
      Format.fprintf ppf "corrupt baseline (line %d): %s" line reason
  | Io msg -> Format.pp_print_string ppf msg

(* An error that escapes a program prints as the facade names it, with its
   text, not as the internal constructor. *)
let () =
  Printexc.register_printer (function
    | Error e -> Some (Format.asprintf "Thumper.Baseline.Error: %a" pp_error e)
    | _ -> None)

(* Grammar constants *)

let header_line = "# thumper baseline v1"
let suite_prefix = "# suite: "
let machine_prefix = "# machine: "
let host_prefix = "# host: "
let ocaml_prefix = "# ocaml: "

(* Header words an annotation may not impersonate. *)
let reserved_words = [ "machine:"; "host:"; "ocaml:"; "suite:" ]

let reserved_annotation text =
  List.exists (fun prefix -> String.starts_with ~prefix text) reserved_words

(* Identifiers *)

let is_id_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
  | _ -> false

let valid_segment s = s <> "" && String.for_all is_id_char s

let valid_id s =
  s <> "" && List.for_all valid_segment (String.split_on_char '/' s)

let valid_metric = valid_segment
let valid_key = valid_segment

let check_suite ~fname name =
  if name = "" || String.contains name '\n' then
    invalid_arg
      (strf
         "%s: suite name must be non-empty and single-line (it heads fresh \
          baselines)"
         fname)

(* Printing samples *)

let e3 = strf "%.3e"

let derived_median samples =
  let n = Array.length samples in
  if n mod 2 = 1 then e3 samples.(n / 2)
  else
    (* a/2 + b/2, not (a + b)/2: the sum of two large finite samples can
       overflow to infinity and print an "inf" median. Halving normal floats
       is exact, so away from subnormals both spellings round identically. *)
    e3 ((samples.((n / 2) - 1) /. 2.) +. (samples.(n / 2) /. 2.))

(* Rows *)

let compare_key (id, metric) (id', metric') =
  match String.compare id id' with 0 -> String.compare metric metric' | c -> c

let row_key r = (r.r_id, r.r_metric)
let compare_rows a b = compare_key (row_key a) (row_key b)
let row_id r = r.r_id
let row_metric r = r.r_metric

let row_evidence r =
  match r.r_evidence with
  | Exact_int _ as e -> e
  | Sampled { k; samples } -> Sampled { k; samples = Array.copy samples }

let check_row_names fname ~id ~metric =
  if not (valid_id id) then
    invalid_arg
      (strf "%s: invalid id %S ('/'-separated segments of [A-Za-z0-9._-])" fname
         id);
  if not (valid_metric metric) then
    invalid_arg
      (strf "%s: invalid metric id %S (must be [A-Za-z0-9._-]+)" fname metric)

let exact_row ~id ~metric n =
  let fname = "Baseline.exact_row" in
  check_row_names fname ~id ~metric;
  if n < 0 then invalid_arg (strf "%s: negative count %d" fname n);
  {
    r_id = id;
    r_metric = metric;
    r_evidence = Exact_int n;
    r_text = strf "%s\t%s\texact\t%d" id metric n;
  }

let sampled_row ~id ~metric ~k ~samples =
  let fname = "Baseline.sampled_row" in
  check_row_names fname ~id ~metric;
  if k < 1 then invalid_arg (strf "%s: batch size %d < 1" fname k);
  let n = Array.length samples in
  if n < 3 then
    invalid_arg (strf "%s: %d samples (at least 3 required)" fname n);
  Array.iter
    (fun x ->
      if not (Float.is_finite x) then
        invalid_arg (strf "%s: non-finite sample %h" fname x))
    samples;
  for i = 0 to n - 2 do
    if samples.(i) > samples.(i + 1) then
      invalid_arg (fname ^ ": samples are not sorted ascending")
  done;
  (* Read back from the texts, so the evidence is what the line holds. *)
  let texts = Array.map e3 samples in
  let stored = Array.map float_of_string texts in
  let text =
    strf "%s\t%s\tbatch=%d\tn=%d\t%s\t%s" id metric k n (derived_median stored)
      (String.concat " " (Array.to_list texts))
  in
  {
    r_id = id;
    r_metric = metric;
    r_evidence = Sampled { k; samples = stored };
    r_text = text;
  }

let sort_rows fname rows =
  let sorted = List.stable_sort compare_rows rows in
  let rec check = function
    | a :: (b :: _ as rest) ->
        if compare_rows a b = 0 then
          invalid_arg
            (strf "%s: duplicate row for %s %s" fname a.r_id a.r_metric);
        check rest
    | _ -> ()
  in
  check sorted;
  sorted

let quote s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '\'';
  String.iter
    (fun c ->
      let n = Char.code c in
      if n < 0x20 || n = 0x7f then Printf.bprintf b "\\x%02x" n
      else Buffer.add_char b c)
    s;
  Buffer.add_char b '\'';
  Buffer.contents b

(* Parsing *)

exception Parse of int * string

let perr lnum fmt = Printf.ksprintf (fun m -> raise (Parse (lnum, m))) fmt

let parse_nat lnum what s =
  if
    s = ""
    || not (String.for_all (function '0' .. '9' -> true | _ -> false) s)
  then perr lnum "%s must be a decimal integer, got %s" what (quote s);
  match int_of_string_opt s with
  | Some n -> n
  | None -> perr lnum "%s is out of range: %s" what (quote s)

let parse_finite lnum what s =
  match float_of_string_opt s with
  | Some f when Float.is_finite f -> f
  | _ -> perr lnum "%s is not a finite number: %s" what (quote s)

let after prefix line =
  String.sub line (String.length prefix)
    (String.length line - String.length prefix)

let parse_row lnum line =
  let check_names id metric =
    if not (valid_id id) then perr lnum "invalid case id %s" (quote id);
    if not (valid_metric metric) then
      perr lnum "invalid metric id %s" (quote metric)
  in
  match String.split_on_char '\t' line with
  | [ id; metric; "exact"; count ] ->
      check_names id metric;
      let n = parse_nat lnum "exact count" count in
      { r_id = id; r_metric = metric; r_evidence = Exact_int n; r_text = line }
  | [ id; metric; batch; nfield; median; samples ] ->
      check_names id metric;
      if not (String.starts_with ~prefix:"batch=" batch) then
        perr lnum "malformed row: expected 'batch=K', got %s" (quote batch);
      let k = parse_nat lnum "batch size" (after "batch=" batch) in
      if k < 1 then perr lnum "batch size must be at least 1";
      if not (String.starts_with ~prefix:"n=" nfield) then
        perr lnum "malformed row: expected 'n=N', got %s" (quote nfield);
      let n = parse_nat lnum "sample count" (after "n=" nfield) in
      if n < 3 then perr lnum "sample count n=%d is below the minimum of 3" n;
      let sample_texts = String.split_on_char ' ' samples in
      let stored = List.length sample_texts in
      if stored <> n then perr lnum "n=%d but %d samples are stored" n stored;
      let arr =
        Array.of_list (List.map (parse_finite lnum "sample") sample_texts)
      in
      for i = 0 to n - 2 do
        if arr.(i) > arr.(i + 1) then
          perr lnum "samples are not sorted ascending"
      done;
      let derived = derived_median arr in
      if not (String.equal derived median) then
        perr lnum "stored median %s does not match its samples (re-derived %s)"
          (quote median) (quote derived);
      {
        r_id = id;
        r_metric = metric;
        r_evidence = Sampled { k; samples = arr };
        r_text = line;
      }
  | _ ->
      perr lnum
        "malformed row: expected 'id\\tmetric\\texact\\tcount' or \
         'id\\tmetric\\tbatch=K\\tn=N\\tmedian\\tsamples'"

(* [i] is a cursor over [lines], on the line after the section's
   [# machine:] line. On return it is on the blank line before the next
   section, or at the end. *)
let parse_section lines i key =
  let n = Array.length lines in
  let entry_lnum = !i + 1 in
  let host = ref None and ocaml_id = ref None and anns = ref [] in
  while !i < n && String.starts_with ~prefix:"#" lines.(!i) do
    let line = lines.(!i) in
    let lnum = !i + 1 in
    if String.starts_with ~prefix:machine_prefix line then
      perr lnum "expected a blank line before the next '# machine:' section"
    else if String.starts_with ~prefix:host_prefix line then (
      if Option.is_some !host then perr lnum "duplicate '# host:' line";
      if Option.is_some !ocaml_id || !anns <> [] then
        perr lnum "misplaced '# host:' line";
      let v = after host_prefix line in
      if v = "" then perr lnum "empty '# host:' value";
      host := Some v)
    else if String.starts_with ~prefix:ocaml_prefix line then (
      if Option.is_some !ocaml_id then perr lnum "duplicate '# ocaml:' line";
      if !anns <> [] then perr lnum "misplaced '# ocaml:' line";
      let v = after ocaml_prefix line in
      if v = "" then perr lnum "empty '# ocaml:' value";
      ocaml_id := Some v)
    else if String.starts_with ~prefix:"# " line then (
      let text = after "# " line in
      if reserved_annotation text then
        perr lnum "malformed section comment %s" (quote line);
      anns := text :: !anns)
    else perr lnum "malformed comment line %s" (quote line);
    incr i
  done;
  (* The grammar's section header is machine + host + ocaml, all three
     (baseline-format.md): a host-less section cannot be described to a
     reviewer, and an ocaml-less one could never compare (staleness reads the
     recorded identity verbatim). *)
  let host =
    match !host with
    | Some v -> v
    | None ->
        perr entry_lnum "section for machine %s is missing its '# host:' line"
          key
  in
  let ocaml =
    match !ocaml_id with
    | Some v -> v
    | None ->
        perr entry_lnum "section for machine %s is missing its '# ocaml:' line"
          key
  in
  if !i < n && not (String.equal lines.(!i) "") then
    perr (!i + 1) "expected a blank line before the section's rows";
  let rec loop prev acc =
    if !i = n || String.equal lines.(!i) "" then List.rev acc
    else begin
      let line = lines.(!i) in
      let lnum = !i + 1 in
      if line.[0] = '#' then perr lnum "unexpected comment among rows";
      let r = parse_row lnum line in
      (match prev with
      | Some prev_key -> (
          match compare_key prev_key (row_key r) with
          | 0 -> perr lnum "duplicate row for %s %s" r.r_id r.r_metric
          | c when c > 0 -> perr lnum "rows are not sorted by (id, metric)"
          | _ -> ())
      | None -> ());
      incr i;
      loop (Some (row_key r)) (r :: acc)
    end
  in
  let next_is_section =
    !i + 1 < n && String.starts_with ~prefix:machine_prefix lines.(!i + 1)
  in
  let rows =
    (* [!i] is at the end or on a blank line. *)
    if !i = n || next_is_section then []
    else begin
      let blank_lnum = !i + 1 in
      incr i;
      if !i = n then perr blank_lnum "trailing blank line at end of file";
      if String.equal lines.(!i) "" then perr (!i + 1) "unexpected blank line";
      loop None []
    end
  in
  {
    s_machine = key;
    s_host = host;
    s_ocaml = ocaml;
    s_annotations = List.rev !anns;
    s_rows = rows;
  }

let parse s =
  if String.equal s "" then { t_suite = None; t_sections = [] }
  else begin
    let pieces = Array.of_list (String.split_on_char '\n' s) in
    let count = Array.length pieces in
    (* A well-formed file ends with a newline, so the final piece is "". *)
    if not (String.equal pieces.(count - 1) "") then
      perr count "truncated file: missing final newline";
    let n = count - 1 in
    let lines = Array.sub pieces 0 n in
    if not (String.equal lines.(0) header_line) then
      perr 1 "expected %s on the first line" (quote header_line);
    (* The grammar requires the suite header on every non-empty file
       (baseline-format.md): a section-bearing file without one would make
       [suite] lie about its "empty-file iff" contract, and the write path
       would have no name to preserve. *)
    if not (n > 1 && String.starts_with ~prefix:suite_prefix lines.(1)) then
      perr 2 "expected a '# suite:' line";
    let suite = after suite_prefix lines.(1) in
    if suite = "" then perr 2 "empty suite name";
    let i = ref 2 in
    let sections = ref [] and prev_key = ref None in
    while !i < n do
      if not (String.equal lines.(!i) "") then
        perr (!i + 1) "expected a blank line before a '# machine:' section";
      incr i;
      if !i = n then perr n "trailing blank line at end of file";
      let line = lines.(!i) in
      if not (String.starts_with ~prefix:machine_prefix line) then
        perr (!i + 1) "expected a '# machine:' section header";
      let key = after machine_prefix line in
      if not (valid_key key) then
        perr (!i + 1) "invalid machine key %s (must be [A-Za-z0-9._-]+)"
          (quote key);
      (match !prev_key with
      | Some p -> (
          match String.compare p key with
          | 0 -> perr (!i + 1) "duplicate section for machine %s" key
          | c when c > 0 ->
              perr (!i + 1)
                "sections are not sorted by machine key (%s after %s)" key p
          | _ -> ())
      | None -> ());
      prev_key := Some key;
      incr i;
      sections := parse_section lines i key :: !sections
    done;
    { t_suite = Some suite; t_sections = List.rev !sections }
  end

let of_string s =
  match parse s with
  | t -> Ok t
  | exception Parse (line, reason) -> Stdlib.Error (Corrupt { line; reason })

(* Rendering *)

let to_string t =
  match (t.t_suite, t.t_sections) with
  | None, [] -> "" (* the empty-file baseline round-trips to itself *)
  | suite, sections ->
      let b = Buffer.create 1024 in
      let line s =
        Buffer.add_string b s;
        Buffer.add_char b '\n'
      in
      line header_line;
      Option.iter (fun s -> line (suite_prefix ^ s)) suite;
      List.iter
        (fun sec ->
          line "";
          line (machine_prefix ^ sec.s_machine);
          line (host_prefix ^ sec.s_host);
          line (ocaml_prefix ^ sec.s_ocaml);
          List.iter (fun a -> line ("# " ^ a)) sec.s_annotations;
          match sec.s_rows with
          | [] -> ()
          | rows ->
              line "";
              List.iter (fun r -> line r.r_text) rows)
        sections;
      Buffer.contents b

(* Reading and writing files *)

(* Absence is decided here, from the errno: a caller probing with
   [Sys.file_exists] races the answer, and one matching [Io]'s text parses
   the errno again. *)
let read path =
  let cannot_read e =
    Stdlib.Error (Io (strf "cannot read %s: %s" path (Unix.error_message e)))
  in
  let rec open_read () =
    match Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
    | fd -> fd
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> open_read ()
  in
  match open_read () with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | exception Unix.Unix_error (e, _, _) -> cannot_read e
  | fd -> (
      (* Drain with [Unix.read] directly: a channel over the descriptor
         ([in_channel_of_descr]) rejects non-regular files (a directory at
         the path raises EINVAL on macOS) before read can even fail. *)
      let close () = try Unix.close fd with Unix.Unix_error _ -> () in
      let buf = Buffer.create 65536 in
      let chunk = Bytes.create 65536 in
      let rec drain () =
        match Unix.read fd chunk 0 (Bytes.length chunk) with
        | 0 -> ()
        | k ->
            Buffer.add_subbytes buf chunk 0 k;
            drain ()
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> drain ()
      in
      match drain () with
      | () ->
          close ();
          Result.map Option.some (of_string (Buffer.contents buf))
      | exception Unix.Unix_error (e, _, _) ->
          close ();
          cannot_read e)

let read_exn path =
  match read path with Ok t -> t | Stdlib.Error e -> raise (Error e)

let write path t =
  try Os.write_atomic path (to_string t)
  with Unix.Unix_error (e, _, _) ->
    raise (Error (Io (strf "cannot write %s: %s" path (Unix.error_message e))))

(* File and section observers *)

let empty ~suite =
  check_suite ~fname:"Baseline.empty" suite;
  { t_suite = Some suite; t_sections = [] }

let suite t = t.t_suite
let machines t = List.map (fun s -> s.s_machine) t.t_sections

let section t key =
  List.find_opt (fun s -> String.equal s.s_machine key) t.t_sections

let machine_of s = s.s_machine
let ocaml_of s = s.s_ocaml
let rows s = s.s_rows

let find_row s ~id ~metric =
  List.find_opt (fun r -> compare_key (row_key r) (id, metric) = 0) s.s_rows

let case_frozen_k s ~id =
  List.find_map
    (fun r ->
      if not (String.equal r.r_id id) then None
      else
        match row_evidence r with
        | Sampled { k; _ } -> Some k
        | Exact_int _ -> None)
    s.s_rows

(* The write-path primitives *)

type identity = { machine : string; host : string; ocaml : string }

let check_annotations fname annotations =
  List.iter
    (fun a ->
      if String.contains a '\n' then
        invalid_arg (strf "%s: multi-line annotation %S" fname a);
      if reserved_annotation a then
        invalid_arg
          (strf "%s: annotation %S starts with a reserved header word" fname a))
    annotations

let set_section ?(annotations = []) t identity row_list =
  let fname = "Baseline.set_section" in
  if Option.is_none t.t_suite then
    invalid_arg
      (fname
     ^ ": baseline has no suite header; start from Baseline.empty ~suite");
  if not (valid_key identity.machine) then
    invalid_arg
      (strf "%s: invalid machine key %S (must be [A-Za-z0-9._-]+)" fname
         identity.machine);
  List.iter
    (fun (what, value) ->
      if value = "" then invalid_arg (strf "%s: empty %s" fname what);
      if String.contains value '\n' then
        invalid_arg (strf "%s: newline in %s %S" fname what value))
    [ ("host", identity.host); ("ocaml", identity.ocaml) ];
  check_annotations fname annotations;
  let sec =
    {
      s_machine = identity.machine;
      s_host = identity.host;
      s_ocaml = identity.ocaml;
      s_annotations = annotations;
      s_rows = sort_rows fname row_list;
    }
  in
  let rec place = function
    | [] -> [ sec ]
    | s :: rest -> (
        match String.compare identity.machine s.s_machine with
        | 0 -> sec :: rest
        | c when c < 0 -> sec :: s :: rest
        | _ -> s :: place rest)
  in
  { t with t_sections = place t.t_sections }

let update_rows ?(annotations = []) t ~machine ~advance ~prune =
  let fname = "Baseline.update_rows" in
  check_annotations fname annotations;
  let advance = sort_rows fname advance in
  let advanced key =
    List.exists (fun r -> compare_key (row_key r) key = 0) advance
  in
  List.iter
    (fun (id, metric) ->
      if advanced (id, metric) then
        invalid_arg
          (strf "%s: %s %s is both advanced and pruned" fname id metric))
    prune;
  let pruned key = List.exists (fun k -> compare_key k key = 0) prune in
  let edit sec =
    let kept =
      List.filter
        (fun r ->
          let key = row_key r in
          not (advanced key || pruned key))
        sec.s_rows
    in
    (* Both inputs are ascending and key-disjoint, so a merge preserves the
       canonical order and every kept row's verbatim text. *)
    let rec merge kept advance =
      match (kept, advance) with
      | rows, [] | [], rows -> rows
      | k :: ks, a :: adv ->
          if compare_rows k a <= 0 then k :: merge ks (a :: adv)
          else a :: merge (k :: ks) adv
    in
    {
      sec with
      s_annotations = sec.s_annotations @ annotations;
      s_rows = merge kept advance;
    }
  in
  let rec update = function
    | [] -> invalid_arg (strf "%s: no section for machine %S" fname machine)
    | s :: rest ->
        if String.equal s.s_machine machine then edit s :: rest
        else s :: update rest
  in
  { t with t_sections = update t.t_sections }
