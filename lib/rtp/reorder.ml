(** A jitter buffer: packets come out in sequence order, or not at all.

    The network may reorder or lose packets, and neither should corrupt the
    recording. Holding a few packets back is enough to absorb ordinary
    reordering; when the gap does not fill, the buffer gives up on it and
    carries on, because a recorder must not stall waiting for a packet that is
    never coming. *)

type 'a t = {
  depth : int;
  mutable expected : int option;
  (* Ascending by sequence number, relative to what is expected. *)
  mutable buffered : (int * 'a) list;
  mutable lost : int;
}

let create ?(depth = 8) () = { depth; expected = None; buffered = []; lost = 0 }
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

(** Add a packet, and return those that may now be written out, in order. *)
let push t sequence value =
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
          if List.length t.buffered <= t.depth then ready
          else
            (* The buffer is full and still blocked: the packet we are waiting
               for is not coming. Skip to the oldest one we do have. *)
            match t.buffered with
            | [] -> ready
            | (sequence, _) :: _ ->
                t.lost <-
                  t.lost
                  + ((sequence - Option.value t.expected ~default:sequence) land 0xffff);
                t.expected <- Some sequence;
                ready @ release t [])

(** Give up everything held back, in order: for the end of a stream. *)
let flush t =
  let remaining = List.map snd t.buffered in
  t.buffered <- [];
  t.expected <- None;
  remaining
