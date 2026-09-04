# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`recrtc` records what a browser sends over WebRTC as an Ogg/Opus file. The
WebRTC transport stack is implemented here because none of it exists in opam:
`tls` has no DTLS, and there is no STUN, ICE, SRTP or SDP package. `README.md`
describes the result; this file is about working on it.

`experiments/recws/` is a separate, self-contained predecessor that uploaded
`MediaRecorder` chunks over HTTP. It is kept for reference and is not part of
the build path described here.

## Commands

```sh
make                     # dune build
make test                # dune test  (add --force: dune caches a passing run)
make serve IP=<address>  # dune exec src/recrtc.exe -- --ip <address>
make serve ARGS=--debug  # extra flags
```

`--ip` is effectively required for anything but a same-machine loopback test;
see "The advertised address" below. `--debug` logs every dropped datagram.

Tests are one executable (`dune exec test/test_recrtc.exe`) built from
`test/testlib.ml` plus one module per area. There is no per-test filter: to run
a single suite, comment out the other `Test_*.run ()` calls in
`test/test_recrtc.ml`. A new test module must be added **both** to the
`(modules ...)` field in `test/dune` and to `test_recrtc.ml`.

### Testing against other implementations

The unit tests are mostly published vectors (RFC 5769 for STUN, RFC 3711
appendix B for SRTP), because a homegrown crypto test only proves the code
agrees with itself. Two further checks are worth running after touching
`lib/dtls` or the media path:

```sh
dune exec test/dtls_harness.exe &     # a bare DTLS server on UDP 7001
openssl s_client -dtls1_2 -use_srtp SRTP_AES128_CM_SHA1_80 \
  -keymatexport EXTRACTOR-dtls_srtp -keymatexportlen 60 -connect 127.0.0.1:7001
```

The handshake must complete and OpenSSL's exported sixty bytes must equal the
four values the harness prints, concatenated.

```sh
chromium --headless=new --no-sandbox --use-fake-ui-for-media-stream \
  --use-fake-device-for-media-stream "http://localhost:8080/?autostart"
```

The `?autostart` hook in `static/recrtc.js` exists for exactly this. Chromium's
fake device emits a 440 Hz beep, so a good recording shows that peak in an FFT
and probes as mono 48 kHz Opus.

## Architecture

Signalling is one HTTP exchange; all media arrives on a **single UDP socket
shared by every session**, where STUN, DTLS and SRTP are demultiplexed by the
first byte of the datagram (RFC 7983). `src/recrtc.ml` holds that loop and the
session table; the libraries under `lib/` are transport pieces that know
nothing about sockets or Dream.

A session is found two ways, and both must stay in step: by the local ICE
fragment inside a STUN check's USERNAME, and by source address
(`sessions_by_peer`) for DTLS and media, which identify themselves no other
way. `track_peer` updates the second when the agent latches or re-latches.

Layering: `sdp` and `ice` are independent; `dtls` produces the SRTP keying
material that `srtp` consumes; `srtp` depends on `rtp` for the header length,
which is also where encryption starts; `oggopus` takes the Opus packets out the
far end. `lib/ice/stun.ml` deliberately has no `Unix` dependency so the RFC
vectors can drive it.

`Dtls.Server` is a pure state machine — `handle : t -> datagram -> datagram
list * event` — which is what lets `test/dtls_harness.exe` and `src/recrtc.ml`
drive the same code. Keep it that way.

Deliberate scope limits, all load-bearing: ICE-lite (we never send checks),
`a=setup:passive` (so only the DTLS *server* side exists), one cipher suite,
one SRTP profile, no application data over DTLS, audio only.

## Things that will bite you

**The advertised address.** The media socket binds to the address given by
`--ip` rather than to every interface. This is not a detail: a peer discards a
check response that arrives from an address other than the one it wrote to
(RFC 8445 §7.2.5.2.1), and a wildcard socket lets the routing table pick the
source. Chrome pairs *its* LAN candidate against our loopback candidate, so an
unreachable `--ip 127.0.0.1` fails in a way that looks like silence: ICE
latches on our side while the browser sits in `checking` forever. `--bind` sets
the local address separately, for a server behind a 1:1 NAT.

**Evaluation order in flight construction.** `handshake_records` takes the next
handshake sequence number and appends to the transcript as a side effect.
OCaml evaluates the operands of `@` right to left, so building a flight as
`records a @ records b` numbers them backwards — which cost an afternoon once,
appearing as an `unexpected_message` alert from OpenSSL. Bind each message with
`let` in order. The same applies anywhere else a sequence counter is bumped
inside an expression.

**A stale server holds the port.** `dune exec` fails with `EADDRINUSE` and
exits, leaving the *old* binary answering requests, so your changes seem to
have no effect. Kill it first — but write the pattern so it cannot match the
shell running it: `pkill -f '[r]ecrtc\.exe'`, not `pkill -f recrtc.exe`.

**Log levels.** `Dream.sub_log` keeps the threshold in force when it was
created, and the `log` value here is created at module initialisation, before
`main` runs. `Dream.initialize_log ~level` alone will not make its `debug`
calls appear; ``Dream.set_log_level "recrtc" `Debug`` is also needed.

**Secure context.** `getUserMedia` needs one. `http://localhost:8080` qualifies;
reaching the same server over a LAN address does not, and the Record button
fails there. Recording from another machine needs HTTPS in front.

**Ogg muxing is ours on purpose.** `ocaml-ogg` cannot do it —
`Ogg.Stream.packet` is abstract with no constructor — and `ocaml-opus` only
encodes from PCM. Routing through them would mean decoding and re-encoding the
browser's audio. `lib/oggopus` writes pages directly so packets are stored
bit-exact. Do not reintroduce those dependencies for this.

**Granule positions come from RTP timestamps**, not from accumulating packet
durations: both count 48 kHz samples, so a lost packet leaves a gap of the
right length instead of pulling everything after it earlier.

## Conventions

- Formatted in ocamlformat's default style, but there is no `.ocamlformat`, so
  `dune build @fmt` touches only `dune` files. Match the surrounding style by
  hand; do not add a `.ocamlformat` unless asked.
- Comments explain *why*, and are worth spending words on where a protocol
  requires something non-obvious; cite the RFC and section when doing so.
- A library whose name matches one of its modules makes that module the only
  entry point, which is why `lib/ice` has `agent.ml` and `stun.ml` and no
  `ice.ml`.
- Commit messages: a short capitalized sentence ending with a period, then a
  body explaining the reasoning, wrapped at 72 columns.
- Untracked `*~` files are Emacs backups — leave them alone.
