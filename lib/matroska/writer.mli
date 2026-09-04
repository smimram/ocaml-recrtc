(** Writing a Matroska file holding the video and audio of one WebRTC session.

    Frames and packets are stored exactly as they arrived: nothing is decoded
    or re-encoded, which is why the muxing is done here rather than through a
    library that would want samples rather than bytes. Matroska is the only
    container that will hold what a browser sends — VP8 or H.264 pictures
    beside Opus packets — without touching either.

    {1 Synchronisation}

    Each track's timestamps come from its own RTP clock, and the two clocks
    start at unrelated random offsets, so they can only be related through
    something outside them. What is used here is arrival: a track's timeline
    is anchored at the moment its first packet reached us, and advances by its
    own clock from there. The residual error is the difference in arrival of
    the two first packets, tens of milliseconds in practice. Getting it exact
    would mean reading the NTP-to-RTP mapping out of the peer's RTCP sender
    reports, which we decrypt but do not yet interpret. *)

type codec =
  | Vp8
  | H264 of string  (** the [avcC] configuration record, from {!Rtp.H264.avcc} *)

val extension : codec -> string
(** [".webm"] or [".mkv"]. WebM admits only VP8 and VP9, so an H.264 recording
    is written as plain Matroska instead — the same file, a different declared
    document type. *)

type t

val create :
  ?writing_app:string ->
  codec:codec ->
  width:int ->
  height:int ->
  ?audio_channels:int ->
  string ->
  t
(** Create the file at the given path and write its headers. The picture size
    has to be known here, since a Matroska video track declares it up front;
    so does the channel count, when there is an audio track at all. *)

val write_video :
  t -> arrival:float -> timestamp:int32 -> keyframe:bool -> string -> unit
(** Append one video frame, with the RTP timestamp of its 90 kHz clock and the
    moment it arrived. *)

val write_audio : t -> arrival:float -> timestamp:int32 -> string -> unit
(** Append one Opus packet, with the RTP timestamp of its 48 kHz clock. *)

val close : t -> unit
(** Emit what the mux queue is still holding, fill in the lengths that were
    left open, and close the file. A file that never reaches this is still
    readable, short of its duration. *)

val duration : t -> float
(** How much has been written, in seconds. *)
