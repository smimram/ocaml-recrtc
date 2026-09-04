(** RFC 3711 test vectors, plus the sequence-number bookkeeping around them. *)

open Testlib

let master_key = hex "E1F97A0D3E018BE0D64FA32C06DE4139"
let master_salt = hex "0EC675AD498AFEEBB6960B3AABE6"

(* §B.2: the counter block and keystream for a session key and salt. *)
let session_key = hex "2B7E151628AED2A6ABF7158809CF4F3C"
let session_salt = hex "F0F1F2F3F4F5F6F7F8F9FAFBFCFD"

let keystream ~length =
  let keys =
    {
      Srtp.cipher = Mirage_crypto.AES.CTR.of_secret session_key;
      authentication = "";
      salt = session_salt;
    }
  in
  (* Counter mode over zeroes is the keystream itself. *)
  Srtp.cipher keys ~ssrc:0l ~index:0 ~data:(String.make length '\000')

let run () =
  suite "srtp";

  (* §B.3: key derivation *)
  check_string "cipher key"
    ~expected:(hex "C61E7A93744F39EE10734AFE3FF7A087")
    (Srtp.derive ~master_key ~master_salt ~label:Srtp.Label.rtp_encryption 16);
  check_string "cipher salt"
    ~expected:(hex "30CBBC08863D8C85D49DB34A9AE1")
    (Srtp.derive ~master_key ~master_salt ~label:Srtp.Label.rtp_salt 14);
  check_string "auth key"
    ~expected:(hex "CEBE321F6FF7716B6FD4AB49AF256A156D38BAA4")
    (Srtp.derive ~master_key ~master_salt ~label:Srtp.Label.rtp_authentication 20);

  (* §B.2: counter block and keystream *)
  check_string "counter block"
    ~expected:(hex "F0F1F2F3F4F5F6F7F8F9FAFBFCFD0000")
    (Srtp.counter ~salt:session_salt ~ssrc:0l ~index:0);
  check_string "keystream"
    ~expected:
      (hex
         "E03EAD0935C95E80E166B16DD92B4EB4\
          D23513162B02D0F72A43A2FE4A5F97AB\
          41E95B3BB0A2E8DD477901E4FCA894C0")
    (keystream ~length:48);

  (* The counter must depend on the source and the packet index. *)
  check "the counter depends on the source"
    (Srtp.counter ~salt:session_salt ~ssrc:1l ~index:0
    <> Srtp.counter ~salt:session_salt ~ssrc:0l ~index:0);
  check "the counter depends on the index"
    (Srtp.counter ~salt:session_salt ~ssrc:0l ~index:1
    <> Srtp.counter ~salt:session_salt ~ssrc:0l ~index:0);

  (* Rollover: a sequence number that wraps must be recognised as belonging to
     the next rollover counter, and a straggler from before the wrap to the
     previous one. *)
  let stream = { Srtp.roc = 0; highest = 0; window = 0L; seen = false } in
  let receive sequence =
    let roc = Srtp.estimate_roc stream sequence in
    let index_ = Srtp.index roc sequence in
    let fresh = Srtp.fresh stream index_ in
    if fresh then Srtp.remember stream ~roc ~sequence ~index_;
    (roc, fresh)
  in
  check "first packet" (receive 65534 = (0, true));
  check "next packet" (receive 65535 = (0, true));
  check "the sequence wraps" (receive 0 = (1, true));
  check "and carries on" (receive 1 = (1, true));
  check "a straggler from before the wrap" (fst (receive 65533) = 0);
  check "a replay is refused" (receive 1 = (1, false));
  check "the rollover counter is now one" (stream.roc = 1)
