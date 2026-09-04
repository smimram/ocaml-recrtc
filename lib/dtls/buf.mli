(** Reading and writing the length-prefixed byte layout TLS is described in.

    TLS specifies its structures as fixed-width integers and vectors carrying
    their length in a 1-, 2- or 3-byte prefix; having those as combinators
    keeps the message codecs close to the notation of the RFCs. *)

exception Truncated

(** {1 Reading} *)

type reader

val reader : ?position:int -> string -> reader
val remaining : reader -> int
val at_end : reader -> bool

(** Every reader below raises {!Truncated} if the input is too short. *)

val take : reader -> int -> string
val uint8 : reader -> int
val uint16 : reader -> int
val uint24 : reader -> int

val uint48 : reader -> int
(** A 48-bit record sequence number; it fits an OCaml int. *)

val vector8 : reader -> string
val vector16 : reader -> string
val vector24 : reader -> string

val sub_vector16 : reader -> reader
(** A reader over the contents of a vector, for structures nested inside one. *)

val list_of : reader -> (reader -> 'a) -> 'a list
(** Read until the reader is exhausted, collecting the results. *)

(** {1 Writing} *)

type writer = Buffer.t

val writer : unit -> writer
val contents : writer -> string
val put_string : writer -> string -> unit
val put_uint8 : writer -> int -> unit
val put_uint16 : writer -> int -> unit
val put_uint24 : writer -> int -> unit
val put_uint48 : writer -> int -> unit

(** A vector's length is only known once its contents are written, so they go
    into a buffer of their own first. *)

val put_vector8 : writer -> (writer -> unit) -> unit
val put_vector16 : writer -> (writer -> unit) -> unit
val put_vector24 : writer -> (writer -> unit) -> unit
val put_vector8_string : writer -> string -> unit
val put_vector16_string : writer -> string -> unit
val put_vector24_string : writer -> string -> unit
