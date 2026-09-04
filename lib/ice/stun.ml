(** STUN (RFC 5389) with the ICE attributes of RFC 5245.

    Only what an ICE-lite agent needs: decoding binding requests, checking their
    short-term-credential integrity, and encoding binding responses. The codec
    is deliberately free of any dependency on [Unix] so that it can be exercised
    against the RFC 5769 test vectors. *)

let magic_cookie = 0x2112A442l

(** A transport address, the IP kept as raw network-order bytes (4 or 16 of
    them) so that this module needs no address type of its own. *)
type address = { ip : string; port : int }

type message_type =
  | Binding_request
  | Binding_success
  | Binding_error
  | Other of int

type attribute =
  | Mapped_address of address
  | Xor_mapped_address of address
  | Username of string
  | Message_integrity of string
  | Fingerprint of int32
  | Error_code of int * string
  | Realm of string
  | Nonce of string
  | Unknown_attributes of int list
  | Priority of int32
  | Use_candidate
  | Ice_controlling of string  (** 8-byte tiebreaker *)
  | Ice_controlled of string
  | Software of string
  | Unknown of int * string

type t = {
  message_type : message_type;
  transaction_id : string;  (** 12 bytes *)
  attributes : attribute list;
  (* The byte ranges an attacker must not be able to alter: the message as
     received, truncated before MESSAGE-INTEGRITY (resp. FINGERPRINT) and with
     the header length rewritten to include it. Kept so that verification works
     on the exact bytes received rather than on a re-encoding, which need not be
     identical. *)
  integrity_input : string option;
  fingerprint_input : string option;
}

let error fmt = Printf.ksprintf (fun s -> Error s) fmt

(* Attribute and message type numbers *)
let t_mapped_address = 0x0001
let t_username = 0x0006
let t_message_integrity = 0x0008
let t_error_code = 0x0009
let t_unknown_attributes = 0x000A
let t_realm = 0x0014
let t_nonce = 0x0015
let t_xor_mapped_address = 0x0020
let t_priority = 0x0024
let t_use_candidate = 0x0025
let t_software = 0x8022
let t_fingerprint = 0x8028
let t_ice_controlled = 0x8029
let t_ice_controlling = 0x802A

let int_of_message_type = function
  | Binding_request -> 0x0001
  | Binding_success -> 0x0101
  | Binding_error -> 0x0111
  | Other n -> n

let message_type_of_int = function
  | 0x0001 -> Binding_request
  | 0x0101 -> Binding_success
  | 0x0111 -> Binding_error
  | n -> Other n

(* CRC-32 (IEEE 802.3, reflected) as used by the FINGERPRINT attribute. *)
let crc32 =
  let table =
    lazy
      (Array.init 256 (fun n ->
           let c = ref (Int32.of_int n) in
           for _ = 0 to 7 do
             c :=
               if Int32.logand !c 1l <> 0l then
                 Int32.logxor 0xEDB88320l (Int32.shift_right_logical !c 1)
               else Int32.shift_right_logical !c 1
           done;
           !c))
  in
  fun s ->
    let table = Lazy.force table in
    let c = ref 0xFFFFFFFFl in
    String.iter
      (fun ch ->
        let i = Int32.to_int (Int32.logand (Int32.logxor !c (Int32.of_int (Char.code ch))) 0xFFl) in
        c := Int32.logxor table.(i) (Int32.shift_right_logical !c 8))
      s;
    Int32.logxor !c 0xFFFFFFFFl

let fingerprint_xor = 0x5354554El

let padding length = (4 - (length land 3)) land 3

(* Decoding --------------------------------------------------------------- *)

(* The header length field must count the attribute being authenticated, so
   verification runs on the message truncated at [offset] with the length
   rewritten to [offset - 20 + attribute_length]. *)
let with_length message offset attribute_length =
  let prefix = Bytes.of_string (String.sub message 0 offset) in
  Bytes.set_uint16_be prefix 2 (offset - 20 + attribute_length);
  Bytes.unsafe_to_string prefix

