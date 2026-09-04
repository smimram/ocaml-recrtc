# matroska

Writing a Matroska file (RFC 9559) holding the video and audio of one WebRTC
session. Depends on `rtp`, for the timeline that turns RTP timestamps into a
stream position, and on `oggopus`, for the Opus identification header — the
same block opens an Ogg Opus file and fills Matroska's `CodecPrivate`.

## Why it is written here

The same reason `oggopus` is: **the packets are stored bit for bit as they
arrived**. The browser has already encoded the pictures and the sound, and
routing them through a library that wants raw samples would mean decoding both
and encoding them again, to produce a file whose contents we already hold.

Matroska is the only container that will take what a browser sends — VP8 or
H.264 pictures beside Opus packets — without touching either. WebM is the same
format with a narrower declared `DocType`, and admits only VP8 and VP9; an
H.264 recording is therefore written as plain Matroska, under `.mkv`. Nothing
else about the two files differs.

## ebml.ml

Elements: an identifier, a length, then a value or more elements. Both the
identifier and the length are variable-width integers, the leading zeros of the
first byte giving the width, which is what lets a reader skip an element it
does not recognise.

The one trap is that **a length of all ones is reserved** to mean "unknown", so
each width holds one less than it looks: 126 fits in a byte and 127 does not.

## writer.ml

Lengths that are not known when an element opens — the segment, and each
cluster — are written as the eight-byte "unknown" form and overwritten in place
when the element closes. That leaves the same property `oggopus` has: **a
recording killed halfway through is still a file that plays**, because a reader
that meets an unknown length simply reads to the next element at that level.
It arrives with no duration, which is exactly what is missing.

A cluster starts at every keyframe, and at least once a second. A block's
position within one is a signed sixteen-bit millisecond offset, so a cluster
could in principle span half a minute; keeping them short bounds what is lost
when a recording is cut off, and gives a player somewhere to seek to.

## Synchronising the two tracks

Each track's timestamps come from its own RTP clock — 90 kHz for video,
48 kHz for audio — and the two start at unrelated random offsets. Nothing
*inside* the streams relates them.

What relates them here is arrival: a track's timeline is anchored at the moment
its first packet reached us and advances by its own clock from there. The
residual error is the difference in arrival of the two first packets, tens of
milliseconds in practice.

Getting it exact would mean reading the NTP-to-RTP mapping out of the peer's
RTCP sender reports, which `src/recrtc.ml` decrypts and does not yet interpret.
That is the known limitation of this library.

Blocks are held for a fifth of a second and written in timestamp order, because
the two tracks reach the writer through jitter buffers of their own and so
interleave imperfectly. Sorting them here costs nothing and spares a player
having to.

## Testing

`test/test_matroska.ml`: the variable-width integers at each width boundary,
including the reserved all-ones value; then a small two-track file, walked
element by element to check that every length lands exactly on the end of its
contents, that both tracks are declared, that a cluster opens at each keyframe,
and that the segment length and the duration were filled in at the end.
