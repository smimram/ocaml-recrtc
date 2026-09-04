(** Ogg pages (RFC 3533).

    A page carries whole or partial packets, split into segments of at most 255
    bytes; a segment shorter than 255 bytes ends a packet, which is why a packet
    whose length is a multiple of 255 needs a trailing empty segment. *)

let capture_pattern = "OggS"
let header_length = 27
let maximum_segments = 255
let segment_length = 255

type flag = Continued | Beginning | End

let int_of_flags flags =
  List.fold_left
    (fun n flag ->
      n lor (match flag with Continued -> 1 | Beginning -> 2 | End -> 4))
    0 flags

(* The Ogg checksum is a CRC-32 with the usual polynomial but, unlike the more
   common variant, without reflection or a final complement. *)
let crc32 =
  let table =
    lazy
      (Array.init 256 (fun n ->
           let r = ref (Int32.shift_left (Int32.of_int n) 24) in
           for _ = 0 to 7 do
             r :=
               if Int32.logand !r 0x80000000l <> 0l then
                 Int32.logxor (Int32.shift_left !r 1) 0x04c11db7l
               else Int32.shift_left !r 1
           done;
           !r))
  in
  fun data ->
    let table = Lazy.force table in
    let crc = ref 0l in
    String.iter
      (fun c ->
        let index =
          Int32.to_int
            (Int32.logand
               (Int32.logxor (Int32.shift_right_logical !crc 24) (Int32.of_int (Char.code c)))
               0xffl)
        in
        crc := Int32.logxor (Int32.shift_left !crc 8) table.(index))
      data;
    !crc

let add_int32_le buffer n =
  for i = 0 to 3 do
    Buffer.add_uint8 buffer (Int32.to_int (Int32.shift_right_logical n (8 * i)) land 0xff)
  done

let add_int64_le buffer n =
  for i = 0 to 7 do
    Buffer.add_uint8 buffer (Int64.to_int (Int64.shift_right_logical n (8 * i)) land 0xff)
  done

(** How many segments a packet of this length occupies. The extra segment for a
    length that is a multiple of 255 is what marks the end of the packet. *)
let segments length = (length / segment_length) + 1

let segment_table packet =
  let length = String.length packet in
  List.init (segments length) (fun i ->
      min segment_length (length - (i * segment_length)))

(** Serialise one page holding [packets] whole. The caller is responsible for
    keeping the total within [maximum_segments] segments. *)
let serialize ~flags ~granule ~serial ~page_number packets =
  let table = List.concat_map segment_table packets in
  if List.length table > maximum_segments then
    invalid_arg "Oggopus.Page.serialize: too many segments for one page";
  let buffer = Buffer.create 4096 in
  Buffer.add_string buffer capture_pattern;
  Buffer.add_uint8 buffer 0 (* stream structure version *);
  Buffer.add_uint8 buffer (int_of_flags flags);
  add_int64_le buffer granule;
  add_int32_le buffer serial;
  add_int32_le buffer (Int32.of_int page_number);
  add_int32_le buffer 0l (* the checksum, filled in below *);
  Buffer.add_uint8 buffer (List.length table);
  List.iter (Buffer.add_uint8 buffer) table;
  List.iter (Buffer.add_string buffer) packets;
  let page = Buffer.to_bytes buffer in
  let checksum = crc32 (Bytes.unsafe_to_string page) in
  let offset = 22 in
  for i = 0 to 3 do
    Bytes.set_uint8 page (offset + i)
      (Int32.to_int (Int32.shift_right_logical checksum (8 * i)) land 0xff)
  done;
  Bytes.unsafe_to_string page
