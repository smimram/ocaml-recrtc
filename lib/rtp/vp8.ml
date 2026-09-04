exception Invalid of string

let invalid fmt = Printf.ksprintf (fun message -> raise (Invalid message)) fmt

(* The descriptor is one required byte,

       0 1 2 3 4 5 6 7
      +-+-+-+-+-+-+-+-+
      |X|R|N|S|R| PID |

   followed, when X is set, by an extension byte saying which of four optional
   fields follow it (RFC 7741 §4.2). The picture identifier is one byte or two
   depending on its own top bit; the temporal-layer index and the key index
   share a byte when either is present. *)
let descriptor_length payload =
  let length = String.length payload in
  if length < 1 then invalid "empty VP8 payload";
  let first = Char.code payload.[0] in
  if first land 0x80 = 0 then 1
  else begin
    if length < 2 then invalid "truncated VP8 descriptor";
    let extension = Char.code payload.[1] in
    let picture_id = extension land 0x80 <> 0 in
    let tl0_index = extension land 0x40 <> 0 in
    let temporal = extension land 0x20 <> 0 in
    let key_index = extension land 0x10 <> 0 in
    let offset = 2 in
    let offset =
      if not picture_id then offset
      else begin
        if length < offset + 1 then invalid "truncated VP8 picture identifier";
        (* The M bit extends the identifier from seven bits to fifteen. *)
        if Char.code payload.[offset] land 0x80 <> 0 then offset + 2 else offset + 1
      end
    in
    let offset = if tl0_index then offset + 1 else offset in
    let offset = if temporal || key_index then offset + 1 else offset in
    if length < offset then invalid "truncated VP8 descriptor";
    offset
  end

let partition payload =
  let offset = descriptor_length payload in
  String.sub payload offset (String.length payload - offset)

let starts_frame payload =
  String.length payload >= 1
  &&
  let first = Char.code payload.[0] in
  (* S marks the start of a partition; the index says which, and only the
     first partition starts a frame. *)
  first land 0x10 <> 0 && first land 0x07 = 0

let keyframe data =
  String.length data >= 1 && Char.code data.[0] land 0x01 = 0

(* A keyframe's uncompressed header is the three-byte tag, the three-byte
   start code 9d 01 2a, then the width and height as fourteen-bit little-endian
   values each sharing a sixteen-bit field with a two-bit scale (RFC 6386
   §9.1). *)
let dimensions data =
  if String.length data < 10 || not (keyframe data) then None
  else if String.sub data 3 3 <> "\x9d\x01\x2a" then None
  else
    Some
      ( String.get_uint16_le data 6 land 0x3fff,
        String.get_uint16_le data 8 land 0x3fff )
