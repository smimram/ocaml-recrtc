(** A jitter buffer: packets come out in sequence order, or not at all.

    Holding a few packets back absorbs the reordering a network does; when a
    gap does not fill, the buffer gives up on it and carries on, because a
    recorder must not stall waiting for a packet that is never coming. *)

type 'a t

val create : ?depth:int -> ?deadline:float -> unit -> 'a t
(** [depth] is how many packets may be held back waiting for a gap to fill
    before it is written off as lost (8 by default), and [deadline] how long,
    in seconds, one may be held back for (0.2 by default). Either bound alone
    leaves the other case unbounded: a stream of a few packets a second reaches
    no depth, and a stream of hundreds reaches the deadline having buffered far
    more than it needs to. *)

val push : ?now:float -> 'a t -> int -> 'a -> 'a list
(** [push t sequence value] adds a packet and returns those that may now be
    written out, in order. Duplicates and packets that arrive after their place
    has passed are dropped. *)

val expire : ?now:float -> 'a t -> 'a list
(** Whatever the deadline has now run out on, for a stream that has gone quiet:
    {!push} is the only other place it is tested, so a buffer that stops being
    pushed to stays blocked however long it waits. *)

val flush : 'a t -> 'a list
(** Everything still held back, in order: for the end of a stream. *)

val lost : 'a t -> int
(** How many packets have been given up on. *)
