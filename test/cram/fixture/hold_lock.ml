(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The second process of the lock sessions. [hold_lock.exe HELD RELEASE]
   takes the measurement lock (THUMPER_LOCK_DIR selects its directory),
   creates HELD, and holds the lock until RELEASE exists. The session starts
   its waiter only once HELD exists and creates RELEASE itself, so no step
   depends on timing. The holder gives up after 60 s, so a session that
   never creates RELEASE cannot leave it running. Exits 0 once released, 1
   if the lock is refused or the 60 s pass. *)

let give_up_s = 60.

let () =
  let held, release =
    match Sys.argv with
    | [| _; h; r |] -> (h, r)
    | _ ->
        prerr_endline "usage: hold_lock.exe HELD RELEASE";
        exit 2
  in
  let deadline = Unix.gettimeofday () +. give_up_s in
  match
    Thumper.Private.Env.Lock.with_lock (fun () ->
        Out_channel.with_open_bin held (fun _ -> ());
        let rec hold () =
          if Sys.file_exists release then true
          else if Unix.gettimeofday () > deadline then false
          else (
            Unix.sleepf 0.02;
            hold ())
        in
        hold ())
  with
  | Ok true -> ()
  | Ok false ->
      Format.eprintf "hold_lock: %s did not appear within %gs@." release
        give_up_s;
      exit 1
  | Error e ->
      Format.eprintf "hold_lock: %a@." Thumper.Private.Env.Lock.pp_error e;
      exit 1
