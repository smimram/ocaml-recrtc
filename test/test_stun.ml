(** RFC 5769 test vectors.

    The vectors pad attribute values with spaces rather than zeroes, which the
    RFC explicitly allows, so we do not compare our encoder's output to them
    byte for byte: we check that we read them correctly (including the
    integrity and fingerprint computations, which cover those padding bytes)
    and that our own output survives a round trip. *)

open Testlib

let password = "VOkJxbRl1RmTxUk/WvJxBt"

(* §2.1 Sample request *)
let request =
  hex
    "00 01 00 58  21 12 a4 42  b7 e7 a7 01  bc 34 d6 86  fa 87 df ae
     80 22 00 10  53 54 55 4e  20 74 65 73  74 20 63 6c  69 65 6e 74
     00 24 00 04  6e 00 01 ff
     80 29 00 08  93 2f f9 b1  51 26 3b 36
     00 06 00 09  65 76 74 6a  3a 68 36 76  59 20 20 20
     00 08 00 14  9a ea a7 0c  bf d8 cb 56  78 1e f2 b5  b2 d3 f2 49  c1 b5 71 a2
     80 28 00 04  e5 7a 3b cf"

(* §2.2 Sample IPv4 response, mapped address 192.0.2.1 port 32853 *)
let ipv4_response =
  hex
    "01 01 00 3c  21 12 a4 42  b7 e7 a7 01  bc 34 d6 86  fa 87 df ae
     80 22 00 0b  74 65 73 74  20 76 65 63  74 6f 72 20
     00 20 00 08  00 01 a1 47  e1 12 a6 43
     00 08 00 14  2b 91 f5 99  fd 9e 90 c3  8c 74 89 f9  2a f9 ba 53  f0 6b e7 d7
     80 28 00 04  c0 7d 4c 96"

(* §2.3 Sample IPv6 response, 2001:db8:1234:5678:11:2233:4455:6677 port 32853 *)
let ipv6_response =
  hex
    "01 01 00 48  21 12 a4 42  b7 e7 a7 01  bc 34 d6 86  fa 87 df ae
     80 22 00 0b  74 65 73 74  20 76 65 63  74 6f 72 20
     00 20 00 14  00 02 a1 47  01 13 a9 fa  a5 d3 f1 79  bc 25 f4 b5  be d2 b9 d9
     00 08 00 14  a3 82 95 4e  4b e6 7b f1  17 84 c9 7c  82 92 c2 75  bf e3 ed 41
     80 28 00 04  c8 fb 0b 4c"

let decode name message =
  match Ice.Stun.decode message with
  | Ok m -> m
  | Error e ->
      check (name ^ " decodes") false;
      Printf.printf "       %s\n" e;
      exit 1

(** Encoding then decoding must preserve the attributes and produce a message
    that authenticates under the same key. *)
let round_trip name message =
  (* The integrity and fingerprint attributes are recomputed by the encoder, and
     cover the padding bytes, which we do not reproduce; only the attributes we
     supply can be compared. *)
  let significant =
    List.filter (function
      | Ice.Stun.Message_integrity _ | Fingerprint _ -> false
      | _ -> true)
  in
  let attributes = significant (Ice.Stun.attributes message) in
  let encoded =
    Ice.Stun.encode ~key:password
      (Ice.Stun.create
         ~message_type:(Ice.Stun.message_type message)
         ~transaction_id:(Ice.Stun.transaction_id message)
         attributes)
  in
  let decoded = decode (name ^ " re-encoded") encoded in
  check (name ^ ": round trip preserves attributes")
    (significant (Ice.Stun.attributes decoded) = attributes);
  check (name ^ ": round trip integrity") (Ice.Stun.check_integrity ~key:password decoded);
  check (name ^ ": round trip fingerprint") (Ice.Stun.check_fingerprint decoded)

let run () =
  suite "stun";

  let m = decode "request" request in
  check "request: type" (Ice.Stun.message_type m = Ice.Stun.Binding_request);
  check "request: username" (Ice.Stun.username m = Some "evtj:h6vY");
  check "request: priority" (Ice.Stun.priority m = Some 0x6e0001ffl);
  check "request: no use-candidate" (not (Ice.Stun.use_candidate m));
  check "request: integrity" (Ice.Stun.check_integrity ~key:password m);
  check "request: fingerprint" (Ice.Stun.check_fingerprint m);
  check "request: a wrong password is rejected"
    (not (Ice.Stun.check_integrity ~key:"wrong" m));
  round_trip "request" m;

  let m = decode "IPv4 response" ipv4_response in
  check "IPv4 response: type" (Ice.Stun.message_type m = Ice.Stun.Binding_success);
  check "IPv4 response: address"
    (List.exists
       (function
         | Ice.Stun.Xor_mapped_address { ip; port } ->
             ip = hex "c0 00 02 01" && port = 32853
         | _ -> false)
       (Ice.Stun.attributes m));
  check "IPv4 response: integrity" (Ice.Stun.check_integrity ~key:password m);
  check "IPv4 response: fingerprint" (Ice.Stun.check_fingerprint m);
  round_trip "IPv4 response" m;

  let m = decode "IPv6 response" ipv6_response in
  check "IPv6 response: address"
    (List.exists
       (function
         | Ice.Stun.Xor_mapped_address { ip; port } ->
             ip = hex "2001 0db8 1234 5678 0011 2233 4455 6677" && port = 32853
         | _ -> false)
       (Ice.Stun.attributes m));
  check "IPv6 response: integrity" (Ice.Stun.check_integrity ~key:password m);
  check "IPv6 response: fingerprint" (Ice.Stun.check_fingerprint m);
  round_trip "IPv6 response" m;

  (* Corruption must be caught: flipping a byte of the body invalidates both
     the integrity and the fingerprint. *)
  let corrupted = Bytes.of_string request in
  Bytes.set corrupted 24 'X';
  let m = decode "corrupted request" (Bytes.to_string corrupted) in
  check "corruption breaks integrity" (not (Ice.Stun.check_integrity ~key:password m));
  check "corruption breaks fingerprint" (not (Ice.Stun.check_fingerprint m))
