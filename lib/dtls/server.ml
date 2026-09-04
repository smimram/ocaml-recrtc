(** A DTLS 1.2 server, restricted to what WebRTC needs of it.

    The browser is the DTLS client (we answer [a=setup:passive]), the only
    cipher suite is [TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256], and the
    handshake exists solely to negotiate SRTP protection and export its keying
    material (RFC 5764): no application data ever flows over the connection.

    The module is a pure state machine over datagrams — [handle] takes what
    arrived and returns what to send — so it can be driven by a socket, by a
    test, or by nothing at all. *)

type config = {
  certificate : Certificate.t;
  max_record : int;
      (** the largest record payload we emit, chosen so that a record and its
          UDP and IP headers stay within the path MTU *)
}

let config ?(max_record = 1100) certificate = { certificate; max_record }

type established = {
  profile : int;  (** the negotiated SRTP protection profile *)
  keying : Crypto.srtp_keying;
}

type event =
  | Pending
  | Established of established
  | Failed of string

(* A handshake message being reassembled from its fragments. Messages are
   small, so tracking coverage byte by byte costs nothing and spares us any
   reasoning about overlapping fragments. *)
type partial = {
  message_type : int;
  data : Bytes.t;
  covered : bool array;
}

type negotiation = {
  client_random : string;
  server_random : string;
  ecdh_secret : Mirage_crypto_ec.P256.Dh.secret;
  extended_master_secret : bool;
  profile : int;
}

type session = { negotiation : negotiation; master : string }

type state =
  | Awaiting_client_hello
  | Awaiting_client_key_exchange of negotiation
  | Awaiting_finished of session
  | Connected of session
  | Broken of string

type t = {
  config : config;
  mutable state : state;
  (* Every handshake message, in the unfragmented form the hash is defined
     over (RFC 6347 §4.2.6), in the order they were sent and received. *)
  transcript : Buffer.t;
  mutable receive_message_seq : int;
  mutable send_message_seq : int;
  mutable send_epoch : int;
  mutable send_sequence : int;
  reassembly : (int, partial) Hashtbl.t;
  mutable read_cipher : Crypto.cipher option;
  mutable write_cipher : Crypto.cipher option;
  (* Kept so that the flight can be sent again: DTLS runs over an unreliable
     transport, and it is the server's job to repeat its flight when the client
     repeats the one before it. *)
  mutable last_flight : string list;
}

let create config =
  {
    config;
    state = Awaiting_client_hello;
    transcript = Buffer.create 4096;
    receive_message_seq = 0;
    send_message_seq = 0;
    send_epoch = 0;
    send_sequence = 0;
    reassembly = Hashtbl.create 8;
    read_cipher = None;
    write_cipher = None;
    last_flight = [];
  }

(* An unrecoverable handshake error, carrying the alert to send. *)
exception Fatal of int * string

let fail description fmt =
  Printf.ksprintf (fun message -> raise (Fatal (description, message))) fmt

(* Sending ---------------------------------------------------------------- *)

let serialize_record t ~content_type fragment =
  let record =
    {
      Record.content_type;
      version = Record.version_1_2;
      epoch = t.send_epoch;
      sequence = t.send_sequence;
      fragment;
    }
  in
  t.send_sequence <- t.send_sequence + 1;
  let record =
    match t.write_cipher with
    | Some cipher when t.send_epoch > 0 -> Crypto.protect cipher record
    | _ -> record
  in
  Record.serialize record

(** Serialise a handshake message, record it in the transcript, and split it
    into as many records as the fragment size requires. *)
let handshake_records t ~message_type body =
  let message_seq = t.send_message_seq in
  t.send_message_seq <- message_seq + 1;
  Buffer.add_string t.transcript
    (Record.Handshake.serialize ~message_type ~message_seq body);
  Record.Handshake.fragment ~max_fragment:t.config.max_record ~message_type
    ~message_seq body
  |> List.map (serialize_record t ~content_type:Record.Handshake)

(** Pack records into as few datagrams as the record size allows: a peer must
    handle several records per datagram, and one datagram per flight keeps the
    number of round trips down. *)
