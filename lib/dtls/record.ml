(** The DTLS record layer and handshake framing (RFC 6347).

    A DTLS record is a TLS record with an explicit epoch and sequence number,
    since datagrams may be lost, reordered or replayed; a handshake message
    likewise carries its sequence number and, because it may exceed the path
    MTU, the offset and length of the fragment at hand. *)

let version_1_2 = 0xFEFD

type content_type =
  | Change_cipher_spec
  | Alert
  | Handshake
  | Application_data
  | Unknown_content_type of int

let int_of_content_type = function
  | Change_cipher_spec -> 20
  | Alert -> 21
  | Handshake -> 22
  | Application_data -> 23
  | Unknown_content_type n -> n

let content_type_of_int = function
  | 20 -> Change_cipher_spec
  | 21 -> Alert
  | 22 -> Handshake
  | 23 -> Application_data
  | n -> Unknown_content_type n

type t = {
  content_type : content_type;
  version : int;
  epoch : int;
  sequence : int;
  fragment : string;
}

let header_length = 13

(** A datagram may carry several records back to back; a truncated tail is
    ignored rather than failing the ones before it. *)
let parse datagram =
  let r = Buf.reader datagram in
  let rec records acc =
    if Buf.remaining r < header_length then List.rev acc
    else
      let content_type = content_type_of_int (Buf.uint8 r) in
      let version = Buf.uint16 r in
      let epoch = Buf.uint16 r in
      let sequence = Buf.uint48 r in
      let length = Buf.uint16 r in
      if Buf.remaining r < length then List.rev acc
      else
        records ({ content_type; version; epoch; sequence; fragment = Buf.take r length } :: acc)
  in
  records []

let serialize record =
  let w = Buf.writer () in
  Buf.put_uint8 w (int_of_content_type record.content_type);
  Buf.put_uint16 w record.version;
  Buf.put_uint16 w record.epoch;
  Buf.put_uint48 w record.sequence;
  Buf.put_vector16_string w record.fragment;
  Buf.contents w

(** The additional data an AEAD cipher authenticates a record with: the
    sequence number (epoch included), then the record header minus its length,
    with the length of the {e plaintext} (RFC 5246 §6.2.3.3). *)
let additional_data record ~plaintext_length =
  let w = Buf.writer () in
  Buf.put_uint16 w record.epoch;
  Buf.put_uint48 w record.sequence;
  Buf.put_uint8 w (int_of_content_type record.content_type);
  Buf.put_uint16 w record.version;
  Buf.put_uint16 w plaintext_length;
  Buf.contents w

(* Handshake framing ------------------------------------------------------ *)

module Handshake = struct
  (* Message types; only those a server ever sees or sends are named. *)
  let client_hello = 1
  let server_hello = 2
  let certificate = 11
  let server_key_exchange = 12
  let certificate_request = 13
  let server_hello_done = 14
  let certificate_verify = 15
  let client_key_exchange = 16
  let finished = 20

  let name = function
    | 0 -> "HelloRequest"
    | 1 -> "ClientHello"
    | 2 -> "ServerHello"
    | 3 -> "HelloVerifyRequest"
    | 11 -> "Certificate"
    | 12 -> "ServerKeyExchange"
    | 13 -> "CertificateRequest"
    | 14 -> "ServerHelloDone"
    | 15 -> "CertificateVerify"
    | 16 -> "ClientKeyExchange"
    | 20 -> "Finished"
    | n -> Printf.sprintf "handshake message %d" n

  type header = {
    message_type : int;
    length : int;  (** of the whole message *)
    message_seq : int;
    fragment_offset : int;
    fragment_length : int;
  }

  let header_length = 12

  type fragment = { header : header; body : string }

  (** The fragments carried by one handshake record. *)
  let parse fragment_data =
    let r = Buf.reader fragment_data in
    let rec fragments acc =
      if Buf.remaining r < header_length then List.rev acc
      else
        let message_type = Buf.uint8 r in
        let length = Buf.uint24 r in
        let message_seq = Buf.uint16 r in
        let fragment_offset = Buf.uint24 r in
        let fragment_length = Buf.uint24 r in
        if Buf.remaining r < fragment_length then List.rev acc
        else
          let body = Buf.take r fragment_length in
          fragments
            ({ header = { message_type; length; message_seq; fragment_offset; fragment_length }; body }
            :: acc)
    in
    fragments []

  let serialize_header w header =
    Buf.put_uint8 w header.message_type;
    Buf.put_uint24 w header.length;
    Buf.put_uint16 w header.message_seq;
    Buf.put_uint24 w header.fragment_offset;
    Buf.put_uint24 w header.fragment_length

  (** A whole, unfragmented message. This is also the form the handshake hash
      is computed over, whatever fragmentation happened on the wire (RFC 6347
      §4.2.6). *)
  let serialize ~message_type ~message_seq body =
    let w = Buf.writer () in
    let length = String.length body in
    serialize_header w
      { message_type; length; message_seq; fragment_offset = 0; fragment_length = length };
    Buf.put_string w body;
    Buf.contents w

  (** Split a message into fragments whose records fit within [max_fragment]
      bytes of payload. *)
  let fragment ~max_fragment ~message_type ~message_seq body =
    let length = String.length body in
    let chunk = max 1 (max_fragment - header_length) in
    let rec split offset =
      if offset >= length && offset > 0 then []
      else
        let fragment_length = min chunk (length - offset) in
        let w = Buf.writer () in
        serialize_header w
          { message_type; length; message_seq; fragment_offset = offset; fragment_length };
        Buf.put_string w (String.sub body offset fragment_length);
        Buf.contents w :: split (offset + fragment_length)
    in
    (* An empty message (ServerHelloDone) is still one fragment. *)
    if length = 0 then
      [ (let w = Buf.writer () in
         serialize_header w
           { message_type; length = 0; message_seq; fragment_offset = 0; fragment_length = 0 };
         Buf.contents w) ]
    else split 0
end

(* Alerts ----------------------------------------------------------------- *)

module Alert = struct
  let warning = 1
  let fatal = 2

  let close_notify = 0
  let handshake_failure = 40
  let illegal_parameter = 47
  let decode_error = 50
  let decrypt_error = 51
  let protocol_version = 70
  let internal_error = 80

  let serialize ~level ~description =
    let w = Buf.writer () in
    Buf.put_uint8 w level;
    Buf.put_uint8 w description;
    Buf.contents w

  let description_name = function
    | 0 -> "close notify"
    | 40 -> "handshake failure"
    | 47 -> "illegal parameter"
    | 50 -> "decode error"
    | 51 -> "decrypt error"
    | 70 -> "protocol version"
    | 80 -> "internal error"
    | n -> Printf.sprintf "alert %d" n
end
