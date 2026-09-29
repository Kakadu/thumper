(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* A budget is compared by all it shows, its metric's id and its contract.
   Every band below is exact in binary floating point (halving is exact), so
   contracts compare exactly. *)

open Windtrap
module Budget = Thumper.Private.Budget
module Metric = Thumper.Private.Metric

let pp_contract ppf = function
  | Budget.Relative { max_regression; band } ->
      Format.fprintf ppf "Relative { max_regression = %g; band = %g }"
        max_regression band
  | Budget.Absolute_max v -> Format.fprintf ppf "Absolute_max %g" v

let equal_contract a b =
  match (a, b) with
  | Budget.Relative a, Budget.Relative b ->
      Float.equal a.max_regression b.max_regression && Float.equal a.band b.band
  | Budget.Absolute_max a, Budget.Absolute_max b -> Float.equal a b
  | Budget.Relative _, Budget.Absolute_max _
  | Budget.Absolute_max _, Budget.Relative _ ->
      false

let contract = Testable.make ~pp:pp_contract ~equal:equal_contract
let shown b = (Metric.id (Budget.metric b), Budget.contract b)
let budget = Testable.contramap shown (pair string contract)

let relative ?equivalent_within ~max_regression () =
  Budget.relative ~metric:Metric.wall_time ?equivalent_within ~max_regression ()

(* Constructors *)

let derived_bands =
  [
    (0., 0.);
    (0.02, 0.01);
    (0.04, 0.02);
    (0.05, 0.025);
    (0.06, 0.025);
    (0.5, 0.025);
  ]

let explicit_bands =
  [
    ("below band_cap", 0.01, 0.05);
    ("above band_cap", 0.04, 0.05);
    ("the whole budget", 0.05, 0.05);
    ("zero", 0., 0.1);
  ]

let shorthands =
  [
    ( "no_slower_than r is relative on wall_time",
      (fun () -> Budget.no_slower_than 0.03),
      fun () -> Budget.relative ~metric:Metric.wall_time ~max_regression:0.03 ()
    );
    ( "no_slower_than passes its band",
      (fun () -> Budget.no_slower_than ~equivalent_within:0.005 0.03),
      fun () ->
        Budget.relative ~metric:Metric.wall_time ~equivalent_within:0.005
          ~max_regression:0.03 () );
    ( "no_slower_than ~metric binds that metric",
      (fun () -> Budget.no_slower_than ~metric:Metric.cpu_time 0.05),
      fun () -> Budget.relative ~metric:Metric.cpu_time ~max_regression:0.05 ()
    );
    ( "no_more_alloc_than r is relative on alloc_words",
      (fun () -> Budget.no_more_alloc_than 0.1),
      fun () ->
        Budget.relative ~metric:Metric.alloc_words ~max_regression:0.1 () );
    ( "no_more_alloc_than ~metric binds that metric",
      (fun () -> Budget.no_more_alloc_than ~metric:Metric.minor_alloc_words 0.1),
      fun () ->
        Budget.relative ~metric:Metric.minor_alloc_words ~max_regression:0.1 ()
    );
    ( "no_more_alloc_than 0 is a zero budget",
      (fun () -> Budget.no_more_alloc_than 0.),
      fun () -> Budget.relative ~metric:Metric.alloc_words ~max_regression:0. ()
    );
  ]

let caps =
  [
    ( "4096 words",
      (fun () -> Budget.at_most ~metric:Metric.alloc_words 4096.),
      ("alloc_words", Budget.Absolute_max 4096.) );
    ( "zero collections",
      (fun () -> Budget.at_most ~metric:Metric.major_collections 0.),
      ("major_collections", Budget.Absolute_max 0.) );
  ]

let refusal f =
  match f () with
  | (_ : Budget.t) -> None
  | exception Invalid_argument msg -> Some msg

