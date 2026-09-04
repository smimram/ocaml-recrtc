(** A web server that records what a browser sends it over WebRTC.

    Signalling is a plain HTTP exchange of SDP; media arrives on a single UDP
    socket shared by every session, on which STUN, DTLS and SRTP are
    multiplexed (RFC 7983). *)

let static_root = "static"
let http_port = ref 8080
let http_interface = ref "localhost"
let media_port = ref 7000

(* The addresses we advertise as host candidates, most preferred first. By
   default the machine's own addresses, which covers a browser on this machine
   as well as one on the network; a server behind a port forwarding has to be
   told its public address with --ip. *)
let advertised_ips = ref []

(* The media socket is bound to the advertised address rather than to every
   interface, so that our answers to connectivity checks always leave from the
   address they were sent to. A peer discards a response coming from anywhere
   else (RFC 8445 §7.2.5.2.1), and a wildcard socket would let the routing table
   choose. Behind a one-to-one NAT the two differ, and the local address must
   then be given explicitly. *)
let bind_ip = ref None
let debug = ref false

(* Recordings are named after the moment they start, so that concurrent or
   successive sessions never overwrite one another. *)
let output_prefix = ref "recording"

(* Which address the kernel would use to reach the outside world. Connecting a
   datagram socket sends nothing: it only consults the routing table. The
   address is from the range reserved for documentation, so nothing can come of
   it even if a packet were sent. *)
let primary_address () =
  let socket = Unix.socket PF_INET SOCK_DGRAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      match
        Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_of_string "203.0.113.1", 9));
        Unix.getsockname socket
      with
      | Unix.ADDR_INET (ip, _) -> [ Unix.string_of_inet_addr ip ]
      | _ | (exception Unix.Unix_error _) -> [])

(* The loopback comes last: a peer elsewhere on the network cannot use it, and
   one on this machine can use either. *)
let default_addresses () = primary_address () @ [ "127.0.0.1" ]

(* What we chose to receive on each kind of media, and the state that turns
   its packets back into something a file can hold. *)
type audio = {
  audio_codec : Sdp.codec;
  (* The network may reorder packets; the file may not. *)
  audio_reorder : (int32 * string) Rtp.Reorder.t;
}

