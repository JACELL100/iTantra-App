# iTantra — Flutter build (Android + iOS)

Offline Indian multilingual speech transceiver for low-bitrate links.
SIH problem statement **26173** (ISRO / Department of Space).

Two phones running this app, paired over Wi-Fi or Bluetooth, work as a
walkie-talkie: speech is transcribed on the sending phone, only the text
crosses the link, and the receiving phone speaks it back in the same
language. A sentence costs roughly 100–200 bytes instead of tens of
kilobytes of audio, which is what makes the link survive on a Bluetooth or
narrowband channel. Everything runs on the device — there is no network
permission in the manifest at all.

Languages: Hindi, Bengali, Gujarati, Marathi, Kannada, Malayalam, Tamil,
Telugu, Odia, English (Indian).

## What is in this repository

```
lib/
  main.dart, app.dart              app entry, theme wiring
  core/
    audio/                         capture, VAD, endpointing, resampling,
                                   frames, streaming playback
    asr/                           log-mel frontend, CTC decoder, ONNX engine
    tts/                           text frontend, number normaliser,
                                   phonemizer, streaming VITS engine
    protocol/                      wire messages, codec, framing, capabilities
    transport/                     TCP, Bluetooth RFCOMM, loopback,
                                   link profiles, offline guard
    security/                      X25519 + AES-GCM session crypto, pairing SAS
    session/                       message pipeline, floor control, alerts,
                                   session controller
    models/                        model-pack manifest + manager
    storage/                       sqflite schema, entities, repository
    metrics/                       stage timeline, percentiles, targets
  ui/                              conversation, settings, diagnostics, PTT
  di/                              service locator
android/                           host project: manifest, Gradle, and the
                                   Kotlin platform channels
ios/                               host project: Info.plist, Podfile, and the
                                   Swift platform channels
test/                             unit tests for the pure-Dart logic
ml/                               model export and verification scripts
tools/                            pack builder, benchmark harness
firmware/                         ESP32 bridge sketch
protocol/                         wire-format specification
docs/                             design notes
implementation_plan.md            the full 30-section design document
```

## Why Dart plus a little Kotlin

All of the logic — endpointing, decoding, framing, crypto, floor control,
metrics, storage, UI — is pure Dart, so it is testable off-device and would
port to another platform unchanged. Kotlin is used only where Flutter has no
plugin-free access to the platform, and each case is there for a measurable
reason:

| Native piece | Why it cannot be Dart |
| --- | --- |
| `AudioCapturePlugin` | `VOICE_COMMUNICATION` source engages the hardware echo canceller, and each 20 ms frame is stamped at the moment it leaves the driver so latency numbers include the audio path |
| `AudioPlaybackPlugin` | audio focus, the alarm stream, and first-audible reporting; an alert has to be non-duckable and non-interruptible |
| `CommunicationService` | a `microphone`-typed foreground service, without which Android freezes the process when the screen turns off |
| `RfcommChannel` | Bluetooth Classic RFCOMM sockets |

ONNX Runtime is reached through the `onnxruntime` Dart package (FFI), so
inference itself stays in Dart.

## Build

### Android

```bash
flutter pub get
flutter run --release        # release, because debug Dart is far slower
```

Requires Flutter 3.24+ / Dart 3.4+ and Android SDK 35 with `minSdk 26`.
`android/local.properties` must contain `flutter.sdk` and `sdk.dir`; the
Flutter tool writes both on first run.

### iOS

```bash
bash tools/bootstrap_ios.sh
flutter run --release -d <your-iphone>
```

Requires macOS with Xcode and CocoaPods; deployment target iOS 13.

The `ios/Runner/*.swift` files, `Info.plist`, and `Podfile` are real
hand-written source. `Runner.xcodeproj` is *not* committed: an Xcode project
file is a generated artifact keyed to a specific Xcode version, and a
hand-edited one fails in miserable ways. `tools/bootstrap_ios.sh` runs
`flutter create --platforms=ios`, then restores our sources over the
templates and runs `pod install`. Two Xcode steps it cannot do for you (the
bridging-header setting and the Background Modes capability) are printed at
the end.

