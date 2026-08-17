# AGENTS.md

## Project

`recrtc` — an OCaml web application for recording audio from the browser. The
server is a small [Dream](https://aantron.github.io/dream/) app
(`src/recrtc.ml`) that serves the static frontend in `static/`: `/` maps to
`static/index.html`, everything else is served from `static/` by
`Dream.static`. The client side lives entirely in `static/index.html` for now
(no bundler, no JS toolchain).

The page has a single button that records microphone audio and uploads it to
the server, which stores it as `audio.webm` in the working directory. See
"Audio recording" below.

## Layout

- `src/recrtc.ml` — Dream server (routing, static file serving, audio upload).
- `src/dune` — executable `recrtc`, depends on `dream` and `lwt.unix`,
  preprocessed with `lwt_ppx` (for `let%lwt`).
- `static/` — frontend assets served as-is.
- `dune-project` — `(lang dune 3.14)`.
- `Makefile` — thin wrapper over dune.
- `audio.webm` — generated at the project root by a recording; gitignored.

Paths (`static/`, `audio.webm`) are relative to the working directory, so the
server must be run from the project root.

## Build and run

```sh
make          # or: dune build
make serve    # or: dune exec src/recrtc.exe   -- serves on http://localhost:8080
```

There are no tests yet. After changing OCaml code, run `dune build` to check it
compiles; after changing `static/`, restart the server (files are read from disk
at request time, so a reload of the page is enough unless routing changed).

If a server seems to ignore your changes, check for a stale instance holding the
port: `dune exec` logs `Unix_error(EADDRINUSE, "bind", "")` and exits, leaving the
*old* binary answering requests (so new routes 404). `pkill -f recrtc.exe` first.

## Audio recording

The browser captures with `getUserMedia` and `MediaRecorder`, and POSTs the
WebM/Opus stream to the server in chunks while recording. There is no
`RTCPeerConnection`: real WebRTC transport would need a server-side ICE and
DTLS-SRTP stack, which OCaml does not have. Routes:

- `POST /record/start` — truncates `audio.webm` (start of a new recording).
- `POST /record/chunk` — appends the raw request body to `audio.webm`.

Things that will bite you here:

- **Only the first chunk carries the WebM header** (EBML, Segment, Tracks); the
  rest are bare Cluster continuations. Chunks are therefore not independently
  decodable and must be appended *in order* to a single file. The client
  serializes uploads by chaining them onto one promise; the server additionally
  holds an `Lwt_mutex` around every write. Keep both.
- Audio is stored **as-is**, no transcode. The extension is `.webm` because
  `MediaRecorder` cannot produce MP3. Converting would mean an ffmpeg step.
- The chunk period is the `recorder.start(250)` argument in `static/index.html`,
  and it dominates end-to-end latency (~300 ms to disk). Going below ~20 ms buys
  nothing: that is the Opus frame and WebM cluster granularity.
- Uploads are raw `application/octet-stream` read with `Dream.body`. Do **not**
  switch to `Dream.form`/`Dream.multipart` without adding `Dream.set_secret` —
  those run a CSRF check.
- `navigator.mediaDevices` only exists in a secure context. `http://localhost:8080`
  qualifies; reaching the same server over a LAN IP does not, and the button will
  fail there. That would need `Dream.run ~tls:true` (`dream.certificate`).

The server half can be tested without a browser or microphone, which is worth
doing since the capture side needs a real mic:

```sh
d=$(mktemp -d)   # keep the fixtures out of the repo; audio.webm lands in the cwd
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=3" -c:a libopus -f webm $d/ref.webm
split -n 12 -d $d/ref.webm $d/part.
curl -X POST http://localhost:8080/record/start
for f in $d/part.*; do curl -X POST --data-binary @$f http://localhost:8080/record/chunk; done
cmp $d/ref.webm audio.webm && ffprobe audio.webm
```

`audio.webm` should grow as the chunks land, end up byte-identical to `ref.webm`,
and probe as a 3 s Opus stream. Re-running it must *replace* the recording rather
than stack onto it — that is what `/record/start` is for.

## Conventions

- OCaml code is formatted in ocamlformat's default style, but there is no
  `.ocamlformat` file, so `dune build @fmt` only reformats `dune` files and
  skips `.ml` files. Match the existing style by hand; do not add a
  `.ocamlformat` unless asked.
- `.gitignore` covers `_build`, editor backups (`*~`) and `audio.webm`.
  Untracked `*~` files in the tree are Emacs backups — leave them alone.
- Commit messages are short capitalized sentences ending with a period
  (e.g. "Minimal server.").
