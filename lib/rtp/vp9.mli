(** The VP9 RTP payload format (draft-ietf-payload-vp9-16).

    Like VP8, every packet carries a payload descriptor before the frame data;
    the descriptor is a transport artefact and does not belong in a file, so it
    is stripped and the rest concatenated. Unlike VP8 the descriptor is
    variable in far more ways — the layer indices, the reference differences of
    flexible mode and the scalability structure are each optional — so its
    length is the only thing read out of it beyond the two bits that say where
    a frame begins and ends. *)

exception Invalid of string

val descriptor_length : string -> int
(** How many leading bytes of a payload are descriptor.

    @raise Invalid if the payload is truncated within it. *)

val payload : string -> string
(** The VP9 data of a payload: everything past its descriptor. *)

val starts_frame : string -> bool
(** Whether a payload begins a frame, from the [B] bit (§4.2). *)

val keyframe : string -> bool
(** Whether reassembled frame data is a keyframe, from the frame type in its
    uncompressed header (VP9 bitstream specification §6.2). *)

val dimensions : string -> (int * int) option
(** The width and height a keyframe declares, or [None] if the data is not a
    keyframe or is too short to say. *)
