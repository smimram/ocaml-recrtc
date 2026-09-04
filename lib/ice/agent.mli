(** An ICE-lite agent (RFC 8445 §2.7).

    A lite agent never gathers candidates beyond its own host addresses and
    never sends connectivity checks: it only answers the checks of the full
    agent at the other end, which is always the controlling one. That is all a
    server with a reachable address needs, and it is what makes traversal work
    for a browser behind a NAT — the browser's outbound check opens the
    mapping, and we answer from the very socket and address it arrived on. *)

type credentials = { ufrag : string; pwd : string }

type t

val create : remote:credentials -> t
(** An agent for a peer with the given credentials, with fresh local ones. *)

val local : t -> credentials
(** Ours, as they went into the answer. The fragment names the session: it is
    the local half of the USERNAME a peer's checks carry. *)

val remote : t -> credentials

val peer : t -> Unix.sockaddr option
(** Where valid checks are coming from, once one has arrived. It is updated
    whenever a valid check arrives from elsewhere, so that a NAT rebinding
    mid-session does not strand the agent at a dead address. *)

val nominated : t -> bool
(** Whether the peer has nominated a pair with USE-CANDIDATE. *)

val alive : ?timeout:float -> t -> bool
(** Whether a valid check has been seen within [timeout] seconds (30 by
    default). A peer refreshes consent every few seconds, so silence means it
    is gone. *)

type outcome =
  | Respond of string  (** the datagram to send back to the source *)
  | Drop of string  (** with the reason, for logging *)

val handle : t -> source:Unix.sockaddr -> string -> outcome
(** Process a datagram that the demultiplexer classified as STUN. A response
    must be sent from the socket the datagram arrived on, to its source: a peer
    discards one that comes from anywhere else. *)

(** {1 Addresses} *)

val address_of_sockaddr : Unix.sockaddr -> Stun.address option
val string_of_sockaddr : Unix.sockaddr -> string
