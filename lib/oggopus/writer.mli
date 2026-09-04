(** Writing an Ogg Opus file (RFC 7845) from the Opus packets of an RTP stream.

    Packets are written exactly as they arrive: they are already what a decoder
    expects, so nothing is decoded or re-encoded. What the container needs
    beyond them is a granule position, which the RTP timestamp supplies
    directly — it counts the same 48 kHz samples that Ogg does. *)

type t

val sample_rate : int
(** Always 48000: every Opus decoder runs at that rate whatever the encoder
    chose. *)

val samples : string -> int
(** A packet's duration in granule units, from its table-of-contents byte
    (RFC 6716 §3.1). *)

val channels : string -> int
(** Whether a packet carries one or two channels. A browser encoding a mono
    microphone sends mono packets whatever its offer said, and the file's
    header has to describe what the packets actually decode to. *)

val create :
  ?channels:int ->
  ?pre_skip:int ->
  ?vendor:string ->
  ?comments:(string * string) list ->
  string ->
  t
(** Create the file at the given path and write the two Opus headers. *)

val write : t -> timestamp:int32 -> string -> unit
(** Append one Opus packet, taken from an RTP packet with the given timestamp.
    Packets must be given in order; the timestamp may wrap. Each finished page
    reaches the disk as it is completed, so an interrupted recording is still a
    playable file. *)

val close : t -> unit
(** Flush what is pending, mark the end of the stream and close the file. *)

val duration : t -> float
(** How much audio has been written, in seconds. *)
