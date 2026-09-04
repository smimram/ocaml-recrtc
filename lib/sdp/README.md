# sdp

Parsing the offer a browser sends and generating the answer to it
(RFC 4566, RFC 8866, with the WebRTC attributes of RFC 8829).

Deliberately partial. There is exactly one shape of session this server ever
sees — a single audio track a browser wants to send — so the parser looks for
the attributes it needs and ignores the rest, rather than modelling SDP. It
does not round-trip: what comes back out is an answer built from scratch, not
the offer amended.

## The offer

Everything the rest of the server needs comes back in one record: the media
identifier, the Opus payload type and its `a=fmtp` parameters, the peer's ICE
credentials, the fingerprint of the certificate it will present, and whether it
asked for `a=rtcp-mux`.

Session-level attributes are folded into the media description, media level
winning, so a browser that puts `a=ice-ufrag` in either place is read the same
way. An offer with no Opus, or with more than one audio section, is rejected
with `Invalid` rather than half-understood.

## The answer

```
a=ice-lite            we answer checks and never send any
a=setup:passive       the browser is the DTLS client
a=recvonly            we receive; the offer said sendonly
a=rtcp-mux            RTCP shares the media port
a=candidate:…         one per address, most preferred first
```

The candidate list is the part worth explaining. A peer pairs its own
candidates with ours by route, and a browser gathers no loopback candidate of
its own while a real interface exists — so a lone `127.0.0.1` candidate leaves
a browser on the very same machine with nothing it can check against. Hence a
list, ordered, with the loopback last: `host_priority` gives each a local
preference counting down from the address we would rather be reached on
(RFC 8445 §5.1.2.1).

The `a=fmtp` line is echoed back unchanged. Those are the parameters the
browser chose for its own encoder, and we are in no position to argue with
them.

## Testing

There are no unit tests here; the browser is the test. It rejects an answer
that is wrong in the smallest way — a missing `a=mid`, a `BUNDLE` group naming
a section that is not there — and it does so silently, leaving ICE to time out
with no clue as to why. That is the reason the answer is built in one place,
in one function, and kept boring.

To see one: post an offer and read what comes back.

```sh
curl -s -X POST -H 'Content-Type: application/sdp'   --data-binary @offer.sdp http://localhost:8080/webrtc/offer
```
