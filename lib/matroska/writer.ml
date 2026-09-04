(* Element identifiers (RFC 9559 §5). *)
module Id = struct
  let ebml = 0x1a45dfa3
  let ebml_version = 0x4286
  let ebml_read_version = 0x42f7
  let ebml_max_id_length = 0x42f2
  let ebml_max_size_length = 0x42f3
  let doc_type = 0x4282
  let doc_type_version = 0x4287
  let doc_type_read_version = 0x4285
  let segment = 0x18538067
  let info = 0x1549a966
  let timestamp_scale = 0x2ad7b1
  let muxing_app = 0x4d80
  let writing_app = 0x5741
  let duration = 0x4489
  let tracks = 0x1654ae6b
  let track_entry = 0xae
  let track_number = 0xd7
  let track_uid = 0x73c5
  let track_type = 0x83
  let flag_lacing = 0x9c
  let codec_id = 0x86
  let codec_private = 0x63a2
  let codec_delay = 0x56aa
  let seek_pre_roll = 0x56bb
  let video = 0xe0
  let pixel_width = 0xb0
  let pixel_height = 0xba
  let audio = 0xe1
  let sampling_frequency = 0xb5
  let channels = 0x9f
  let cluster = 0x1f43b675
  let timestamp = 0xe7
  let simple_block = 0xa3
end

type codec = Vp8 | Vp9 | H264 of string

let extension = function Vp8 | Vp9 -> ".webm" | H264 _ -> ".mkv"
let doc_type = function Vp8 | Vp9 -> "webm" | H264 _ -> "matroska"

let video_track = 1
let audio_track = 2

(* One tick of every timestamp in the file. A millisecond is as fine as the
   sixteen-bit offset within a cluster can usefully resolve. *)
let timestamp_scale = 1_000_000

(* How long a block waits before being written, in milliseconds of its own
   timeline. The two tracks arrive through jitter buffers of their own and so
   interleave imperfectly; holding them briefly and writing in timestamp order
   costs nothing and spares a player having to sort. *)
let mux_lag = 200

(* A cluster starts afresh at least this often. A block's position within one
   is a signed sixteen-bit millisecond offset, so a cluster could span half a
   minute; keeping them to a second bounds what is lost when a recording is
   cut short, and gives a player somewhere to seek to. *)
let cluster_span = 1000

type block = { at : int; track : int; keyframe : bool; data : string }

type t = {
  channel : out_channel;
  (* Where the lengths left open sit, to be filled in at the end. *)
  mutable segment_length : int;
  mutable duration_value : int;
  mutable cluster : (int * int) option;  (** length offset, timestamp *)
  mutable cluster_blocks : int;
  video_timeline : Rtp.Timeline.t;
  audio_timeline : Rtp.Timeline.t;
  (* The arrival of the first packet of the session, and of each track's
     first, which is what relates the two RTP clocks. *)
  mutable start : float option;
  mutable video_anchor : float option;
  mutable audio_anchor : float option;
  mutable queue : block list;  (** ascending by position *)
  mutable last_at : int;
  mutable duration : int;
}

(* Writing elements whose length is not known yet ------------------------- *)

(* The length is reserved at its widest so that it can be overwritten in
   place, and left as "unknown" until then: a recording that never reaches
   [close] is still a file a player can read to its end. *)
let open_element t id =
  output_string t.channel (Ebml.id id);
  let offset = pos_out t.channel in
  output_string t.channel Ebml.unknown_size;
  offset

let patch t offset contents =
  let resume = pos_out t.channel in
  flush t.channel;
  seek_out t.channel offset;
  output_string t.channel contents;
  flush t.channel;
  seek_out t.channel resume

let close_element t offset =
  patch t offset (Ebml.reserved_size (pos_out t.channel - offset - 8))

(* The headers ------------------------------------------------------------ *)

let header ~codec =
  Ebml.master Id.ebml
    [
      Ebml.uint Id.ebml_version 1;
      Ebml.uint Id.ebml_read_version 1;
      Ebml.uint Id.ebml_max_id_length 4;
      Ebml.uint Id.ebml_max_size_length 8;
      Ebml.string Id.doc_type (doc_type codec);
      Ebml.uint Id.doc_type_version 4;
      Ebml.uint Id.doc_type_read_version 2;
    ]

let video_entry ~codec ~width ~height =
  Ebml.master Id.track_entry
    ([
       Ebml.uint Id.track_number video_track;
       Ebml.uint Id.track_uid video_track;
       Ebml.uint Id.track_type 1;
       (* Lacing packs several frames into one block; nothing here does. *)
       Ebml.uint Id.flag_lacing 0;
       Ebml.string Id.codec_id
         (match codec with
         | Vp8 -> "V_VP8"
         | Vp9 -> "V_VP9"
         | H264 _ -> "V_MPEG4/ISO/AVC");
     ]
    @ (match codec with
      | Vp8 | Vp9 -> []
      | H264 avcc -> [ Ebml.binary Id.codec_private avcc ])
    @ [
        Ebml.master Id.video
          [ Ebml.uint Id.pixel_width width; Ebml.uint Id.pixel_height height ];
      ])

