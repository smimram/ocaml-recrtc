(** An ICE-lite agent (RFC 8445 §2.7).

    A lite agent never gathers candidates beyond its own host address and never
    sends connectivity checks: it only answers the checks of the full agent at
    the other end, which is always the controlling one. That is all a server
    with a reachable address needs, and it is what makes traversal work for a
    browser behind a NAT — the browser's outbound check opens the mapping, and
    we answer from the very socket and address the check arrived on. *)

type credentials = { ufrag : string; pwd : string }

type t = {
  local : credentials;
  remote : credentials;
  (* The address checks are coming from. It is latched on the first valid
     request and updated whenever a valid request arrives from elsewhere, so
     that a NAT rebinding mid-session does not strand the session at a dead
     address. *)
  mutable peer : Unix.sockaddr option;
  mutable nominated : bool;
  mutable last_valid_check : float;
}

(* Credentials are drawn from the ICE character set (RFC 8445 §5.3), which is
   what base64 gives us minus its padding. *)
let random_string length =
  let alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  in
  let random = Mirage_crypto_rng.generate length in
  String.map (fun c -> alphabet.[Char.code c land 63]) random

let create ~remote =
  {
    local = { ufrag = random_string 8; pwd = random_string 24 };
    remote;
    peer = None;
    nominated = false;
    last_valid_check = Unix.gettimeofday ();
  }

(* Addresses ------------------------------------------------------------- *)

let address_of_sockaddr = function
  | Unix.ADDR_INET (ip, port) ->
      Some { Stun.ip = Ipaddr.to_octets (Ipaddr_unix.of_inet_addr ip); port }
  | Unix.ADDR_UNIX _ -> None

let string_of_sockaddr = function
  | Unix.ADDR_INET (ip, port) ->
      Printf.sprintf "%s:%d" (Unix.string_of_inet_addr ip) port
  | Unix.ADDR_UNIX path -> path

(* Handling checks -------------------------------------------------------- *)

type outcome =
  | Respond of string  (** the datagram to send back to the source *)
  | Drop of string  (** with the reason, for logging *)

(** The username a peer must present: our fragment, then theirs (RFC 8445
    §7.2.2). *)
let expected_username t = t.local.ufrag ^ ":" ^ t.remote.ufrag

let error t request ~code ~reason =
  Respond (Stun.encode ~key:t.local.pwd (Stun.binding_error request ~code ~reason))

(** Process a datagram that the demultiplexer classified as STUN. *)
let handle t ~source datagram =
  match Stun.decode datagram with
  | Error e -> Drop ("malformed STUN message: " ^ e)
  | Ok request -> (
      match request.message_type with
      (* We send no checks, so a response can only be stray or spoofed. *)
      | Stun.Binding_success | Stun.Binding_error ->
          Drop "unsolicited STUN response"
      | Stun.Other n -> Drop (Printf.sprintf "unsupported STUN method 0x%04x" n)
      | Stun.Binding_request ->
          if not (Stun.check_fingerprint request) then
            Drop "bad STUN fingerprint"
          else if Stun.username request <> Some (expected_username t) then
            (* Answering with 401 rather than dropping helps the peer notice a
               stale session instead of retrying until it times out. *)
            error t request ~code:401 ~reason:"Unauthorized"
          else if not (Stun.check_integrity ~key:t.local.pwd request) then
            error t request ~code:401 ~reason:"Unauthorized"
          else if
            (* A lite agent is always controlled; a peer claiming to be
               controlled too is a role conflict (RFC 8445 §7.3.1.1). *)
            List.exists
              (function Stun.Ice_controlled _ -> true | _ -> false)
              request.attributes
          then error t request ~code:487 ~reason:"Role Conflict"
          else
            match address_of_sockaddr source with
            | None -> Drop "check from a non-IP address"
            | Some address ->
                t.last_valid_check <- Unix.gettimeofday ();
                if t.peer <> Some source then t.peer <- Some source;
                if Stun.use_candidate request then t.nominated <- true;
                Respond
                  (Stun.encode ~key:t.local.pwd
                     (Stun.binding_success request ~address)))

(** Whether a valid check has been seen recently. The browser refreshes consent
    every few seconds, so silence means the peer is gone. *)
let alive ?(timeout = 30.) t = Unix.gettimeofday () -. t.last_valid_check < timeout
