(** The handshake messages a DTLS server exchanges with a WebRTC client.

    Only one cipher suite is supported —
    [TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256] — which every browser offers, so
    the set of messages is small: the key exchange is always ephemeral ECDH on
    P-256 and the record protection is always an AEAD. *)

let ecdhe_ecdsa_aes_128_gcm_sha256 = 0xC02B

(* The signalling-plane counterpart of an SCSV: a client that has never
   renegotiated announces it this way instead of with the extension. *)
let empty_renegotiation_info_scsv = 0x00FF

module Group = struct
  let secp256r1 = 23
end

module Signature_algorithm = struct
  (* hash and signature, as the two bytes of a SignatureAndHashAlgorithm. *)
  let sha256 = 4
  let ecdsa = 3
end

module Extension = struct
  let supported_groups = 10
  let ec_point_formats = 11
  let signature_algorithms = 13
  let use_srtp = 14
  let extended_master_secret = 23
  let renegotiation_info = 0xff01

  let uncompressed_point = 0
end

module Srtp_profile = struct
  (* RFC 5764 §4.1.2 *)
  let aes128_cm_hmac_sha1_80 = 0x0001
  let aes128_cm_hmac_sha1_32 = 0x0002
end

(* ClientHello ------------------------------------------------------------ *)

type client_hello = {
  client_version : int;
  random : string;  (** 32 bytes: a timestamp and 28 random ones *)
  session_id : string;
  cookie : string;  (** DTLS only; empty unless we ask for one *)
  cipher_suites : int list;
  compression_methods : int list;
  extensions : (int * string) list;
}

let parse_extensions r =
  (* The extension block is optional, and absent from a bare TLS 1.0 hello. *)
  if Buf.at_end r then []
  else
    let block = Buf.sub_vector16 r in
    Buf.list_of block (fun r ->
        let typ = Buf.uint16 r in
        (typ, Buf.vector16 r))

let parse_client_hello body =
  let r = Buf.reader body in
  let client_version = Buf.uint16 r in
  let random = Buf.take r 32 in
  let session_id = Buf.vector8 r in
  let cookie = Buf.vector8 r in
  let cipher_suites =
    let suites = Buf.sub_vector16 r in
    Buf.list_of suites Buf.uint16
  in
  let compression_methods = List.map Char.code (List.of_seq (String.to_seq (Buf.vector8 r))) in
  {
    client_version;
    random;
    session_id;
    cookie;
    cipher_suites;
    compression_methods;
    extensions = parse_extensions r;
  }

let extension hello typ = List.assoc_opt typ hello.extensions
let offers hello typ = List.mem_assoc typ hello.extensions

(** The SRTP protection profiles the client offers, most preferred first
    (RFC 5764 §4.1.1). *)
let srtp_profiles hello =
  match extension hello Extension.use_srtp with
  | None -> []
  | Some value -> (
      try
        let r = Buf.reader value in
        let profiles = Buf.sub_vector16 r in
        Buf.list_of profiles Buf.uint16
      with Buf.Truncated -> [])

(* ClientKeyExchange ------------------------------------------------------ *)

(** For an ECDHE suite the message is the client's ephemeral public point. *)
let parse_client_key_exchange body = Buf.vector8 (Buf.reader body)

(* Server messages -------------------------------------------------------- *)

let put_extension w typ f =
  Buf.put_uint16 w typ;
  Buf.put_vector16 w f

let server_hello ~random ~session_id ~extensions =
  let w = Buf.writer () in
  Buf.put_uint16 w Record.version_1_2;
  Buf.put_string w random;
  Buf.put_vector8_string w session_id;
  Buf.put_uint16 w ecdhe_ecdsa_aes_128_gcm_sha256;
  Buf.put_uint8 w 0 (* no compression *);
  Buf.put_vector16 w (fun w ->
      List.iter (fun (typ, f) -> put_extension w typ f) extensions);
  Buf.contents w

let use_srtp_extension profile w =
  Buf.put_vector16 w (fun w -> Buf.put_uint16 w profile);
  Buf.put_vector8_string w "" (* no MKI *)

let ec_point_formats_extension w =
  Buf.put_vector8 w (fun w -> Buf.put_uint8 w Extension.uncompressed_point)

let renegotiation_info_extension w = Buf.put_vector8_string w ""
let extended_master_secret_extension _ = ()

let certificate ders =
  let w = Buf.writer () in
  Buf.put_vector24 w (fun w -> List.iter (Buf.put_vector24_string w) ders);
  Buf.contents w

(** The ECDHE parameters, as they appear in ServerKeyExchange and as they are
    signed: a named curve and the server's ephemeral public point. *)
let ecdh_params ~group ~public_point =
  let w = Buf.writer () in
  Buf.put_uint8 w 3 (* named_curve *);
  Buf.put_uint16 w group;
  Buf.put_vector8_string w public_point;
  Buf.contents w

let server_key_exchange ~params ~signature =
  let w = Buf.writer () in
  Buf.put_string w params;
  Buf.put_uint8 w Signature_algorithm.sha256;
  Buf.put_uint8 w Signature_algorithm.ecdsa;
  Buf.put_vector16_string w signature;
  Buf.contents w

let server_hello_done = ""
