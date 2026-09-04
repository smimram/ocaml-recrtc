(** EBML encoding, and the shape of the file the writer produces. *)

open Testlib

module Ebml = Matroska.Ebml

(* Walk a file, checking that every element's length reaches exactly the end of
   its contents, and collect the identifiers seen at the top of each level. *)
let rec walk ?(depth = 0) ~masters data offset stop acc =
  if offset >= stop then acc
  else begin
    (* Identifiers are one to four bytes, the leading one bits of the first
       giving the width. *)
    let first = Char.code data.[offset] in
    let id_width =
      if first land 0x80 <> 0 then 1
      else if first land 0x40 <> 0 then 2
      else if first land 0x20 <> 0 then 3
      else 4
    in
    let id = ref 0 in
    for i = 0 to id_width - 1 do
      id := (!id lsl 8) lor Char.code data.[offset + i]
    done;
    let marker = Char.code data.[offset + id_width] in
    let size_width =
      let rec width n = if marker land (0x80 lsr (n - 1)) <> 0 then n else width (n + 1) in
      width 1
    in
    let size = ref (marker land ((0x80 lsr (size_width - 1)) - 1)) in
    for i = 1 to size_width - 1 do
      size := (!size lsl 8) lor Char.code data.[offset + id_width + i]
    done;
    let contents = offset + id_width + size_width in
    if contents + !size > stop then failwith "an element runs past its parent";
    let acc = (depth, !id) :: acc in
    let acc =
      if List.mem !id masters then
        walk ~depth:(depth + 1) ~masters data contents (contents + !size) acc
      else acc
    in
    walk ~depth ~masters data (contents + !size) stop acc
  end

let read path =
  let channel = open_in_bin path in
  let length = in_channel_length channel in
  let data = really_input_string channel length in
  close_in channel;
  data

let run () =
  suite "ebml";

  check_string "an identifier keeps its own bytes" ~expected:(hex "1a45dfa3")
    (Ebml.id 0x1a45dfa3);
  (* A length is a marker bit whose position gives the width; a value of all
     ones is reserved, so each width stops one short. *)
  check_string "zero" ~expected:(hex "80") (Ebml.size 0);
  check_string "the largest one byte holds" ~expected:(hex "fe") (Ebml.size 126);
  check_string "one more needs two" ~expected:(hex "407f") (Ebml.size 127);
  check_string "and so does 128" ~expected:(hex "4080") (Ebml.size 128);
  check_string "the largest two bytes hold" ~expected:(hex "7ffe")
    (Ebml.size 16382);
  check_string "one more needs three" ~expected:(hex "203fff")
    (Ebml.size 16383);
  check_string "a reserved length is always eight bytes"
    ~expected:(hex "0100000000000064") (Ebml.reserved_size 100);
  check "so it is the width of an unknown one"
    (String.length Ebml.unknown_size = 8);

  check_string "an integer drops its leading zeros"
    ~expected:(hex "4286" ^ hex "81" ^ hex "01")
    (Ebml.uint 0x4286 1);
  check_string "and keeps what it needs"
    ~expected:(hex "2ad7b1" ^ hex "83" ^ hex "0f4240")
    (Ebml.uint 0x2ad7b1 1_000_000);
  (* All sixty-four bits of a double, which is more than an OCaml int holds. *)
  check_string "a double is written whole"
    ~expected:(hex "4489" ^ hex "88" ^ hex "408f400000000000")
    (Ebml.float 0x4489 1000.);
  check_string "and a negative one too" ~expected:(hex "c000000000000000")
    (Ebml.float_bytes (-2.));

  suite "matroska";

  let path = Filename.temp_file "recrtc-test" ".webm" in
  let writer =
    Matroska.Writer.create ~codec:Matroska.Writer.Vp8 ~width:640 ~height:480
      ~audio_channels:1 path
  in
  (* A second of media on both tracks, arriving interleaved and a little out of
     order across them, as two jitter buffers deliver it. *)
  let arrival = 1000. in
  Matroska.Writer.write_video writer ~arrival ~timestamp:0l ~keyframe:true "picture";
  for i = 0 to 49 do
    let at = arrival +. (float_of_int i *. 0.02) in
    Matroska.Writer.write_audio writer ~arrival:at
      ~timestamp:(Int32.of_int (i * 960))
      "opus";
    if i mod 5 = 0 then
      Matroska.Writer.write_video writer ~arrival:at
        ~timestamp:(Int32.of_int (i * 1800))
        ~keyframe:(i = 25) "picture"
  done;
  Matroska.Writer.close writer;
  (* Only after closing: until then the mux queue is still holding the last
     fraction of a second back. *)
  check "the duration follows the media"
    (Matroska.Writer.duration writer > 0.9
    && Matroska.Writer.duration writer < 1.1);

  let data = read path in
  let ids, sound =
    match
      walk
        ~masters:
        [
          0x1a45dfa3 (* EBML *);
          0x18538067 (* Segment *);
          0x1549a966 (* Info *);
          0x1654ae6b (* Tracks *);
          0xae (* TrackEntry *);
          0xe0 (* Video *);
          0xe1 (* Audio *);
          0x1f43b675 (* Cluster *);
        ]
        data 0 (String.length data) []
    with
    | ids -> (List.rev ids, true)
    | exception _ -> ([], false)
  in
  let has depth id = List.mem (depth, id) ids in
  check "every element's length lands where it should" sound;
  check "the file opens with an EBML header" (List.hd ids = (0, 0x1a45dfa3));
  check "and holds one segment" (has 0 0x18538067);
  check "with an information section" (has 1 0x1549a966);
  check "declaring a timestamp scale" (has 2 0x2ad7b1);
  check "and a duration" (has 2 0x4489);
  check "there are tracks" (has 1 0x1654ae6b);
  check "two of them"
    (List.length (List.filter (fun e -> e = (2, 0xae)) ids) = 2);
  check "one with a picture size" (has 4 0xb0 && has 4 0xba);
  check "one with a sampling frequency" (has 4 0xb5);
  check "the audio track has its Opus header" (has 3 0x63a2);
  (* A cluster opens at each keyframe: the first picture and the one halfway
     through. *)
  check "there is a cluster for each keyframe"
    (List.length (List.filter (fun e -> e = (1, 0x1f43b675)) ids) >= 2);
  check "holding blocks"
    (List.length (List.filter (fun e -> e = (2, 0xa3)) ids) > 50);

  (* Nothing may be left unknown once the file is closed: a reader that trusts
     lengths has to find the end where it is told. *)
  let segment = String.index_from data 0 '\x18' in
  check "the segment's length was filled in"
    (String.sub data (segment + 4) 8 <> Ebml.unknown_size);

  (* The duration, in the millisecond ticks the header declared. *)
  let rec find needle from =
    if String.sub data from (String.length needle) = needle then from
    else find needle (from + 1)
  in
  let duration = find (hex "448988") 0 + 3 in
  check "the duration was filled in"
    (Int64.float_of_bits (String.get_int64_be data duration) > 900.);

  Sys.remove path
