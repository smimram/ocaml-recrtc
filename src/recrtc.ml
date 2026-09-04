(** A web server that records the audio a browser sends it over WebRTC.

    Signalling is a plain HTTP exchange of SDP; media arrives on a single UDP
    socket shared by every session, on which STUN, DTLS and SRTP are
    multiplexed (RFC 7983). *)

let static_root = "static"
let http_port = ref 8080
let http_interface = ref "localhost"
let media_port = ref 7000

(* The address we advertise as our host candidate. It must be the one the
   browser can reach: the loopback for local use, otherwise the machine's LAN
   address, or its public address when the server sits behind a port
   forwarding. *)
let advertised_ip = ref "127.0.0.1"

(* The media socket is bound to the advertised address rather than to every
   interface, so that our answers to connectivity checks always leave from the
   address they were sent to. A peer discards a response coming from anywhere
   else (RFC 8445 §7.2.5.2.1), and a wildcard socket would let the routing table
   choose. Behind a one-to-one NAT the two differ, and the local address must
   then be given explicitly. *)
let bind_ip = ref None
let debug = ref false

type session = {
  ice : Ice.Agent.t;
  offer : Sdp.offer;
  dtls : Dtls.Server.t;
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
          created = Unix.gettimeofday ();
        }
      in
      Hashtbl.replace sessions ice.local.ufrag session;
      let answer =
        Sdp.answer ~offer ~ip:!advertised_ip ~port:!media_port
          ~ice_ufrag:ice.local.ufrag ~ice_pwd:ice.local.pwd
          ~fingerprint:("sha-256", (Lazy.force certificate).fingerprint)
          ()
      in
      log.info (fun log ->
          log "new session %s (peer ufrag %s, Opus on payload type %d)"
            ice.local.ufrag offer.ice_ufrag offer.opus.payload_type);
      Dream.respond ~headers:[ ("Content-Type", "application/sdp") ] answer

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
      log.warning (fun log ->
          log "session %s: DTLS handshake failed: %s" session.ice.local.ufrag message)
  | Dtls.Server.Established { profile; keying = _ } ->
      log.info (fun log ->
          log "session %s: DTLS established, SRTP profile 0x%04x" session.ice.local.ufrag
            profile));
  Lwt.return_unit

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
      | Some session ->
          log.debug (fun log ->
              log "media packet (SRTP not implemented yet), Opus is expected on payload type %d"
                session.offer.opus.payload_type));
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
        Hashtbl.remove sessions ufrag;
        Option.iter (Hashtbl.remove sessions_by_peer) session.ice.peer
      end)
    (Hashtbl.copy sessions);
  reap_sessions ()

let media_socket () =
  let socket = Lwt_unix.socket PF_INET SOCK_DGRAM 0 in
  Lwt_unix.setsockopt socket SO_REUSEADDR true;
  let address = Option.value !bind_ip ~default:!advertised_ip in
  Lwt_unix.bind socket
    (Unix.ADDR_INET (Unix.inet_addr_of_string address, !media_port))
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
      ( "--bind",
        Arg.String (fun address -> bind_ip := Some address),
        "ADDRESS  local address the media socket binds to, when it differs          from the advertised one (behind a NAT, say)" );
      ( "--ip",
        Arg.Set_string advertised_ip,
        "ADDRESS  the address advertised as our ICE candidate, which must be \
         reachable by the browser (default 127.0.0.1)" );
    ]
    (fun argument -> raise (Arg.Bad ("unexpected argument: " ^ argument)))
    "recrtc [options]";
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
          log "media socket listening on %s:%d"
            (Option.value !bind_ip ~default:!advertised_ip)
            !media_port);
      media_loop socket);
  Lwt.async reap_sessions;
  Dream.run ~interface:!http_interface ~port:!http_port
  @@ Dream.logger
  @@ Dream.router
       [
         Dream.get "/" (fun request ->
             Dream.from_filesystem static_root "index.html" request);
         Dream.post "/webrtc/offer" handle_offer;
         Dream.get "/**" (Dream.static static_root);
       ]
