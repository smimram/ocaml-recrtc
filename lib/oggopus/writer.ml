(** Writing an Ogg Opus file (RFC 7845) from the Opus packets of an RTP stream.

    The packets are written exactly as they arrived: they are already the Opus
    packets a decoder expects, so nothing is decoded or re-encoded. What the
    container needs beyond them is a granule position, which the RTP timestamp
    supplies directly — it counts the same 48 kHz samples that Ogg does. *)

let sample_rate = 48000

(* Every Opus decoder runs at 48 kHz whatever the encoder chose, so a packet's
   duration in granule units follows from its table-of-contents byte alone
   (RFC 6716 §3.1). *)
let samples packet =
  if packet = "" then 0
  else
    let toc = Char.code packet.[0] in
    let configuration = toc lsr 3 in
    let frame =
      if configuration < 12 then [| 480; 960; 1920; 2880 |].(configuration land 3)
      else if configuration < 16 then [| 480; 960 |].(configuration land 1)
      else [| 120; 240; 480; 960 |].(configuration land 3)
    in
    let frames =
      match toc land 3 with
      | 0 -> 1
      | 1 | 2 -> 2
      | _ -> if String.length packet < 2 then 1 else Char.code packet.[1] land 0x3f
    in
    frame * frames

(** Whether a packet carries two channels, from the stereo flag of its
    table-of-contents byte. A browser encoding a mono microphone sends mono
    packets whatever its offer said about the channel count, and the header of
    the file has to describe what the packets actually decode to. *)
let channels packet =
  if packet = "" then 1 else if Char.code packet.[0] land 0x04 = 0 then 1 else 2

(* Headers (RFC 7845 §5) --------------------------------------------------- *)

let add_uint16_le buffer n =
  Buffer.add_uint8 buffer (n land 0xff);
  Buffer.add_uint8 buffer ((n lsr 8) land 0xff)

let add_uint32_le buffer n =
  add_uint16_le buffer (n land 0xffff);
  add_uint16_le buffer ((n lsr 16) land 0xffff)

let head ~channels ~pre_skip =
  let buffer = Buffer.create 19 in
  Buffer.add_string buffer "OpusHead";
  Buffer.add_uint8 buffer 1 (* version *);
  Buffer.add_uint8 buffer channels;
  add_uint16_le buffer pre_skip;
  add_uint32_le buffer sample_rate (* of the original input, informational *);
  add_uint16_le buffer 0 (* output gain *);
  Buffer.add_uint8 buffer 0 (* channel mapping family: mono or stereo *);
  Buffer.contents buffer

let tags ~vendor ~comments =
  let buffer = Buffer.create 64 in
  let string s =
    add_uint32_le buffer (String.length s);
    Buffer.add_string buffer s
  in
  Buffer.add_string buffer "OpusTags";
  string vendor;
  add_uint32_le buffer (List.length comments);
  List.iter (fun (name, value) -> string (name ^ "=" ^ value)) comments;
  Buffer.contents buffer

(* The stream ------------------------------------------------------------- *)

type t = {
  channel : out_channel;
  serial : int32;
  pre_skip : int;
  mutable page_number : int;
  (* The timestamp the stream started at, against which granule positions are
     measured, and the last one seen, to notice the 32-bit clock wrapping. *)
  mutable origin : int64 option;
  mutable last_timestamp : int32;
  mutable wraps : int64;
  mutable granule : int64;  (** at the end of the last buffered packet *)
  mutable packets : string list;  (** buffered for the current page, reversed *)
  mutable segments : int;
}

(* A page may hold 255 segments at most, and there is little point filling it
   to the brim: a smaller page loses less audio if the file is truncated. *)
let segments_per_page = 200

let create ?(channels = 2) ?(pre_skip = 312) ?(vendor = "recrtc")
    ?(comments = []) path =
  let channel = open_out_bin path in
  let t =
    {
      channel;
      serial = Random.int32 Int32.max_int;
      pre_skip;
      page_number = 0;
      origin = None;
      last_timestamp = 0l;
      wraps = 0L;
      granule = 0L;
      packets = [];
      segments = 0;
    }
  in
  (* The two headers each take a page of their own, the first marked as the
     beginning of the stream (RFC 7845 §3). *)
  let page ?(flags = []) packet =
    output_string channel
      (Page.serialize ~flags ~granule:0L ~serial:t.serial ~page_number:t.page_number
         [ packet ]);
    t.page_number <- t.page_number + 1
  in
  page ~flags:[ Page.Beginning ] (head ~channels ~pre_skip);
  page (tags ~vendor ~comments);
  t

let flush_page ?(flags = []) t =
  if t.packets <> [] then begin
    output_string t.channel
      (Page.serialize ~flags ~granule:t.granule ~serial:t.serial
         ~page_number:t.page_number (List.rev t.packets));
    (* Each page reaches the disk as it is finished: a recording interrupted by
       a crash is then still a playable file, short of its last page. *)
    flush t.channel;
    t.page_number <- t.page_number + 1;
    t.packets <- [];
    t.segments <- 0
  end

(** The stream's own timeline, in 48 kHz samples, from an RTP timestamp that
    wraps every day or so. *)
let unsigned timestamp = Int64.logand (Int64.of_int32 timestamp) 0xFFFFFFFFL

let elapsed t timestamp =
  (* The clock wrapped if the new timestamp is far enough behind the last one;
     a small step backwards is only a packet arriving out of order. *)
  if
    Int32.unsigned_compare timestamp t.last_timestamp < 0
    && Int64.sub (unsigned t.last_timestamp) (unsigned timestamp) > 0x40000000L
  then t.wraps <- Int64.add t.wraps 0x100000000L;
  t.last_timestamp <- timestamp;
  let absolute = Int64.add t.wraps (unsigned timestamp) in
  match t.origin with
  | Some origin -> Int64.sub absolute origin
  | None ->
      t.origin <- Some absolute;
      0L

(** Append one Opus packet, taken from an RTP packet with the given timestamp.
    Packets must be given in order. *)
let write t ~timestamp packet =
  let position = elapsed t timestamp in
  let granule =
    Int64.add (Int64.of_int t.pre_skip) (Int64.add position (Int64.of_int (samples packet)))
  in
  (* A page's granule position is that of the last packet finishing in it, so
     the pending packets are flushed before the count moves on. *)
  let needed = Page.segments (String.length packet) in
  if t.segments + needed > segments_per_page then flush_page t;
  t.packets <- packet :: t.packets;
  t.segments <- t.segments + needed;
  t.granule <- granule

let close t =
  (* The last page must be marked, or a decoder cannot tell the file from a
     truncated one. *)
  if t.packets = [] then begin
    (* Nothing pending: an empty terminating page still carries the flag. *)
    output_string t.channel
      (Page.serialize ~flags:[ Page.End ] ~granule:t.granule ~serial:t.serial
         ~page_number:t.page_number [ "" ]);
    t.page_number <- t.page_number + 1
  end
  else flush_page ~flags:[ Page.End ] t;
  close_out t.channel

let duration t = Int64.to_float t.granule /. float_of_int sample_rate
