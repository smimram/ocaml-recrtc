(** What arrived, counted for the receiver reports that tell a sender about it.

    One of these per source. The counting is of what came off the wire, before
    the jitter buffer: what a report describes is the network, and a packet the
    buffer later gave up on did arrive. *)

type t

val create : clock_rate:int -> t
(** [clock_rate] is the source's own, in which the jitter is measured. *)

val receive : ?now:float -> t -> Packet.t -> unit
(** Count a packet, and let it inform the jitter. *)

val sender_report : ?now:float -> t -> ntp:int32 -> unit
(** Note the middle 32 bits of a sender report's NTP timestamp, and when it
    arrived: a report echoes both back so that the sender can work out the
    round trip. *)

val source : t -> int32 option
(** The synchronisation source being counted, once a packet has arrived. *)

val report : ?now:float -> t -> Rtcp.report option
(** The statistics as a report block, or [None] if nothing has arrived yet.

    This is not a pure reading: the loss fraction is over the interval since
    the last report, so asking for one starts a new interval. *)
