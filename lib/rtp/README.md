# rtp

RTP packets (RFC 3550) and a jitter buffer. No dependencies; nothing here knows
about sockets.

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

## Testing

`test/test_rtp.ml`: a packet with two CSRCs and a header extension, so the
payload offset depends on both; then the buffer, through reordering, a
duplicate, a late arrival, a gap that fills and a gap that never does.
