# iTantra link protocol, version 1

This is the contract between two iTantra endpoints. It is deliberately small:
the link may be a 9.6 kbit/s Bluetooth channel, so every field has to justify
its bytes.

## 1. Layering

```
[ message ]        Kotlin sealed class Message
[ codec   ]        compact JSON, 1-2 character keys
[ crypto  ]        optional AES-256-GCM, ECDH P-256 session keys
[ framing ]        6-byte header + payload
[ transport]       TCP over Wi-Fi, Bluetooth RFCOMM, or BLE GATT chunks
```

Each layer is independent. The bridge firmware, for example, understands only
framing.

### Why JSON and not CBOR

CBOR was the original choice and was measured against JSON with short keys.
On representative Hindi and Tamil sentences the difference was 6-11 bytes per
message, about 8 ms of channel time at 9.6 kbit/s, because the payload is
dominated by UTF-8 text that neither format compresses. JSON was kept because
it needs no dependency, is inspectable with `tcpdump` during a demo, and makes
the golden test vectors below readable. If a future version adds binary audio
fallback, that field should be CBOR or raw, not base64 inside JSON.

## 2. Framing

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 2 | magic `0x49 0x54` (`IT`) |
| 2 | 1 | protocol version, currently `1` |
| 3 | 3 | payload length, big endian, 24 bits |
| 6 | n | payload |

- Maximum payload: 8192 bytes (`ProtocolLimits.MAX_MESSAGE_BYTES`).
  `BleBridgeTransport` lowers this to 2048 because a larger frame would hold a
  BLE link long enough to delay an alert.
- A reader that loses synchronisation discards one byte at a time until it
  finds the magic. This is what makes joining a link mid-transmission, or
  surviving a corrupted burst, recoverable.
- A length beyond the maximum is a protocol error, not a large allocation.
  This is the check that prevents a memory-exhaustion attack from a single
  6-byte header.

## 3. Encryption

Optional, negotiated at pairing, and applied to the framing payload.

- Ephemeral ECDH on P-256 produces a shared secret per session.
- SHA-256 over the secret with labels `itantra-a` and `itantra-b` derives two
  AES-256 keys, one per direction. Separate keys per direction remove any
  possibility of an attacker replaying a message back at its sender.
- AES-256-GCM with a 12-byte counter nonce and a 128-bit tag. The counter
  never repeats within a session, and a session key is never persisted.
- Authentication is a 6-digit short authentication string derived from both
  public keys and shown on both phones. It is order-independent, so both ends
  compute the same digits regardless of who dialled. This defeats a
  man-in-the-middle without a PKI, which cannot exist offline.

Without a PKI, unauthenticated ECDH alone would be defeated by an active
attacker, which is why the digit comparison is part of the protocol rather
than a UI nicety.

## 4. Message types

All messages carry `t` (type), `i` (message id), and `s` (sent-at, epoch
milliseconds). Message ids are unique per sender and are the basis for
de-duplication and receipts.

### `text`

| Key | Type | Meaning |
| --- | --- | --- |
| `l` | string | BCP-47 language tag, `^[a-z]{2}-[A-Z]{2}$` |
| `x` | string | recognised text, at most 4096 UTF-8 bytes |
| `q` | number | sequence number within the session |
| `c` | bool | true if this continues the previous utterance |
| `f` | number | mean ASR token confidence, 0-100 (whole percent) |

Confidence is quantised to whole percent because two decimal places of a
confidence score cost bytes and change no decision.

### `alert`

As `text`, plus:

| Key | Type | Meaning |
| --- | --- | --- |
| `v` | string | `INFO`, `WARNING`, or `DISTRESS` |
| `r` | number | how many times to announce |

An unrecognised severity decodes as `WARNING`, never `DISTRESS`. A corrupted
byte must not be able to trigger the loudest, non-interruptible behaviour.

### `receipt`

| Key | Type | Meaning |
| --- | --- | --- |
| `a` | string | acknowledged message id |
| `g` | string | `RECEIVED`, `RENDERED`, `PLAYED`, or `FAILED` |

Three stages rather than one because "delivered" and "the human heard it" are
different facts, and in a distress scenario only the second one matters.

### `floor`

| Key | Type | Meaning |
| --- | --- | --- |
| `o` | string | `REQUEST`, `GRANT`, `DENY`, or `RELEASE` |
| `w` | number | lease duration in milliseconds |

The lease exists so that a peer which crashes or walks out of range while
holding the floor cannot silence the channel permanently.

### `capabilities`

Exchanged once after connecting: protocol version, device name, installed ASR
and TTS language tags, whether alerts and floor control are supported, and the
maximum frame the sender accepts. This is how a phone learns that its peer
cannot speak Odia before a user tries.

### `ping` / `pong`

Round-trip measurement. `pong` echoes the ping's id and send time, so latency
is computed without assuming the two clocks agree.

## 5. De-duplication

Receivers remember message ids for 10 minutes, bounded at 2000 entries. A
retransmitted alert is stored and announced exactly once. This matters because
the packet most likely to be lost on a bad link is the receipt, which means
retransmission of an already-delivered message is the normal case, not an edge
case.

## 6. Ordering and loss

There is no retransmission at this layer. Over TCP the transport handles it;
over RFCOMM the link is reliable; over BLE a lost notification loses a frame.
The application layer accepts this: a missed sentence is re-spoken by a human,
which is faster than a protocol-level recovery on a link this slow. Sequence
numbers let the UI show a gap rather than silently reorder speech.

## 7. Version negotiation

The version byte is in the frame header, so a mismatch is detected before any
parsing. Version 1 endpoints reject other versions rather than guessing.
Capability messages carry a semantic version for feature negotiation within a
protocol version.

## 8. Test vectors

`protocol/vectors/` contains byte-exact encodings. `ProtocolCodecTest` and the
bridge firmware are both checked against them, which is how a Kotlin change and
a C++ change are prevented from drifting apart.
