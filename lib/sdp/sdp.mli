(** Minimal SDP support for a WebRTC audio receiver.

    We only ever deal with the one shape of session a browser produces for a
    single audio track, so the parser is deliberately partial: it looks for the
    attributes we need and ignores everything else. *)

type direction = Sendrecv | Sendonly | Recvonly | Inactive

val string_of_direction : direction -> string

(** A codec as described by [a=rtpmap] and its optional [a=fmtp]. *)
type codec = {
  payload_type : int;
  name : string;
  clock_rate : int;
  channels : int;
  fmtp : string option;
}

(** Everything we need out of an offer. Session-level [a=ice-ufrag] and friends
    are folded into the media description, media level winning. *)
type offer = {
  mid : string;
  opus : codec;
  ice_ufrag : string;
  ice_pwd : string;
  fingerprint : string * string;  (** algorithm, colon-separated hex *)
  setup : string;
  rtcp_mux : bool;
  direction : direction;
}

exception Invalid of string

val parse_offer : string -> offer
(** @raise Invalid if the offer is malformed or proposes no Opus audio. *)

val answer :
  offer:offer ->
  addresses:string list ->
  port:int ->
  ice_ufrag:string ->
  ice_pwd:string ->
  fingerprint:string * string ->
  unit ->
  string
(** The answer to an offer: an ICE-lite, DTLS-passive, receive-only endpoint
    reachable at [port] on each of [addresses], most preferred first.

    Several addresses are worth offering because a peer pairs its own
    candidates with ours by route: a browser on the same machine as the server
    has no loopback candidate of its own to pair with a loopback one of ours.

    @raise Invalid_argument if [addresses] is empty. *)
