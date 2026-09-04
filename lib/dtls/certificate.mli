(** The self-signed certificate the DTLS server presents.

    WebRTC identifies endpoints by the certificate fingerprint carried in the
    SDP rather than by any chain of trust, so a throwaway self-signed
    certificate generated at start-up is exactly what is wanted. ECDSA on P-256
    keeps the Certificate message small enough not to fragment our handshake
    flight. *)

type t = {
  private_key : X509.Private_key.t;
  certificate : X509.Certificate.t;
  der : string;  (** the certificate as it goes on the wire *)
  fingerprint : string;  (** SHA-256, colon-separated hex, as in a=fingerprint *)
}

val generate : unit -> t
(** @raise Failure if the key or the certificate cannot be made. *)