let audio_entry ~channels =
  (* What a decoder discards at the start and after a seek, in nanoseconds
     (RFC 7845 §4 and the Matroska Opus guidelines). *)
  let delay =
    Oggopus.Writer.pre_skip * 1_000_000_000 / Oggopus.Writer.sample_rate
  in
  Ebml.master Id.track_entry
    [
      Ebml.uint Id.track_number audio_track;
      Ebml.uint Id.track_uid audio_track;
      Ebml.uint Id.track_type 2;
      Ebml.uint Id.flag_lacing 0;
      Ebml.string Id.codec_id "A_OPUS";
      (* The very header an Ogg Opus file opens with; Matroska stores it out
         of band instead. *)
      Ebml.binary Id.codec_private
        (Oggopus.Writer.head ~channels ~pre_skip:Oggopus.Writer.pre_skip);
      Ebml.uint Id.codec_delay delay;
      Ebml.uint Id.seek_pre_roll 80_000_000;
      Ebml.master Id.audio
        [
          Ebml.float Id.sampling_frequency
            (float_of_int Oggopus.Writer.sample_rate);
          Ebml.uint Id.channels channels;
        ];
    ]

let create ?(writing_app = "recrtc") ~codec ~width ~height ?audio_channels path =
  let channel = open_out_bin path in
  output_string channel (header ~codec);
  let t =
    {
      channel;
      segment_length = 0;
      duration_value = 0;
      cluster = None;
      cluster_blocks = 0;
      video_timeline = Rtp.Timeline.create ();
      audio_timeline = Rtp.Timeline.create ();
      start = None;
      video_anchor = None;
      audio_anchor = None;
      queue = [];
      last_at = 0;
      duration = 0;
    }
  in
  t.segment_length <- open_element t Id.segment;
  (* The duration is only known at the end, so a full-width zero is written
     now and overwritten then. *)
  let duration = Ebml.float Id.duration 0. in
  let info =
    Ebml.master Id.info
      [
        Ebml.uint Id.timestamp_scale timestamp_scale;
        Ebml.string Id.muxing_app writing_app;
        Ebml.string Id.writing_app writing_app;
        duration;
      ]
  in
  (* Its eight bytes of value end the element, which ends the section. *)
  t.duration_value <- pos_out t.channel + String.length info - 8;
  output_string t.channel info;
  output_string t.channel
    (Ebml.master Id.tracks
       (video_entry ~codec ~width ~height
       :: (match audio_channels with
          | None -> []
          | Some channels -> [ audio_entry ~channels ])));
  flush t.channel;
  t

(* Clusters and blocks ---------------------------------------------------- *)

let close_cluster t =
  match t.cluster with
  | None -> ()
  | Some (offset, _) ->
      close_element t offset;
      t.cluster <- None;
      t.cluster_blocks <- 0

let open_cluster t at =
  close_cluster t;
  let offset = open_element t Id.cluster in
  output_string t.channel (Ebml.uint Id.timestamp at);
  t.cluster <- Some (offset, at)

let emit t block =
  (* Positions only ever move forward: a block that slipped past the mux queue
     is nudged up to the last one rather than made to sit outside its
     cluster. *)
  let at = max block.at t.last_at in
  t.last_at <- at;
  if at > t.duration then t.duration <- at;
  (match t.cluster with
  | Some (_, since)
    when at - since < cluster_span
         && not (block.keyframe && block.track = video_track && t.cluster_blocks > 0)
    -> ()
  | _ -> open_cluster t at);
  let since = match t.cluster with Some (_, since) -> since | None -> at in
  let relative = at - since in
  let payload = Bytes.create 3 in
  Bytes.set_uint16_be payload 0 (relative land 0xffff);
  (* The only flag a simple block carries that matters here: whether the frame
     can be decoded on its own. *)
  Bytes.set_uint8 payload 2 (if block.keyframe then 0x80 else 0x00);
  output_string t.channel
    (Ebml.binary Id.simple_block
       (Ebml.vint block.track ^ Bytes.unsafe_to_string payload ^ block.data));
  t.cluster_blocks <- t.cluster_blocks + 1;
  flush t.channel

let rec insert block = function
  | [] -> [ block ]
  | head :: rest when block.at < head.at -> block :: head :: rest
  | head :: rest -> head :: insert block rest

let drain t ~before =
  let rec loop = function
    | block :: rest when block.at <= before ->
        emit t block;
        loop rest
    | queue -> queue
  in
  t.queue <- loop t.queue

let enqueue t block =
  t.queue <- insert block t.queue;
  drain t ~before:(block.at - mux_lag)

(* Where a track's packet falls on the file's single timeline: how far its own
   clock has run since its first packet, plus how much later than the session
   that first packet arrived. *)
let position t ~anchor ~arrival ~ticks ~rate =
  let start =
    match t.start with
    | Some start -> start
    | None ->
        t.start <- Some arrival;
        arrival
  in
  let offset = int_of_float ((anchor -. start) *. 1000.) in
  offset + Int64.to_int (Int64.div (Int64.mul ticks 1000L) (Int64.of_int rate))

let write_video t ~arrival ~timestamp ~keyframe data =
  let anchor =
    match t.video_anchor with
    | Some anchor -> anchor
    | None ->
        t.video_anchor <- Some arrival;
        arrival
  in
  let ticks = Rtp.Timeline.elapsed t.video_timeline timestamp in
  let at = position t ~anchor ~arrival ~ticks ~rate:90000 in
  enqueue t { at; track = video_track; keyframe; data }

let write_audio t ~arrival ~timestamp data =
  let anchor =
    match t.audio_anchor with
    | Some anchor -> anchor
    | None ->
        t.audio_anchor <- Some arrival;
        arrival
  in
  let ticks = Rtp.Timeline.elapsed t.audio_timeline timestamp in
  let at = position t ~anchor ~arrival ~ticks ~rate:Oggopus.Writer.sample_rate in
  (* Every Opus packet stands on its own. *)
  enqueue t { at; track = audio_track; keyframe = true; data }

let duration t = float_of_int t.duration /. 1000.

let close t =
  drain t ~before:max_int;
  close_cluster t;
  patch t t.duration_value (Ebml.float_bytes (float_of_int t.duration));
  close_element t t.segment_length;
  close_out t.channel
