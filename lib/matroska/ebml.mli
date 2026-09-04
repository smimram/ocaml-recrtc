(** EBML, the tagged binary encoding Matroska is written in (RFC 8794).

    Everything is an element: an identifier, a length, and either a value or
    more elements. Both the identifier and the length are variable-width
    integers whose leading zeros say how many bytes follow, so an element can
    be skipped by a reader that does not know it. *)

val id : int -> string
(** An element identifier, as the bytes it is conventionally written in — the
    width marker is already part of the value, so [0x1a45dfa3] is four bytes
    and [0xa3] is one. *)

val size : int -> string
(** A length, in as few bytes as it fits in. *)

val reserved_size : int -> string
(** The same, always eight bytes wide, so that a length written before it is
    known can be patched in place afterwards. *)

val unknown_size : string
(** The eight-byte length meaning "until the next element at this level".
    Written for an element still being filled, it leaves a file that is still
    readable if nothing ever closes it. *)

val element : int -> string -> string
(** [element id contents]: the identifier, the length and the contents. *)

val master : int -> string list -> string
(** An element whose contents are other elements. *)

val uint : int -> int -> string
(** An unsigned integer element, in as few bytes as it fits in. *)

val float : int -> float -> string
(** A floating-point element, always the eight-byte form. *)

val float_bytes : float -> string
(** Just the eight bytes of one, for overwriting a value written before it was
    known. *)

val string : int -> string -> string
val binary : int -> string -> string

val vint : int -> string
(** A variable-width integer on its own, for the track number that opens a
    block. *)
