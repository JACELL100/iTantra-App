# Architecture

## The shape of the problem

Audio is expensive to transmit; text is not. A second of intelligible speech
is roughly 4-16 kB as compressed audio and roughly 20 bytes as text. On a
9.6 kbit/s link, sending audio is impossible and sending text is trivial.

So iTantra does not transmit voice. It transmits meaning:

```
phone A                            link                     phone B
microphone -> VAD -> endpointer -> ASR -> text ---------> text -> TTS -> speaker
```

The user experience is a walkie-talkie. The wire carries sentences.

This is also what makes the system inclusive in the way the problem statement
asks for: a person who cannot read still speaks and still hears speech. The
text exists only in transit.

## Module map

| Package | Responsibility |
| --- | --- |
| `core.audio` | Capture, resampling, VAD, endpointing, playback and audio focus |
| `core.asr` | Log-mel features, CTC decoding, ONNX inference |
| `core.tts` | Text normalisation, phonemisation, ONNX synthesis |
| `core.protocol` | Message types, codec, framing, capabilities |
| `core.security` | ECDH session keys, AES-GCM, pairing verification |
| `core.transport` | TCP, RFCOMM, BLE, loopback, link emulation, offline guard |
| `core.storage` | Room entities, DAOs, repository |
| `core.models` | Model pack manifest, validation, installation |
| `core.metrics` | Stage timestamps and latency summaries |
| `core.session` | The state machine that assembles all of the above |
| `service` | Foreground service keeping the loop alive |
| `ui` | Compose screens and one view model |

Dependencies point inward: `ui` and `service` depend on `core`, and no `core`
package depends on Android UI. `SessionController` is the only class that knows
about both audio and the network, which is why it is the only class that needs
an integration test.

## The two paths

### Send

1. `CaptureEngine` opens `VOICE_COMMUNICATION` with hardware AEC and noise
   suppression when available, and emits 20 ms frames.
2. `Resampler` converts whatever rate the device gave us to 16 kHz.
3. `VadEngine` returns a speech probability per frame. The default is an
   energy/SNR detector, because it costs a fraction of one percent of a core
   while idle listening, and idle CPU is explicitly graded.
4. `EndpointController` decides when a sentence ended: 450 ms of silence, or a
   12 s hard limit for a speaker who never pauses. It keeps 250 ms of pre-roll
   so the first phoneme is never clipped.
5. `OnnxCtcAsrEngine` produces text.
6. `MessagePipeline` encodes, optionally encrypts, and hands bytes to a
   transport.

### Receive

1. `MessagePipeline` decrypts, decodes, and de-duplicates.
2. `MessageRepository` stores the message. Storing before speaking means a
   distress message survives the app being killed mid-announcement.
3. `OnnxVitsTtsEngine` synthesises clause by clause and streams PCM chunks.
4. `PlaybackController` plays chunks as they arrive, so the first syllable is
   audible before the sentence has finished synthesising. This single decision
   dominates perceived receive latency on a low-end phone.
5. A receipt goes back with the stage actually reached.

## Latency budget

Measured on the monotonic clock inside the app, so the two phones' wall clocks
are irrelevant.

| Stage | Budget |
| --- | --- |
| Endpoint detection after speech ends | 450 ms (tunable) |
| ASR compute | RTF <= 0.6 |
| Encode, encrypt, transmit | < 100 ms on Wi-Fi, < 300 ms on BLE |
| TTS to first PCM chunk | < 400 ms |
| Playback start | < 100 ms |

The endpoint delay is the largest single term and it is a product decision, not
a performance limit: shortening it truncates people mid-sentence, which is
worse than 200 ms of extra delay. Push-to-talk bypasses it entirely, which is
why PTT is the default mode.

## Concurrency

- Capture runs on its own coroutine and never blocks on inference.
- Inference is serialised per engine; ONNX sessions are not thread-safe.
- Playback runs on its own coroutine with a bounded channel, so a slow speaker
  cannot stall synthesis.
- `SessionController` owns all state transitions. Nothing else mutates session
  state, which is what keeps the state machine reasonable to reason about.

## Failure behaviour

Every failure has a defined, non-silent outcome:

- Microphone denied or busy: the UI says so, capture does not silently produce
  zeros.
- Missing model pack for a language: that language is shown disabled with an
  explanation, rather than failing at the moment of speaking.
- Malformed or unauthenticated frame: dropped and counted, never partially
  interpreted.
- Link lost mid-session: messages already stored remain; the UI shows the link
  state rather than pretending to be connected.
- Alert playback interrupted: the receipt reports `FAILED`, so the sender knows
  the message was not heard.

## What is deliberately absent

- No dependency injection framework. The graph is a dozen singletons.
- No navigation library. Four flat destinations.
- No audio codec. Sending audio is the thing this design exists to avoid.
- No retransmission layer. On a link this slow, a human repeating a sentence is
  faster than protocol recovery.
- No cloud anything. `OfflineGuard` makes that mechanical rather than a promise.
