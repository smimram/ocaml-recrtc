(** Ogg pages (RFC 3533).

    A page carries whole or partial packets, split into segments of at most 255
    bytes; a segment shorter than that ends a packet, which is why a packet
    whose length is a multiple of 255 needs a trailing empty segment. *)

type flag = Continued | Beginning | End

val maximum_segments : int
(** How many segments one page may carry. *)

val segments : int -> int
(** How many segments a packet of this length occupies. *)

val serialize :
  flags:flag list ->
  granule:int64 ->
  serial:int32 ->
  page_number:int ->
  string list ->
  string
(** One page holding the given packets whole, checksum included.

    @raise Invalid_argument
      if the packets need more than {!maximum_segments} segments. *)
