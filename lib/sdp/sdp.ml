(** Minimal SDP support for a WebRTC receiver.

    We only ever deal with the shape of session a browser produces for a
    microphone and a camera, so the parser is deliberately partial: it looks
    for the attributes we need and ignores everything else. *)

type direction = Sendrecv | Sendonly | Recvonly | Inactive

let direction_of_string = function
  | "sendrecv" -> Some Sendrecv
  | "sendonly" -> Some Sendonly
  | "recvonly" -> Some Recvonly
  | "inactive" -> Some Inactive
  | _ -> None

let string_of_direction = function
  | Sendrecv -> "sendrecv"
  | Sendonly -> "sendonly"
  | Recvonly -> "recvonly"
  | Inactive -> "inactive"

(** A codec as described by [a=rtpmap] and its optional [a=fmtp]. *)
type codec = {
  payload_type : int;
  name : string;
  clock_rate : int;
  channels : int;
  fmtp : string option;
}

(** One media section of the offer, with the codec we chose to receive on it —
    [None] for a section we have nothing to offer, whose [m=] line is kept so
    that the answer can echo it back rejected. *)
type media = {
  mid : string;
  kind : string;
  line : string;
  codec : codec option;
  direction : direction;
}

(** Everything we need out of an offer. Session-level [a=ice-ufrag] and friends
    are folded into the media descriptions, media level winning. *)
type offer = {
  media : media list;
  ice_ufrag : string;
  ice_pwd : string;
  fingerprint : string * string;  (** algorithm, colon-separated hex *)
  setup : string;
  rtcp_mux : bool;
}

let codec offer kind =
  List.find_map
    (fun media -> if media.kind = kind then media.codec else None)
    offer.media

exception Invalid of string

let invalid fmt = Printf.ksprintf (fun s -> raise (Invalid s)) fmt

(* Parsing ---------------------------------------------------------------- *)

let lines s =
  String.split_on_char '\n' s
  |> List.map (fun l ->
         let n = String.length l in
         if n > 0 && l.[n - 1] = '\r' then String.sub l 0 (n - 1) else l)
  |> List.filter (fun l -> l <> "")

(* Split "type=value" into ('type', "value"). *)
let field line =
  if String.length line < 2 || line.[1] <> '=' then invalid "bad line: %s" line
  else (line.[0], String.sub line 2 (String.length line - 2))

(* Split "name:value" into ("name", Some "value"); flag attributes such as
   "rtcp-mux" have no value. *)
let attribute value =
  match String.index_opt value ':' with
  | None -> (value, None)
  | Some i ->
      ( String.sub value 0 i,
        Some (String.sub value (i + 1) (String.length value - i - 1)) )

let words = String.split_on_char ' '

let int_of_string_exn what s =
  match int_of_string_opt s with
  | Some n -> n
  | None -> invalid "expected an integer for %s, got %S" what s

