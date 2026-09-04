(* The bytes of an integer, most significant first, dropping the leading zero
   bytes but never the whole thing. *)
let bytes_of_int ?width value =
  let needed =
    match width with
    | Some width -> width
    | None ->
        let rec count n shift =
          if shift >= 64 || value lsr shift = 0 then max 1 n
          else count (n + 1) (shift + 8)
        in
        count 0 0
  in
  String.init needed (fun i -> Char.chr ((value lsr (8 * (needed - 1 - i))) land 0xff))

let id value = bytes_of_int value

(* A variable-width integer is a marker bit whose position gives the width,
   then the value in the bits below it (RFC 8794 §4.4). A value of all ones is
   reserved to mean "unknown", so each width holds one less than it looks. *)
let vint_width value =
  let rec search width =
    if width > 8 then invalid_arg "Matroska.Ebml: value too large for a variable-width integer"
    else if value < (1 lsl (7 * width)) - 1 then width
    else search (width + 1)
  in
  search 1

let vint_of_width value width =
  let marker = 1 lsl (8 - width) in
  bytes_of_int ~width (value lor (marker lsl (8 * (width - 1))))

let vint value = vint_of_width value (vint_width value)
let size value = vint value
let reserved_size value = vint_of_width value 8
let unknown_size = "\x01\xff\xff\xff\xff\xff\xff\xff"

let element id_ contents = id id_ ^ size (String.length contents) ^ contents
let master id_ contents = element id_ (String.concat "" contents)
let uint id_ value = element id_ (bytes_of_int value)
(* Through Int64 rather than [bytes_of_int]: a double's bit pattern uses all
   sixty-four bits, and OCaml's int has only sixty-three. *)
let float_bytes value =
  let bits = Int64.bits_of_float value in
  String.init 8 (fun i ->
      Char.chr
        (Int64.to_int (Int64.shift_right_logical bits (8 * (7 - i))) land 0xff))

let float id_ value = element id_ (float_bytes value)
let string id_ value = element id_ value
let binary id_ value = element id_ value
