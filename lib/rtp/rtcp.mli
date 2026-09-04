(** The one RTCP packet this receiver ever sends: a picture loss indication.

    Everything else a receiver may report — reception statistics, round trip
    times, congestion feedback — is of no use to a recorder, which cannot ask
    for a packet twice or slow the sender down usefully. A keyframe request is
    the exception: after a lost packet every picture predicted from the one it
    ruined is unusable, and a browser sends a fresh keyframe only when asked. *)

type t = string

val pli : sender:int32 -> media:int32 -> t
(** A picture loss indication (RFC 4585 §6.3.1): a payload-specific feedback
    packet naming the source whose stream is unreadable. [sender] is our own
    synchronisation source, which a browser does not otherwise know and does
    not check; [media] is the source of the pictures being asked for. *)
