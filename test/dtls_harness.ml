(** A bare DTLS server on a UDP port, for testing the handshake against another
    implementation:

    {[ dune exec test/dtls_harness.exe &
       openssl s_client -dtls1_2 -use_srtp SRTP_AES128_CM_SHA1_80 \
         -connect 127.0.0.1:7001 ]}

    It prints the exported SRTP keying material, which openssl prints too
    (with [-keymatexport], or from its SRTP debug output), so the two can be
    compared. *)

let port = ref 7001

let hex s =
  String.concat "" (List.map (fun c -> Printf.sprintf "%02x" (Char.code c)) (List.of_seq (String.to_seq s)))

let () =
  Arg.parse [ ("--port", Arg.Set_int port, "PORT  (default 7001)") ] ignore
    "dtls_harness [--port PORT]";
  Mirage_crypto_rng_unix.use_default ();
  let certificate = Dtls.Certificate.generate () in
  Printf.printf "certificate fingerprint %s\n%!" certificate.fingerprint;
  let socket = Unix.socket PF_INET SOCK_DGRAM 0 in
  Unix.setsockopt socket SO_REUSEADDR true;
  Unix.bind socket (ADDR_INET (Unix.inet_addr_loopback, !port));
  Printf.printf "listening on UDP port %d\n%!" !port;
  let buffer = Bytes.create 4096 in
  let server = ref (Dtls.Server.create (Dtls.Server.config certificate)) in
  let peer = ref None in
  while true do
    let length, source = Unix.recvfrom socket buffer 0 (Bytes.length buffer) [] in
    (* A datagram from a new peer starts a fresh handshake. *)
    if !peer <> Some source then begin
      peer := Some source;
      server := Dtls.Server.create (Dtls.Server.config certificate);
      print_endline "--- new peer"
    end;
    let datagram = Bytes.sub_string buffer 0 length in
    let datagrams, event = Dtls.Server.handle !server datagram in
    List.iter
      (fun datagram ->
        ignore
          (Unix.sendto socket (Bytes.unsafe_of_string datagram) 0
             (String.length datagram) [] source))
      datagrams;
    match event with
    | Dtls.Server.Pending -> ()
    | Dtls.Server.Failed message -> Printf.printf "failed: %s\n%!" message
    | Dtls.Server.Established { profile; keying } ->
        Printf.printf "established, SRTP profile 0x%04x\n" profile;
        Printf.printf "  client key  %s\n" (hex keying.srtp_client_key);
        Printf.printf "  server key  %s\n" (hex keying.srtp_server_key);
        Printf.printf "  client salt %s\n" (hex keying.srtp_client_salt);
        Printf.printf "  server salt %s\n%!" (hex keying.srtp_server_salt)
  done