let decode_address ~xor ~transaction_id value =
  if String.length value < 4 then error "truncated address attribute"
  else
    let family = Char.code value.[1] in
    let length = match family with 1 -> 4 | 2 -> 16 | _ -> -1 in
    if length < 0 then error "unknown address family %d" family
    else if String.length value < 4 + length then
      error "truncated address attribute"
    else
      let port = String.get_uint16_be value 2 in
      let ip = String.sub value 4 length in
      if not xor then Ok { ip; port }
      else
        (* The mask is the magic cookie, extended with the transaction id for
           IPv6. *)
        let mask =
          let cookie = Bytes.create 4 in
          Bytes.set_int32_be cookie 0 magic_cookie;
          Bytes.unsafe_to_string cookie ^ transaction_id
        in
        let ip = String.mapi (fun i c -> Char.chr (Char.code c lxor Char.code mask.[i])) ip in
        Ok { ip; port = port lxor 0x2112 }

let decode_attribute ~transaction_id typ value =
  let string_attribute f = Ok (f value) in
  let int32_attribute f =
    if String.length value <> 4 then error "expected a 32-bit attribute"
    else Ok (f (String.get_int32_be value 0))
  in
  match typ with
  | _ when typ = t_mapped_address ->
      Result.map (fun a -> Mapped_address a)
        (decode_address ~xor:false ~transaction_id value)
  | _ when typ = t_xor_mapped_address ->
      Result.map (fun a -> Xor_mapped_address a)
        (decode_address ~xor:true ~transaction_id value)
  | _ when typ = t_username -> string_attribute (fun v -> Username v)
  | _ when typ = t_message_integrity ->
      if String.length value <> 20 then error "bad MESSAGE-INTEGRITY length"
      else Ok (Message_integrity value)
  | _ when typ = t_fingerprint -> int32_attribute (fun v -> Fingerprint v)
  | _ when typ = t_error_code ->
      if String.length value < 4 then error "truncated ERROR-CODE"
      else
        let code = (Char.code value.[2] * 100) + Char.code value.[3] in
        Ok (Error_code (code, String.sub value 4 (String.length value - 4)))
  | _ when typ = t_realm -> string_attribute (fun v -> Realm v)
  | _ when typ = t_nonce -> string_attribute (fun v -> Nonce v)
  | _ when typ = t_unknown_attributes ->
      Ok
        (Unknown_attributes
           (List.init (String.length value / 2) (fun i ->
                String.get_uint16_be value (2 * i))))
  | _ when typ = t_priority -> int32_attribute (fun v -> Priority v)
  | _ when typ = t_use_candidate -> Ok Use_candidate
  | _ when typ = t_ice_controlling ->
      if String.length value <> 8 then error "bad ICE-CONTROLLING length"
      else Ok (Ice_controlling value)
  | _ when typ = t_ice_controlled ->
      if String.length value <> 8 then error "bad ICE-CONTROLLED length"
      else Ok (Ice_controlled value)
  | _ when typ = t_software -> string_attribute (fun v -> Software v)
  | _ -> Ok (Unknown (typ, value))

