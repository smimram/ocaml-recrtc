(** A stream's own timeline, in the units of its RTP clock.

    An RTP timestamp starts at a random offset and is only thirty-two bits
    wide, so it wraps — every thirteen hours at 90 kHz, every day at 48 kHz.
    A container wants neither: it wants a count from the start of the stream
    that keeps growing. *)

type t

val create : unit -> t

val elapsed : t -> int32 -> int64
(** How far the given timestamp is past the first one ever given, in RTP
    clock ticks. The first call defines the origin and answers zero.

    Timestamps are expected roughly in order; a small step backwards is taken
    for a packet out of order, a large one for the clock wrapping. *)

val position : t -> int64
(** What the last {!elapsed} returned, or zero before the first call. *)
