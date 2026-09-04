# dtls

A DTLS 1.2 server (RFC 6347), cut down to the one thing WebRTC needs it for:
agreeing on SRTP keys and exporting them (RFC 5764).

`ocaml-tls` cannot be used for this. It implements TLS over a stream: no
explicit record epoch or sequence number, no handshake fragmentation, no
`use_srtp`. What it does provide, and what is used here, is the TLS 1.2
pseudo-random function, which DTLS 1.2 shares unchanged.

| | |
|---|---|
| `buf.ml` | the length-prefixed byte layout TLS is described in |
| `record.ml` | the record layer, handshake framing, alerts |
| `messages.ml` | the handshake messages themselves |
| `crypto.ml` | key schedule, AEAD record protection, the exporter |
| `certificate.ml` | the self-signed P-256 certificate we present |
| `server.ml` | the state machine |

## What it does not do

No application data ever crosses this connection — there are no data channels
here, only audio — so the handshake is the whole of it. That licenses a lot of
cutting:

- **One cipher suite**, `TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256`, which every
  browser offers. An AEAD suite avoids the MAC-then-encrypt CBC path entirely,
  and ECDSA on P-256 keeps the Certificate message small enough that our flight
  fits in one datagram.
- **No HelloVerifyRequest.** The cookie exchange is optional for a server and
  browsers cope without it. It exists to blunt amplification attacks; if this
  server is ever exposed to the open internet, that is the first thing to add.
- **No client certificate.** We do not send a CertificateRequest, so the
  fingerprint in the offer is never checked against what the browser presents.
  The peer is authenticated in practice by the ICE credentials, which only it
  and the signalling channel know — but this is the real gap in the security
  story, and it is the second thing to add.
- **No renegotiation, no session resumption, no DTLS 1.3.**

## The handshake

```
  client                                    server
  ClientHello                 ------>
                              <------       ServerHello
                                            Certificate
                                            ServerKeyExchange
                                            ServerHelloDone
  ClientKeyExchange
  [ChangeCipherSpec]
  Finished                    ------>
                              <------       [ChangeCipherSpec]
                                            Finished
```

Then the keys, and nothing more:

```
PRF(master_secret, "EXTRACTOR-dtls_srtp", client_random ‖ server_random, 60)
  → client key(16) ‖ server key(16) ‖ client salt(14) ‖ server salt(14)
```

We are the receiver, so the **client** half is the one that unprotects what
arrives.

**Extended master secret is not optional in practice.** Browsers offer it, and
when they do the master secret must come from a hash of the handshake rather
than from the two nonces (RFC 7627). Getting this wrong produces a handshake
that completes and keys that do not match.

## Datagrams

The two things that separate this from TLS:

- **Records carry an epoch and a sequence number**, and several may share a
  datagram. The AEAD nonce and additional data are built from them, so the
  record header is not merely a frame — it is authenticated.
- **Handshake messages carry a message sequence, and may be fragmented.**
  Incoming fragments are reassembled with a coverage map, and messages are
  handed to the state machine strictly in sequence. Outgoing messages are split
  to `max_record` bytes; the transcript hash, though, is always computed over
  the *unfragmented* form (RFC 6347 §4.2.6).

Retransmission is the peer's business first: when it repeats a message we have
already processed, our last flight was lost, so we send it again. `retransmit`
exposes the same flight for a timer, which the server does not currently need.

**A trap worth knowing**, because it cost an afternoon: building a flight takes
the next message sequence and appends to the transcript as a side effect, and
OCaml evaluates the operands of `@` right to left. Writing a flight as
`records a @ records b` numbers it backwards, and OpenSSL answers with
`unexpected_message`. Bind each message with `let`, in order.

## Testing

The state machine is pure — `handle : t -> datagram -> datagram list * event` —
which is what lets a test drive it without a socket.
`test/dtls_harness.exe` puts it on a UDP port so another implementation can:

```sh
dune exec test/dtls_harness.exe &
openssl s_client -dtls1_2 -use_srtp SRTP_AES128_CM_SHA1_80 \
  -keymatexport EXTRACTOR-dtls_srtp -keymatexportlen 60 -connect 127.0.0.1:7001
```

The handshake must complete, report `ECDHE-ECDSA-AES128-GCM-SHA256` and
`SRTP_AES128_CM_SHA1_80`, say `Extended master secret: yes`, and print sixty
bytes of keying material equal to the four values the harness prints,
concatenated. Agreement with OpenSSL on those sixty bytes is the whole point of
this library, so it is the test that matters most.