type video = {
  video_codec : Sdp.codec;
  format : Rtp.Frame.codec;
  (* One picture is routinely thirty packets, so the buffer has to be far
     deeper than audio's to absorb the same amount of reordering. *)
  video_reorder : Rtp.Packet.t Rtp.Reorder.t;
  frames : Rtp.Frame.t;
  (* Everything before the first keyframe is dropped, so that the recording
     opens on a picture that can be decoded on its own. *)
  mutable started : bool;
  (* The source the pictures come from, which a keyframe request has to name.
     It is not known until the first packet arrives. *)
  mutable ssrc : int32 option;
  (* Since when a lost packet has left the stream undecodable, and when we last
     asked for the keyframe that would end it. *)
  mutable damaged_since : float option;
  mutable asked_at : float;
}

type container = Ogg of Oggopus.Writer.t | Matroska of Matroska.Writer.t

(* Media that arrived before the file could be opened. A Matroska file declares
   the picture size and the channel count in its header, and neither is known
   until the first keyframe and the first Opus packet have arrived. *)
type buffered = Buffered_audio of int32 * string | Buffered_video of Rtp.Frame.frame

type session = {
  ice : Ice.Agent.t;
  dtls : Dtls.Server.t;
  mutable srtp : Srtp.t option;
  (* The other half of the keying material: what the keyframe requests, the
     only thing we ever send, are protected with. *)
  mutable srtp_sender : Srtp.sender option;
  (* Our own synchronisation source. We send no media, so it names us in
     feedback packets and nowhere else. *)
  sender_ssrc : int32;
  audio : audio option;
  (* Cleared if the camera never produces a picture, so that a session that
     offered video but sends none still leaves a recording of its audio. *)
  mutable video : video option;
  mutable recording : container option;
  mutable recording_path : string;
  mutable pending : (float * buffered) list;  (* newest first *)
  mutable buffering_since : float option;
  mutable audio_channels : int option;
  created : float;
}

(* The local ICE fragment names a session throughout: in the log, in the answer
   and in the request that ends it. *)
let ufrag session = (Ice.Agent.local session.ice).ufrag

(* Sessions are found by the ICE fragment a STUN check carries, and by source
   address once a peer has been latched, since DTLS and RTP datagrams identify
   themselves in no other way. *)
let sessions : (string, session) Hashtbl.t = Hashtbl.create 16
let sessions_by_peer : (Unix.sockaddr, session) Hashtbl.t = Hashtbl.create 16

let certificate = lazy (Dtls.Certificate.generate ())
let dtls_config = lazy (Dtls.Server.config (Lazy.force certificate))

let log = Dream.sub_log "recrtc"

(* Names the session in the answer and in the request that ends it. *)
let session_header = "X-Recrtc-Session"

(* Recording --------------------------------------------------------------- *)

let recording_path extension =
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let stamp =
    Printf.sprintf "%s-%04d%02d%02d-%02d%02d%02d" !output_prefix
      (now.tm_year + 1900) (now.tm_mon + 1) now.tm_mday now.tm_hour now.tm_min
      now.tm_sec
  in
  (* Two sessions can start within the same second, and neither may overwrite
     the other. *)
  let rec free n =
    let path =
      if n = 1 then stamp ^ extension
      else Printf.sprintf "%s-%d%s" stamp n extension
    in
    if Sys.file_exists path then free (n + 1) else path
  in
  free 1

let opened session path =
  session.recording_path <- path;
  log.info (fun log -> log "session %s: recording to %s" (ufrag session) path)

(* Audio alone goes to an Ogg file, as it always has; the container is only
   opened on the first packet, since until one has arrived there is nothing to
   describe in its header. *)
let ogg session packet =
  match session.recording with
  | Some (Ogg writer) -> Some writer
  | Some (Matroska _) -> None
  | None ->
      let path = recording_path ".opus" in
      let writer =
        Oggopus.Writer.create ~channels:(Oggopus.Writer.channels packet) path
      in
      session.recording <- Some (Ogg writer);
      opened session path;
      Some writer

(* The video half of the Matroska header. H.264 keeps its parameter sets out of
   band, so the file cannot be opened until they have been seen — which is the
   same keyframe that gives us the picture size. *)
let matroska_codec video =
  match video.format with
  | Rtp.Frame.Vp8 -> Some Matroska.Writer.Vp8
  | Rtp.Frame.Vp9 -> Some Matroska.Writer.Vp9
  | Rtp.Frame.H264 -> (
      match Rtp.Frame.parameter_sets video.frames with
      | Some (sps, pps) -> Some (Matroska.Writer.H264 (Rtp.H264.avcc ~sps ~pps))
      | None -> None)

(* How long the header waits for a track that has been negotiated but has not
   yet produced a packet, before going ahead without it. *)
let header_timeout = 2.

let buffered_for session =
  match session.buffering_since with
  | Some since -> Unix.gettimeofday () -. since
  | None -> 0.

let waiting_for_audio session =
  session.audio <> None
  && session.audio_channels = None
  && buffered_for session < header_timeout

(* [force] gives up waiting for a track that has not appeared: for the end of a
   session, where there is no more waiting to be done. *)
let open_matroska ?(force = false) session video =
  match (matroska_codec video, Rtp.Frame.dimensions video.frames) with
  | Some codec, Some (width, height)
    when session.recording = None && (force || not (waiting_for_audio session))
    ->
      let path = recording_path (Matroska.Writer.extension codec) in
      let writer =
        Matroska.Writer.create ~codec ~width ~height
          ?audio_channels:session.audio_channels path
      in
      session.recording <- Some (Matroska writer);
      opened session path;
      log.info (fun log ->
          log "session %s: %s %dx%d%s" (ufrag session)
            (match codec with
            | Matroska.Writer.Vp8 -> "VP8"
            | Matroska.Writer.Vp9 -> "VP9"
            | Matroska.Writer.H264 _ -> "H.264")
            width height
            (match session.audio_channels with
            | Some channels -> Printf.sprintf ", Opus on %d channel(s)" channels
            | None -> ", no audio"));
      (* Whatever arrived while the header was still unknown belongs in the
         file, in the order it arrived. *)
      let pending = List.rev session.pending in
      session.pending <- [];
      session.buffering_since <- None;
      List.iter
        (fun (arrival, item) ->
          match item with
          | Buffered_audio (timestamp, packet) ->
              Matroska.Writer.write_audio writer ~arrival ~timestamp packet
          | Buffered_video { Rtp.Frame.timestamp; keyframe; data } ->
              Matroska.Writer.write_video writer ~arrival ~timestamp ~keyframe data)
        pending;
      Some writer
  | _ -> None

(* How long a session that negotiated video waits for a picture before
   concluding there will not be one. Chrome sends a keyframe within a few
   frames of the connection opening, so silence this long means the camera
   never started. *)
let video_timeout = 5.

let rec write_audio session ~timestamp packet =
  if session.audio_channels = None then
    session.audio_channels <- Some (Oggopus.Writer.channels packet);
  match (session.recording, session.video) with
  | Some (Matroska writer), _ ->
      Matroska.Writer.write_audio writer ~arrival:(Unix.gettimeofday ())
        ~timestamp packet
  | _, Some _ -> buffer session (Buffered_audio (timestamp, packet))
  | _, None -> (
      match ogg session packet with
      | Some writer -> Oggopus.Writer.write writer ~timestamp packet
      | None -> ())

(* A session recording video buffers until its header can be written. *)
and buffer session item =
  if session.buffering_since = None then
    session.buffering_since <- Some (Unix.gettimeofday ());
  session.pending <- (Unix.gettimeofday (), item) :: session.pending;
  match session.video with
  | None -> ()
  | Some video ->
      ignore (open_matroska session video);
      (* If no picture has ever arrived, the buffer would otherwise grow
         without end; give up on the camera and record the audio alone. *)
      if
        session.recording = None
        && Rtp.Frame.dimensions video.frames = None
        && buffered_for session > video_timeout
      then begin
          log.warning (fun log ->
              log "session %s: no video after %.0fs, recording audio only"
                (ufrag session) video_timeout);
          session.video <- None;
          let pending = List.rev session.pending in
          session.pending <- [];
          session.buffering_since <- None;
          List.iter
            (fun (_, item) ->
              match item with
              | Buffered_audio (timestamp, packet) ->
                  write_audio session ~timestamp packet
              | Buffered_video _ -> ())
            pending
      end

let write_frame session (frame : Rtp.Frame.frame) =
  match session.recording with
  | Some (Matroska writer) ->
      Matroska.Writer.write_video writer ~arrival:(Unix.gettimeofday ())
        ~timestamp:frame.timestamp ~keyframe:frame.keyframe frame.data
  | Some (Ogg _) ->
      (* Unreachable: an Ogg file is only ever opened once the session has
         given up on video, after which no frame reaches here. *)
      ()
  | None -> buffer session (Buffered_video frame)

let stop_recording session =
  (* Whatever the jitter buffers are still holding belongs in the file, and so
     does anything still waiting on a header that will never be completed. *)
  Option.iter
    (fun audio ->
      List.iter
        (fun (timestamp, packet) -> write_audio session ~timestamp packet)
        (Rtp.Reorder.flush audio.audio_reorder))
    session.audio;
  Option.iter
    (fun video ->
      List.iter
        (fun packet -> List.iter (write_frame session) (Rtp.Frame.push video.frames packet))
        (Rtp.Reorder.flush video.video_reorder);
      List.iter (write_frame session) (Rtp.Frame.flush video.frames);
      (* A recording too short to have satisfied both tracks still has media
         worth keeping. *)
      if session.recording = None then
        ignore (open_matroska ~force:true session video))
    session.video;
  match session.recording with
  | None -> ()
  | Some container ->
      let duration =
        match container with
        | Ogg writer ->
            Oggopus.Writer.close writer;
            Oggopus.Writer.duration writer
        | Matroska writer ->
            Matroska.Writer.close writer;
            Matroska.Writer.duration writer
      in
      session.recording <- None;
      let losses =
        String.concat ", "
          (List.filter_map Fun.id
             [
               Option.map
                 (fun audio ->
                   Printf.sprintf "%d audio packet(s) lost"
                     (Rtp.Reorder.lost audio.audio_reorder))
                 session.audio;
               Option.map
                 (fun video ->
                   Printf.sprintf "%d video packet(s) lost, %d frame(s) dropped"
                     (Rtp.Reorder.lost video.video_reorder)
                     (Rtp.Frame.dropped video.frames))
                 session.video;
             ])
      in
      log.info (fun log ->
          log "session %s: recorded %.1fs to %s, %s" (ufrag session) duration
            session.recording_path losses)

(* Signalling ------------------------------------------------------------- *)

let handle_offer request =
  let%lwt body = Dream.body request in
  log.debug (fun log -> log "offer:\n%s" body);
  match Sdp.parse_offer body with
  | exception Sdp.Invalid message ->
      log.warning (fun log -> log "rejected an offer: %s" message);
      Dream.respond ~status:`Bad_Request message
  | offer ->
      let ice = Ice.Agent.create ~remote:{ ufrag = offer.ice_ufrag; pwd = offer.ice_pwd } in
      let audio =
        Option.map
          (fun codec ->
            { audio_codec = codec; audio_reorder = Rtp.Reorder.create () })
          (Sdp.codec offer "audio")
      in
      let video =
        Option.bind (Sdp.codec offer "video") (fun codec ->
            Option.map
              (fun format ->
                {
                  video_codec = codec;
                  format;
                  (* A picture is spread over far more packets than an Opus
                     frame, so the same amount of reordering needs a much
                     deeper buffer to absorb it. *)
                  video_reorder = Rtp.Reorder.create ~depth:128 ();
                  frames = Rtp.Frame.create format;
                  started = false;
                  ssrc = None;
                  damaged_since = None;
                  asked_at = 0.;
                })
              (match String.lowercase_ascii codec.name with
              | "vp8" -> Some Rtp.Frame.Vp8
              | "vp9" -> Some Rtp.Frame.Vp9
              | "h264" -> Some Rtp.Frame.H264
              | _ -> None))
      in
      let session =
        {
          ice;
          dtls = Dtls.Server.create (Lazy.force dtls_config);
          srtp = None;
          srtp_sender = None;
          sender_ssrc = Random.int32 Int32.max_int;
          audio;
          video;
          recording = None;
          recording_path = "";
          pending = [];
          buffering_since = None;
          audio_channels = None;
          created = Unix.gettimeofday ();
        }
      in
      Hashtbl.replace sessions (Ice.Agent.local ice).ufrag session;
      let answer =
        Sdp.answer ~offer ~addresses:!advertised_ips ~port:!media_port
          ~ice_ufrag:(Ice.Agent.local ice).ufrag ~ice_pwd:(Ice.Agent.local ice).pwd
          ~fingerprint:("sha-256", (Lazy.force certificate).fingerprint)
          ()
      in
      let describe kind = function
        | None -> None
        | Some (codec : Sdp.codec) ->
            Some (Printf.sprintf "%s on payload type %d" kind codec.payload_type)
      in
      log.info (fun log ->
          log "new session %s (peer ufrag %s, %s)" (Ice.Agent.local ice).ufrag
            offer.ice_ufrag
            (String.concat ", "
               (List.filter_map Fun.id
                  [
                    describe "Opus" (Option.map (fun a -> a.audio_codec) audio);
                    describe
                      (match video with
                      | Some { format = Rtp.Frame.Vp9; _ } -> "VP9"
                      | Some { format = Rtp.Frame.H264; _ } -> "H.264"
                      | _ -> "VP8")
                      (Option.map (fun v -> v.video_codec) video);
                  ])));
      log.debug (fun log -> log "answer:\n%s" answer);
      Dream.respond
        ~headers:
          [
            ("Content-Type", "application/sdp");
            (* So that the page can ask for its own session to be closed
               rather than leaving it to the idle sweep. *)
            (session_header, (Ice.Agent.local ice).ufrag);
          ]
        answer

let handle_stop request =
  match Dream.header request session_header with
  | None -> Dream.respond ~status:`Bad_Request "no session given"
  | Some ufrag -> (
      match Hashtbl.find_opt sessions ufrag with
      | None -> Dream.respond ~status:`Not_Found "no such session"
      | Some session ->
          log.info (fun log -> log "session %s: stopped by the client" ufrag);
          stop_recording session;
          Hashtbl.remove sessions ufrag;
          Option.iter (Hashtbl.remove sessions_by_peer) (Ice.Agent.peer session.ice);
          Dream.respond "")

(* Media ------------------------------------------------------------------ *)

(* Keep the address table in step with the agent, which latches and re-latches
   the peer address as checks arrive. *)
let track_peer session previous =
  if Ice.Agent.peer session.ice <> previous then begin
    Option.iter (fun address -> Hashtbl.remove sessions_by_peer address) previous;
    Option.iter
      (fun address ->
        Hashtbl.replace sessions_by_peer address session;
        log.info (fun log ->
            log "session %s latched onto %s" (ufrag session)
              (Ice.Agent.string_of_sockaddr address)))
      (Ice.Agent.peer session.ice)
  end

let send socket ~destination datagram =
  let datagram = Bytes.unsafe_of_string datagram in
  let%lwt _ =
    Lwt_unix.sendto socket datagram 0 (Bytes.length datagram) [] destination
  in
  Lwt.return_unit

(* A STUN check names the session it belongs to through the local half of its
   USERNAME attribute. *)
let session_of_check datagram =
  match Ice.Stun.decode datagram with
  | Error _ -> None
  | Ok message -> (
      match Ice.Stun.username message with
      | None -> None
      | Some username -> (
          match String.index_opt username ':' with
          | None -> None
          | Some i -> Hashtbl.find_opt sessions (String.sub username 0 i)))

let handle_stun socket ~source datagram =
  match session_of_check datagram with
  | None ->
      log.debug (fun log ->
          log "STUN check for an unknown session from %s"
            (Ice.Agent.string_of_sockaddr source));
      Lwt.return_unit
  | Some session -> (
      let previous = Ice.Agent.peer session.ice in
      match Ice.Agent.handle session.ice ~source datagram with
      | Ice.Agent.Drop reason ->
          log.debug (fun log -> log "dropped a check: %s" reason);
          Lwt.return_unit
      | Ice.Agent.Respond response ->
          track_peer session previous;
          send socket ~destination:source response)

let handle_dtls socket ~source session datagram =
  let datagrams, event = Dtls.Server.handle session.dtls datagram in
  let%lwt () = Lwt_list.iter_s (send socket ~destination:source) datagrams in
  (match event with
  | Dtls.Server.Pending -> ()
  | Dtls.Server.Failed message ->
      (* A peer that closes the connection cleanly ends up here too, so this is
         also where a recording finishes when the browser hangs up. *)
      log.warning (fun log ->
          log "session %s: DTLS ended: %s" (ufrag session) message);
      stop_recording session
  | Dtls.Server.Established { profile = _; keying } ->
      (* The handshake keeps reporting itself established as the peer repeats
         its last flight; the keys are taken once. *)
      if session.srtp = None then begin
        (* We only ever receive, so the client's half of the keying material is
           the one we need. *)
        session.srtp <-
          Some
            (Srtp.create ~master_key:keying.srtp_client_key
               ~master_salt:keying.srtp_client_salt);
        session.srtp_sender <-
          Some
            (Srtp.sender ~master_key:keying.srtp_server_key
               ~master_salt:keying.srtp_server_salt);
        log.info (fun log ->
            log "session %s: DTLS established, SRTP keys in hand"
              (ufrag session))
      end);
  Lwt.return_unit

(* Feedback ---------------------------------------------------------------- *)

(* A datagram sent from within the media path, where there is no Lwt thread to
   sequence it into. Nothing depends on when it leaves, or on its leaving at
   all: a lost keyframe request is asked again a moment later. *)
let send_async socket ~destination datagram =
  Lwt.async (fun () -> send socket ~destination datagram)

(* How often a keyframe may be asked for. A request costs the browser a whole
   picture, so asking once per lost packet would answer a burst of loss with a
   burst of keyframes; one in flight at a time is enough. *)
let pli_interval = 0.5

(* How long the recording waits for the keyframe it asked for before writing
   pictures that are known to be corrupt. A browser that honours the request
   answers within a round trip; one that does not would otherwise leave us
   recording nothing at all, and a damaged picture beats a missing one. *)
let keyframe_timeout = 2.

(* After a lost packet every picture predicted from the one it ruined is ruined
   too, and a browser sends a fresh keyframe only when asked (RFC 4585 §6.3.1);
   left alone it would carry the corruption to the end of the recording. *)
let request_keyframe socket session video ~now =
  match (session.srtp_sender, Ice.Agent.peer session.ice, video.ssrc) with
  | Some sender, Some destination, Some ssrc when now -. video.asked_at > pli_interval
    ->
      video.asked_at <- now;
      let pli = Rtp.Rtcp.pli ~sender:session.sender_ssrc ~media:ssrc in
      send_async socket ~destination (Srtp.protect_rtcp sender pli);
      log.debug (fun log -> log "session %s: asked for a keyframe" (ufrag session))
  | _ -> ()

(* Media ------------------------------------------------------------------- *)

let deliver_audio session packets =
  List.iter
    (fun (timestamp, payload) -> write_audio session ~timestamp payload)
    packets

let deliver_video socket session video packets =
  let now = Unix.gettimeofday () in
  List.iter
    (fun packet ->
      let dropped = Rtp.Frame.dropped video.frames in
      let frames = Rtp.Frame.push video.frames packet in
      (* A picture the loss of a packet made unusable. Nothing after it is
         decodable either, so the recording pauses there and asks for the
         keyframe that will let it resume. *)
      if Rtp.Frame.dropped video.frames > dropped && video.started then begin
        if video.damaged_since = None then begin
          video.damaged_since <- Some now;
          log.debug (fun log ->
              log "session %s: lost a picture, waiting for a keyframe"
                (ufrag session))
        end;
        request_keyframe socket session video ~now
      end;
      List.iter
        (fun (frame : Rtp.Frame.frame) ->
          (* Nothing before the first keyframe can be decoded, so nothing
             before it is worth keeping. *)
          if frame.keyframe then begin
            if video.damaged_since <> None then
              log.debug (fun log ->
                  log "session %s: keyframe, recording resumes" (ufrag session));
            video.started <- true;
            video.damaged_since <- None
          end;
          let writable =
            video.started
            &&
            match video.damaged_since with
            | None -> true
            | Some since -> now -. since > keyframe_timeout
          in
          if writable then write_frame session frame
          else if video.damaged_since <> None then
            (* The keyframe has not come; keep asking for as long as pictures
               keep arriving that cannot be used. *)
            request_keyframe socket session video ~now)
        frames)
    packets

(* The two streams share a transport under BUNDLE and are told apart by their
   payload type, which the answer fixed one per kind. *)
let handle_rtp socket session (packet : Rtp.Packet.t) =
  let matching payload_type = function
    | Some x when payload_type x = packet.payload_type -> Some x
    | _ -> None
  in
  let audio = matching (fun a -> a.audio_codec.payload_type) session.audio in
  let video = matching (fun v -> v.video_codec.payload_type) session.video in
  match (audio, video) with
  | Some audio, _ ->
      deliver_audio session
        (Rtp.Reorder.push audio.audio_reorder packet.sequence
           (packet.timestamp, packet.payload))
  | _, Some video ->
      if video.ssrc = None then video.ssrc <- Some packet.ssrc;
      deliver_video socket session video
        (Rtp.Reorder.push video.video_reorder packet.sequence packet)
  | None, None ->
      (* Comfort noise, retransmissions, redundancy and the codecs we turned
         down all arrive on payload types of their own. *)
      log.debug (fun log -> log "ignoring payload type %d" packet.payload_type)

let handle_media socket session datagram =
  match session.srtp with
  | None ->
      (* Media before the handshake finished: there is nothing to decrypt it
         with yet. *)
      log.debug (fun log -> log "media before the SRTP keys were exchanged")
  | Some srtp -> (
      let unprotect =
        if Rtp.Packet.is_rtcp datagram then Srtp.unprotect_rtcp srtp
        else Srtp.unprotect srtp
      in
      match unprotect datagram with
      | Error error ->
          log.warning (fun log ->
              log "session %s: %s" (ufrag session) (Srtp.string_of_error error))
      | Ok packet when Rtp.Packet.is_rtcp datagram ->
          log.debug (fun log -> log "RTCP, %d bytes" (String.length packet))
      | Ok packet -> (
          match Rtp.Packet.parse packet with
          | exception Rtp.Packet.Invalid message ->
              log.warning (fun log -> log "malformed RTP packet: %s" message)
          | packet -> handle_rtp socket session packet))

let handle_datagram socket ~source datagram =
  let session () = Hashtbl.find_opt sessions_by_peer source in
  match Char.code datagram.[0] with
  (* RFC 7983 demultiplexing. *)
  | b when b < 4 -> handle_stun socket ~source datagram
  | b when b >= 20 && b < 64 -> (
      match session () with
      | None ->
          log.debug (fun log -> log "DTLS from an unknown peer");
          Lwt.return_unit
      | Some session -> handle_dtls socket ~source session datagram)
  | b when b >= 128 && b < 192 ->
      (match session () with
      | None -> log.debug (fun log -> log "media from an unknown peer")
      | Some session -> handle_media socket session datagram);
      Lwt.return_unit
  | b ->
      log.debug (fun log -> log "unrecognised datagram starting with 0x%02x" b);
      Lwt.return_unit

let media_loop socket =
  (* Comfortably above the 1200-byte MTU WebRTC keeps to. *)
  let buffer = Bytes.create 2048 in
  let rec loop () =
    let%lwt length, source =
      Lwt_unix.recvfrom socket buffer 0 (Bytes.length buffer) []
    in
    let%lwt () =
      if length = 0 then Lwt.return_unit
      else
        try%lwt handle_datagram socket ~source (Bytes.sub_string buffer 0 length)
        with exn ->
          log.error (fun log ->
              log "while handling a datagram from %s: %s"
                (Ice.Agent.string_of_sockaddr source)
                (Printexc.to_string exn));
          Lwt.return_unit
    in
    loop ()
  in
  loop ()

(* Offers that never lead to a connection, and peers that go away without
   saying so, would otherwise accumulate. *)
let rec reap_sessions () =
  let%lwt () = Lwt_unix.sleep 10. in
  let now = Unix.gettimeofday () in
  Hashtbl.iter
    (fun key session ->
      if not (Ice.Agent.alive session.ice) then begin
        log.info (fun log ->
            log "forgetting session %s, idle, %.0fs old" key (now -. session.created));
        stop_recording session;
        Hashtbl.remove sessions key;
        Option.iter (Hashtbl.remove sessions_by_peer) (Ice.Agent.peer session.ice)
      end)
    (Hashtbl.copy sessions);
  reap_sessions ()

(* With one advertised address we can bind to it; with several, only the
   wildcard covers them all. *)
let bind_address () =
  match (!bind_ip, !advertised_ips) with
  | Some address, _ -> address
  | None, [ address ] -> address
  | None, _ -> "0.0.0.0"

let media_socket () =
  let socket = Lwt_unix.socket PF_INET SOCK_DGRAM 0 in
  Lwt_unix.setsockopt socket SO_REUSEADDR true;
  Lwt_unix.bind socket
    (Unix.ADDR_INET (Unix.inet_addr_of_string (bind_address ()), !media_port))
  |> Lwt.map (fun () -> socket)

(* Entry point ------------------------------------------------------------ *)

let () =
  Arg.parse
    [
      ("--port", Arg.Set_int http_port, "PORT  HTTP port (default 8080)");
      ( "--interface",
        Arg.Set_string http_interface,
        "ADDRESS  interface the HTTP server binds to (default localhost, use          0.0.0.0 to accept connections from other machines)" );
      ("--media-port", Arg.Set_int media_port, "PORT  UDP port for media (default 7000)");
      ("--debug", Arg.Set debug, "  log every datagram that is dropped");
      ( "--output",
        Arg.Set_string output_prefix,
        "PREFIX  recordings are written to PREFIX-<date>.opus (default \
         recording)" );
      ( "--bind",
        Arg.String (fun address -> bind_ip := Some address),
        "ADDRESS  local address the media socket binds to, when it differs          from the advertised one (behind a NAT, say)" );
      ( "--ip",
        Arg.String (fun address -> advertised_ips := !advertised_ips @ [ address ]),
        "ADDRESS  an address to advertise as an ICE candidate, which must be \
         reachable by the browser; may be repeated, most preferred first \
         (default: this machine's own addresses)" );
    ]
    (fun argument -> raise (Arg.Bad ("unexpected argument: " ^ argument)))
    "recrtc [options]";
  if !advertised_ips = [] then advertised_ips := default_addresses ();
  Dream.initialize_log ~level:(if !debug then `Debug else `Info) ();
  (* The sub-log keeps the threshold it was created with, so it needs telling
     separately. *)
  if !debug then Dream.set_log_level "recrtc" `Debug;
  Mirage_crypto_rng_unix.use_default ();
  log.info (fun log ->
      log "certificate fingerprint %s" (Lazy.force certificate).fingerprint);
  Lwt.async (fun () ->
      let%lwt socket = media_socket () in
      log.info (fun log ->
          log "media socket listening on %s:%d, advertising %s" (bind_address ())
            !media_port
            (String.concat ", " !advertised_ips));
      media_loop socket);
  Lwt.async reap_sessions;
  Dream.run ~interface:!http_interface ~port:!http_port
  @@ Dream.logger
  @@ Dream.router
       [
         Dream.get "/" (fun request ->
             Dream.from_filesystem static_root "index.html" request);
         Dream.post "/webrtc/offer" handle_offer;
         Dream.post "/webrtc/stop" handle_stop;
         Dream.get "/**" (Dream.static static_root);
       ]
