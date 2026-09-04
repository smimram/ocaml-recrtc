(** The DTLS record layer and handshake framing (RFC 6347).

    A DTLS record is a TLS record with an explicit epoch and sequence number,
    since datagrams may be lost, reordered or replayed; a handshake message
    likewise carries its sequence number and, because it may exceed the path
    MTU, the offset and length of the fragment at hand. *)

val version_1_2 : int
(** 0xFEFD. DTLS versions decrease as they advance. *)

type content_type =
  | Change_cipher_spec
  | Alert
  | Handshake
  | Application_data
  | Unknown_content_type of int

type t = {
  content_type : content_type;
  version : int;
  epoch : int;
  sequence : int;
  fragment : string;
}

val parse : string -> t list
(** The records of one datagram, which may carry several back to back. A
    truncated tail is ignored rather than failing the records before it. *)

val serialize : t -> string

val additional_data : t -> plaintext_length:int -> string
(** What an AEAD cipher authenticates a record with: the sequence number,
    epoch included, then the record header minus its length, with the length of
    the {e plaintext} (RFC 5246 §6.2.3.3). *)

module Handshake : sig
  (** Message types; only those a server sees or sends are named. *)

  val client_hello : int
  val server_hello : int
  val certificate : int
  val server_key_exchange : int
  val certificate_request : int
  val server_hello_done : int
  val certificate_verify : int
  val client_key_exchange : int
  val finished : int

  val name : int -> string
  (** For error messages. *)

  type header = {
    message_type : int;
    length : int;  (** of the whole message *)
    message_seq : int;
    fragment_offset : int;
    fragment_length : int;
  }

  type fragment = { header : header; body : string }

  val parse : string -> fragment list
  (** The fragments carried by one handshake record. *)

  val serialize : message_type:int -> message_seq:int -> string -> string
  (** A whole, unfragmented message. This is also the form the handshake hash
      is computed over, whatever fragmentation happened on the wire (RFC 6347
      §4.2.6). *)

  val fragment :
    max_fragment:int -> message_type:int -> message_seq:int -> string -> string list
  (** Split a message into fragments whose records fit within [max_fragment]
      bytes. An empty message is still one fragment. *)
end

module Alert : sig
  val warning : int
  val fatal : int
  val close_notify : int
  val handshake_failure : int
  val illegal_parameter : int
  val decode_error : int
  val decrypt_error : int
  val protocol_version : int
  val internal_error : int
  val serialize : level:int -> description:int -> string
  val description_name : int -> string
end
