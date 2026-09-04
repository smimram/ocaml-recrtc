# srtp

SRTP and SRTCP (RFC 3711) under `AES_CM_128_HMAC_SHA1_80`, the profile
DTLS-SRTP negotiates with browsers: AES-128 in counter mode for
confidentiality, an 80-bit HMAC-SHA1 tag for authentication.

**Media travels one way**, so of RTP only the receiving half exists. Of RTCP
there is also a protect side, `sender` and `protect_rtcp`, for the keyframe
requests that are the one thing a recorder has to say back. It runs the same
primitives the other way, counter mode being its own inverse, under the
server's half of the exported keying material rather than the client's, and
counts its own index up from zero — that index is what keeps two identical
packets from sharing a counter block.

## Key derivation

Everything descends from the 16-byte master key and 14-byte master salt that
DTLS exported, through the key derivation function of §4.3.1: AES in counter
mode under the master key, over a block made by exclusive-oring a label into
the master salt. The key derivation rate is zero, as DTLS-SRTP leaves it, so
`index DIV rate` is zero and the input depends on the label alone.

Six labels, giving an encryption key, an authentication key and a session salt
for each of SRTP and SRTCP.

## Unprotecting a packet

```
index   = ROC ‖ sequence                       48 bits
counter = (salt ‖ 0x0000) ⊕ (ssrc << 64) ⊕ (index << 16)
tag     = HMAC-SHA1(auth key, packet ‖ ROC)[0..10)
```

Two things about that are easy to get wrong:

- **The rollover counter is not in the packet.** A sequence number is sixteen
  bits and wraps roughly every twenty minutes of audio; the counter that
  extends it lives only in the receiver's head, inferred from the numbers seen
  so far (§3.3.1). It is authenticated along with the packet, so a wrong guess
  does not corrupt audio quietly — the tag simply fails to match.
- **The header is not encrypted, and the encrypted part starts where it ends.**
  That includes the CSRC list and any header extension, which is why this
  library depends on `rtp` for `Packet.header_length`. Encrypted header
  extensions (RFC 6904) are not implemented; browsers do not ask for them here.

A replay window of 64 packets sits behind the highest index accepted so far.
Tags are compared in constant time.

SRTCP differs in that its index *does* travel in the packet, in a trailing word
whose top bit says whether the payload was encrypted, and that only what
follows the first two words is encrypted.

## Testing

`test.ml` runs the RFC 3711 appendix B vectors — B.3 for all three
derived keys, B.2 for the counter block and keystream — because a homegrown
crypto test only proves the code agrees with itself.

The rollover and replay logic is then driven through `unprotect`: the test
protects packets under a counter the receiver is never told, so an inference
failure shows up exactly as it would in the wild, as a tag that does not match.
The same route catches tampering, a wrong key, a replay and a truncated packet.
Only the primitives those vectors need are public; the counter and the window
are reached through `unprotect` alone.
