(** The VP8 RTP payload format (RFC 7741).

    Every packet carries a payload descriptor before the VP8 partition data;
    the descriptor is a transport artefact and does not belong in a file, so it
    is stripped and the rest concatenated. *)

exception Invalid of string

val descriptor_length : string -> int
(** How many leading bytes of a payload are descriptor.

    @raise Invalid if the payload is truncated within it. *)

val partition : string -> string
(** The VP8 data of a payload: everything past its descriptor. *)

val starts_frame : string -> bool
(** Whether a payload begins the first partition of a frame, from the [S] bit
    and a partition index of zero (RFC 7741 §4.2). *)

val keyframe : string -> bool
(** Whether reassembled frame data is a keyframe, from the inverted frame-type
    bit of its uncompressed header (RFC 6386 §9.1). *)

val dimensions : string -> (int * int) option
(** The width and height a keyframe declares, or [None] if the data is not a
    keyframe or is too short to say. *)