let refusals =
  [
    ( "no_slower_than -0.05",
      (fun () -> Budget.no_slower_than (-0.05)),
      __POS_OF__
        {| Thumper.Budget.no_slower_than: negative or NaN max_regression |} );
    ( "no_more_alloc_than nan",
      (fun () -> Budget.no_more_alloc_than Float.nan),
      __POS_OF__
        {| Thumper.Budget.no_more_alloc_than: negative or NaN max_regression |}
    );
    ( "relative -1",
      (fun () -> relative ~max_regression:(-1.) ()),
      __POS_OF__ {| Thumper.Budget.relative: negative or NaN max_regression |}
    );
    ( "a band of -0.01",
      (fun () -> Budget.no_slower_than ~equivalent_within:(-0.01) 0.05),
      __POS_OF__
        {| Thumper.Budget.no_slower_than: negative or NaN equivalent_within |}
    );
    ( "a band of nan",
      (fun () -> Budget.no_slower_than ~equivalent_within:Float.nan 0.05),
      __POS_OF__
        {| Thumper.Budget.no_slower_than: negative or NaN equivalent_within |}
    );
    ( "a band of 0.06 in a budget of 0.05",
      (fun () -> Budget.no_slower_than ~equivalent_within:0.06 0.05),
      __POS_OF__
        {| Thumper.Budget.no_slower_than: equivalent_within exceeds max_regression |}
    );
    ( "a band of 0.01 in a zero budget",
      (fun () -> Budget.no_more_alloc_than ~equivalent_within:0.01 0.),
      __POS_OF__
        {| Thumper.Budget.no_more_alloc_than: equivalent_within exceeds max_regression |}
    );
    ( "relative, a band of 0.2 in a budget of 0.1",
      (fun () -> relative ~equivalent_within:0.2 ~max_regression:0.1 ()),
      __POS_OF__
        {| Thumper.Budget.relative: equivalent_within exceeds max_regression |}
    );
    ( "at_most -1",
      (fun () -> Budget.at_most ~metric:Metric.alloc_words (-1.)),
      __POS_OF__ {| Thumper.Budget.at_most: negative or NaN threshold |} );
    ( "at_most nan on wall_time, the threshold first",
      (fun () -> Budget.at_most ~metric:Metric.wall_time Float.nan),
      __POS_OF__ {| Thumper.Budget.at_most: negative or NaN threshold |} );
    ( "at_most on wall_time",
      (fun () -> Budget.at_most ~metric:Metric.wall_time 1.),
      __POS_OF__
        {| Thumper.Budget.at_most: metric wall_time can never be measured exactly, and an absolute cap applies to exact evidence only; use a relative budget |}
    );
    ( "at_most on cpu_time",
      (fun () -> Budget.at_most ~metric:Metric.cpu_time 1.),
      __POS_OF__
        {| Thumper.Budget.at_most: metric cpu_time can never be measured exactly, and an absolute cap applies to exact evidence only; use a relative budget |}
    );
  ]

let constructors =
  group "Constructors"
    [
      cases "relative's band is min band_cap (r / 2)"
        ~name:(fun (r, _) -> Printf.sprintf "r = %g" r)
        derived_bands
        (fun (r, band) ->
          equal contract
            (Budget.Relative { max_regression = r; band })
            (Budget.contract (relative ~max_regression:r ())));
      cases "relative's band is equivalent_within when given"
        ~name:(fun (name, _, _) -> name)
        explicit_bands
        (fun (_, e, r) ->
          equal contract
            (Budget.Relative { max_regression = r; band = e })
            (Budget.contract
               (relative ~equivalent_within:e ~max_regression:r ())));
      cases "the shorthands"
        ~name:(fun (name, _, _) -> name)
        shorthands
        (fun (_, shorthand, expected) ->
          equal budget (expected ()) (shorthand ()));
      cases "at_most caps a counter metric"
        ~name:(fun (name, _, _) -> name)
        caps
        (fun (_, b, expected) ->
          equal (pair string contract) expected (shown (b ())));
      cases "a constructor refuses"
        ~name:(fun (name, _, _) -> name)
        refusals
        (fun (_, f, pos) -> expect (require_some (refusal f)) pos);
    ]

(* Observers and checks *)

let observers =
  group "Observers and checks"
    [
      test "check_distinct takes one budget per metric" (fun () ->
          Budget.check_distinct ~fname:"f" [];
          Budget.check_distinct ~fname:"f"
            [ Budget.no_slower_than 0.05; Budget.no_more_alloc_than 0.01 ]);
      test "check_distinct names the first metric bound twice" (fun () ->
          raises
            (Invalid_argument
               "f: two budgets for metric alloc_words in one ~budgets list")
            (fun () ->
              Budget.check_distinct ~fname:"f"
                [
                  Budget.no_more_alloc_than 0.01;
                  Budget.no_slower_than 0.05;
                  Budget.at_most ~metric:Metric.alloc_words 4096.;
                ]));
    ]

(* Defaults *)

let defaults =
  group "Defaults"
    [
      test "default_max_regression is 0.05" (fun () ->
          equal float_exact 0.05 Budget.default_max_regression);
      test "band_cap is 0.025" (fun () ->
          equal float_exact 0.025 Budget.band_cap);
      test "defaults is one wall_time budget of 0.05, band 0.025" (fun () ->
          equal
            (list (pair string contract))
            [
              ( "wall_time",
                Budget.Relative { max_regression = 0.05; band = 0.025 } );
            ]
            (List.map shown Budget.defaults));
    ]

let () = exit (run "budget" [ constructors; observers; defaults ])