let decode message =
  let length = String.length message in
  if length < 20 then error "message shorter than a STUN header"
  else if Char.code message.[0] land 0xC0 <> 0 then
    error "the two leading bits of a STUN message must be zero"
  else if String.get_int32_be message 4 <> magic_cookie then
    error "bad magic cookie"
  else
    let body_length = String.get_uint16_be message 2 in
    if body_length land 3 <> 0 then error "message length is not a multiple of 4"
    else if 20 + body_length > length then error "truncated message"
    else
      let transaction_id = String.sub message 8 12 in
      let rec attributes offset acc integrity_input fingerprint_input =
        if offset >= 20 + body_length then
          Ok (List.rev acc, integrity_input, fingerprint_input)
        else if offset + 4 > 20 + body_length then error "truncated attribute"
        else
          let typ = String.get_uint16_be message offset in
          let value_length = String.get_uint16_be message (offset + 2) in
          if offset + 4 + value_length > 20 + body_length then
            error "attribute runs past the end of the message"
          else
            let value = String.sub message (offset + 4) value_length in
            match decode_attribute ~transaction_id typ value with
            | Error _ as e -> e
            | Ok attribute ->
                let integrity_input =
                  if typ = t_message_integrity && integrity_input = None then
                    Some (with_length message offset 24)
                  else integrity_input
                in
                let fingerprint_input =
                  if typ = t_fingerprint && fingerprint_input = None then
                    Some (with_length message offset 8)
                  else fingerprint_input
                in
                attributes
                  (offset + 4 + value_length + padding value_length)
                  (attribute :: acc) integrity_input fingerprint_input
      in
      match attributes 20 [] None None with
      | Error _ as e -> e
      | Ok (attributes, integrity_input, fingerprint_input) ->
          Ok
            {
              message_type = message_type_of_int (String.get_uint16_be message 0);
              transaction_id;
              attributes;
              integrity_input;
              fingerprint_input;
            }

(* Encoding --------------------------------------------------------------- *)

let encode_address ~xor ~transaction_id { ip; port } =
  let buffer = Buffer.create 20 in
  Buffer.add_char buffer '\000';
  Buffer.add_char buffer (match String.length ip with 4 -> '\001' | _ -> '\002');
  let port, ip =
    if not xor then (port, ip)
    else
      let mask =
        let cookie = Bytes.create 4 in
        Bytes.set_int32_be cookie 0 magic_cookie;
        Bytes.unsafe_to_string cookie ^ transaction_id
      in
      ( port lxor 0x2112,
        String.mapi (fun i c -> Char.chr (Char.code c lxor Char.code mask.[i])) ip )
  in
  Buffer.add_uint16_be buffer port;
  Buffer.add_string buffer ip;
  Buffer.contents buffer

let encode_attribute ~transaction_id = function
  | Mapped_address a ->
      (t_mapped_address, encode_address ~xor:false ~transaction_id a)
  | Xor_mapped_address a ->
      (t_xor_mapped_address, encode_address ~xor:true ~transaction_id a)
  | Username u -> (t_username, u)
  | Message_integrity m -> (t_message_integrity, m)
  | Fingerprint f ->
      let b = Bytes.create 4 in
      Bytes.set_int32_be b 0 f;
      (t_fingerprint, Bytes.unsafe_to_string b)
  | Error_code (code, reason) ->
      let b = Bytes.create 4 in
      Bytes.set_uint8 b 2 (code / 100);
      Bytes.set_uint8 b 3 (code mod 100);
      (t_error_code, Bytes.unsafe_to_string b ^ reason)
  | Realm r -> (t_realm, r)
  | Nonce n -> (t_nonce, n)
  | Unknown_attributes types ->
      let b = Bytes.create (2 * List.length types) in
      List.iteri (fun i t -> Bytes.set_uint16_be b (2 * i) t) types;
      (t_unknown_attributes, Bytes.unsafe_to_string b)
  | Priority p ->
      let b = Bytes.create 4 in
      Bytes.set_int32_be b 0 p;
      (t_priority, Bytes.unsafe_to_string b)
  | Use_candidate -> (t_use_candidate, "")
  | Ice_controlling t -> (t_ice_controlling, t)
  | Ice_controlled t -> (t_ice_controlled, t)
  | Software s -> (t_software, s)
  | Unknown (typ, value) -> (typ, value)

let add_attribute buffer ~transaction_id attribute =
  let typ, value = encode_attribute ~transaction_id attribute in
  Buffer.add_uint16_be buffer typ;
  Buffer.add_uint16_be buffer (String.length value);
  Buffer.add_string buffer value;
  Buffer.add_string buffer (String.make (padding (String.length value)) '\000')

