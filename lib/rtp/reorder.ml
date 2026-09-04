(** A jitter buffer: packets come out in sequence order, or not at all.

    The network may reorder or lose packets, and neither should corrupt the
    recording. Holding a few packets back is enough to absorb ordinary
    reordering; when the gap does not fill, the buffer gives up on it and
    carries on, because a recorder must not stall waiting for a packet that is
    never coming. *)

type 'a t = {
  depth : int;
  deadline : float;
  mutable expected : int option;
  (* Ascending by sequence number, relative to what is expected. *)
  mutable buffered : (int * 'a) list;
  (* When the packet now at the head of the buffer first found itself waiting
     on a gap, so that the wait can be bounded in time as well as in packets. *)
  mutable blocked_since : float option;
  mutable lost : int;
}

let create ?(depth = 8) ?(deadline = 0.2) () =
  { depth; deadline; expected = None; buffered = []; blocked_since = None; lost = 0 }

let lost t = t.lost

(* Sequence numbers are sixteen bits and wrap, so ordering is only meaningful
   within half the space (RFC 3550 §A.1). *)
let before a b = (b - a) land 0xffff <> 0 && (b - a) land 0xffff < 32768
let next sequence = (sequence + 1) land 0xffff

let rec insert sequence value = function
  | [] -> [ (sequence, value) ]
  | (s, _) :: _ when s = sequence -> (* a duplicate *) raise Exit
  | ((s, _) as head) :: rest when before sequence s -> (sequence, value) :: head :: rest
  | head :: rest -> head :: insert sequence value rest

(** Everything at the head of the buffer that is now in sequence. *)
let rec release t acc =
  match (t.buffered, t.expected) with
  | (sequence, value) :: rest, Some expected when sequence = expected ->
      t.buffered <- rest;
      t.expected <- Some (next sequence);
      release t (value :: acc)
  | _ -> List.rev acc

(* The buffer is blocked exactly when it holds something it cannot yet release,
   which after [release] is whenever it holds anything at all. The clock starts
   when that first becomes true and is reset the moment the head moves. *)
let note_blocked t now =
  if t.buffered = [] then t.blocked_since <- None
  else if t.blocked_since = None then t.blocked_since <- Some now

(** Write off the gap at the head and skip to the oldest packet we do have. *)
let skip t now =
  match t.buffered with
  | [] -> []
  | (sequence, _) :: _ ->
      t.lost <-
        t.lost + ((sequence - Option.value t.expected ~default:sequence) land 0xffff);
      t.expected <- Some sequence;
      t.blocked_since <- None;
      let released = release t [] in
      note_blocked t now;
      released

(* Two bounds on how long a gap may hold up everything behind it, because
   neither one alone is enough. The depth catches a busy stream, where the
   packets pile up in no time; the deadline catches a sparse one, where a few
   packets a second would otherwise sit on the buffer for seconds on end. *)
let overdue t now =
  List.length t.buffered > t.depth
  || match t.blocked_since with
     | Some since -> now -. since > t.deadline
     | None -> false

(** Add a packet, and return those that may now be written out, in order. *)
let push ?now t sequence value =
  let now = match now with Some now -> now | None -> Unix.gettimeofday () in
  match t.expected with
  | Some expected when before sequence expected ->
      (* Too late: whatever it belonged to has already been written. *)
      []
  | _ -> (
      if t.expected = None then t.expected <- Some sequence;
      match insert sequence value t.buffered with
      | exception Exit -> []
      | buffered ->
          t.buffered <- buffered;
          let ready = release t [] in
          note_blocked t now;
          if not (overdue t now) then ready
          else
            (* Still blocked, and out of patience: the packet we are waiting
               for is not coming. *)
            ready @ skip t now)

(** Whether the gap at the head has waited long enough, for a stream that has
    gone quiet: nothing else would notice, [push] being the only other place
    the deadline is ever tested. *)
let expire ?now t =
  let now = match now with Some now -> now | None -> Unix.gettimeofday () in
  if overdue t now then skip t now else []

(** Give up everything held back, in order: for the end of a stream. *)
let flush t =
  let remaining = List.map snd t.buffered in
  t.buffered <- [];
  t.expected <- None;
  t.blocked_since <- None;
  remaining
