(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let strf = Printf.sprintf

type prepared = { run_batch : int -> unit; teardown : unit -> unit }

type case = {
  id : string;
  full_name : string;
  tags : string list;
  metrics : Metric.t list option;
  budgets : Budget.t list option;
  prepare : unit -> prepared;
}

(* An authored node: the validated id segment, the display name, and the
   scope's own (uninherited) tags/metrics/budgets. *)
type spec = {
  seg : string;
  name : string;
  tags : string list;
  metrics : Metric.t list option;
  budgets : Budget.t list option;
}

type t = Case of spec * (unit -> prepared) | Group of spec * t list

(* The slug rule is [Thumper]'s id contract (thumper.mli, "Ids"). *)
let slug name =
  if Baseline.valid_segment name then name
  else begin
    let b = Buffer.create (String.length name) in
    let pending = ref false in
    String.iter
      (fun c ->
        if Baseline.is_id_char c then begin
          if !pending && Buffer.length b > 0 then Buffer.add_char b '-';
          pending := false;
          Buffer.add_char b c
        end
        else pending := true)
      name;
    Buffer.contents b
  end

let segment ~ctor ~id ~name =
  (* The display name always renders (reports, full_name): an empty one is a
     programmer error even when [?id] supplies the identity segment. *)
  if name = "" then invalid_arg (strf "%s: empty name" ctor);
  match id with
  | Some id ->
      if not (Baseline.valid_segment id) then
        invalid_arg
          (strf
             "%s: invalid id %S: an id is one segment of [A-Za-z0-9._-]+ \
              (groups join segments with '/')"
             ctor id);
      id
  | None ->
      let s = slug name in
      if s = "" then
        invalid_arg
          (strf
             "%s: name %S has no [A-Za-z0-9._-] characters to slug into an id; \
              pass ~id"
             ctor name);
      s

let check_metrics ~ctor = function
  | None -> ()
  | Some [] ->
      invalid_arg (strf "%s: empty ~metrics list (omit it to inherit)" ctor)
  | Some ms ->
      let rec go seen = function
        | [] -> ()
        | m :: rest ->
            if List.exists (Metric.equal m) seen then
              invalid_arg
                (strf "%s: duplicate metric %s in ~metrics" ctor (Metric.id m))
            else go (m :: seen) rest
      in
      go [] ms

let spec ~ctor ?id ?(tags = []) ?metrics ?budgets name =
  let seg = segment ~ctor ~id ~name in
  check_metrics ~ctor metrics;
  Option.iter (Budget.check_distinct ~fname:ctor) budgets;
  { seg; name; tags; metrics; budgets }

let black_box x = Sys.opaque_identity x

let bench ?id ?tags ?metrics ?budgets name f =
  let s = spec ~ctor:"Thumper.bench" ?id ?tags ?metrics ?budgets name in
  let prepare () =
    {
      run_batch =
        (fun k ->
          (* Re-opaque the closure each batch: sinking results alone does not
             stop flambda from inlining a known pure [f] and hoisting its
             loop-invariant body out of the measured loop. A call to an
             unknown closure can be neither hoisted nor eliminated. *)
          let f = Sys.opaque_identity f in
          for _ = 1 to k do
            ignore (Sys.opaque_identity (f ()))
          done);
      teardown = ignore;
    }
  in
  Case (s, prepare)

let bench_with_setup ?id ?tags ?metrics ?budgets ~setup ?(teardown = ignore)
    name f =
  let s =
    spec ~ctor:"Thumper.bench_with_setup" ?id ?tags ?metrics ?budgets name
  in
  let prepare () =
    let env = setup () in
    {
      run_batch =
        (fun k ->
          (* As in [bench], and [env] too: the loop must not specialize on a
             setup value the compiler can see. *)
          let f = Sys.opaque_identity f and env = Sys.opaque_identity env in
          for _ = 1 to k do
            ignore (Sys.opaque_identity (f env))
          done);
      teardown = (fun () -> teardown env);
    }
  in
  Case (s, prepare)

let group ?id ?tags ?metrics ?budgets name children =
  Group (spec ~ctor:"Thumper.group" ?id ?tags ?metrics ?budgets name, children)

(* Selection *)

type filter =
  [ `Id of string | `Tag of string | `And of filter list | `Or of filter list ]

let contains_substring s sub =
  let n = String.length s and m = String.length sub in
  let rec matches_at i j =
    j = m || (s.[i + j] = sub.[j] && matches_at i (j + 1))
  in
  let rec from i = i + m <= n && (matches_at i 0 || from (i + 1)) in
  m = 0 || from 0

let rec matches f case =
  match f with
  | `Id sub -> contains_substring case.id sub
  | `Tag t -> List.mem t case.tags
  | `And fs -> List.for_all (fun f -> matches f case) fs
  | `Or fs -> List.exists (fun f -> matches f case) fs

(* Inheritance *)

let union_tags outer inner =
  let rec go seen = function
    | [] -> []
    | t :: rest ->
        if List.mem t seen then go seen rest else t :: go (t :: seen) rest
  in
  go [] (outer @ inner)

let inherit_metrics ~inner ~outer =
  match inner with Some _ as m -> m | None -> outer

let merge_budgets ~inner ~outer =
  let norm = function Some [] -> None | b -> b in
  match (norm inner, norm outer) with
  | None, o -> o
  | (Some _ as i), None -> i
  | Some i, Some o ->
      let shadowed b =
        List.exists
          (fun b' -> Metric.equal (Budget.metric b) (Budget.metric b'))
          i
      in
      Some (i @ List.filter (fun b -> not (shadowed b)) o)

let join prefix seg = if prefix = "" then seg else prefix ^ "/" ^ seg

let flatten benches =
  let rec walk ~id_path ~name_path ~tags ~metrics ~budgets node =
    let s = match node with Case (s, _) | Group (s, _) -> s in
    let id_path = join id_path s.seg in
    let name_path = join name_path s.name in
    let tags = union_tags tags s.tags in
    let metrics = inherit_metrics ~inner:s.metrics ~outer:metrics in
    let budgets = merge_budgets ~inner:s.budgets ~outer:budgets in
    match node with
    | Case (_, prepare) ->
        [
          {
            id = id_path;
            full_name = name_path;
            tags;
            metrics;
            budgets;
            prepare;
          };
        ]
    | Group (_, children) ->
        List.concat_map
          (walk ~id_path ~name_path ~tags ~metrics ~budgets)
          children
  in
  List.concat_map
    (walk ~id_path:"" ~name_path:"" ~tags:[] ~metrics:None ~budgets:None)
    benches

(* Resolution *)

type error =
  | Duplicate_id of string
  | Uncollected_budget of { scope : string; metric : string }

let pp_error ppf = function
  | Duplicate_id id ->
      Format.fprintf ppf "duplicate case id '%s' (rename the case or pass ~id)"
        id
  | Uncollected_budget { scope = ""; metric } ->
      Format.fprintf ppf
        "the run has a budget on %s but does not collect it (add it to \
         Config.metrics or drop the budget)"
        metric
  | Uncollected_budget { scope; metric } ->
      Format.fprintf ppf
        "'%s' has a budget on %s but does not collect it (add it to ~metrics \
         or drop the budget)"
        scope metric

let resolve benches =
  let cases = flatten benches in
  let rec find_dup seen = function
    | [] -> None
    | c :: rest ->
        if List.mem c.id seen then Some c.id else find_dup (c.id :: seen) rest
  in
  match find_dup [] cases with
  | Some id -> Error (Duplicate_id id)
  | None -> Ok cases

let check_collected ~metrics ~budgets benches =
  let uncollected ~scope ~metrics budgets =
    List.find_map
      (fun b ->
        let m = Budget.metric b in
        if List.exists (Metric.equal m) metrics then None
        else Some (Uncollected_budget { scope; metric = Metric.id m }))
      budgets
  in
  let rec walk ~path ~metrics node =
    let s, children =
      match node with Case (s, _) -> (s, []) | Group (s, c) -> (s, c)
    in
    let scope = join path s.seg in
    let metrics = Option.value s.metrics ~default:metrics in
    match uncollected ~scope ~metrics (Option.value s.budgets ~default:[]) with
    | Some _ as e -> e
    | None -> List.find_map (walk ~path:scope ~metrics) children
  in
  let first =
    match uncollected ~scope:"" ~metrics budgets with
    | Some _ as e -> e
    | None -> List.find_map (walk ~path:"" ~metrics) benches
  in
  match first with None -> Ok () | Some e -> Error e

(* Case observers *)

let id (c : case) = c.id
let full_name (c : case) = c.full_name
let metrics (c : case) = c.metrics
let budgets (c : case) = c.budgets

(* Running *)

let prepare c = c.prepare ()
