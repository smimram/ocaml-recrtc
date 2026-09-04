(** Reading and writing the length-prefixed byte layout TLS is described in.

    TLS specifies its structures as fixed-width integers and vectors carrying
    their length in a 1-, 2- or 3-byte prefix; having those as combinators keeps
    the message codecs close to the notation of the RFCs. *)

exception Truncated

(* Reading ---------------------------------------------------------------- *)

type reader = { data : string; mutable position : int }

let reader ?(position = 0) data = { data; position }
let remaining r = String.length r.data - r.position
let at_end r = remaining r = 0

let advance r n =
  if remaining r < n then raise Truncated;
  let position = r.position in
  r.position <- position + n;
  position

let take r n = String.sub r.data (advance r n) n

let uint8 r = Char.code r.data.[advance r 1]
let uint16 r = String.get_uint16_be r.data (advance r 2)

let uint24 r =
  let p = advance r 3 in
  (Char.code r.data.[p] lsl 16)
  lor (Char.code r.data.[p + 1] lsl 8)
  lor Char.code r.data.[p + 2]

(* A 48-bit record sequence number; it fits an OCaml int. *)
let uint48 r =
  let p = advance r 6 in
  let byte i = Char.code r.data.[p + i] in
  List.fold_left (fun n i -> (n lsl 8) lor byte i) 0 [ 0; 1; 2; 3; 4; 5 ]

let vector8 r = take r (uint8 r)
let vector16 r = take r (uint16 r)
let vector24 r = take r (uint24 r)

(** A reader over the contents of a vector, for structures nested inside one. *)
let sub_vector16 r = reader (vector16 r)

(** Read [f] until the reader is exhausted, collecting the results. *)
let rec list_of r f = if at_end r then [] else let x = f r in x :: list_of r f

(* Writing ---------------------------------------------------------------- *)

type writer = Buffer.t

let writer () = Buffer.create 256
let contents = Buffer.contents
let put_string = Buffer.add_string
let put_uint8 w n = Buffer.add_uint8 w n
let put_uint16 w n = Buffer.add_uint16_be w n

let put_uint24 w n =
  put_uint8 w ((n lsr 16) land 0xff);
  put_uint16 w (n land 0xffff)

let put_uint48 w n =
  put_uint16 w ((n lsr 32) land 0xffff);
  Buffer.add_int32_be w (Int32.of_int (n land 0xffffffff))

(* The length of a vector is only known once its contents are written, so they
   go into a buffer of their own first. Vectors nest a few levels deep at most,
   and the messages are small. *)
let vector put_length w f =
  let inner = writer () in
  f inner;
  put_length w (Buffer.length inner);
  Buffer.add_buffer w inner

let put_vector8 w f = vector put_uint8 w f
let put_vector16 w f = vector put_uint16 w f
let put_vector24 w f = vector put_uint24 w f

(** The common case of a vector whose contents are already serialised. *)
let put_vector8_string w s = put_vector8 w (fun w -> put_string w s)
let put_vector16_string w s = put_vector16 w (fun w -> put_string w s)
let put_vector24_string w s = put_vector24 w (fun w -> put_string w s)
