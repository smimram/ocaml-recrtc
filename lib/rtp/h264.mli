(** The H.264 RTP payload format (RFC 6184).

    A packet carries a network abstraction layer unit whole, several of them
    aggregated, or one slice of a unit too large for a datagram. This module
    puts them back together and reads what a container needs to describe the
    stream: the parameter sets, and the picture size hidden inside the sequence
    parameter set. *)

val nal_type : string -> int
(** The type field of a NAL unit's first byte. 5 is a picture that can be
    decoded on its own, 7 a sequence parameter set, 8 a picture parameter
    set. *)

val starts_unit : string -> bool
(** Whether a payload begins a NAL unit rather than continuing a fragmented
    one: the test for having joined a picture partway through. *)

type t
(** Reassembles fragmented units across packets. *)

val create : unit -> t

val push : t -> string -> string list
(** The NAL units a payload completes, in order — none while a fragmented unit
    is still arriving, one for a packet carrying a unit whole, several for an
    aggregation packet. Unknown packet types are ignored. *)

val reset : t -> unit
(** Abandon a partly received fragment: for a gap in the sequence, after which
    the rest of the unit can no longer be trusted. *)

val avcc : sps:string -> pps:string -> string
(** The [avcC] configuration record that a container stores out of band, built
    from the two parameter sets. Its length field is set to four bytes, which
    is how {!length_prefixed} writes them. *)

val length_prefixed : string -> string
(** One NAL unit with the four-byte big-endian length that replaces the start
    code once the units are stored in a container. *)

val dimensions : string -> (int * int) option
(** The picture width and height a sequence parameter set declares, cropping
    included, or [None] if it cannot be parsed. *)
