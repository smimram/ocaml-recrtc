exception Invalid of string

let invalid fmt = Printf.ksprintf (fun message -> raise (Invalid message)) fmt

(* The descriptor is one required byte,

       0 1 2 3 4 5 6 7
      +-+-+-+-+-+-+-+-+
      |I|P|L|F|B|E|V|Z|

   where each of I, L, F and V admits a further field after it
   (draft-ietf-payload-vp9-16 §4.2). Nothing here reads those fields: a single
   layer is all we record, so their only interest is how many bytes they take
   before the frame data starts. *)

let byte payload offset =
  if offset >= String.length payload then invalid "truncated VP9 descriptor";
  Char.code payload.[offset]

(* The scalability structure, present when V is set: a byte counting the
   spatial layers, optionally their sizes, and optionally a picture group whose
   entries each carry a variable number of reference differences (§4.2.1). *)
let scalability_length payload offset =
  let first = byte payload offset in
  let layers = ((first lsr 5) land 0x07) + 1 in
  let resolutions = first land 0x10 <> 0 in
  let picture_group = first land 0x08 <> 0 in
  let offset = offset + 1 in
  (* Each resolution is a sixteen-bit width and height. *)
  let offset = if resolutions then offset + (4 * layers) else offset in
  if not picture_group then offset
  else begin
    let count = byte payload offset in
    let offset = ref (offset + 1) in
    for _ = 1 to count do
      let entry = byte payload !offset in
      (* Two bits say how many one-byte differences follow the entry. *)
      let references = (entry lsr 2) land 0x03 in
      offset := !offset + 1 + references
    done;
    !offset
  end

let descriptor_length payload =
  let first = byte payload 0 in
  let picture_id = first land 0x80 <> 0 in
  let predicted = first land 0x40 <> 0 in
  let layers = first land 0x20 <> 0 in
  let flexible = first land 0x10 <> 0 in
  let scalability = first land 0x02 <> 0 in
  let offset = 1 in
  let offset =
    if not picture_id then offset
      (* The M bit extends the identifier from seven bits to fifteen. *)
    else if byte payload offset land 0x80 <> 0 then offset + 2
    else offset + 1
  in
  let offset =
    if not layers then offset
      (* TL0PICIDX follows the layer indices, but only in non-flexible mode,
         where it is what orders the temporal base layer. *)
    else if flexible then offset + 1
    else offset + 2
  in
  let offset =
    if not (predicted && flexible) then offset
    else begin
      (* Up to three reference differences, each keeping the low bit set while
         another follows. *)
      let offset = ref offset in
      let continues = ref true and read = ref 0 in
      while !continues do
        if !read = 3 then invalid "too many VP9 reference differences";
        continues := byte payload !offset land 0x01 <> 0;
        incr offset;
        incr read
      done;
      !offset
    end
  in
  let offset = if scalability then scalability_length payload offset else offset in
  if String.length payload < offset then invalid "truncated VP9 descriptor";
  offset

let payload data =
  let offset = descriptor_length data in
  String.sub data offset (String.length data - offset)

let starts_frame data =
  (* B marks the first packet of a frame. With more than one spatial layer it
     is set once per layer; a single layer is all we ever negotiate. *)
  String.length data >= 1 && Char.code data.[0] land 0x08 <> 0

(* The uncompressed header a frame opens with (VP9 bitstream specification
   §6.2). Only as much of it is read as tells a keyframe from the rest, and
   for a keyframe reaches the frame size that ends it. Anything unexpected
   raises, and is reported as "not a keyframe we can read". *)

exception Truncated

type reader = { data : string; mutable bit : int }

let bit r =
  let index = r.bit / 8 in
  if index >= String.length r.data then raise Truncated;
  let value = (Char.code r.data.[index] lsr (7 - (r.bit mod 8))) land 1 in
  r.bit <- r.bit + 1;
  value

let bits r n =
  let value = ref 0 in
  for _ = 1 to n do
    value := (!value lsl 1) lor bit r
  done;
  !value

(* §6.2.2: the colour syntax stands between the sync code and the frame size,
   and its length depends on the profile and on the colour space. *)
let skip_color_config r ~profile =
  if profile >= 2 then ignore (bit r) (* ten_or_twelve_bit *);
  let color_space = bits r 3 in
  if color_space <> 7 (* CS_RGB *) then begin
    ignore (bit r) (* color_range *);
    (* The odd profiles carry the subsampling explicitly, and a reserved bit
       after it. *)
    if profile = 1 || profile = 3 then ignore (bits r 3)
  end
  else if profile = 1 || profile = 3 then ignore (bit r)

let uncompressed_header data =
  let r = { data; bit = 0 } in
  if bits r 2 <> 2 then raise Truncated (* the frame marker *);
  let low = bit r in
  let high = bit r in
  let profile = (high lsl 1) lor low in
  if profile = 3 then ignore (bit r) (* reserved *);
  (* A frame that only shows one already decoded says nothing more. *)
  if bit r = 1 then None
  else begin
    let key = bit r = 0 in
    let _show_frame = bit r in
    let _error_resilient = bit r in
    if not key then None
    else begin
      (* The sync code, read a byte at a time: the reader advances as a side
         effect, so the three cannot share one expression. *)
      let first = bits r 8 in
      let second = bits r 8 in
      let third = bits r 8 in
      if (first, second, third) <> (0x49, 0x83, 0x42) then raise Truncated;
      skip_color_config r ~profile;
      let width = bits r 16 + 1 in
      let height = bits r 16 + 1 in
      Some (width, height)
    end
  end

let dimensions data =
  match uncompressed_header data with exception _ -> None | size -> size

(* A keyframe is exactly the frame whose header can be read this far — an
   interframe stops before the sync code, and so does anything malformed — so
   the two questions have one answer. *)
let keyframe data = dimensions data <> None