(* An m-section: the m= line's own value plus the attributes that follow it. *)
type section = {
  kind : string;
  line : string;  (** the whole m= value, for echoing a rejection back *)
  attributes : (string * string option) list;
}

let sections sdp =
  let session, media =
    List.fold_left
      (fun (session, media) line ->
        match field line with
        | 'm', value ->
            let kind = match words value with k :: _ -> k | [] -> "" in
            (session, { kind; line = value; attributes = [] } :: media)
        | 'a', value -> (
            let a = attribute value in
            match media with
            | [] -> (a :: session, [])
            | m :: ms -> (session, { m with attributes = a :: m.attributes } :: ms))
        | _ -> (session, media))
      ([], []) (lines sdp)
  in
  (* Attributes accumulated in reverse; media sections see session-level
     attributes as a fallback, hence appending them last. *)
  let session = List.rev session in
  List.rev_map
    (fun m -> { m with attributes = List.rev m.attributes @ session })
    media

let get section name = List.assoc_opt name section.attributes

let get_value section name =
  match get section name with
  | Some (Some v) -> Some v
  | Some None | None -> None

let require section name =
  match get_value section name with
  | Some v -> v
  | None -> invalid "missing a=%s" name

let has section name = List.mem_assoc name section.attributes

(* All values for a repeated attribute, in order of appearance. *)
let get_all section name =
  List.filter_map
    (fun (n, v) -> if n = name then v else None)
    section.attributes

let parse_rtpmap ~fmtps value =
  (* "111 opus/48000/2" *)
  match words value with
  | [ pt; description ] -> (
      let payload_type = int_of_string_exn "payload type" pt in
      let fmtp =
        List.find_map
          (fun fmtp ->
            match String.index_opt fmtp ' ' with
            | Some i when String.sub fmtp 0 i = pt ->
                Some (String.sub fmtp (i + 1) (String.length fmtp - i - 1))
            | _ -> None)
          fmtps
      in
      match String.split_on_char '/' description with
      | [ name; rate ] ->
          Some
            {
              payload_type;
              name;
              clock_rate = int_of_string_exn "clock rate" rate;
              channels = 1;
              fmtp;
            }
      | [ name; rate; channels ] ->
          Some
            {
              payload_type;
              name;
              clock_rate = int_of_string_exn "clock rate" rate;
              channels = int_of_string_exn "channel count" channels;
              fmtp;
            }
      | _ -> None)
  | _ -> None

let parse_fingerprint value =
  match String.index_opt value ' ' with
  | Some i ->
      ( String.lowercase_ascii (String.sub value 0 i),
        String.uppercase_ascii
          (String.sub value (i + 1) (String.length value - i - 1)) )
  | None -> invalid "bad a=fingerprint: %S" value

(* Choosing a codec ------------------------------------------------------- *)

(* A section lists far more than the stream itself: retransmissions, redundancy
   and forward error correction each take a payload type of their own, and a
   browser offers several video codecs at once. We pick one thing to receive
   per section and ignore the rest, which is why the media loop can filter on
   the payload type alone. *)

let codecs section =
  let fmtps = get_all section "fmtp" in
  List.filter_map (parse_rtpmap ~fmtps) (get_all section "rtpmap")

(* Encoding names are case-insensitive (RFC 4566 §6), and browsers disagree
   on the case they write: "opus" but "VP8". They are matched accordingly, and
   the answer echoes back the spelling the offer used rather than one of our
   own. *)
let named codec name = String.lowercase_ascii codec.name = name
let first_named codecs name = List.find_opt (fun c -> named c name) codecs

(* H.264 is offered twice over, once for each packetization mode. Mode 1 is
   what a browser actually sends and the only one that can fragment a picture
   across datagrams; mode 0 would silently drop every frame larger than an
   MTU (RFC 6184 §6.2). *)
let fragmentable codec =
  match codec.fmtp with
  | None -> false
  | Some fmtp ->
      List.exists
        (fun parameter -> String.trim parameter = "packetization-mode=1")
        (String.split_on_char ';' fmtp)

let choose_video codecs =
  match first_named codecs "vp8" with
  | Some vp8 -> Some vp8
  | None -> (
      let h264 = List.filter (fun c -> named c "h264") codecs in
      match List.find_opt fragmentable h264 with
      | Some codec -> Some codec
      | None -> None)

let choose section =
  let codecs = codecs section in
  match section.kind with
  | "audio" -> first_named codecs "opus"
  | "video" -> choose_video codecs
  | _ -> None

let parse_offer sdp =
  let sections = sections sdp in
  (* Under BUNDLE every section carries the same transport parameters, so the
     first that has them speaks for all. *)
  let transport =
    match List.filter (fun s -> get_value s "ice-ufrag" <> None) sections with
    | s :: _ -> s
    | [] -> invalid "no media section carries a=ice-ufrag"
  in
  let media =
    List.map
      (fun section ->
        {
          mid = (match get_value section "mid" with Some m -> m | None -> "0");
          kind = section.kind;
          line = section.line;
          codec = choose section;
          direction =
            List.find_map
              (fun (name, _) -> direction_of_string name)
              section.attributes
            |> Option.value ~default:Sendrecv;
        })
      sections
  in
  if not (List.exists (fun m -> m.codec <> None) media) then
    invalid
      "the offer proposes nothing we can receive: Opus for audio, VP8 or \
       H.264 for video";
  {
    media;
    ice_ufrag = require transport "ice-ufrag";
    ice_pwd = require transport "ice-pwd";
    fingerprint = parse_fingerprint (require transport "fingerprint");
    setup =
      (match get_value transport "setup" with Some s -> s | None -> "actpass");
    rtcp_mux = has transport "rtcp-mux";
  }

(* Generation ------------------------------------------------------------- *)

(** The priority of a host candidate (RFC 8445 §5.1.2.1). The type preference
    of a host candidate is 126 and the component is always 1 here, so only the
    local preference distinguishes ours; [rank] counts down from the address we
    would rather be reached on. *)
let host_priority rank =
  let local_preference = max 0 (65535 - rank) in
  (126 * 0x1000000) + (local_preference * 256) + 255

(** The answer to [offer]: we are an ICE-lite, DTLS-passive, receive-only
    endpoint reachable at [port] on each of [addresses], most preferred first,
    with every section we accepted bundled onto that one transport.

    Several are worth offering because the peer pairs its own candidates with
    ours by address family and route: a browser on the same machine as the
    server has no loopback candidate of its own to pair with a loopback one of
    ours, and would find nothing to check against. *)
let answer ~offer ~addresses ~port ~ice_ufrag ~ice_pwd ~fingerprint () =
  let ip =
    match addresses with
    | ip :: _ -> ip
    | [] -> invalid_arg "Sdp.answer: no address to advertise"
  in
  let buffer = Buffer.create 1024 in
  let line fmt = Printf.ksprintf (fun s -> Buffer.add_string buffer (s ^ "\r\n")) fmt in
  let algorithm, digest = fingerprint in
  let accepted = List.filter (fun m -> m.codec <> None) offer.media in
  line "v=0";
  line "o=- %Lu 1 IN IP4 127.0.0.1" (Random.int64 Int64.max_int);
  line "s=-";
  line "t=0 0";
  line "a=ice-lite";
  (* Only the sections we accepted share the transport; a rejected one is not
     part of the group. *)
  line "a=group:BUNDLE %s"
    (String.concat " " (List.map (fun m -> m.mid) accepted));
  line "a=msid-semantic: WMS";
  (* An answer has one section per section of the offer, in the same order:
     that correspondence is how the two sides agree on what each is about
     (RFC 3264 §6). A section we cannot use is given a port of zero rather
     than left out. *)
  List.iter
    (fun (media : media) ->
      let protocol =
        match words media.line with _ :: _ :: protocol :: _ -> protocol
        | _ -> "UDP/TLS/RTP/SAVPF"
      in
      match media.codec with
      | None ->
          (* Rejected, but still described: the formats are echoed because a
             section with an empty format list is malformed. *)
          let formats =
            match words media.line with
            | _ :: _ :: _ :: formats when formats <> [] -> String.concat " " formats
            | _ -> "0"
          in
          line "m=%s 0 %s %s" media.kind protocol formats;
          line "c=IN IP4 %s" ip;
          line "a=mid:%s" media.mid;
          line "a=inactive"
      | Some codec ->
          let pt = codec.payload_type in
          line "m=%s %d %s %d" media.kind port protocol pt;
          line "c=IN IP4 %s" ip;
          line "a=rtcp:%d IN IP4 %s" port ip;
          line "a=ice-ufrag:%s" ice_ufrag;
          line "a=ice-pwd:%s" ice_pwd;
          line "a=fingerprint:%s %s" algorithm digest;
          line "a=setup:passive";
          line "a=mid:%s" media.mid;
          line "a=recvonly";
          line "a=rtcp-mux";
          (match media.kind with
          | "audio" ->
              line "a=rtpmap:%d %s/%d/%d" pt codec.name codec.clock_rate
                codec.channels
          | _ -> line "a=rtpmap:%d %s/%d" pt codec.name codec.clock_rate);
          (* Echoed verbatim: the browser chose these parameters for its own
             encoder, and an answer that changed them would be asking it to
             encode differently. *)
          Option.iter (fun fmtp -> line "a=fmtp:%d %s" pt fmtp) codec.fmtp;
          List.iteri
            (fun rank address ->
              line "a=candidate:%d 1 udp %d %s %d typ host" (rank + 1)
                (host_priority rank) address port)
            addresses;
          line "a=end-of-candidates")
    offer.media;
  Buffer.contents buffer
