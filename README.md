# recrtc

A web server that records what a browser sends it over WebRTC — the
microphone, and the camera if you want it — as an Ogg/Opus or Matroska file.
The WebRTC stack it needs — SDP, ICE, DTLS and SRTP — is implemented here, in
OCaml, since none of it exists in opam.

```
make serve                       # then open http://localhost:8080
make serve IP=203.0.113.7        # only if we cannot see the address ourselves
```

Press *Record*, allow the microphone and the camera, press *Stop*: the server
writes `recording-<date>.webm`, which any player reads. Untick *camera* and it
writes `recording-<date>.opus` instead.

## What it does

The browser sends an offer over HTTP; the server answers as an **ICE-lite**,
**DTLS-passive**, receive-only endpoint. Both tracks are bundled onto one
transport, so all media arrives on one UDP port, where STUN, DTLS and SRTP are
demultiplexed by their first byte (RFC 7983) and the two streams are told apart
by payload type.

- The browser's connectivity checks are answered from the socket they arrived
  on, which is what opens the mapping when the browser is behind a NAT. Every
  address of this machine is advertised as a candidate, the loopback last, so
  that a browser here and a browser on the network each find one they can pair
  with. `--ip` overrides the list, which is what a server behind a port
  forwarding needs.
- DTLS exists only to agree on SRTP keys — there is no application data, so
  the handshake is cut to one cipher suite, `ECDHE-ECDSA-AES128-GCM-SHA256`,
  against a self-signed P-256 certificate made at start-up.
- The Opus packets and the video frames are written to the file exactly as they
  arrive, nothing is decoded or re-encoded. For audio the RTP timestamp is the
  granule position Ogg wants, so a lost packet leaves a gap of the right length
  rather than shifting the sound.
- Video is VP8, VP9 or H.264, reassembled from the packets it was cut into. A
  picture missing a packet is dropped whole rather than written short: unlike
  an audio gap, a partial picture corrupts every frame predicted from it.
  Recording starts at the first keyframe, so the file opens on a picture that
  decodes on its own.
- Audio alone goes to Ogg. With video it goes to Matroska — `.webm` for VP8
  and VP9, `.mkv` for H.264, whose codec WebM's `DocType` does not admit.

## Layout

| | |
|---|---|
| `lib/sdp` | parsing an offer, generating the answer |
| `lib/ice` | STUN codec (RFC 5389) and an ICE-lite agent (RFC 8445) |
| `lib/dtls` | a DTLS 1.2 server (RFC 6347) exporting SRTP keys (RFC 5764) |
| `lib/srtp` | unprotecting SRTP and SRTCP (RFC 3711), and protecting the SRTCP we send |
| `lib/rtp` | RTP packets, a jitter buffer, the RTCP we send back, VP8, VP9 and H.264 payload formats |
| `lib/oggopus` | writing Ogg pages and an Opus stream (RFC 7845) |
| `lib/matroska` | writing EBML and a Matroska file (RFC 9559) |
| `src` | the HTTP server, the media socket and the sessions |
| `static` | the page and its script |

Each library under `lib/` has a README of its own, covering what it implements,
what it deliberately does not, and how it is checked.

## Testing

`make test` runs the published vectors the delicate parts stand on: RFC 5769
for STUN, RFC 3711 appendix B for the SRTP key derivation and keystream, plus
the RTP, jitter-buffer, Opus framing, VP8, VP9, H.264 and EBML logic.

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

Its fake device draws a rolling disc with the time burnt into the picture and
sounds a steady tone, so seeking to five seconds and reading the frame checks
the timeline as well as the pixels. Add `&audio` for audio alone, or
`&codec=h264` to narrow the offer and exercise the other video path.

## Not there yet

- The client certificate is not requested, so the fingerprint in the offer is
  not checked against the one the browser presents.
- The RTCP sent back is a keyframe request when a picture is lost, and a
  receiver report once a second. There is no negative acknowledgement, so a
  lost packet is never retransmitted, and no transport-wide congestion
  feedback.
- The two tracks are lined up by when their first packets arrived, not by the
  NTP-to-RTP mapping in the browser's sender reports, of which we read only the
  timestamp a receiver report has to echo. Good to a few tens of milliseconds,
  not to the sample.
- One audio and one video stream per session, and one SRTP profile
  (`AES_CM_128_HMAC_SHA1_80`).
