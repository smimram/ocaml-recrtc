(** STUN (RFC 5389) with the ICE attributes of RFC 5245.

    Only what an ICE-lite agent needs: decoding binding requests, checking
    their short-term-credential integrity, and encoding binding responses.
    Deliberately free of any dependency on [Unix], so that it can be exercised
    against the RFC 5769 test vectors. *)

val magic_cookie : int32

type address = { ip : string; port : int }
(** A transport address, the IP kept as raw network-order bytes (4 or 16 of
    them) so that this module needs no address type of its own. *)

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

type t
(** A message. Abstract because a decoded one also carries the exact bytes the
    integrity and fingerprint attributes were computed over, which must be the
    ones received rather than a re-encoding. *)

val create : message_type:message_type -> transaction_id:string -> attribute list -> t
val message_type : t -> message_type
val transaction_id : t -> string
val attributes : t -> attribute list

val decode : string -> (t, string) result
(** Parse a message, or say why it is not one. *)

val encode : ?key:string -> ?fingerprint:bool -> t -> string
(** Serialise a message. When [key] is given, a MESSAGE-INTEGRITY attribute
    computed with it is appended; when [fingerprint] holds (the default), a
    FINGERPRINT attribute closes the message. Both are appended in that order,
    as the RFC requires. *)

(** {1 Inspection} *)

val username : t -> string option
val priority : t -> int32 option
val use_candidate : t -> bool

val check_integrity : key:string -> t -> bool
(** Whether the message carries a MESSAGE-INTEGRITY attribute valid under the
    short-term credential [key] (an ICE password). Compared in constant time. *)

val check_fingerprint : t -> bool
(** Whether the FINGERPRINT attribute, if any, is valid. A message without one
    passes: the attribute is optional in STUN at large, though ICE requires
    it. *)

(** {1 Responses} *)

val binding_success : t -> address:address -> t
(** The success response to a binding request, carrying the peer's reflexive
    address. *)

val binding_error : t -> code:int -> reason:string -> t
