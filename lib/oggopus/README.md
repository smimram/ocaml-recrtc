# oggopus

Writing an Ogg Opus file (RFC 3533, RFC 7845) from the Opus packets of an RTP
stream. Depends on `rtp`, for the timeline the granule positions are measured
against.

This is what an audio-only session is recorded to. A session that also carries
video goes to `matroska` instead, which borrows the Opus identification header
from here — the same block opens an Ogg file and fills Matroska's
`CodecPrivate`.

## Why it is written here

`ocaml-ogg` cannot do this job: `Ogg.Stream.packet` is abstract with no
constructor, so packets can only come from a decoder or an encoder built on it,
and `ocaml-opus` encodes from PCM. Muxing through them would mean decoding the
browser's audio and encoding it again — a lossy round trip to produce a file
whose contents we already hold, exactly.

So the pages are written directly, and **the packets are stored bit for bit as
they arrived**. They are already what a decoder expects; nothing is transcoded.

## Granule positions

The one thing the container needs that RTP does not hand over directly is a
granule position — and it nearly does, because both count samples at 48 kHz.

```
granule = pre-skip + (timestamp - first timestamp) + samples(packet)
```

Taking it from the timestamp rather than from accumulating packet durations is
what makes a lost packet leave a gap of the right length instead of pulling
everything after it earlier. The 32-bit RTP clock wraps about every day, which
is handled; a small step backwards is a packet out of order, not a wrap.

A packet's own duration comes from its table-of-contents byte (RFC 6716 §3.1) —
configuration for the frame length, the low two bits for how many frames
follow — and is needed only to place the end of the last packet on a page.

**The channel count comes from the packets, not from the SDP.** A browser
offers `opus/48000/2` and then encodes a mono microphone as mono packets; the
file's header has to describe what the packets actually decode to, so it is
read from the stereo flag of the first one.

## Pages

Two headers first, `OpusHead` and `OpusTags`, each alone on its page, the first
marked as the beginning of the stream. Then audio pages, up to 200 segments
each — the format allows 255, and a smaller page loses less if the file is cut
short.

Two details of the format that bite:

- A packet is split into segments of 255 bytes, and **a segment shorter than
  255 is what ends it** — so a packet whose length is an exact multiple of 255
  needs a trailing empty segment, or the next packet is read as its
  continuation.
- The checksum is a CRC-32 with the usual polynomial but **without reflection
  or a final complement**, computed over the whole page with the checksum field
  zeroed.

Each page reaches the disk as it is finished, so a recording interrupted by a
crash is still a playable file, short of its last page.

## Testing

The Opus framing has unit tests in `test/test_rtp.ml`; the container is checked
against the players that have to read it:

```sh
ffprobe recording-*.opus     # mono, 48000 Hz, and the expected duration
mpv recording-*.opus
```
