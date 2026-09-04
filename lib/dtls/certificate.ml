(** The self-signed certificate the DTLS server presents.

    WebRTC identifies endpoints by the certificate fingerprint carried in the
    SDP rather than by any chain of trust, so a throwaway self-signed
    certificate generated at start-up is exactly what is wanted. ECDSA on P-256
    keeps the Certificate message small enough to avoid fragmenting our
    handshake flight. *)

type t = {
  private_key : X509.Private_key.t;
  certificate : X509.Certificate.t;
  der : string;  (** the certificate as it goes on the wire *)
  fingerprint : string;  (** SHA-256, colon-separated hex, as in a=fingerprint *)
}

let hex_fingerprint digest =
  String.concat ":"
    (List.map
       (fun c -> Printf.sprintf "%02X" (Char.code c))
       (List.of_seq (String.to_seq digest)))

let name =
  [
    X509.Distinguished_name.(
      Relative_distinguished_name.singleton (CN "recrtc"));
  ]

let generate () =
  let private_key = X509.Private_key.generate `P256 in
  let now = Ptime_clock.now () in
  let days n = Ptime.Span.of_int_s (n * 24 * 60 * 60) in
  (* Backdated an hour so that a client whose clock lags slightly still
     accepts it. *)
  let valid_from =
    Option.value ~default:now (Ptime.sub_span now (Ptime.Span.of_int_s 3600))
  in
  let valid_until =
    Option.value ~default:now (Ptime.add_span now (days 30))
  in
  match X509.Signing_request.create name private_key with
  | Error (`Msg e) -> failwith ("could not create a signing request: " ^ e)
  | Ok request -> (
      match
        X509.Signing_request.sign request ~valid_from ~valid_until private_key
          name
      with
      | Error e ->
          failwith
            (Format.asprintf "could not self-sign the certificate: %a"
               X509.Validation.pp_signature_error e)
      | Ok certificate ->
          {
            private_key;
            certificate;
            der = X509.Certificate.encode_der certificate;
            fingerprint =
              hex_fingerprint (X509.Certificate.fingerprint `SHA256 certificate);
          })
