(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* [Private] is defined first, before the facade [Baseline] below shadows the
   internal [Baseline]: the interface's [module X = ...] aliases must denote
   the internal units, not the facade's constrained re-exports. *)
module Private = struct
  module Baseline = Baseline
  module Bench = Bench
  module Budget = Budget
  module Check = Check
  module Cli = Cli
  module Config = Config
  module Env = Env
  module Measure = Measure
  module Metric = Metric
  module Os = Os
  module Report = Report
  module Run = Run
  module Stats = Stats
  module Verdict = Verdict
end

module Metric = Metric
module Budget = Budget
module Config = Config

type bench = Bench.t
type filter = Bench.filter

let bench = Bench.bench
let bench_with_setup = Bench.bench_with_setup
let group = Bench.group
let black_box = Bench.black_box

module Run = Run

module Baseline = struct
  include Baseline

  (* The host's identity is computed by [Env]; [Baseline] itself is pure. *)
  let machine_key = Env.machine_key

  let record ?baseline name run =
    check_suite ~fname:"Thumper.Baseline.record" name;
    let identity =
      {
        machine = Env.machine_key ();
        host = Env.host_description ();
        ocaml = Env.ocaml_identity ();
      }
    in
    let file = Option.value baseline ~default:(empty ~suite:name) in
    record ~identity ~suite:name ~selection:`Partial ~run file
end

module Verdict = Verdict
module Check = Check

let measure ?config ?filter benches = Check.measure ?config ?filter benches

let run ?baseline ?config ?budgets ?(argv = Sys.argv) name benches =
  Cli.main ?baseline ?config ?budgets ~argv ~name benches
