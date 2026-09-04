(** Minimal SDP support for a WebRTC audio receiver.

    We only ever deal with the one shape of session a browser produces for a
    single sendonly audio track, so the parser is deliberately partial: it looks
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

(** Everything we need out of an offer. Session-level [a=ice-ufrag] and friends
    are folded into the media description, media level winning. *)
type offer = {
  mid : string;
  opus : codec;
  ice_ufrag : string;
  ice_pwd : string;
  fingerprint : string * string;  (** algorithm, colon-separated hex *)
  setup : string;
  rtcp_mux : bool;
  direction : direction;
}

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
type section = { kind : string; attributes : (string * string option) list }

let sections sdp =
  let session, media =
    List.fold_left
      (fun (session, media) line ->
        match field line with
        | 'm', value ->
            let kind = match words value with k :: _ -> k | [] -> "" in
            (session, { kind; attributes = [] } :: media)
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
              name = String.lowercase_ascii name;
              clock_rate = int_of_string_exn "clock rate" rate;
              channels = 1;
              fmtp;
            }
      | [ name; rate; channels ] ->
          Some
            {
              payload_type;
              name = String.lowercase_ascii name;
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

let parse_offer sdp =
  let audio =
    match List.filter (fun s -> s.kind = "audio") (sections sdp) with
    | [ s ] -> s
    | [] -> invalid "no audio media section"
    | _ -> invalid "several audio media sections are not supported"
  in
  let fmtps = get_all audio "fmtp" in
  let opus =
    match
      List.filter_map (parse_rtpmap ~fmtps) (get_all audio "rtpmap")
      |> List.filter (fun c -> c.name = "opus")
    with
    | c :: _ -> c
    | [] -> invalid "the offer does not propose Opus"
  in
  let direction =
    List.find_map
      (fun (name, _) -> direction_of_string name)
      audio.attributes
    |> Option.value ~default:Sendrecv
  in
  {
    mid = (match get_value audio "mid" with Some m -> m | None -> "0");
    opus;
    ice_ufrag = require audio "ice-ufrag";
    ice_pwd = require audio "ice-pwd";
    fingerprint = parse_fingerprint (require audio "fingerprint");
    setup = (match get_value audio "setup" with Some s -> s | None -> "actpass");
    rtcp_mux = has audio "rtcp-mux";
    direction;
  }

(* Generation ------------------------------------------------------------- *)

(** The answer to [offer]: we are an ICE-lite, DTLS-passive, receive-only
    endpoint with a single host candidate at [ip]:[port]. *)
let answer ~offer ~ip ~port ~ice_ufrag ~ice_pwd ~fingerprint () =
  let buffer = Buffer.create 1024 in
  let line fmt = Printf.ksprintf (fun s -> Buffer.add_string buffer (s ^ "\r\n")) fmt in
  let algorithm, digest = fingerprint in
  let pt = offer.opus.payload_type in
  line "v=0";
  line "o=- %Lu 1 IN IP4 127.0.0.1" (Random.int64 Int64.max_int);
  line "s=-";
  line "t=0 0";
  line "a=ice-lite";
  line "a=group:BUNDLE %s" offer.mid;
  line "a=msid-semantic: WMS";
  line "m=audio %d UDP/TLS/RTP/SAVPF %d" port pt;
  line "c=IN IP4 %s" ip;
  line "a=rtcp:%d IN IP4 %s" port ip;
  line "a=ice-ufrag:%s" ice_ufrag;
  line "a=ice-pwd:%s" ice_pwd;
  line "a=fingerprint:%s %s" algorithm digest;
  line "a=setup:passive";
  line "a=mid:%s" offer.mid;
  line "a=recvonly";
  line "a=rtcp-mux";
  line "a=rtpmap:%d %s/%d/%d" pt offer.opus.name offer.opus.clock_rate
    offer.opus.channels;
  (* Echoed verbatim: the browser chose these parameters for its encoder. *)
  Option.iter (fun fmtp -> line "a=fmtp:%d %s" pt fmtp) offer.opus.fmtp;
  line "a=candidate:1 1 udp 2130706431 %s %d typ host" ip port;
  line "a=end-of-candidates";
  Buffer.contents buffer
