# Flutter build notes

These notes cover the decisions specific to the Flutter/Dart implementation.
The system design, evaluation strategy, and model selection live in
`implementation_plan.md`.

## Where the boundary sits

Dart owns everything except four native surfaces: PCM capture, PCM playback
with audio focus, the foreground service, and Bluetooth RFCOMM. Each of
those needs an Android API with no plugin-free equivalent. Everything else --
VAD, endpointing, log-mel, CTC decoding, the text frontend, framing, crypto,
floor control, dedup, metrics, storage, UI -- is Dart, which means it runs
under `flutter test` on a laptop with no device attached.

That split was chosen for testability rather than elegance. The parts most
likely to be wrong (endpointing thresholds, frame reassembly across
arbitrary chunk boundaries, digit expansion in ten languages) are exactly
the parts that are now unit-testable.

## Streaming through the isolate boundary

Capture pushes 20 ms frames over an `EventChannel`. Platform channels
marshal on the platform thread, and `Uint8List` is passed as a direct
byte-buffer rather than a list of numbers, so a frame costs one copy. At 50
frames per second with 640-byte payloads that is 32 kB/s of channel traffic,
which is comfortably inside the budget; sending individual samples or JSON
would not be.

Inference runs through the `onnxruntime` package (FFI), so a session call
blocks the calling isolate for the duration of the compute. ASR runs on an
utterance after endpointing, so a 200 ms block is invisible. TTS is chunked
by the text frontend at ~160 characters, which keeps each synthesis call
short enough that the first chunk becomes audible while later chunks are
still being generated -- that is what keeps perceived latency low rather than
total synthesis time.

If profiling on a specific low-end device shows UI jank during synthesis,
the fix is to move the engine into a background isolate with
`Isolate.run`. It is not done by default because isolate setup costs more
than it saves for short utterances, and the ONNX session cannot be shared
across isolates without re-initialising it.

## Idle CPU

The scored metric is CPU during idle listening. The VAD is a pure-Dart
energy detector with an adaptive noise floor: no neural network runs until
speech is detected, so idle cost is one pass over 320 samples per 20 ms
frame. Measured against a target of under 2% of one core.

Dart's UI does not repaint during idle either -- the PTT button's glow is
driven by a level value that only changes while capture is active, and
`ConversationController` notifies listeners on state transitions rather than
on every frame.

## Deviations from the Kotlin/Compose build

- Storage is `sqflite` rather than Room, so the schema and the row mapping
  are written by hand in `core/storage/`. Both tables and both indices are
  identical to the Kotlin build's, so a database from one is readable by the
  other.
- Dependency injection is a hand-written service locator instead of Hilt.
  With one graph and no scoping requirements, a container adds ceremony
  without adding safety.
- Sealed classes carry state (`LinkState`, `FloorState`, `SessionEvent`,
  `WireMessage`), so `switch` over them is exhaustively checked by the
  analyser -- the same guarantee Kotlin's sealed interfaces give.
- Crypto uses the `cryptography` package for X25519 and AES-GCM rather than
  the platform's JCA. The wire format is unchanged: 8-byte big-endian
  counter, 16-byte tag, then ciphertext, with a 12-byte nonce built from a
  direction prefix and the counter.

## Things to verify first on a real device

1. `ml/export/verify_frontend.py` against the Dart log-mel output. A
   mismatch here silently destroys accuracy.
2. First-audible timing for a distress alert while a music app holds focus.
3. RFCOMM reconnection after the peer walks out of range and returns; the
   floor lease should expire rather than lock the radio.