let set_length message =
  Bytes.set_uint16_be message 2 (Bytes.length message - 20);
  message

(** [encode ?key ?fingerprint message] serialises [message]. When [key] is
    given, a MESSAGE-INTEGRITY attribute computed with it is appended; when
    [fingerprint] holds (the default), a FINGERPRINT attribute closes the
    message. Both are appended in that order, as the RFC requires. *)
let encode ?key ?(fingerprint = true) { message_type; transaction_id; attributes; _ } =
  let buffer = Buffer.create 128 in
  Buffer.add_uint16_be buffer (int_of_message_type message_type);
  Buffer.add_uint16_be buffer 0 (* patched below *);
  Buffer.add_int32_be buffer magic_cookie;
  Buffer.add_string buffer transaction_id;
  List.iter (add_attribute buffer ~transaction_id) attributes;
  let message = ref (set_length (Buffer.to_bytes buffer)) in
  Option.iter
    (fun key ->
      let input = with_length (Bytes.unsafe_to_string !message) (Bytes.length !message) 24 in
      let mac = Digestif.SHA1.(to_raw_string (hmac_string ~key input)) in
      let buffer = Buffer.create (Bytes.length !message + 24) in
      Buffer.add_bytes buffer !message;
      add_attribute buffer ~transaction_id (Message_integrity mac);
      message := set_length (Buffer.to_bytes buffer))
    key;
  if fingerprint then begin
    let input = with_length (Bytes.unsafe_to_string !message) (Bytes.length !message) 8 in
    let crc = Int32.logxor (crc32 input) fingerprint_xor in
    let buffer = Buffer.create (Bytes.length !message + 8) in
    Buffer.add_bytes buffer !message;
    add_attribute buffer ~transaction_id (Fingerprint crc);
    message := set_length (Buffer.to_bytes buffer)
  end;
  Bytes.unsafe_to_string !message

(* Inspection ------------------------------------------------------------- *)

let find message f = List.find_map f message.attributes

let username message =
  find message (function Username u -> Some u | _ -> None)

let priority message =
  find message (function Priority p -> Some p | _ -> None)

let use_candidate message = List.mem Use_candidate message.attributes

let integrity message =
  find message (function Message_integrity m -> Some m | _ -> None)

(** Constant-time comparison, so that a wrong integrity value cannot be found
    byte by byte. *)
let equal_bytes a b =
  String.length a = String.length b
  && (let d = ref 0 in
      String.iteri (fun i c -> d := !d lor (Char.code c lxor Char.code b.[i])) a;
      !d = 0)

(** Whether the message carries a MESSAGE-INTEGRITY attribute valid under the
    short-term credential [key] (an ICE password). *)
let check_integrity ~key message =
  match (integrity message, message.integrity_input) with
  | Some mac, Some input ->
      equal_bytes mac Digestif.SHA1.(to_raw_string (hmac_string ~key input))
  | _ -> false

(** Whether the FINGERPRINT attribute, if any, is valid. A message without one
    passes: the attribute is optional in STUN at large, though ICE requires it. *)
let check_fingerprint message =
  match
    (find message (function Fingerprint f -> Some f | _ -> None), message.fingerprint_input)
  with
  | Some crc, Some input -> Int32.logxor (crc32 input) fingerprint_xor = crc
  | Some _, None | None, Some _ -> false
  | None, None -> true

let response ~message_type request attributes =
  {
    message_type;
    transaction_id = request.transaction_id;
    attributes;
    integrity_input = None;
    fingerprint_input = None;
  }

(** The success response to a binding request, carrying the peer's reflexive
    address. *)
let binding_success request ~address = response ~message_type:Binding_success request [ Xor_mapped_address address ]

let binding_error request ~code ~reason =
  response ~message_type:Binding_error request [ Error_code (code, reason) ]
