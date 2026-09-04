(** The handshake messages a DTLS server exchanges with a WebRTC client.

    Only one cipher suite is supported —
    [TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256] — which every browser offers, so
    the set of messages is small: the key exchange is always ephemeral ECDH on
    P-256 and the record protection is always an AEAD. *)

val ecdhe_ecdsa_aes_128_gcm_sha256 : int

val empty_renegotiation_info_scsv : int
(** The signalling-plane counterpart of the renegotiation_info extension: a
    client that has never renegotiated may announce it this way instead. *)

module Group : sig
  val secp256r1 : int
end

module Extension : sig
  val supported_groups : int
  val ec_point_formats : int
  val signature_algorithms : int
  val use_srtp : int
  val extended_master_secret : int
  val renegotiation_info : int
end

module Srtp_profile : sig
  val aes128_cm_hmac_sha1_80 : int
  val aes128_cm_hmac_sha1_32 : int
end

(** {1 What the client sends} *)

type client_hello = {
  client_version : int;
  random : string;  (** 32 bytes *)
  session_id : string;
  cookie : string;  (** DTLS only; empty unless we ask for one *)
  cipher_suites : int list;
  compression_methods : int list;
  extensions : (int * string) list;
}

val parse_client_hello : string -> client_hello
val offers : client_hello -> int -> bool

val srtp_profiles : client_hello -> int list
(** The SRTP protection profiles the client offers, most preferred first
    (RFC 5764 §4.1.1). Empty when it offers the extension not at all. *)

val parse_client_key_exchange : string -> string
(** For an ECDHE suite the message is the client's ephemeral public point. *)

(** {1 What the server sends} *)

val server_hello :
  random:string ->
  session_id:string ->
  extensions:(int * (Buf.writer -> unit)) list ->
  string

val use_srtp_extension : int -> Buf.writer -> unit
val ec_point_formats_extension : Buf.writer -> unit
val renegotiation_info_extension : Buf.writer -> unit
val extended_master_secret_extension : Buf.writer -> unit
val certificate : string list -> string

val ecdh_params : group:int -> public_point:string -> string
(** The ECDHE parameters, as they appear in ServerKeyExchange and as they are
    signed. *)

val server_key_exchange : params:string -> signature:string -> string
val server_hello_done : string
