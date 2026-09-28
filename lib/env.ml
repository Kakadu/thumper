(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let strf = Printf.sprintf

let rec sleep_until wake =
  let remaining = wake -. Os.monotonic_s () in
  if remaining > 0. then
    match Unix.sleepf remaining with
    | () -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> sleep_until wake

(* Identity *)

let hash s =
  (* [Int64.mul] wraps modulo 2^64, and [%016Lx] prints the unsigned value. *)
  let h = ref 0xcbf29ce484222325L in
  String.iter
    (fun c ->
      h :=
        Int64.mul (Int64.logxor !h (Int64.of_int (Char.code c))) 0x100000001b3L)
    s;
  strf "%016Lx" !h

(* [process_line prog args] is the trimmed first stdout line of [prog], run
   without a shell ([prog] is searched in PATH), and [None] on any failure:
   spawn error, no output, empty output, or non-zero exit. *)
let process_line prog args =
  match Unix.open_process_args_in prog (Array.of_list (prog :: args)) with
  | exception (Unix.Unix_error _ | Sys_error _) -> None
  | ic -> (
      let line =
        match input_line ic with
        | line -> Some line
        | exception (End_of_file | Sys_error _) -> None
      in
      match Unix.close_process_in ic with
      | Unix.WEXITED 0 -> (
          match Option.map String.trim line with
          | Some "" | None -> None
          | Some _ as some -> some)
      | _ | (exception (Unix.Unix_error _ | Sys_error _)) -> None)

(* The first "model name" value of /proc/cpuinfo (Linux); [None] elsewhere. *)
let cpuinfo_model () =
  match open_in "/proc/cpuinfo" with
  | exception Sys_error _ -> None
  | ic ->
      Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
      let rec scan () =
        match input_line ic with
        | exception End_of_file -> None
        | line -> (
            match String.index_opt line ':' with
            | Some i when String.trim (String.sub line 0 i) = "model name" -> (
                match
                  String.trim
                    (String.sub line (i + 1) (String.length line - i - 1))
                with
                | "" -> scan ()
                | model -> Some model)
            | _ -> scan ())
      in
      scan ()

type facts = {
  hostname : string;
  host : string; (* the hardware UUID, else [hostname] *)
  os : string;
  arch : string;
  cpu_model : string;
}

(* Read once, and only when needed: reading them spawns uname and sysctl. *)
let facts =
  lazy
    (let os =
       match process_line "uname" [ "-s" ] with
       | Some sysname -> String.lowercase_ascii sysname
       | None -> "unknown"
     in
     let arch =
       Option.value (process_line "uname" [ "-m" ]) ~default:"unknown"
     in
     let cpu_model =
       let detected =
         if String.equal os "darwin" then
           match process_line "sysctl" [ "-n"; "machdep.cpu.brand_string" ] with
           | Some _ as model -> model
           | None ->
               (* PATH without /usr/sbin (some CI shells): sysctl's canonical
                  macOS location. *)
               process_line "/usr/sbin/sysctl"
                 [ "-n"; "machdep.cpu.brand_string" ]
         else cpuinfo_model ()
       in
       Option.value detected ~default:""
     in
     let hostname = Unix.gethostname () in
     (* A Mac's host name follows the network it joins (DHCP), which would give
        one Mac a section per network; its hardware UUID does not move. *)
     let host = Option.value (Thumper_clock.host_uuid ()) ~default:hostname in
     { hostname; host; os; arch; cpu_model })

let machine_key () =
  match Sys.getenv_opt "THUMPER_MACHINE" with
  | Some key ->
      (* The key heads a baseline section: the file grammar decides what it
         may be. *)
      if not (Baseline.valid_segment key) then
        invalid_arg
          (strf "THUMPER_MACHINE: %s (need a non-empty key over [A-Za-z0-9._-])"
             (Baseline.quote key))
      else key
  | None ->
      (* The machine itself is in the key, not only its CPU model: splitting
         one machine in two costs a new section, which the report shows,
         while merging two machines of one model (different cooling) would
         compare their timings silently. *)
      let { host; os; cpu_model; _ } = Lazy.force facts in
      hash (String.concat ":" [ host; os; cpu_model ])

(* Host strings are rendered verbatim into single-line output (the
   baseline's [# host:] header, the report's header): an interior control
   character in a detected value (however unlikely) must not be able to break
   the file grammar or the terminal line. *)
let printable s = String.map (fun c -> if Char.code c < 0x20 then ' ' else c) s

let cpu_model () =
  match (Lazy.force facts).cpu_model with
  | "" -> "unknown"
  | model -> printable model

let host_description () =
  let { hostname; os; arch; _ } = Lazy.force facts in
  let os = match os with "darwin" -> "macos" | other -> other in
  printable (String.concat " \xc2\xb7 " [ hostname; cpu_model (); arch; os ])

let ocaml_identity () =
  let profile =
    (* The runtime variant is the only execution-profile fact OCaml exposes at
       run time; flambda is invisible. *)
    let variant =
      match Sys.runtime_variant () with
      | "" -> "release"
      | "d" -> "debug"
      | "i" -> "instrumented"
      | other -> other
    in
    match Sys.backend_type with
    | Sys.Native -> variant
    | Sys.Bytecode ->
        if String.equal variant "release" then "bytecode"
        else "bytecode+" ^ variant
    | Sys.Other name ->
        if String.equal variant "release" then name else name ^ "+" ^ variant
  in
  strf "%s \xc2\xb7 %d-bit \xc2\xb7 %s" Sys.ocaml_version Sys.word_size profile

(* Sampling the load *)

let cores () = Domain.recommended_domain_count ()
let load_average () = Thumper_clock.load_average ()

(* An empirical threshold: half a runnable task per core. *)
let load_threshold = 0.5

type load = Quiet | Loaded of { load : float; cores : int }

(* An unreadable load average is [Quiet]: refusing to measure on a host that
   reports no load would trade a verdict that judgment already degrades for no
   verdict at all. *)
let classify ~load ~cores =
  if cores < 1 then
    invalid_arg (strf "Env.classify: %d cores (need at least 1)" cores);
  match load with
  | Some load when load /. float_of_int cores >= load_threshold ->
      Loaded { load; cores }
  | Some _ | None -> Quiet

let load () = classify ~load:(load_average ()) ~cores:(cores ())

(* wait_quiet poll cadence: the kernel recomputes the 1-minute load average on
   a multi-second cadence, so sub-second polling is wasted work; 1 s keeps the
   overshoot negligible against the minutes-long decay being waited out. *)
let default_poll_s = 1.0

let wait_quiet ~timeout_s ?(poll_s = default_poll_s) ?load:(sample = load) () =
  if not (timeout_s >= 0.) then
    invalid_arg
      (strf
         "Env.wait_quiet: timeout_s %g (need a non-negative timeout in seconds)"
         timeout_s);
  if not (poll_s > 0. && poll_s < infinity) then
    invalid_arg
      (strf
         "Env.wait_quiet: poll_s %g (need a positive finite poll interval in \
          seconds)"
         poll_s);
  let deadline = Os.monotonic_s () +. timeout_s in
  let rec loop () =
    match sample () with
    | Quiet -> Ok ()
    | Loaded _ ->
        let now = Os.monotonic_s () in
        if now >= deadline then Error `Timeout
        else begin
          sleep_until (now +. Float.min poll_s (deadline -. now));
          loop ()
        end
  in
  loop ()

(* Holding the measurement lock *)

module Lock = struct
  type error =
    | Timeout of { path : string; wait_s : float }
    | Unusable of string

  let pp_error ppf = function
    | Timeout { path; wait_s } ->
        Format.fprintf ppf
          "timed out after %gs waiting for the measurement lock %s" wait_s path
    | Unusable msg -> Format.fprintf ppf "measurement lock unusable: %s" msg

  let default_wait_s = 600.
  let poll_s = 0.05

  let lock_path ?dir () =
    let dir =
      match dir with
      | Some dir -> dir
      | None -> (
          match Sys.getenv_opt "THUMPER_LOCK_DIR" with
          | Some dir when dir <> "" -> dir
          | Some _ | None -> Filename.get_temp_dir_name ())
    in
    Filename.concat dir (strf "thumper-%d.lock" (Unix.geteuid ()))

  let same_file (a : Unix.stats) (b : Unix.stats) =
    a.st_dev = b.st_dev && a.st_ino = b.st_ino

  (* Whether this process holds the lock. fcntl locks belong to the process,
     so a nested acquisition would succeed at once and its release would drop
     the outer lock. *)
  let held = ref false

  (* The holder stamp is the pid and the clock at acquisition, so it differs
     between two holders even when the second reuses the first one's pid. *)
  let read_stamp fd =
    ignore (Unix.lseek fd 0 Unix.SEEK_SET);
    let buf = Bytes.create 128 in
    let rec read () =
      match Unix.read fd buf 0 (Bytes.length buf) with
      | n -> Bytes.sub_string buf 0 n
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> read ()
    in
    read ()

  let write_stamp fd =
    let stamp = strf "%d:%d\n" (Unix.getpid ()) (Thumper_clock.now_ns ()) in
    Unix.ftruncate fd 0;
    ignore (Unix.lseek fd 0 Unix.SEEK_SET);
    Os.write_all fd stamp

  (* [lockf] locks from the current offset, which reading the stamp moves, so
     every attempt seeks back to 0 first. *)
  let acquire ~path ~wait_s ~on_wait fd =
    let rec attempt ~deadline ~last_stamp =
      ignore (Unix.lseek fd 0 Unix.SEEK_SET);
      match Unix.lockf fd Unix.F_TLOCK 0 with
      | () -> Ok ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) ->
          if Os.monotonic_s () >= deadline then Error (Timeout { path; wait_s })
          else attempt ~deadline ~last_stamp
      | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
          let stamp = read_stamp fd in
          let owner_changed =
            match last_stamp with
            | None -> false
            | Some previous -> not (String.equal previous stamp)
          in
          let deadline =
            if owner_changed then Os.monotonic_s () +. wait_s else deadline
          in
          (match on_wait with
          | Some notify -> notify ~owner_changed
          | None -> ());
          let now = Os.monotonic_s () in
          if now >= deadline then Error (Timeout { path; wait_s })
          else begin
            sleep_until (now +. Float.min poll_s (deadline -. now));
            attempt ~deadline ~last_stamp:(Some stamp)
          end
    in
    attempt ~deadline:(Os.monotonic_s () +. wait_s) ~last_stamp:None

  (* Open the lock file without ever creating through a symbolic link: OCaml's
     Unix binding exposes no O_NOFOLLOW, so the file is only ever created
     under O_CREAT|O_EXCL, which POSIX requires to fail with EEXIST when the
     path names a symbolic link, even a dangling one, while an existing path
     is opened plainly and left to the symlink and swap checks in
     [acquire_fd]. In a shared sticky lock directory, creating through a
     planted symlink would create an attacker-chosen file with our
     credentials. The ENOENT/EEXIST alternation is bounded: a path flapping
     between absent and symlinked is hostile, and refusing loudly (the escaped
     EEXIST becomes [Unusable]) beats spinning. *)
  let rec open_lock ~attempts path =
    match Unix.openfile path [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0o600 with
    | fd -> fd
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> (
        match
          Unix.openfile path
            [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
            0o600
        with
        | fd -> fd
        | exception Unix.Unix_error (Unix.EEXIST, _, _) when attempts > 1 ->
            open_lock ~attempts:(attempts - 1) path)

  let unusable fmt = Printf.ksprintf (fun msg -> Error (Unusable msg)) fmt

  (* The descriptor's file and the named file must be one regular file
     ([lstat] refuses a symbolic link, the inode comparison a swap), checked
     again once locked: an unlink race would leave the lock on an orphaned
     inode. *)
  let acquire_fd ~path ~wait_s ~on_wait =
    match open_lock ~attempts:8 path with
    | exception Unix.Unix_error (e, _, _) ->
        unusable "cannot open %s: %s" path (Unix.error_message e)
    | fd -> (
        let checked =
          try
            let opened = Unix.fstat fd in
            let named = Unix.lstat path in
            if
              opened.st_kind <> Unix.S_REG
              || named.st_kind <> Unix.S_REG
              || not (same_file opened named)
            then unusable "%s is not one stable regular file" path
            else if opened.st_uid <> Unix.geteuid () then
              unusable "%s is not owned by the current user" path
            else if opened.st_perm land 0o077 <> 0 then
              unusable "%s permissions are broader than 0600" path
            else
              match acquire ~path ~wait_s ~on_wait fd with
              | Error _ as error -> error
              | Ok () ->
                  let named = Unix.lstat path in
                  if named.st_kind <> Unix.S_REG || not (same_file opened named)
                  then unusable "%s changed while being acquired" path
                  else begin
                    write_stamp fd;
                    Ok ()
                  end
          with Unix.Unix_error (e, _, _) ->
            unusable "cannot use %s: %s" path (Unix.error_message e)
        in
        match checked with
        | Ok () -> Ok fd
        | Error _ as error ->
            (try Unix.close fd with Unix.Unix_error _ -> ());
            error)

  (* The lock file is never unlinked: removing it on release lets a waiter
     lock the old inode while a newcomer creates and locks a new file, and two
     processes then both hold "the" lock. *)
  let release fd =
    (try
       ignore (Unix.lseek fd 0 Unix.SEEK_SET);
       Unix.lockf fd Unix.F_ULOCK 0
     with Unix.Unix_error _ -> ());
    try Unix.close fd with Unix.Unix_error _ -> ()

  let with_lock ?dir ?(wait_s = default_wait_s) ?on_wait f =
    if not (wait_s >= 0.) then
      invalid_arg
        (strf
           "Env.Lock.with_lock: wait_s %g (need a non-negative wait in seconds)"
           wait_s);
    if !held then Ok (f ())
    else
      let path = lock_path ?dir () in
      match acquire_fd ~path ~wait_s ~on_wait with
      | Error _ as error -> error
      | Ok fd ->
          held := true;
          Fun.protect
            ~finally:(fun () ->
              held := false;
              release fd)
            (fun () -> Ok (f ()))
end
