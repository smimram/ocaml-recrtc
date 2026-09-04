(lang dune 3.14)

(generate_opam_files true)

(name recrtc)
(source (github smimram/ocaml-recrtc))
(license LGPL-2.1-or-later)
(authors "Samuel Mimram <smimram@gmail.com>")
(maintainers "Samuel Mimram <smimram@gmail.com>")

(package
 (name recrtc)
 ; Nothing is installed: this package exists to record the dependencies.
 (allow_empty)
 (synopsis "Record what a browser sends over WebRTC as an Ogg/Opus file")
 (description
  "A web server which records the audio a browser sends it over WebRTC. The\
\nWebRTC stack it needs is implemented here, in OCaml: SDP, ICE and STUN,\
\nDTLS with the SRTP key exchange, SRTP itself, and an Ogg/Opus muxer which\
\nstores the browser's packets bit-exact.")
 (depends
  (ocaml (>= 4.14))
  dream
  digestif
  ipaddr
  lwt
  lwt_ppx
  mirage-crypto
  mirage-crypto-ec
  (mirage-crypto-rng (>= 1.0.0))
  ptime
  tls
  x509))