### Cross-platform split

~85% of the code — all of `lib/` except the platform-channel call sites — is
one shared Dart implementation: VAD, endpointing, log-mel, CTC decoding, the
text frontend and number normaliser, framing, codec, crypto, floor control,
metrics, storage, and the whole UI. Each host implements four channels with
identical payloads:

| Channel | Android (Kotlin) | iOS (Swift) |
| --- | --- | --- |
| `audio_capture` | `AudioRecord`, `VOICE_COMMUNICATION` | `AVAudioEngine` tap, `.voiceChat`, 48→16 kHz conversion |
| `audio_playback` | `AudioTrack` + audio focus + `STREAM_ALARM` | `AVAudioPlayerNode` + session categories |
| `rfcomm` | real RFCOMM sockets | explicit `unsupported` → BLE fallback |
| `platform_info` | capability probe | capability probe |

Dart asks `platform_info` what the host can actually do rather than checking
`Platform.isIOS` inline, and the UI tells the user the truth about the two
real iOS limits. **Read `docs/ios_parity.md`** — iOS cannot raise the output
volume (alerts ignore the mute switch and duck other audio, but play at the
user's level) and cannot use Bluetooth Classic without MFi certification.
For a mixed pair, put Android at the alerting end.

`docs/requirements_traceability.md` maps every requirement, metric, and
restriction in problem statement 26173 to the code that satisfies it, with
gaps declared rather than hidden.

### Honest status of this drop

This is complete source, not a built artifact. It was produced in a sandbox
with **no network access**, which has two consequences you should know about
before you judge it:

- `flutter pub get`, Gradle and CocoaPods were never run here, so there is no
  `pubspec.lock`, no `.dart_tool/`, no Gradle wrapper JAR, no `Pods/`, and no
  APK or IPA. Expect to fix a small number of compile errors on first build
  — API drift between files written without a compiler is normal and the
  fixes are mechanical.
- **No model weights are included.** They are hundreds of megabytes and most
  carry licences that forbid redistribution. See below.

## Model packs

The app ships with no models and looks for packs in
`<app support>/packs/<lang>-<role>/`, each containing `model.onnx`,
`manifest.json`, and the tokeniser files. `tools/build_pack.py` produces
them; `ml/export/` holds the export and verification scripts, including
`verify_frontend.py`, which checks the Dart log-mel frontend against the
Python reference to 1e-3 — if that check fails, word error rate collapses
for reasons no amount of decoder tuning will fix.

Suggested sources, with their licences, because this matters:

| Role | Model | Licence | Note |
| --- | --- | --- | --- |
| ASR (9 Indic) | AI4Bharat IndicConformer-600M | MIT | no English |
| ASR (English) | separate English CTC model | — | IndicConformer does not cover it |
| TTS | ARTPARK DhVaani-0.5 | Apache-2.0 | 123 M params, ~491 MB before quantisation |
| TTS (alt) | AI4Bharat IndicF5 | check upstream | |
| Phonemisation | eSpeak NG | GPL-3.0 | **build-time only** — its rules are baked into the pack, the library is never linked into the APK |

**Do not use `facebook/mms-tts-ory` for Odia.** It is CC-BY-NC-4.0, which
rules it out for anything that could be deployed. Odia TTS is the one real
gap in the open-source landscape here; `implementation_plan.md` sets out the
options.

## Measuring it

The diagnostics screen reports p50/p95 for every stage against the targets in
`core/metrics/metrics.dart`: send ≤ 900 ms, receive ≤ 700 ms, phone-to-phone
delta ≤ 1500 ms, ASR RTF ≤ 0.6, TTS RTF ≤ 0.5. Timings are taken from the
capture timestamp to first-audible on the far phone, not from the point where
it is convenient to start a stopwatch.

`LoopbackTransport` with `LinkProfile.poor` reproduces Bluetooth-grade
latency and loss in a unit test, so the pipeline can be verified without two
phones.

## Licence

Apache-2.0 — see `LICENSE` and `NOTICE`.
