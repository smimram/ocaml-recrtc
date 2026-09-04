type t = string

let version = 2
let psfb = 206
let pli_format = 1
let header_words length = (length / 4) - 1

let pli ~sender ~media =
  let packet = Bytes.create 12 in
  Bytes.set_uint8 packet 0 ((version lsl 6) lor pli_format);
  Bytes.set_uint8 packet 1 psfb;
  Bytes.set_uint16_be packet 2 (header_words (Bytes.length packet));
  Bytes.set_int32_be packet 4 sender;
  Bytes.set_int32_be packet 8 media;
  Bytes.unsafe_to_string packet
