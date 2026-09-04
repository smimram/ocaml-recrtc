(** Minimal SDP support for a WebRTC receiver.

    We only ever deal with the shape of session a browser produces for a
    microphone and a camera, so the parser is deliberately partial: it looks
    for the attributes we need and ignores everything else. *)

type direction = Sendrecv | Sendonly | Recvonly | Inactive

val string_of_direction : direction -> string

(** A codec as described by [a=rtpmap] and its optional [a=fmtp]. The name is
    kept as the offer spelled it — encoding names are case-insensitive, and an
    answer that respells one is asking for trouble. *)
type codec = {
  payload_type : int;
  name : string;
  clock_rate : int;
  channels : int;
  fmtp : string option;
}

(** One media section of the offer. [codec] is what we chose to receive on it,
    or [None] for a section we have nothing to offer — a second camera, a data
    channel, a codec we do not implement. The answer must still contain a
    matching section, so the [m=] line is kept to be echoed back with a port of
    zero. *)
type media = {
  mid : string;
  kind : string;  (** ["audio"], ["video"], or whatever else was offered *)
  line : string;  (** the [m=] line's value, as it was written *)
  codec : codec option;
  direction : direction;
}

(** Everything we need out of an offer. Session-level [a=ice-ufrag] and friends
    are folded into the media descriptions, media level winning, and taken from
    the first section: under BUNDLE every section agrees on them. *)
type offer = {
  media : media list;  (** in the offer's own order, which the answer keeps *)
  ice_ufrag : string;
  ice_pwd : string;
  fingerprint : string * string;  (** algorithm, colon-separated hex *)
  setup : string;
  rtcp_mux : bool;
}

val codec : offer -> string -> codec option
(** What we chose to receive for a kind of media, ["audio"] or ["video"]. *)

exception Invalid of string

val parse_offer : string -> offer
(** @raise Invalid
      if the offer is malformed, or proposes nothing we can receive: Opus for
      audio, VP8 or H.264 for video. *)

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
    reachable at [port] on each of [addresses], most preferred first, with one
    section per section of the offer and every accepted one bundled onto the
    same transport.

    Several addresses are worth offering because a peer pairs its own
    candidates with ours by route: a browser on the same machine as the server
    has no loopback candidate of its own to pair with a loopback one of ours.

    @raise Invalid_argument if [addresses] is empty. *)
