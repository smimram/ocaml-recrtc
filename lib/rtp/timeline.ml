type t = {
  mutable origin : int64 option;
  mutable last : int32;
  mutable wraps : int64;
  mutable position : int64;
}

let create () = { origin = None; last = 0l; wraps = 0L; position = 0L }
let position t = t.position

(* The timestamp as the unsigned quantity it is: OCaml's int32 is signed, and
   the top half of the range would otherwise come out negative. *)
let unsigned timestamp = Int64.logand (Int64.of_int32 timestamp) 0xFFFFFFFFL

let elapsed t timestamp =
  (* The clock wrapped if the new timestamp is far enough behind the last one;
     a small step backwards is only a packet arriving out of order. *)
  if
    Int32.unsigned_compare timestamp t.last < 0
    && Int64.sub (unsigned t.last) (unsigned timestamp) > 0x40000000L
  then t.wraps <- Int64.add t.wraps 0x100000000L;
  t.last <- timestamp;
  let absolute = Int64.add t.wraps (unsigned timestamp) in
  let position =
    match t.origin with
    | Some origin -> Int64.sub absolute origin
    | None ->
        t.origin <- Some absolute;
        0L
  in
  t.position <- position;
  position
