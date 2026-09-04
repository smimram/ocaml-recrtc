(** A jitter buffer: packets come out in sequence order, or not at all.

    Holding a few packets back absorbs the reordering a network does; when a
    gap does not fill, the buffer gives up on it and carries on, because a
    recorder must not stall waiting for a packet that is never coming. *)

type 'a t

val create : ?depth:int -> unit -> 'a t
(** [depth] is how many packets may be held back waiting for a gap to fill
    before it is written off as lost (8 by default). *)

val push : 'a t -> int -> 'a -> 'a list
(** [push t sequence value] adds a packet and returns those that may now be
    written out, in order. Duplicates and packets that arrive after their place
    has passed are dropped. *)

val flush : 'a t -> 'a list
(** Everything still held back, in order: for the end of a stream. *)

val lost : 'a t -> int
(** How many packets have been given up on. *)
