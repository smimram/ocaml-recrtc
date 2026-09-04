# ice

STUN (RFC 5389) and an ICE-lite agent (RFC 8445 §2.7): enough for a server
with a reachable address to be connected to, and no more.

- `stun.ml` — the message codec, MESSAGE-INTEGRITY and FINGERPRINT.
- `agent.ml` — one agent per session, answering the checks of the peer.

## Why lite is enough

A lite agent gathers nothing beyond its own host addresses and never sends a
connectivity check. It is always the controlled agent; the peer is always the
controlling one and does the work of nomination.

That is not a shortcut around NAT traversal — it is how traversal happens here.
The browser is behind the NAT, and its outbound check is what opens the
mapping; we answer from the very socket and address the check arrived on, and
media flows back through the hole it made. Full ICE on this side would buy
nothing, because a server that already has a reachable address never needs to
punch outward. A browser on a network that blocks UDP outright needs a TURN
server of its own; its relayed candidate then reaches us like any other peer,
and this agent neither knows nor cares.

**The response must leave from the address the check was sent to.** A peer
discards one that comes from anywhere else (RFC 8445 §7.2.5.2.1). The caller
owns the socket, so the caller must honour this: reply to the source, on the
socket it arrived on, never on a fresh one.

## What the agent answers

| | |
|---|---|
| valid check | Binding Success with XOR-MAPPED-ADDRESS |
| bad fingerprint, or unparseable | dropped |
| USERNAME naming another session | dropped — see below |
| USERNAME naming us, wrong peer fragment | 401 Unauthorized |
| bad MESSAGE-INTEGRITY | 401 Unauthorized |
| ICE-CONTROLLED | 487 Role Conflict — a lite agent is never controlling |

A check whose local fragment names no session gets **silence**, not an error.
An error response must itself be authenticated, and without a session there is
no password to authenticate it with; answering unauthenticated would be worse
than saying nothing.

The peer address is latched on the first valid check and re-latched whenever a
valid one arrives from somewhere else, so a NAT rebinding mid-session does not
strand the agent at a dead address. `alive` reports whether a check has been
seen lately: a browser refreshes consent every few seconds, so silence means it
has gone.

## The codec

`stun.ml` has no dependency on `Unix` — an address is raw network-order bytes —
so the RFC 5769 vectors can drive it directly. The parts those vectors are
there to catch:

- **MESSAGE-INTEGRITY and FINGERPRINT are computed over a rewritten header.**
  The length field must count the attribute being computed, which is not yet
  in the message. A decoded message therefore keeps the exact bytes each was
  computed over — which is why the type is abstract, since a re-encoding need
  not be identical to what arrived and would verify differently.
- **Attribute values are padded to four bytes**, and the padding is covered by
  both. Its content is arbitrary: the RFC's own vectors use spaces, we write
  zeroes, and neither is more correct, so the vectors are checked by verifying
  what they contain rather than by reproducing their bytes.
- **XOR-MAPPED-ADDRESS** masks the port with the top half of the magic cookie
  and the address with the whole of it, extended by the transaction id for
  IPv6.

Tags are compared in constant time.

## Testing

`test/test_stun.ml` runs the RFC 5769 §2.1–2.3 vectors: a request and an IPv4
and IPv6 response, each checked for its attributes, its integrity under the
published password, and its fingerprint, plus a round trip through our own
encoder and a corruption that must break both.