let pack ~limit records =
  let datagrams, last =
    List.fold_left
      (fun (datagrams, current) record ->
        if current <> "" && String.length current + String.length record > limit
        then (current :: datagrams, record)
        else (datagrams, current ^ record))
      ([], "") records
  in
  List.rev (if last = "" then datagrams else last :: datagrams)

let flight t records =
  let datagrams = pack ~limit:t.config.max_record records in
  t.last_flight <- datagrams;
  datagrams

let alert t ~level ~description =
  [ serialize_record t ~content_type:Record.Alert
      (Record.Alert.serialize ~level ~description) ]

let record_in_transcript t ~message_type ~message_seq body =
  Buffer.add_string t.transcript
    (Record.Handshake.serialize ~message_type ~message_seq body)

(* Flight 2: ServerHello, Certificate, ServerKeyExchange, ServerHelloDone --- *)

let choose_profile hello =
  let offered = Messages.srtp_profiles hello in
  if offered = [] then
    fail Record.Alert.handshake_failure
      "the client did not offer the use_srtp extension";
  (* We implement one profile; the client lists its own in order of preference,
     so simply take ours if it is there. *)
  if List.mem Messages.Srtp_profile.aes128_cm_hmac_sha1_80 offered then
    Messages.Srtp_profile.aes128_cm_hmac_sha1_80
  else
    fail Record.Alert.handshake_failure
      "no common SRTP protection profile"

let server_hello_extensions hello ~profile =
  let optional condition extension = if condition then [ extension ] else [] in
  [ (Messages.Extension.use_srtp, Messages.use_srtp_extension profile) ]
  @ optional
      (Messages.offers hello Messages.Extension.extended_master_secret)
      (Messages.Extension.extended_master_secret, Messages.extended_master_secret_extension)
  @ optional
      (Messages.offers hello Messages.Extension.renegotiation_info
      || List.mem Messages.empty_renegotiation_info_scsv hello.cipher_suites)
      (Messages.Extension.renegotiation_info, Messages.renegotiation_info_extension)
  @ optional
      (Messages.offers hello Messages.Extension.ec_point_formats)
      (Messages.Extension.ec_point_formats, Messages.ec_point_formats_extension)

let sign t data =
  match
    X509.Private_key.sign `SHA256 ~scheme:`ECDSA t.config.certificate.private_key
      (`Message data)
  with
  | Ok signature -> signature
  | Error (`Msg message) ->
      fail Record.Alert.internal_error "could not sign: %s" message

let handle_client_hello t body =
  let hello = Messages.parse_client_hello body in
  if hello.client_version > Record.version_1_2 then
    (* DTLS versions decrease as they advance: 1.0 is 0xFEFF, 1.2 is 0xFEFD. *)
    fail Record.Alert.protocol_version "the client offers no version we support";
  if not (List.mem Messages.ecdhe_ecdsa_aes_128_gcm_sha256 hello.cipher_suites)
  then
    fail Record.Alert.handshake_failure
      "the client does not offer ECDHE-ECDSA with AES-128-GCM";
  let profile = choose_profile hello in
  let server_random = Mirage_crypto_rng.generate 32 in
  let ecdh_secret, ecdh_public = Mirage_crypto_ec.P256.Dh.gen_key () in
  let negotiation =
    {
      client_random = hello.random;
      server_random;
      ecdh_secret;
      extended_master_secret =
        Messages.offers hello Messages.Extension.extended_master_secret;
      profile;
    }
  in
  let params =
    Messages.ecdh_params ~group:Messages.Group.secp256r1 ~public_point:ecdh_public
  in
  let signature = sign t (hello.random ^ server_random ^ params) in
  (* Each message takes the next handshake sequence number and extends the
     transcript, so the four must be built in this order and not left to the
     evaluation order of an expression. *)
  let server_hello =
    handshake_records t ~message_type:Record.Handshake.server_hello
      (Messages.server_hello ~random:server_random ~session_id:""
         ~extensions:(server_hello_extensions hello ~profile))
  in
  let certificate =
    handshake_records t ~message_type:Record.Handshake.certificate
      (Messages.certificate [ t.config.certificate.der ])
  in
  let server_key_exchange =
    handshake_records t ~message_type:Record.Handshake.server_key_exchange
      (Messages.server_key_exchange ~params ~signature)
  in
  let server_hello_done =
    handshake_records t ~message_type:Record.Handshake.server_hello_done
      Messages.server_hello_done
  in
  let records =
    server_hello @ certificate @ server_key_exchange @ server_hello_done
  in
  t.state <- Awaiting_client_key_exchange negotiation;
  flight t records

