(** The RTCP this receiver builds, and the little of it that it reads.

    A recorder has two things to say back. A picture loss indication, because
    after a lost packet every picture predicted from the one it ruined is
    unusable and a browser sends a fresh keyframe only when asked. And a
    receiver report, because a sender that hears nothing about what arrived has
    nothing to size its bitrate against. *)

type t = string

val pli : sender:int32 -> media:int32 -> t
(** A picture loss indication (RFC 4585 §6.3.1): a payload-specific feedback
    packet naming the source whose stream is unreadable. [sender] is our own
    synchronisation source, which a browser does not otherwise know and does
    not check; [media] is the source of the pictures being asked for. *)

(** One source's reception statistics (RFC 3550 §6.4.1). [cumulative_lost] is
    signed and occupies three octets; [fraction_lost] is the loss since the
    last report, as a fraction of 256. [last_sr] and [delay_since_last_sr] are
    what let the sender work out the round trip: the middle 32 bits of the NTP
    timestamp of the last sender report we saw, and how long ago we saw it, in
    units of 1/65536 of a second. Both are zero until a sender report has
    arrived. *)
type report = {
  source : int32;
  fraction_lost : int;
  cumulative_lost : int;
  extended_highest : int32;
  jitter : int32;
  last_sr : int32;
  delay_since_last_sr : int32;
}

val receiver_report : sender:int32 -> report list -> t
(** A receiver report (RFC 3550 §6.4.2): one block for each source we are
    receiving, under our own synchronisation source. *)

val source_description : sender:int32 -> cname:string -> t
(** The CNAME chunk (RFC 3550 §6.5) that must accompany a report: the
    persistent name of the endpoint sending it, as against the synchronisation
    source, which may change. *)

val compound : t list -> t
(** Packets sent as one datagram, which is how RTCP travels unless reduced-size
    RTCP was negotiated, which we do not negotiate (RFC 3550 §6.1). *)

val sender_reports : string -> (int32 * int32) list
(** The source and NTP timestamp of every sender report in a compound packet,
    which is all we read of what a browser sends us: it is what a receiver
    report has to echo back. Anything else in the packet is stepped over. *)
