# iTantra — Flutter build (Android + iOS)

Offline Indian multilingual speech transceiver for low-bitrate links.
SIH problem statement **26173** (ISRO / Department of Space).

Two phones running this app, paired over Wi-Fi or Bluetooth, work as a
walkie-talkie: speech is transcribed on the sending phone, only the text
crosses the link, and the receiving phone speaks it back in the same
language. A sentence costs roughly 100–200 bytes instead of tens of
kilobytes of audio, which is what makes the link survive on a Bluetooth or
narrowband channel. Everything runs on the device: there is no server
anywhere in the design, and the app contains no HTTP client of any kind.

On Android the manifest does declare `INTERNET`, and it has to — Android
refuses *every* socket to an app without it, including one to `127.0.0.1`, so
removing the permission would break the phone-to-phone link rather than
improve the guarantee. The offline guarantee is enforced where it can be:
every socket is opened through `OfflineGuard`, which refuses anything outside
`127/8`, `169.254/16`, `10/8`, `172.16/12` and `192.168/16` and refuses
hostnames outright, because resolving one is itself network activity. That is
covered by `test/offline_guard_test.dart`. See `docs/privacy.md`.

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
| `AudioCapturePlugin` | The `VOICE_RECOGNITION` source turns off automatic gain control and noise suppression, which an acoustic model needs and a human ear does not, and each 20 ms frame is stamped at the moment it leaves the driver so latency numbers include the audio path |
| `AudioPlaybackPlugin` | audio focus, the alarm stream, and first-audible reporting; an alert has to be non-duckable and non-interruptible |
| `CommunicationService` | a `microphone`-typed foreground service, without which Android freezes the process when the screen turns off |
| `RfcommChannel` | Bluetooth Classic RFCOMM sockets |

ONNX Runtime is reached through the `onnxruntime` Dart package (FFI), so
inference itself stays in Dart.

## Build

### Android

```bash
flutter pub get
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Requires Flutter 3.24+ / Dart 3.4+ and Android SDK 36 with `minSdk 26`.
`android/local.properties` must contain `flutter.sdk` and `sdk.dir`.

Verified with: Flutter 3.35, AGP 8.7.3, Kotlin 2.1.0, Gradle 8.9, on a
Galaxy A03s (SM-A037F, Android 13, arm64). The universal release APK is
73.5 MB because it carries both `arm64-v8a` and `armeabi-v7a`; add
`--split-per-abi` to halve it when only one ABI matters.

### iOS

```bash
bash tools/bootstrap_ios.sh      # checks the project, then pod install
flutter run --release -d <your-iphone>
```

Requires macOS with Xcode and CocoaPods; deployment target iOS 13. The script
verifies that every Swift source is actually in the Runner target's compile
phase before it does anything else — a `.swift` file that sits in the folder
but was never added to the target builds fine and then fails at runtime with a
missing channel, which is the one iOS failure mode that is genuinely hard to
spot.

`Runner.xcodeproj` **is** committed, with the five Swift sources wired into
the `Runner` target's compile phase and the bundle id set to
`org.itantra.flutterhost` to match Android. `flutter create`'s scene-based
lifecycle template was deliberately not used: `AppDelegate.swift` owns the
window itself, and mixing the two leaves `window?.rootViewController` nil,
which silently skips plugin registration.

**iOS has not been built or run.** No macOS was available, so the Swift is
written to compile and its channel contracts match the Kotlin side exactly,
but it is unverified on a device — treat the first `pod install` as the real
test. The Android implementation is the verified one.

### Cross-platform split

~85% of the code — all of `lib/` except the platform-channel call sites — is
one shared Dart implementation: VAD, endpointing, log-mel, CTC decoding, the
text frontend and number normaliser, framing, codec, crypto, floor control,
metrics, storage, and the whole UI. Each host implements four channels with
identical payloads:

| Channel | Android (Kotlin) | iOS (Swift) |
| --- | --- | --- |
| `audio_capture` | `AudioRecord`, `VOICE_RECOGNITION` first with fallbacks | `AVAudioEngine` tap, `.measurement` mode, 20 ms re-chunking |
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

What is verified:

- `flutter analyze` is clean and `flutter test` passes 36/36.
- The release APK builds warning-free with R8 full mode and resource
  shrinking, installs, launches and runs on a physical Android 13 phone, with
  no exceptions in logcat across cold starts.
- Every platform channel has a native implementation on both Android and iOS.

What is **not** verified:

- **iOS is unbuilt.** No macOS was available. The Swift is complete and its
  contracts match Kotlin, but the first `pod install` on a Mac is the real
  test.
- **No speech has been recognised or synthesised on a device**, because no
  model weights ship with the app (see below). The capture, playback, codec,
  framing, storage and transport paths are exercised without models; the audio
  quality of a real pack is not.
- Two-phone operation over Wi-Fi and Bluetooth has not been run, because it
  needs two handsets. `LoopbackTransport` covers the same paths in tests.

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
