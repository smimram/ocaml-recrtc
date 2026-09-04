(** The key schedule and record protection of TLS 1.2, as DTLS 1.2 uses them
    unchanged.

    The pseudo-random function is the one from [ocaml-tls]; everything else is
    the AEAD record layer of RFC 5246 §6.2.3.3 with the sequence number DTLS
    puts on the wire. *)

val prf : secret:string -> label:string -> seed:string -> int -> string
val hash : string -> string

(** {1 The key schedule} *)

val extended_master_secret : premaster:string -> session_hash:string -> string
(** RFC 7627: binding the master secret to a hash of the handshake rather than
    to the two nonces defeats the triple-handshake attack. Browsers always
    offer it. *)

val master_secret :
  premaster:string -> client_random:string -> server_random:string -> string

type keys = {
  client_key : string;
  server_key : string;
  client_iv : string;
  server_iv : string;
}

val keys :
  master:string -> client_random:string -> server_random:string -> keys
(** An AEAD suite needs no MAC key; AES-128-GCM takes a 16-byte key and the
    4-byte fixed part of a nonce, per direction. *)

val verify_data : master:string -> label:string -> transcript:string -> string
(** The twelve bytes a Finished message carries. *)

(** {1 What the handshake is for} *)

type srtp_keying = {
  srtp_client_key : string;
  srtp_server_key : string;
  srtp_client_salt : string;
  srtp_server_salt : string;
}

val srtp_keying :
  master:string -> client_random:string -> server_random:string -> srtp_keying
(** The keying material DTLS-SRTP extracts for the SRTP session (RFC 5764
    §4.2): a 16-byte key and a 14-byte salt for each direction. *)

(** {1 Record protection} *)

type cipher

val cipher : key:string -> iv:string -> cipher
val protect : cipher -> Record.t -> Record.t
val unprotect : cipher -> Record.t -> string option
(** The plaintext fragment, or [None] if it does not authenticate. *)
