(** A minimal test harness: enough to run published test vectors without
    pulling in a testing framework. *)

let failures = ref 0
let current = ref ""

let suite name = current := name

let check name condition =
  if condition then Printf.printf "  ok   %s: %s\n" !current name
  else begin
    incr failures;
    Printf.printf "  FAIL %s: %s\n" !current name
  end

(** Hexadecimal, ignoring any whitespace, as pasted from an RFC. *)
let hex s =
  let digits =
    String.to_seq s
    |> Seq.filter (fun c -> not (List.mem c [ ' '; '\n'; '\t'; '\r' ]))
    |> String.of_seq
  in
  String.init (String.length digits / 2) (fun i ->
      Char.chr (int_of_string ("0x" ^ String.sub digits (2 * i) 2)))

let to_hex s =
  String.concat "" (List.map (fun c -> Printf.sprintf "%02x" (Char.code c)) (List.of_seq (String.to_seq s)))

let check_string name ~expected actual =
  if expected = actual then check name true
  else begin
    check name false;
    Printf.printf "       expected %s\n       actual   %s\n" (to_hex expected)
      (to_hex actual)
  end

let exit_status () =
  if !failures = 0 then print_endline "all tests passed"
  else Printf.printf "%d failure(s)\n" !failures;
  if !failures > 0 then exit 1
