(** A web server that records the audio a browser sends it over WebRTC.

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

type session = {
  ice : Ice.Agent.t;
  offer : Sdp.offer;
  dtls : Dtls.Server.t;
  mutable srtp : Srtp.t option;
  mutable recording : Oggopus.Writer.t option;
  mutable recording_path : string;
  (* The network may reorder packets; the file may not. *)
  reorder : (int32 * string) Rtp.Reorder.t;
  created : float;
}

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

let recording_path () =
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
      if n = 1 then stamp ^ ".opus" else Printf.sprintf "%s-%d.opus" stamp n
    in
    if Sys.file_exists path then free (n + 1) else path
  in
  free 1

(* The file is opened on the first packet: its header describes the stream, and
   until a packet has arrived there is nothing to describe. *)
let writer session packet =
  match session.recording with
  | Some writer -> writer
  | None ->
      let path = recording_path () in
      let writer =
        Oggopus.Writer.create ~channels:(Oggopus.Writer.channels packet) path
      in
      session.recording <- Some writer;
      session.recording_path <- path;
      log.info (fun log ->
          log "session %s: recording to %s" session.ice.local.ufrag path);
      writer

let write_packets session packets =
  List.iter
    (fun (timestamp, payload) ->
      Oggopus.Writer.write (writer session payload) ~timestamp payload)
    packets

let stop_recording session =
  match session.recording with
  | None -> ()
  | Some writer ->
      (* Whatever the jitter buffer is still holding belongs in the file. *)
      write_packets session (Rtp.Reorder.flush session.reorder);
      Oggopus.Writer.close writer;
      session.recording <- None;
      log.info (fun log ->
          log "session %s: recorded %.1fs to %s, %d packet(s) lost"
            session.ice.local.ufrag
            (Oggopus.Writer.duration writer)
            session.recording_path
            (Rtp.Reorder.lost session.reorder))

(* Signalling ------------------------------------------------------------- *)

let handle_offer request =
  let%lwt body = Dream.body request in
  match Sdp.parse_offer body with
  | exception Sdp.Invalid message ->
      log.warning (fun log -> log "rejected an offer: %s" message);
      Dream.respond ~status:`Bad_Request message
  | offer ->
      let ice = Ice.Agent.create ~remote:{ ufrag = offer.ice_ufrag; pwd = offer.ice_pwd } in
      let session =
        {
          ice;
          offer;
          dtls = Dtls.Server.create (Lazy.force dtls_config);
          srtp = None;
          recording = None;
          recording_path = "";
          reorder = Rtp.Reorder.create ();
          created = Unix.gettimeofday ();
        }
      in
      Hashtbl.replace sessions ice.local.ufrag session;
      let answer =
        Sdp.answer ~offer ~addresses:!advertised_ips ~port:!media_port
          ~ice_ufrag:ice.local.ufrag ~ice_pwd:ice.local.pwd
          ~fingerprint:("sha-256", (Lazy.force certificate).fingerprint)
          ()
      in
      log.info (fun log ->
          log "new session %s (peer ufrag %s, Opus on payload type %d)"
            ice.local.ufrag offer.ice_ufrag offer.opus.payload_type);
      Dream.respond
        ~headers:
          [
            ("Content-Type", "application/sdp");
            (* So that the page can ask for its own session to be closed
               rather than leaving it to the idle sweep. *)
            (session_header, ice.local.ufrag);
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
          Option.iter (Hashtbl.remove sessions_by_peer) session.ice.peer;
          Dream.respond "")

(* Media ------------------------------------------------------------------ *)

(* Keep the address table in step with the agent, which latches and re-latches
   the peer address as checks arrive. *)
let track_peer session previous =
  if session.ice.peer <> previous then begin
    Option.iter (fun address -> Hashtbl.remove sessions_by_peer address) previous;
    Option.iter
      (fun address ->
        Hashtbl.replace sessions_by_peer address session;
        log.info (fun log ->
            log "session %s latched onto %s" session.ice.local.ufrag
              (Ice.Agent.string_of_sockaddr address)))
      session.ice.peer
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
      let previous = session.ice.peer in
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
          log "session %s: DTLS ended: %s" session.ice.local.ufrag message);
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
        log.info (fun log ->
            log "session %s: DTLS established, SRTP keys in hand"
              session.ice.local.ufrag)
      end);
  Lwt.return_unit

let handle_media session datagram =
  match session.srtp with
  | None ->
      (* Media before the handshake finished: there is nothing to decrypt it
         with yet. *)
      log.debug (fun log -> log "media before the SRTP keys were exchanged")
  | Some srtp ->
      let unprotect =
        if Rtp.Packet.is_rtcp datagram then Srtp.unprotect_rtcp srtp
        else Srtp.unprotect srtp
      in
      (match unprotect datagram with
      | Error error ->
          log.warning (fun log ->
              log "session %s: %s" session.ice.local.ufrag (Srtp.string_of_error error))
      | Ok packet when Rtp.Packet.is_rtcp datagram ->
          log.debug (fun log -> log "RTCP, %d bytes" (String.length packet))
      | Ok packet -> (
          match Rtp.Packet.parse packet with
          | exception Rtp.Packet.Invalid message ->
              log.warning (fun log -> log "malformed RTP packet: %s" message)
          | packet when packet.payload_type <> session.offer.opus.payload_type ->
              (* Comfort noise, retransmissions and redundancy all arrive on
                 payload types of their own; we want the Opus stream. *)
              log.debug (fun log ->
                  log "ignoring payload type %d" packet.payload_type)
          | packet ->
              write_packets session
                (Rtp.Reorder.push session.reorder packet.sequence
                   (packet.timestamp, packet.payload))))

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
      | Some session -> handle_media session datagram);
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
    (fun ufrag session ->
      if not (Ice.Agent.alive session.ice) then begin
        log.info (fun log ->
            log "forgetting session %s, idle, %.0fs old" ufrag (now -. session.created));
        stop_recording session;
        Hashtbl.remove sessions ufrag;
        Option.iter (Hashtbl.remove sessions_by_peer) session.ice.peer
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
