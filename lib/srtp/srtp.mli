(** SRTP (RFC 3711) for the one profile DTLS-SRTP negotiates with browsers,
    [AES_CM_128_HMAC_SHA1_80]: AES-128 in counter mode for confidentiality and
    an 80-bit HMAC-SHA1 tag for authentication.

    Only the receiving half is implemented, since the server never sends media.
    Each synchronisation source is tracked separately, as each has its own
    rollover counter and replay window. *)

type t

type error =
  | Too_short
  | Malformed of string
  | Authentication_failed
  | Replayed

val string_of_error : error -> string

val key_length : int
(** 16: the length of a master or session key. *)

val salt_length : int
(** 14: the length of a master or session salt. *)

val create : master_key:string -> master_salt:string -> t
(** A receiving context from one half of the material DTLS-SRTP exported.

    @raise Invalid_argument if the key or the salt is the wrong length. *)

val unprotect : t -> string -> (string, error) result
(** Authenticate and decrypt an SRTP packet, yielding the RTP packet inside.

    The rollover counter is not carried by the packet: it is inferred from the
    sequence numbers seen so far, and authenticated along with the packet, so a
    wrong guess shows up as {!Authentication_failed}. *)

val unprotect_rtcp : t -> string -> (string, error) result
(** The same for SRTCP, whose index does travel in the packet, in a trailing
    word whose top bit says whether the packet was encrypted. *)

(** {1 Primitives}

    The pieces the key derivation and ciphering are built from, exposed so that
    the published test vectors can drive them directly. *)

module Label : sig
  val rtp_encryption : int
  val rtp_authentication : int
  val rtp_salt : int
  val rtcp_encryption : int
  val rtcp_authentication : int
  val rtcp_salt : int
end

val derive : master_key:string -> master_salt:string -> label:int -> int -> string
(** The key derivation function (RFC 3711 §4.3.1): AES in counter mode under
    the master key, with the label exclusive-ored into the master salt. The key
    derivation rate is zero, as DTLS-SRTP leaves it, so the input depends on
    the label alone. *)

type keys = {
  cipher : Mirage_crypto.AES.CTR.key;
  authentication : string;
  salt : string;
}

val counter : salt:string -> ssrc:int32 -> index:int -> string
(** The counter block of RFC 3711 §4.1.1: the session salt, the source and the
    packet index, each shifted into its own position. *)

val cipher : keys -> ssrc:int32 -> index:int -> data:string -> string
(** Counter mode is its own inverse, so this both protects and unprotects. *)

val tag_length : int
(** 10: the length of the authentication tag this profile appends. *)

val authenticate : key:string -> string -> string
(** The truncated HMAC-SHA1 tag over the given bytes. *)
