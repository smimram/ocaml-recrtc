# rtp

RTP packets (RFC 3550), a jitter buffer, the payload formats that carry video,
and the timeline a container measures against. No dependencies; nothing here
knows about sockets.

## packet.ml

Reading only, and only the fields a receiver needs: what identifies a stream,
what orders it, and where the header ends.

That last one is load-bearing. `header_length` is exposed separately from
`parse` because **SRTP must know it before it can decrypt what follows** — the
header, its CSRC list and any extension travel in the clear, and the encrypted
part starts immediately after. Getting the extension length wrong shifts the
keystream and produces noise rather than an error.

`is_rtcp` tells the two apart when they share a port, which they do whenever
`a=rtcp-mux` is negotiated: RTCP's packet types all fall in 64..95 once the
marker bit is masked off (RFC 5761 §4).

## reorder.ml

A network reorders and loses packets; a file may not. The buffer holds packets
back until they are in sequence, and hands them out in order.

The rule that shapes it: **a recorder must never stall waiting for a packet
that is not coming.** So the buffer is bounded — eight packets by default —
and once it is deeper than that with a gap still unfilled, it writes the
missing one off, counts it, and moves on to the oldest packet it does have. A
packet that turns up after its place has passed is dropped, as is a duplicate.

Sequence numbers are sixteen bits and wrap, so every comparison is modular:
ordering is only meaningful within half the space (RFC 3550 §A.1).

Losing a packet leaves a hole in the recording, and the hole is the right
length, because the granule position downstream comes from RTP timestamps
rather than from counting packets.

## timeline.ml

An RTP timestamp starts at a random offset and is thirty-two bits wide, so it
wraps — every thirteen hours at 90 kHz, every day at 48 kHz. A container wants
neither: it wants a count from the start of the stream that keeps growing.

The rule for telling the two apart: a *small* step backwards is a packet out of
order, a *large* one is the clock wrapping. Both `oggopus` and `matroska`
measure against this, which is why it lives here rather than in either.

## vp8.ml, vp9.ml and h264.ml

The three payload formats (RFC 7741, draft-ietf-payload-vp9-16 and RFC 6184).
All exist to undo what the transport did to a picture and hand back exactly the
bytes the encoder produced.

VP8 puts a descriptor of one to six bytes in front of every payload; it is a
transport artefact and does not belong in a file, so it is stripped and the
partitions concatenated. A keyframe then declares its own size in the
uncompressed header behind the `9d 01 2a` start code (RFC 6386 §9.1).

VP9 is the same idea with a descriptor that varies far more: the picture
identifier, the layer indices, the reference differences of flexible mode and a
whole scalability structure are each optional, and the structure's own length
depends on how many spatial layers and picture-group entries it describes.
Nothing in it is read beyond `B`, which says where a frame begins, and its
total length. The size comes from the frame instead, out of the uncompressed
header behind the `49 83 42` sync code — reached by reading past a colour
section whose length depends on the profile and on the colour space (VP9
bitstream specification §6.2). A keyframe is exactly the frame whose header
parses that far, so the same code answers both questions.

H.264 is more work. A unit small enough for a datagram is the packet; several
small ones arrive aggregated behind their lengths; one too large arrives in
fragments whose first and last are flagged, and whose own header has to be
**rebuilt from the two bytes the format puts in its place** — the reference
bits from one, the type from the other (§5.8). The units are then stored each
behind a four-byte length, as a container expects them.

The picture size is the awkward part: Matroska demands it in the header and
H.264 buries it in the sequence parameter set, behind exponential-Golomb codes
and an optional scaling matrix that has to be read only to be skipped. The
emulation-prevention bytes come out first, cropping comes off at the end, and
the amount cropped depends on the chroma subsampling.

## frame.ml

A frame is the run of packets sharing a timestamp, ended by the marker bit.

The rule that shapes it, and the one place it differs from the audio path:
**an incomplete picture is dropped, not written short.** A missing audio packet
leaves a gap of the right length and the recording carries on. A missing video
packet does not shorten the picture, it corrupts it — and every picture
predicted from it after that. So a gap in the sequence numbering, or joining a
picture partway through, discards the whole frame and counts it.

## Testing

`test/test_vp8.ml`, `test/test_vp9.ml` and `test/test_h264.ml` cover the
descriptors — including the ones a browser actually sends, and the scalability
structure — the fragmenting, and the picture size read back out of a keyframe
and out of two real parameter sets — one baseline and one high profile, both cropped, both
carrying emulation-prevention bytes.

`test/test_rtp.ml`: a packet with two CSRCs and a header extension, so the
payload offset depends on both; then the buffer, through reordering, a
duplicate, a late arrival, a gap that fills and a gap that never does.
