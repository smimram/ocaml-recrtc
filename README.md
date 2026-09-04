# recrtc

A web server that records what a browser sends it over WebRTC, as an
Ogg/Opus file. The WebRTC stack it needs — SDP, ICE, DTLS and SRTP — is
implemented here, in OCaml, since none of it exists in opam.

```
make serve                       # then open http://localhost:8080
make serve IP=203.0.113.7        # only if we cannot see the address ourselves
```

Press *Record*, allow the microphone, press *Stop*: the server writes
`recording-<date>.opus`, which any player reads.

## What it does

The browser sends an offer over HTTP; the server answers as an **ICE-lite**,
**DTLS-passive**, receive-only endpoint with a single host candidate. Media
then arrives on one UDP port, where STUN, DTLS and SRTP are demultiplexed by
their first byte (RFC 7983).

- The browser's connectivity checks are answered from the socket they arrived
  on, which is what opens the mapping when the browser is behind a NAT. Every
  address of this machine is advertised as a candidate, the loopback last, so
  that a browser here and a browser on the network each find one they can pair
  with. `--ip` overrides the list, which is what a server behind a port
  forwarding needs.
- DTLS exists only to agree on SRTP keys — there is no application data, so
  the handshake is cut to one cipher suite, `ECDHE-ECDSA-AES128-GCM-SHA256`,
  against a self-signed P-256 certificate made at start-up.
- The Opus packets are written to the file exactly as they arrive, nothing is
  decoded or re-encoded. The RTP timestamp is the granule position Ogg wants,
  so a lost packet leaves a gap of the right length rather than shifting the
  audio.

## Layout

| | |
|---|---|
| `lib/sdp` | parsing an offer, generating the answer |
| `lib/ice` | STUN codec (RFC 5389) and an ICE-lite agent (RFC 8445) |
| `lib/dtls` | a DTLS 1.2 server (RFC 6347) exporting SRTP keys (RFC 5764) |
| `lib/srtp` | unprotecting SRTP and SRTCP (RFC 3711) |
| `lib/rtp` | RTP packets and a jitter buffer |
| `lib/oggopus` | writing Ogg pages and an Opus stream (RFC 7845) |
| `src` | the HTTP server, the media socket and the sessions |
| `static` | the page and its script |

## Testing

`make test` runs the published vectors the delicate parts stand on: RFC 5769
for STUN, RFC 3711 appendix B for the SRTP key derivation and keystream, plus
the RTP, jitter-buffer and Opus framing logic.

The DTLS server can be exercised on its own against another implementation:

```
dune exec test/dtls_harness.exe &
openssl s_client -dtls1_2 -use_srtp SRTP_AES128_CM_SHA1_80 \
  -keymatexport EXTRACTOR-dtls_srtp -keymatexportlen 60 -connect 127.0.0.1:7001
```

The handshake completes and the sixty exported bytes agree with the ones the
harness prints.

End to end, a headless browser will do:

```
chromium --headless=new --use-fake-ui-for-media-stream \
  --use-fake-device-for-media-stream "http://localhost:8080/?autostart"
```

## Not there yet

- The client certificate is not requested, so the fingerprint in the offer is
  not checked against the one the browser presents.
- No RTCP is sent back: no receiver reports, so the browser gets no feedback
  on what arrived.
- Audio only, one stream per session, and one SRTP profile
  (`AES_CM_128_HMAC_SHA1_80`).
