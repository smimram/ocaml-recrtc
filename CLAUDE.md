# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`recrtc` records what a browser sends over WebRTC — Opus audio, and VP8, VP9
or H.264 video — as an Ogg/Opus or Matroska file. The WebRTC transport stack is
implemented here because none of it exists in opam: `tls` has no DTLS, and
there is no STUN, ICE, SRTP or SDP package. `README.md` describes the result;
this file is about working on it.

`experiments/recws/` is a separate, self-contained predecessor that uploaded
`MediaRecorder` chunks over HTTP. It is kept for reference and is not part of
the build path described here.

## Commands

```sh
make                     # dune build
make test                # dune test  (add --force: dune caches a passing run)
make serve               # dune exec src/recrtc.exe
make serve IP=<address>  # override the advertised candidates
make serve ARGS=--debug  # extra flags
```

`--debug` logs every dropped datagram, and the offer and answer in full, which
is usually the fastest way to see why a browser is not sending something.
`--ip` is only needed when the address
to advertise is not one the machine can see for itself; see "The advertised
address" below.

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

The `?autostart` hook in `static/recrtc.js` exists for exactly this; `&audio`
records audio alone, and `&codec=vp9` or `&codec=h264` narrows the offer
through `setCodecPreferences` so the other video paths can be reached, since a
browser otherwise always picks VP8 from what we accept.

Chromium's fake device sounds a steady tone (400 Hz in current builds, not the
440 Hz older notes claim — measure, do not assume) and draws a rolling disc
**with the timecode burnt into the picture**. That last one is the useful part:
seek to five seconds, extract the frame, and if it reads `0:00:05` the two
timelines are right, which no amount of probing the container will tell you.

```sh
ffprobe -hide_banner recording-*.webm          # VP8 640x480 + Opus 48000 mono
ffmpeg -i recording-*.webm -f null -           # decodes clean, exit 0
ffmpeg -ss 5 -i recording-*.webm -frames:v 1 frame.png
```

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

Both tracks share that one transport under BUNDLE and are told apart **by
payload type**, which `lib/sdp` fixes at one per kind when it answers.

Layering: `sdp` and `ice` are independent; `dtls` produces the SRTP keying
material that `srtp` consumes; `srtp` depends on `rtp` for the header length,
which is also where encryption starts; `rtp` also holds the VP8, VP9 and H.264
payload formats and the timeline both containers measure against; `oggopus`
takes the Opus packets out the far end, and `matroska` takes both, borrowing
the Opus header from `oggopus`. `lib/ice/stun.ml` deliberately has no `Unix`
dependency so the RFC vectors can drive it.

`Dtls.Server` is a pure state machine — `handle : t -> datagram -> datagram
list * event` — which is what lets `test/dtls_harness.exe` and `src/recrtc.ml`
drive the same code. Keep it that way.

Deliberate scope limits, all load-bearing: ICE-lite (we never send checks),
`a=setup:passive` (so only the DTLS *server* side exists), one cipher suite,
one SRTP profile, no application data over DTLS, no RTCP ever sent, one audio
and one video stream per session.

## Things that will bite you

**The advertised address.** Two constraints pull against each other here.
A peer discards a check response arriving from an address other than the one it
wrote to (RFC 8445 §7.2.5.2.1), which argues for binding the media socket to
the single address we advertise. But a browser only pairs its own candidates
with ones it can route to, and it gathers no loopback candidate when a real
interface exists — so advertising `127.0.0.1` alone strands a browser on this
very machine, in a way that looks like silence: ICE latches on our side while
the browser sits in `checking` and then `failed`.

So the default advertises every address of the machine, loopback last, and
binds the wildcard; the routing table then picks a source that agrees with the
destination for every pair a peer can actually reach us on. Passing a single
`--ip` goes back to binding that address exactly. `--bind` sets the local
address independently, for a server behind a 1:1 NAT.

**Evaluation order in flight construction.** `handshake_records` takes the next
handshake sequence number and appends to the transcript as a side effect.
OCaml evaluates the operands of `@` right to left, so building a flight as
`records a @ records b` numbers them backwards — which cost an afternoon once,
appearing as an `unexpected_message` alert from OpenSSL. Bind each message with
`let` in order. The same applies anywhere else a sequence counter is bumped
inside an expression.

