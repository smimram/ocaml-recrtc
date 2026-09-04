(** The key schedule and record protection of TLS 1.2, as DTLS 1.2 uses them
    unchanged.

    The pseudo-random function is the one from [ocaml-tls]; everything else is
    the AEAD record layer of RFC 5246 §6.2.3.3 with the sequence number DTLS
    puts on the wire. *)

let ciphersuite = `ECDHE_ECDSA_WITH_AES_128_GCM_SHA256

let prf ~secret ~label ~seed length =
  Tls.Handshake_crypto.pseudo_random_function `TLS_1_2 ciphersuite length secret
    label seed

let hash = Digestif.SHA256.(fun s -> to_raw_string (digest_string s))

let master_secret_length = 48

(** RFC 7627: binding the master secret to a hash of the handshake rather than
    to the two nonces defeats the triple-handshake attack. Browsers always
    offer it. *)
let extended_master_secret ~premaster ~session_hash =
  prf ~secret:premaster ~label:"extended master secret" ~seed:session_hash
    master_secret_length

let master_secret ~premaster ~client_random ~server_random =
  prf ~secret:premaster ~label:"master secret"
    ~seed:(client_random ^ server_random) master_secret_length

(* AEAD suites need no MAC key; AES-128-GCM takes a 16-byte key and a 4-byte
   fixed part of the nonce, per direction. *)
let key_length = 16
let fixed_iv_length = 4

type keys = {
  client_key : string;
  server_key : string;
  client_iv : string;
  server_iv : string;
}

let keys ~master ~client_random ~server_random =
  let block =
    prf ~secret:master ~label:"key expansion"
      ~seed:(server_random ^ client_random)
      (2 * (key_length + fixed_iv_length))
  in
  let at offset length = String.sub block offset length in
  {
    client_key = at 0 key_length;
    server_key = at key_length key_length;
    client_iv = at (2 * key_length) fixed_iv_length;
    server_iv = at ((2 * key_length) + fixed_iv_length) fixed_iv_length;
  }

let verify_data_length = 12

let verify_data ~master ~label ~transcript =
  prf ~secret:master ~label ~seed:(hash transcript) verify_data_length

(** The keying material DTLS-SRTP extracts for the SRTP session (RFC 5764 §4.2):
    a 16-byte key and a 14-byte salt for each direction. *)
let srtp_key_length = 16
let srtp_salt_length = 14

type srtp_keying = {
  srtp_client_key : string;
  srtp_server_key : string;
  srtp_client_salt : string;
  srtp_server_salt : string;
}

let srtp_keying ~master ~client_random ~server_random =
  let material =
    prf ~secret:master ~label:"EXTRACTOR-dtls_srtp"
      ~seed:(client_random ^ server_random)
      (2 * (srtp_key_length + srtp_salt_length))
  in
  let at offset length = String.sub material offset length in
  {
    srtp_client_key = at 0 srtp_key_length;
    srtp_server_key = at srtp_key_length srtp_key_length;
    srtp_client_salt = at (2 * srtp_key_length) srtp_salt_length;
    srtp_server_salt = at ((2 * srtp_key_length) + srtp_salt_length) srtp_salt_length;
  }

(* Record protection ------------------------------------------------------ *)

module Gcm = Mirage_crypto.AES.GCM

type cipher = { key : Gcm.key; iv : string }

let cipher ~key ~iv = { key = Gcm.of_secret key; iv }

(* The nonce is the fixed part from the key block followed by the eight bytes
   the record carries explicitly, for which the epoch and sequence number serve
   (RFC 6347 §4.1.2.1). *)
let explicit_nonce (record : Record.t) =
  let w = Buf.writer () in
  Buf.put_uint16 w record.epoch;
  Buf.put_uint48 w record.sequence;
  Buf.contents w

let tag_length = Gcm.tag_size
let explicit_nonce_length = 8

let protect cipher (record : Record.t) =
  let explicit = explicit_nonce record in
  let adata =
    Record.additional_data record ~plaintext_length:(String.length record.fragment)
  in
  let sealed =
    Gcm.authenticate_encrypt ~key:cipher.key ~nonce:(cipher.iv ^ explicit) ~adata
      record.fragment
  in
  { record with fragment = explicit ^ sealed }

let unprotect cipher (record : Record.t) =
  let length = String.length record.fragment in
  if length < explicit_nonce_length + tag_length then None
  else
    let explicit = String.sub record.fragment 0 explicit_nonce_length in
    let sealed =
      String.sub record.fragment explicit_nonce_length (length - explicit_nonce_length)
    in
    let adata =
      Record.additional_data record
        ~plaintext_length:(String.length sealed - tag_length)
    in
    Gcm.authenticate_decrypt ~key:cipher.key ~nonce:(cipher.iv ^ explicit) ~adata
      sealed
