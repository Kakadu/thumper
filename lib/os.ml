(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let monotonic_s () = Int64.to_float (Thumper_clock.now_ns ()) *. 1e-9

let write_all fd s =
  let rec loop off len =
    if len > 0 then
      match Unix.write_substring fd s off len with
      | 0 -> raise (Unix.Unix_error (Unix.EIO, "write", ""))
      | n -> loop (off + n) (len - n)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop off len
  in
  loop 0 (String.length s)

let rec fsync fd =
  try Unix.fsync fd with Unix.Unix_error (Unix.EINTR, _, _) -> fsync fd

(* The temporary file is created exclusively, so two processes publishing to
   one directory never share it; the pid plus an attempt counter names it, and
   a leftover from a killed process is skipped, not reused. A hundred names
   are tried, then the collision is the error. *)
let rec create_temp dir attempt =
  let temp =
    Filename.concat dir
      (Printf.sprintf ".thumper-%d-%d.tmp" (Unix.getpid ()) attempt)
  in
  match
    Unix.openfile temp
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
      0o644
  with
  | fd -> (temp, fd)
  | exception Unix.Unix_error (Unix.EEXIST, _, _) when attempt < 99 ->
      create_temp dir (attempt + 1)

let write_atomic path data =
  let temp, fd = create_temp (Filename.dirname path) 0 in
  let fill () =
    (* An atomic replace must not change the target's permission bits. *)
    (match Unix.stat path with
    | st -> Unix.fchmod fd st.Unix.st_perm
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
    write_all fd data;
    fsync fd
  in
  (* The cleanup's own failures are swallowed, so the backtrace is taken
     first and the original failure re-raised with it. *)
  let discard e bt =
    (try Unix.unlink temp with Unix.Unix_error _ -> ());
    Printexc.raise_with_backtrace e bt
  in
  match fill () with
  | exception e ->
      let bt = Printexc.get_raw_backtrace () in
      (try Unix.close fd with Unix.Unix_error _ -> ());
      discard e bt
  | () -> (
      try
        Unix.close fd;
        Unix.rename temp path
      with e -> discard e (Printexc.get_raw_backtrace ()))