**A stale server holds the port.** `dune exec` fails with `EADDRINUSE` and
exits, leaving the *old* binary answering requests, so your changes seem to
have no effect. Kill it first — but `pkill -f` matches the shell running the
command as readily as the server, and killing your own shell mid-script is a
confusing way to find that out. The bracket trick (`pkill -f '[r]ecrtc\.exe'`)
only helps when that pattern is the line's *only* mention of the binary; if the
same command also runs `./_build/.../recrtc.exe`, the shell matches anyway.
Kill by PID, or give the `pkill` a line of its own.

**Codec names are echoed, not normalised.** Encoding names in `a=rtpmap` are
case-insensitive (RFC 4566 §6) and browsers are inconsistent: Chrome writes
`opus` but `VP8`. `lib/sdp` used to lowercase the name it parsed, which was
invisible for audio and fatal for video — answering `vp8` where Chrome offered
`VP8` makes it negotiate the section, report the sender *active*, and then
never start its encoder. No error, no warning, `framesEncoded` stuck at zero
and `targetBitrate` undefined. Match case-insensitively; echo the offer's own
spelling.

When video is silently absent like that, the fastest diagnosis is
`connection.getStats()` from the page against `--enable-logging=stderr`:
`media-source` tells you whether the camera is producing frames at all, and
`outbound-rtp` whether the encoder ever ran. It separates "the browser is not
sending" from "we are not receiving" in one step.

**An incomplete picture is dropped, not written short.** This is where the
video path stops resembling the audio one. A lost audio packet leaves a gap of
the right length and everything after it is still fine. A lost video packet
does not shorten a picture, it corrupts it, and every frame predicted from it
afterwards. `Rtp.Frame` therefore discards a frame with a sequence gap in it,
and the recording does not start until the first keyframe.

**Matroska lengths of all ones are reserved.** A variable-width integer whose
value bits are all ones means "unknown", so each width holds one less than it
looks: 126 fits in one byte and 127 needs two. Getting this wrong writes a file
that parses right up until it doesn't.

**Log levels.** `Dream.sub_log` keeps the threshold in force when it was
created, and the `log` value here is created at module initialisation, before
`main` runs. `Dream.initialize_log ~level` alone will not make its `debug`
calls appear; ``Dream.set_log_level "recrtc" `Debug`` is also needed.

**Secure context.** `getUserMedia` needs one. `http://localhost:8080` qualifies;
reaching the same server over a LAN address does not, and the Record button
fails there. Recording from another machine needs HTTPS in front.

**Muxing is ours on purpose, in both containers.** `ocaml-ogg` cannot do it —
`Ogg.Stream.packet` is abstract with no constructor — and `ocaml-opus` only
encodes from PCM. Routing through them, or through anything that wants raw
samples, would mean decoding and re-encoding what the browser already encoded.
`lib/oggopus` and `lib/matroska` write bytes directly so packets and frames are
stored bit-exact. Do not reintroduce those dependencies for this.

**Granule positions come from RTP timestamps**, not from accumulating packet
durations: both count 48 kHz samples, so a lost packet leaves a gap of the
right length instead of pulling everything after it earlier. `Rtp.Timeline`
holds the wrap handling both containers need.

**A Matroska recording that is killed still plays.** Lengths not known when an
element opens — the segment, each cluster — are written as the eight-byte
"unknown" form and patched in place on close. Keep it that way: it is why a
`kill -9` mid-recording leaves a file that decodes to its last cluster, missing
only its duration. Worth re-checking after touching `lib/matroska/writer.ml`.

## Conventions

- Formatted in ocamlformat's default style, but there is no `.ocamlformat`, so
  `dune build @fmt` touches only `dune` files. Match the surrounding style by
  hand; do not add a `.ocamlformat` unless asked.
- Comments explain *why*, and are worth spending words on where a protocol
  requires something non-obvious; cite the RFC and section when doing so.
- Every module under `lib/` has an `.mli`, which is where its documentation
  lives; the `.ml` keeps only the comments about how something is done.
  `srtp.mli` ends with a "Primitives" section exposed for the published test
  vectors — the rest of that library's internals, the rollover counter and
  replay window among them, are reached through `unprotect` alone.
- A library whose name matches one of its modules makes that module the only
  entry point, which is why `lib/ice` has `agent.ml` and `stun.ml` and no
  `ice.ml`.
- Commit messages: a short capitalized sentence ending with a period, then a
  body explaining the reasoning, wrapped at 72 columns.
- Untracked `*~` files are Emacs backups — leave them alone.
