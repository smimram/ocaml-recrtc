(** A DTLS 1.2 server, restricted to what WebRTC needs of it.

    The browser is the DTLS client (we answer [a=setup:passive]), the only
    cipher suite is [TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256], and the
    handshake exists solely to negotiate SRTP protection and export its keying
    material (RFC 5764): no application data ever flows over the connection.

    This is a pure state machine over datagrams — {!handle} takes what arrived
    and returns what to send — so it can be driven by a socket, by a test, or
    by nothing at all. *)

type config

val config : ?max_record:int -> Certificate.t -> config
(** [max_record] is the largest record payload we emit, chosen so that a record
    and its UDP and IP headers stay within the path MTU (1100 by default). *)

type t

val create : config -> t
(** A handshake waiting for a ClientHello. One peer, one handshake: a datagram
    from somewhere else needs a state of its own. *)

type established = {
  profile : int;  (** the negotiated SRTP protection profile *)
  keying : Crypto.srtp_keying;
}

type event =
  | Pending
  | Established of established
  | Failed of string

val handle : t -> string -> string list * event
(** Process one datagram: the datagrams to send back, and where the handshake
    now stands.

    [Established] keeps being returned for as long as the peer repeats its last
    flight, so a caller that acts on it — taking the keys, say — should do so
    once. Once established, nothing more needs feeding in. *)

val retransmit : t -> string list
(** The last flight again, for a retransmission timer. A flight is also sent
    again on its own whenever the peer repeats the one before it, which covers
    the common case without a timer. *)