let handle_client_key_exchange t negotiation body =
  let point = Messages.parse_client_key_exchange body in
  let premaster =
    match Mirage_crypto_ec.P256.Dh.key_exchange negotiation.ecdh_secret point with
    | Ok secret -> secret
    | Error e ->
        fail Record.Alert.illegal_parameter "bad client key share: %a"
          (fun () -> Format.asprintf "%a" Mirage_crypto_ec.pp_error) e
  in
  let master =
    if negotiation.extended_master_secret then
      Crypto.extended_master_secret ~premaster
        ~session_hash:(Crypto.hash (Buffer.contents t.transcript))
    else
      Crypto.master_secret ~premaster ~client_random:negotiation.client_random
        ~server_random:negotiation.server_random
  in
  let keys =
    Crypto.keys ~master ~client_random:negotiation.client_random
      ~server_random:negotiation.server_random
  in
  t.read_cipher <- Some (Crypto.cipher ~key:keys.client_key ~iv:keys.client_iv);
  t.write_cipher <- Some (Crypto.cipher ~key:keys.server_key ~iv:keys.server_iv);
  t.state <- Awaiting_finished { negotiation; master };
  []

(* Flight 4: ChangeCipherSpec, Finished ----------------------------------- *)

let handle_finished t session ~message_seq body =
  let expected =
    Crypto.verify_data ~master:session.master ~label:"client finished"
      ~transcript:(Buffer.contents t.transcript)
  in
  if body <> expected then
    fail Record.Alert.decrypt_error "the client's Finished does not verify";
  (* The client's own Finished is part of what ours attests to. *)
  record_in_transcript t ~message_type:Record.Handshake.finished ~message_seq body;
  let change_cipher_spec =
    serialize_record t ~content_type:Record.Change_cipher_spec "\001"
  in
  t.send_epoch <- t.send_epoch + 1;
  t.send_sequence <- 0;
  let finished =
    handshake_records t ~message_type:Record.Handshake.finished
      (Crypto.verify_data ~master:session.master ~label:"server finished"
         ~transcript:(Buffer.contents t.transcript))
  in
  t.state <- Connected session;
  flight t (change_cipher_spec :: finished)

(* Receiving -------------------------------------------------------------- *)

let handle_handshake_message t ~message_type ~message_seq body =
  match (t.state, message_type) with
  | Awaiting_client_hello, m when m = Record.Handshake.client_hello ->
      (* The transcript starts with the ClientHello as received. *)
      record_in_transcript t ~message_type ~message_seq body;
      handle_client_hello t body
  | Awaiting_client_key_exchange negotiation, m
    when m = Record.Handshake.client_key_exchange ->
      record_in_transcript t ~message_type ~message_seq body;
      handle_client_key_exchange t negotiation body
  | Awaiting_finished session, m when m = Record.Handshake.finished ->
      handle_finished t session ~message_seq body
  | _, m ->
      fail Record.Alert.handshake_failure "unexpected %s" (Record.Handshake.name m)

(** Add a fragment to the message being reassembled, and hand over every
    message that is complete, in sequence order. *)
let reassemble t (fragment : Record.Handshake.fragment) =
  let header = fragment.header in
  if header.message_seq < t.receive_message_seq then
    (* Already processed: the client has not seen our answer to it. *)
    `Retransmission
  else begin
    let partial =
      match Hashtbl.find_opt t.reassembly header.message_seq with
      | Some partial -> partial
      | None ->
          let partial =
            {
              message_type = header.message_type;
              data = Bytes.create header.length;
              covered = Array.make header.length false;
            }
          in
          Hashtbl.replace t.reassembly header.message_seq partial;
          partial
    in
    if
      header.fragment_offset + header.fragment_length > Bytes.length partial.data
      || header.length <> Bytes.length partial.data
    then fail Record.Alert.decode_error "inconsistent handshake fragment";
    Bytes.blit_string fragment.body 0 partial.data header.fragment_offset
      header.fragment_length;
    Array.fill partial.covered header.fragment_offset header.fragment_length true;
    `Fragment
  end

let complete_messages t =
  let rec next acc =
    match Hashtbl.find_opt t.reassembly t.receive_message_seq with
    | Some partial when Array.for_all Fun.id partial.covered ->
        let message_seq = t.receive_message_seq in
        Hashtbl.remove t.reassembly message_seq;
        t.receive_message_seq <- message_seq + 1;
        next ((message_seq, partial.message_type, Bytes.to_string partial.data) :: acc)
    | _ -> List.rev acc
  in
  next []

let handle_record t (record : Record.t) =
  match record.content_type with
  | Record.Handshake ->
      let fragments = Record.Handshake.parse record.fragment in
      let retransmission =
        List.exists (fun f -> reassemble t f = `Retransmission) fragments
      in
      let datagrams =
        List.concat_map
          (fun (message_seq, message_type, body) ->
            handle_handshake_message t ~message_type ~message_seq body)
          (complete_messages t)
      in
      (* Nothing new to say, but the peer is repeating itself: our last flight
         was lost, so send it again. *)
      if datagrams = [] && retransmission then t.last_flight else datagrams
  | Record.Change_cipher_spec ->
      (* Nothing to record: the epoch a record belongs to is written on the
         record, and everything past epoch zero is decrypted with the keys the
         key exchange settled, which exist by now or the Finished will not
         authenticate. *)
      []
  | Record.Alert when String.length record.fragment < 2 ->
      fail Record.Alert.decode_error "truncated alert"
  | Record.Alert ->
      let level = Char.code record.fragment.[0] in
      let description = Char.code record.fragment.[1] in
      if level = Record.Alert.warning && description = Record.Alert.close_notify
      then fail Record.Alert.close_notify "the peer closed the connection"
      else
        raise
          (Fatal
             ( -1,
               Printf.sprintf "the peer sent a fatal alert: %s"
                 (Record.Alert.description_name description) ))
  | Record.Application_data ->
      (* We negotiate no application protocol: anything here is not for us. *)
      []
  | Record.Unknown_content_type n ->
      fail Record.Alert.decode_error "unknown record type %d" n

let decrypt t (record : Record.t) =
  if record.epoch = 0 then Some record
  else
    match t.read_cipher with
    | None -> None
    | Some cipher -> (
        match Crypto.unprotect cipher record with
        | Some fragment -> Some { record with fragment }
        | None -> None)

let event t =
  match t.state with
  | Connected { negotiation; master } ->
      Established
        {
          profile = negotiation.profile;
          keying =
            Crypto.srtp_keying ~master ~client_random:negotiation.client_random
              ~server_random:negotiation.server_random;
        }
  | Broken message -> Failed message
  | _ -> Pending

(** Process one datagram; returns the datagrams to send back and where the
    handshake now stands. Once [Established] is returned the caller has the
    SRTP keys and no longer needs to feed us anything. *)
let handle t datagram =
  match t.state with
  | Broken message -> ([], Failed message)
  | _ -> (
      try
        let datagrams =
          Record.parse datagram
          |> List.filter_map (decrypt t)
          |> List.concat_map (handle_record t)
        in
        (datagrams, event t)
      with
      | Fatal (description, message) ->
          t.state <- Broken message;
          let datagrams =
            if description < 0 then []
            else alert t ~level:Record.Alert.fatal ~description
          in
          (datagrams, Failed message)
      | Buf.Truncated ->
          t.state <- Broken "truncated handshake message";
          ( alert t ~level:Record.Alert.fatal ~description:Record.Alert.decode_error,
            Failed "truncated handshake message" ))

(** The last flight again, for a retransmission timer. *)
let retransmit t = t.last_flight
