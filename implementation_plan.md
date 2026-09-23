# iTantra â€” Detailed Implementation Plan

**SIH Problem Statement:** 26173  
**Organization:** Indian Space Research Organisation (ISRO), Department of Space  
**Category / theme:** Software / Smart Automation  
**Document:** implementation_plan.md  
**Prepared:** 9 September 2026  
**Status:** Proposed engineering plan; not a claim of an implemented or benchmarked system.

> Build an offline Android speech-to-text â†’ authenticated low-bitrate text transport â†’ text-to-speech communication system for Hindi, Gujarati, Marathi, Kannada, Malayalam, Tamil, Telugu, Odia, Bengali, and English. Prioritize preservation of meaning, native-listener intelligibility, and measured operation on inexpensive phones over impressive but unverified model claims.

## Contents

1. Executive decisions and feasibility boundaries
2. Requirements and acceptance traceability
3. Scope, operating modes, and user journeys
4. System architecture
5. Technology stack and dependency policy
6. Ten-language model strategy
7. Speech capture, VAD, and endpointing
8. STT pipeline and model optimization
9. Text representation and language handling
10. TTS pipeline and playback
11. Push-to-talk and hands-free operation
12. Android services, permissions, and lifecycle
13. Transport adapters and embedded bridge
14. Wire protocol, delivery, and security
15. Low-bitrate scheduling and backpressure
16. Alerts, accessibility, and safety
17. Model-pack management and offline provisioning
18. Data collection, training, and evaluation
19. Performance budgets and measurement
20. UI and interaction specification
21. Repository, interfaces, and persistence
22. Implementation work packages
23. Timeline, ownership, and critical path
24. Test strategy and acceptance scenarios
25. Risk register and decision gates
26. Release, deployment, and demonstration
27. Initial engineering backlog
28. Configuration and example schemas
29. Definition of done and organizer questions
30. Source register

---

## 1. Executive decisions and feasibility boundaries

### 1.1 Recommended approach

- Use **native Kotlin Android**, coroutines, a small Compose UI, and a lifecycle-owned communication service.
- Start with **phone-to-phone Bluetooth Classic RFCOMM** and **local Wi-Fi TCP**. Add Wi-Fi Direct discovery and an embedded BLE/Wi-Fi bridge behind a common transport interface.
- Run all speech inference on the phones. Treat the embedded board as a **byte relay**, not as a ten-language ASR/TTS inference target.
- **Primary ASR engine: Gemma 4 E2B-it via LiteRT-LM** (2.58 GB `.litertlm` pack, Apache-2.0). Native audio input handles transcription and translation for all 10+ languages including code-switched Hindiâ€“English. **Fallback ASR: per-language ONNX CTC packs** (IndicConformer) for devices with <6 GB RAM or where Gemma latency exceeds budget.
- TTS remains **DhVaani / IndicF5** (ASR is replaced; TTS is unchanged).
- Default to **explicit language selection** and one active ASR pack plus one active TTS pack. Permit all packs to be stored offline, but never load all into RAM.
- Ship final, immutable speech segments across the low-rate link. Local partial transcripts may update freely; remote playback must never speak unstable hypotheses.
- First establish an arbitrary-speech two-phone loop in English and Hindi, but place **Odia and low-end device feasibility in the first week**, not at the end.
- Treat ten-language lightweight neural speech as a gated engineering/research problem. A prototype with only selected languages or robotic fallback voices is useful progress, **not full compliance**.

### 1.2 Important truths to preserve in the submission

1. **This is semantic speech transport, not a waveform-preserving codec.** Speaker identity, emotion, background sounds, laughter, and nonverbal distress can be lost. An ASR error can change meaning.
2. **"Fully offline" does not mean removing Android's INTERNET permission.** Local Wi-Fi sockets require it; internet access is not required. Demonstrate no cloud dependency using isolation and traffic evidence. [S8]
3. **A normal Android app cannot guarantee physically maximum, globally non-interruptible sound.** Audio focus, calls, DND policy, routing, volume controls, hardware, and force-stop remain under OS/user control. Define non-interruptibility inside the app, document system limits, and seek written organizer acceptance. [S6â€“S7]
4. **Multilingual does not mean every requested language is supported equally.** Gemma 4 covers 140+ languages for text and native audio input for transcription/translation; validate per-language quality in Phase 0 before claiming coverage.
5. **Model weights, engine code, phonemizers, datasets, and reference voices have separate licenses.** Gemma 4 is Apache-2.0 (clean redistribution); DhVaani is Apache-2.0; eSpeak NG is GPL-3.0 (build-time only). Downloadable or noncommercial weights are not automatically acceptable under a strict open-source-only rule. [S3â€“S5]
6. **Quantizing a large model does not magically make it tiny.** Gemma 4 E2B is 2.58 GB on disk, ~1.1 GB resident RAM on mobile. Keep ONNX CTC packs as fallback for <6 GB devices.
7. **Streaming audio into an offline model is not true streaming inference.** Gemma 4 is autoregressive: it emits full tokens after end-of-speech, not CTC-style partial hypotheses. Latency metric shifts from "ASR RTF" to "time-to-first-token + tokens/s."
8. **"Phone-like" operation has unavoidable buffering.** Text recognition and speech regeneration cannot be assumed to match direct audio-call latency or reproduce simultaneous speakers faithfully.
9. The provided evaluation weights are efficiency 20%, accuracy 40%, and latency 20%: **80% total**. Do not invent the missing 20% or normalize the rubric without organizer clarification.

### 1.3 Assumptions requiring confirmation

- Proposed support baseline: Android 8.0 / API 26 and above, primarily ARM64; actual device list determines whether 32-bit ARM support is required.
- Low-end baseline: an actual 2â€“3 GB RAM ARM64 phone (uses ONNX CTC fallback); mid-range baseline: 4â€“6 GB device (may run Gemma with thermal throttling); high-end baseline: 6 GB+ phone (Gemma primary). These are team planning categories, not organizer specifications.
- General speech is required, not only a fixed emergency phrasebook.
- Same-language transmission is required; **cross-language translation is a free add-on with Gemma 4 E2B** (sender-side translation, both strings sent).
- Models may be installed from an offline pack before operation.
- Training and developer model acquisition can happen before the demo; runtime has no server dependency.
- Six-person team and a twelve-week runway are assumed for the full plan. A shorter sprint plan is included, but cannot guarantee new ten-language model training.

---

## 2. Requirements and acceptance traceability

| ID | Requirement | Implementation owner/subsystem | Acceptance evidence |
|---|---|---|---|
| R01 | Android app on low/mid/high-range phones | Android + optimization | Signed APK installed and sustained on documented physical devices |
| R02 | Offline STT for ten languages | ASR (Gemma 4 E2B primary, ONNX CTC fallback) | Unseen native-speaker recordings and live microphone transcripts per language; Phase 0 validation table |
| R03 | Offline TTS for ten languages | TTS | Arbitrary unseen text spoken and scored by native listeners per language |
| R04 | Pause/stoppage sentence formation | VAD + segmenter | Boundary precision, missed syllables, finalization delay, pause test suite |
| R05 | Immediate efficient text transmission | Session + protocol | Packet capture and timestamped final-segment transmission |
| R06 | Wi-Fi/Bluetooth phone connection | Transport | Two-phone demonstration on each implemented transport |
| R07 | Embedded-device integration | Bridge | Opaque framed data relayed through hardware, with measured bytes and latency |
| R08 | Voice-note playback | Playback + persistence | Receive, play, replay, and failure/retry states |
| R09 | Priority alerts | Alert controller | Authenticated alert preempts normal app playback; platform limitations documented |
| R10 | Push-to-talk walkie-talkie | Floor controller | Press, release, endpoint flush, remote playback, role reversal |
| R11 | PTT disabled gives hands-free session | Audio/session | Automatic segmentation in both directions, loopback and double-talk tests |
| R12 | Small model/app/RAM footprint | Packaging + profiling | APK bytes, installed pack bytes, peak PSS, native allocations |
| R13 | Low idle-listening CPU | VAD/service | Silence, noise, disconnected, and connected-idle measurements |
| R14 | Low WER, intelligible flowing TTS | Evaluation | Raw and normalized WER/CER, comprehension, MOS, critical-entity results |
| R15 | Low latency and favorable RTF | Instrumentation | Stage-level p50/p95, cold/warm, per language/device; **Gemma: TTFT + tokens/s** |
| R16 | Open-source voice pipeline | Compliance | SBOM, licenses, model provenance, reproducible builds |
| R17 | No internet-hosted inference | Offline QA | Airplane mode with local radios re-enabled; WAN-blocked operation |
| R18 | Robust deployable architecture | Reliability + release | Reconnection, deduplication, crash recovery, corruption handling, install guide |
| R19 | Cross-language walkie-talkie | ASR (Gemma) + protocol | Sender translates, sends src_lang + tgt_lang + both texts; receiver TTS speaks tgt_lang |

**Traceability rule:** Every release test and backlog issue references one or more requirement IDs. Acceptance means recorded evidence, not merely an enabled button or a language name in settings.

---

## 3. Scope, operating modes, and user journeys

### 3.1 Required modes

**Transmit-only STT mode**

1. User selects input language and paired receiver.
2. App verifies language pack and receiver capabilities.
3. PTT or hands-free capture begins with an audible/haptic cue.
4. VAD forms an utterance; ASR emits local partial text where supported.
5. Segment is finalized, encoded, authenticated, queued, and transmitted.
6. Sender receives separate received, playback-started, and playback-completed statuses.

**Receive-only TTS mode**

1. Phone listens within a user-started session.
2. App authenticates and validates a received message.
3. Receiver selects the exact supported language pack.
4. TTS generates PCM and schedules playback.
5. Voice note remains available for replay under the retention policy.

**Bidirectional push-to-talk**

- Both phones contain both pipelines, but only one speaker holds the floor at a time.
- The first prototype can use manual roles. The final version negotiates floor ownership.
- Release means finalize current speech, not discard pending decoder output.
- A floor lease and maximum utterance duration prevent a stuck button from blocking a session indefinitely.

**Hands-free / phone-like session**

- Session explicitly starts and stops; no covert permanent microphone.
- Each phone detects local speech and automatically commits bounded segments.
- Headset-assisted full-duplex text exchange is the first validation path.
- Speakerphone mode requires echo handling and clear turn-taking behavior.
- If safe full-duplex capture is not achieved, label the implementation **automatic half-duplex**, not a completed full-duplex phone mode.

**Cross-language walkie-talkie (Gemma 4 E2B add-on)**

- Sender selects source language (detected or explicit) and target language.
- Gemma 4 transcribes and translates in one pass; sender transmits both `text` (source) and `translated_text` (target) with `src_lang` and `tgt_lang`.
- Receiver uses `tgt_lang` to select TTS voice and speaks the translation.
- Falls back to same-language mode if receiver lacks target TTS pack.

**Alert message**

- User deliberately invokes an SOS/alert action, selects or speaks content, and confirms as appropriate.
- Receiver validates sender authorization and message freshness.
- Alert preempts normal app queues and uses an explicitly armed alert-volume policy.
- Transport receipt, playback completion, and human acknowledgment are distinct.

### 3.2 Not in the baseline

- Identity-preserving voice cloning, emotion preservation, speaker diarization, cloud relay, cellular telephony, internet accounts, map services, unlimited mesh routing, and custom RF physical-layer design.
- Raw audio fallback as the normal transport. If later added, label it a separate optional mode and obtain organizer approval.
- Clinical, aviation, maritime, disaster-response, or safety certification.

### 3.3 Failure-aware user journey

At every stage, an audio-first user must know whether the app is listening, processing, waiting for link capacity, delivered, played, or failed. Use distinct earcons and vibration patterns; do not rely solely on reading text or interpreting a color.

---

## 4. System architecture

```text
PHONE A                                                      PHONE B
Microphone                                                   Speaker / headset
   |                                                              ^
AudioRecord -> capture ring -> DSP -> VAD                            |
                  |                                AudioTrack
           endpoint controller                         ^
                  |                                    |
            ASR Engine (Gemma 4 E2B / ONNX CTC)        PCM buffering
                  |                                    ^
      language + translation + safety metadata + message ID   normalizer
                  |                                    ^
      durable outbox + priorities                    priority inbox
                  |                                    ^
         encode -> encrypt/authenticate             verify -> deduplicate
                  |                                    ^
       framed transport ======================= framed transport
          BT / local Wi-Fi / bridge
```

Both phones can run both sides, governed by session, floor, audio-focus,
model-residency, thermal, and backpressure controllers.

### 4.1 Component responsibilities

- `SessionController`: connection lifecycle, language negotiation, capabilities, reconnect, session end.
- `CaptureEngine`: microphone ownership, frame timestamps, sample-rate conversion, bounded ring buffer.
- `VadEngine`: speech probability or decisions only; no transcription responsibility.
- `EndpointController`: pause timers, minimum duration, pre-roll, forced segmentation, PTT release.
- `AsrEngine`: **two implementations behind the same interface** â€” `GemmaAsrEngine` (LiteRT-LM, primary on 6 GB+) and `OnnxCtcAsrEngine` (fallback). Model loading, features, decoding, partial/final events, cancellation.
- `TranscriptCommitter`: immutable segment IDs, normalization policy, confidence annotations, translation metadata.
- `MessageStore`: transactional outbox/inbox and delivery states.
- `ProtocolCodec`: bounded binary encode/decode, version negotiation, authenticated envelope.
- `TransportAdapter`: byte movement, peer discovery/connect, MTU and link statistics.
- `TtsEngine`: pack-specific text frontend and synthesis (DhVaani / IndicF5 unchanged).
- `PlaybackController`: audio focus, routing, playback queues and underrun handling.
- `AlertController`: authorization, priority, freshness, volume consent, acknowledgment.
- `ModelPackManager`: import, validation, activation, eviction, rollback.
- `MetricsCollector`: local structured measurements with opt-in export and no transcript by default.

### 4.2 Concurrency model

- Main/UI dispatcher: state rendering and permission flows only.
- Capture thread: bounded copies; no inference, database writes, logging, or network waits.
- Audio processing worker: resampling, DSP, VAD, segment state.
- ASR worker: one active decoder/model instance unless thread safety is proven.
- TTS worker: serialized synthesis per engine; bounded look-ahead.
- Transport reader and writer: separate coroutine jobs; a single writer orders frames.
- Database dispatcher: short transactional operations outside capture paths.
- Resource governor: adjusts inference concurrency and prevents ASR/TTS thread oversubscription.

Use explicit buffer ownership. Avoid one heap allocation per audio frame. Cancellation must release native tensors, model sessions, sockets, AudioRecord, and AudioTrack.

### 4.3 Architectural invariants

1. No raw microphone PCM leaves the phone in the baseline.
2. Only authenticated final text is automatically spoken remotely.
3. No silent rewriting of critical content.
4. A received frame is not the same as a played message.
5. A transport acknowledgment does not imply human comprehension.
6. No unbounded audio, transcript, packet, or synthesis queues.
7. No network operation lies on the capture-thread critical path.
8. No model is accepted merely because it has an ONNX extension.
9. The user can stop the session and revoke microphone access.
10. No alert functionality depends on unrestricted background execution.

---

## 5. Technology stack and dependency policy

### 5.1 Preferred implementation stack

| Layer | Proposed choice | Engineering note |
|---|---|---|
| Android application | Kotlin, AndroidX, Compose | Keep UI lean; profile actual release build |
| Async/state | Coroutines, Flow, StateFlow | Explicit bounded channels; no silent transcript drops |
| Capture/playback | AudioRecord / AudioTrack | Direct control over PCM, buffering, route, timing |
| Local database | Room/SQLite | Persist outbox before acknowledging durable receipt |
| Small settings | DataStore | Model selection, accessibility, consent settings |
| **ASR runtime (primary)** | **LiteRT-LM (Gemma 4 E2B-it)** | **Native audio input, transcription + translation, Apache-2.0** |
| ASR runtime (fallback) | ONNX Runtime CPU; sherpa-onnx when compatible | Per-language CTC packs for <6 GB devices |
| TTS runtime | ONNX Runtime CPU (VITS) | DhVaani / IndicF5 unchanged |
| Whisper baseline | whisper.cpp through JNI, if chosen | Not the Odia solution and not inherently true streaming |
| VAD | Open-source WebRTC VAD or Silero VAD | Pin exact implementation/license and benchmark |
| Training/export | PyTorch + model-native training code | Developer workstation only; not an Android Python runtime |
| Alternative edge runtime | ExecuTorch or TensorFlow Lite/LiteRT | Use only when export and operators are proven |
| **Flutter binding for Gemma** | **flutter_gemma (community)** | **Officially pointed by LiteRT-LM for Flutter; Android + iOS** |
| Wi-Fi | Local TCP + native discovery/P2P APIs | No Google Nearby dependency |
| Bluetooth phones | Native RFCOMM | Connection and permission UX required |
| Embedded Bluetooth | BLE GATT | Different framing/MTU behavior from RFCOMM |
| Serialization | Deterministic CBOR with bounded schema | Avoid verbose JSON on constrained payload paths |
| Cryptography | Reviewed open-source protocol/library | No hand-written primitive or novel handshake |
| Profiling | Perfetto, Android profilers, adb, local benchmark runner | Pin tool versions and preserve raw artifacts |
| Firmware | ESP-IDF or equivalent open-source stack | Hardware-specific selection gate |

### 5.2 Runtime selection rules

- sherpa-onnx supports offline speech functionality and Android, but **a supported model family does not imply every fine-tuned checkpoint is compatible**. Verify tokenizer, input tensors, metadata, vocoder, and frontend. [S10]
- Prefer one major native inference runtime in the production flavor. Multiple runtimes can inflate APK and PSS; prototype variants may include several for evaluation.
- Do not start new work around legacy PyTorch Mobile solely because it appears in the problem statement. Current PyTorch edge documentation centers on ExecuTorch. [S11]
- TensorFlow Lite for Microcontrollers is appropriate for tiny MCU workloads, not a default runtime for large multilingual speech models on phones.
- CPU inference is the reference. Treat GPU/NPU delegates as optional measured accelerators, not required functionality or a loophole around the open-source requirement.
- Do not call Android SpeechRecognizer or the device's default TextToSpeech provider as the compliant speech engine. Their installed implementation, licensing, language availability, and offline behavior are not controlled by this app.
- No Google Nearby Connections, proprietary wake-word SDK, cloud analytics, cloud crash reporting, or hosted inference in the compliance build.
- **Gemma 4 E2B selection**: probe free RAM and GPU delegate availability via `platform_info` capability probe. Use Gemma on 6 GB+ devices; fall back to ONNX CTC on lower-RAM devices. No inline `Platform.isIOS` checks â€” Dart asks `platform_info` what the host can actually do.
- **flutter_gemma** is the community Flutter binding that LiteRT-LM officially points Flutter developers at; `flutter_gemma_mediapipe` is the opt-in engine package for `.task` models. Supports Android and iOS.
- **LiteRT-LM Swift API** is early preview; Dart call sites stay shared via flutter_gemma; declared iOS limits (RFCOMM, volume) are untouched by this change.

### 5.3 Dependency acceptance checklist

For every library and model: exact version/commit, source URL, SPDX license where available, copyright notices, redistributability, transitive dependencies, native ABIs, minSdk, build recipe, known vulnerabilities, and runtime network behavior.

If eSpeak NG is linked or shipped, comply with its GPL obligations and obtain a compatibility review of the combined distribution. Do not call the entire resulting application permissively licensed without that review. [S5]

---

## 6. Ten-language model strategy

### 6.1 Coverage ledger

Maintain a machine-readable ledger from day one. The initial rows below identify **research routes**, not validated production models.

| Language | App tag | ASR route (Gemma 4 E2B primary) | Fallback ASR (ONNX CTC) | TTS route | Required native-language tests |
|---|---|---|---|---|---|
| Hindi | hi-IN | Gemma 4 E2B native audio | IndicConformer | DhVaani | Schwa, digits, negation, Hindi-English names |
| Gujarati | gu-IN | Gemma 4 E2B native audio | IndicConformer | DhVaani | Script frontend, loanwords, names |
| Marathi | mr-IN | Gemma 4 E2B native audio | IndicConformer | DhVaani | Conjuncts, morphology, place names |
| Kannada | kn-IN | Gemma 4 E2B native audio | IndicConformer | DhVaani | Gemination, suffixes, numbers |
| Malayalam | ml-IN | Gemma 4 E2B native audio | IndicConformer | DhVaani | Long compounds, chillus, segmentation |
| Tamil | ta-IN | Gemma 4 E2B native audio | IndicConformer | DhVaani | Colloquial speech, names, pronunciation |
| Telugu | te-IN | Gemma 4 E2B native audio | IndicConformer | DhVaani | Vowel length, gemination, suffixes |
| Odia | or-IN | Gemma 4 E2B native audio | Explicit Odia checkpoint | DhVaani | Odia script, dialect coverage, model code mapping |
| Bengali | bn-IN | Gemma 4 E2B native audio | IndicConformer | DhVaani | Conjuncts, numbers, regional accent |
| English | en-IN | Gemma 4 E2B native audio | Whisper-small.en / Conformer EN | VITS / Piper / DhVaani | Indian accents, abbreviations, mixed names |

Use app BCP-47 tags independently of model IDs. For example, `or-IN` can map to model-specific `or` or `ory`; do not substitute Bengali or Assamese as an Odia fallback.

Ledger fields: source revision, task, language tags, code license, weight license, pack bytes, PSS, input/output rates, tokenizer hash, frontend hash, quantization, native runtime, export status, language QA status, and benchmark report path. Initial benchmark values must be `null`/`not_measured`, never invented zeroes.

**Gemma 4 E2B validation note:** Phase 0 requires installing Google AI Edge Gallery from Play Store, opening Audio Scribe, and transcribing/translating recorded clips in all 10 target languages, especially noisy and code-switched speech. Deliverable: go/no-go table of per-language quality. Don't skip this â€” audio-language coverage is narrower than the 140-language text claim.

### 6.2 ASR candidate lanes

**Lane A â€” Gemma 4 E2B-it via LiteRT-LM (Primary)**

- Single 2.58 GB `.litertlm` pack replaces all per-language ASR packs. Apache-2.0 license.
- Native audio input: accepts 16 kHz PCM frames directly, max 30 seconds per segment (aligns with VAD/endpointing chunks).
- Transcription + translation in one pass: 140+ languages for text, cross-lingual audio encoder handles Hindiâ€“English code-switching natively (Devanagari stays Devanagari mid-utterance).
- Fully on-device: Google's Audio Scribe in AI Edge Gallery and Gemma Translator reference project prove offline operation via LiteRT-LM.
- RAM: ~1.1 GB resident on mobile config; 676 MBâ€“1.7 GB peak measured. Comfortable on 6 GB+ phones, tight below that.
- Latency profile: autoregressive, not CTC streaming. ~0.3 s time-to-first-token on GPU, 25â€“56 tokens/s decode. No partial hypotheses â€” final text emitted after end-of-speech.

**Lane B â€” ONNX CTC Per-Language Packs (Fallback)**

- IndicConformer-600M multilingual exported per-language to ONNX + INT8 quantisation. MIT license.
- Each pack ~45â€“70 MB. Load only active language.
- Greedy CTC decoding; beam search measured independently.
- Used on devices with <6 GB RAM or when Gemma latency exceeds budget.
- Keeps existing `core/asr` interface boundary clean â€” swap implementation behind `AsrEngine`.

**Lane C â€” Custom Compact Student (Only After Feasibility Gate)**

- Choose compact CTC Conformer/FastConformer student (~20â€“80M params) if Gemma + fallback both fail on low-end.
- Distill from properly licensed teacher; fine-tune with licensed native audio.
- Begin with one difficult + one well-resourced language to test recipe.
- Do not promise new ten-language student within short timeline; reserve compute/reviewers/contingency if needed.

### 6.3 TTS candidate lanes

**Lane A â€” Compact per-language neural synthesis**

- Evaluate verified VITS/Piper-compatible or other compact models for each language individually.
- Do not claim that Piper or sherpa-onnx supplies high-quality voices for all ten languages out of the box.
- If a voice is missing, train/fine-tune a compact acoustic model and vocoder only with authorized data and a compatible frontend.
- Validate grapheme/phoneme vocabulary, number expansion, punctuation, vocoder sample rate, and voice license.

**Lane B â€” DhVaani feasibility experiment**

- Its model card lists all ten requested languages among 27 and states Apache-2.0. It is based on a 123M-parameter flow-matching model, with a listed 491 MB weights file and a reference-audio requirement. [S3]
- This is a promising coverage candidate, **not evidence of low-end Android readiness**.
- Test native export, frontend parity, vocoder dependencies, total artifact size, memory, and time-to-first-audio.
- Use a fixed authorized reference voice. Do not expose arbitrary impersonation/voice-cloning as a product feature.
- Test fewer flow steps only as an explicit quality/latency experiment. A lower step count is not automatically acceptable.
- The card warns that rare out-of-vocabulary characters may be silently dropped. The app must detect unsupported critical text before synthesis.

**Lane C â€” Quality references, not default deployment**

- IndicF5 explicitly lists the nine requested Indic languages among eleven, but does not list English. It requires reference audio and reference text. Verify all weights/dependencies/licenses before use. [S4]
- Large generative TTS models can serve as offline development references if permitted; do not infer phone feasibility from desktop demos.

**Lane D â€” Non-neural engineering fallback**

- eSpeak NG's source language list includes the requested languages, including Odia. Verify the exact distributed build with `espeak-ng --voices`. [S5]
- Use it to unblock early transport/UX testing or as a clearly labeled degraded fallback.
- It does not establish natural neural TTS compliance and may score poorly for flow and intelligibility.
- Cached reviewed alert phrases improve reliability but **cannot replace arbitrary-text TTS evaluation**.

**Blocked-by-default route**

Meta MMS TTS Odia is publicly available, but the model card states CC-BY-NC-4.0. Do not treat it as an unrestricted open-source deployment model. Exclude it from the strict compliance build unless organizers explicitly accept that license and intended use. Noncommercial availability is not proof of meeting the problem's open-source restriction. [S12]

### 6.4 Model decision gates

A candidate advances only if it passes, in order:

1. Exact artifact and license approval.
2. Desktop inference on arbitrary target-language inputs.
3. Native export and numerical/frontend parity.
4. Physical low-end phone inference without OOM.
5. Sustained RTF and thermal limits.
6. Native-language accuracy/intelligibility gate.
7. Pack installation, cold start, and repeated reload tests.

If any language has no viable candidate, mark the ten-language release **blocked**. Never hide a missing language behind an English transliteration or a stock OS engine.

---

## 7. Speech capture, VAD, and endpointing

### 7.1 Audio capture path

1. Request microphone permission through a visible activity.
2. Start the appropriate foreground service during a user action.
3. Construct AudioRecord for the selected audio route.
4. Capture at a supported hardware rate; resample to the model's required rate.
5. Baseline ASR input is mono 16 kHz signed PCM16 where the chosen model requires it.
6. Tag frames with monotonic capture timing and route changes.
7. Push fixed-size chunks into a bounded reusable ring.
8. Apply lightweight preprocessing and VAD outside the audio callback/read loop.

**PCM sanity check:** 16,000 samples/s Ã— 16 bits Ã— 1 channel = 256,000 bits/s. A 20 ms PCM16 frame has 320 samples and 640 bytes. This local capture rate is not the transmitted bitrate.

### 7.2 DSP policy

- Compare raw capture with Android's voice-communication path; vendor AEC/NS behavior varies.
- Enable `AcousticEchoCanceler`/`NoiseSuppressor` only if available and validated on the device.
- Avoid stacking vendor noise suppression with aggressive software suppression by default.
- Evaluate an open-source software echo/noise path when native effects are inadequate; account for CPU and licensing.
- Clamp impossible amplitudes, detect clipping, track silence/noise level, and avoid automatic gain changes that distort quiet speech.
- Resampling must preserve duration and avoid drift; validate with tones and known-duration speech.
- Never use denoising that removes consonants merely to improve a synthetic SNR score.

### 7.3 Starting endpoint configuration

These are **initial tunable settings**, not validated language-independent constants:

| Setting | Starting value | Rationale |
|---|---|---|
| Capture processing frame | 20 ms | Fits WebRTC-style frame handling; aggregate as another VAD requires |
| Pre-roll | 200â€“300 ms | Preserve initial consonants |
| Minimum speech | 150â€“250 ms | Reject short transients without excluding short words |
| End-of-speech silence | 450 ms default | Balance natural pauses and latency |
| Allowed silence tuning | 250â€“800 ms | Device/noise/speaking-style experiment range |
| Post-roll | 100â€“200 ms | Preserve final syllables |
| Soft utterance cap | 8 s | Seek safe segment boundary |
| Hard utterance cap | 12 s | Bound memory and offline inference tail |
| Maximum PTT hold | 30 s initial | Split safely before cap; prevent stuck floor |

A 20 ms input chunk does not imply every VAD accepts exactly 320 samples. Silero and other models have version-specific frame requirements; adapt through a small accumulator.

### 7.4 Endpoint state machine

```text
IDLE -> POSSIBLE_SPEECH -> SPEAKING -> POSSIBLE_END -> FINALIZING -> IDLE
           |                 ^            |
           +---- reject -----+            +---- speech resumed ----> SPEAKING

PTT release / hard cap / session stop -> bounded finalization or explicit cancel
```

Rules:

- VAD is evidence of acoustic activity, not proof of a grammatical sentence.
- Punctuation prediction must not block transmission indefinitely.
- For long speech, split into utterance segments and retain ordering/continuation metadata.
- Do not split exclusively on punctuation; many live ASR outputs lack it.
- Preserve buffer overlap locally, but reconcile repeated tokens before committing.
- If ASR backlog grows, stop accepting additional segments with an audible warning or apply negotiated turn-taking. Never silently overwrite important audio.
- PTT captures only while requested; hands-free listening runs VAD while ASR sleeps during silence.

### 7.5 Endpoint tests

Short words, elongated vowels, long internal pauses, stuttering, soft speech, shouted speech, fan noise, sirens, music, two speakers, microphone taps, sentence-final fricatives, PTT release during a word, route changes, and generated TTS leaking into the microphone.

Measure missed-start rate, clipped-end rate, false speech segments/hour, silence-triggered hallucinations, segmentation delay, and finalization backlog.

---

## 8. STT pipeline and model optimization

### 8.1 Recognition contract

Input: language tag, normalized PCM frames (16 kHz mono), sample rate, utterance ID, capture start/end, optional constrained vocabulary hints, optional target language for translation.

Output events:

- `Partial`: **Not applicable for Gemma 4 E2B** (autoregressive, no streaming partials). For ONNX CTC fallback: locally replaceable hypothesis, not eligible for remote playback.
- `Final`: immutable committed text, source language, target language (if translated), segment index, finalization timestamp, optional calibrated uncertainty metadata.
- `NoSpeech`: no trustworthy text to transmit.
- `Failure`: typed reason such as model missing, unsupported input, memory pressure, or inference error.

### 8.2 Decoder choices

**Gemma 4 E2B (Primary):**
- Autoregressive token generation after end-of-speech. No CTC decoder, no beam search, no partial hypotheses.
- Temperature 0 for deterministic output; max tokens per segment bounded by 30 s audio limit.
- Translation: same audio path, specify target language in prompt; outputs `translated_text` alongside `text`.

**ONNX CTC Fallback:**
- Begin with greedy CTC when the chosen model supports it and accuracy is viable.
- Measure beam search independently; increased beam width may improve some words but raises CPU and latency.
- Add a small local lexicon/hotword mechanism only if the decoder supports it.
- Do not force critical terms into the transcript because they are in a hotword list.
- Automatic punctuation is optional and must not change lexical content.
- Do not add a generative LLM "cleanup" pass to emergency speech.
- Never use Whisper's translation task when same-language transcription is required.

### 8.3 Streaming policy

**Gemma 4 E2B:** Not a streaming model. Recognizes bounded utterances (VAD/endpointed segments, max 30 s). Full forward pass after speech ends. No partials, no overlap, no reconciliation.

**ONNX CTC Fallback:** Recognize bounded utterances. Explicitly document look-ahead, overlap, repeated compute, reconciliation, and hard-cut behavior if overlapping windows are used.

**Remote commit policy:** Default to final endpointed segments for both engines. No stable-prefix mode â€” Gemma emits full text only after endpoint; CTC partials are local UI only, never transmitted.

### 8.4 Optimization sequence (Gemma 4 E2B)

1. **Phase 0 validation:** Run Google AI Edge Gallery Audio Scribe on target languages (1â€“2 days, zero cost).
2. **Desktop evaluation harness:** Use LiteRT-LM CLI/Python API with `litert-community/gemma-4-E2B-it-litert-lm`; run captured audio, compute WER per language vs IndicConformer baseline, score translation pairs (3â€“5 days).
3. **TranslateGemma fallback:** Lightweight 55-language open translation models for on-device if Gemma built-in translation disappoints.
4. **Android integration:** Add `flutter_gemma` binding; implement `GemmaAsrEngine` beside ONNX engine behind same `AsrEngine` interface; reuse `AudioCapturePlugin` frames â€” audio segment in, JSON `{text, lang, translated_text?, tgt_lang?}` out.
5. **Backend selection:** In `platform_info` capability probe (free RAM / GPU delegate), keeping no-inline-`Platform.isIOS` discipline.

### 8.5 Compact-student training path (Fallback Lane C Only)

- Freeze reproducible train/dev/test speaker splits first.
- Use licensed teacher outputs only where license and data consent permit.
- Begin with supervised CTC loss; introduce compatible logit distillation and/or feature distillation under a documented objective.
- If teacher/student tokenizers differ, align vocabularies or use a supported sequence-level objective; do not directly compare incompatible logits.
- Train language-specific students first if multilingual capacity proves insufficient.
- Track results per language and accent; aggregate averages cannot hide Odia or Malayalam failures.
- Use augmentation for reverberation, environmental noise, clipping, gain, and channel response, with realistic distributions.
- Keep real native speech in final evaluation; synthetic teacher data cannot validate real recognition.
- Budget compute after a pilot training run, not from an arbitrary promised number of GPU-hours.

---

## 9. Text representation and language handling

### 9.1 Three representations

1. **Original ASR transcript:** preserves engine output for local debugging or audit when retention is enabled.
2. **Transport text:** conservative Unicode-normalized message, sent with language and flags.
3. **TTS spoken representation:** deterministic language-aware expansion of the transport text.

Do not overwrite the original transcript with speech-friendly expansion. Preserve both when auditing number/name pronunciation.

### 9.2 Normalization rules

- UTF-8 on the wire; validate decoding strictly after reassembly.
- Use Unicode NFC as a default only after script-specific regression tests.
- Preserve meaningful combining marks, virama, nukta, and relevant joiners.
- Do not strip all non-ASCII characters or remove punctuation indiscriminately.
- Reject dangerous control sequences; do not interpret markup, SSML, URLs, or embedded commands as executable instructions.
- Text size is measured in **UTF-8 bytes**, not visible characters or Kotlin UTF-16 code units.
- Segment at Unicode/grapheme-aware text boundaries for synthesis; byte fragmentation occurs only in a lower layer and reassembles before parsing.
- Flag unsupported characters; never silently drop a critical symbol, sign, or digit.

### 9.3 Numbers and critical content

Define per-language tests for:

- Integers, decimals, negative signs, percentages, dates, time, distances, units, phone numbers, coordinates, addresses, and identifiers.
- Leading zeroes and sequences that must be spoken digit by digit.
- Negation: â€œdo not enterâ€ versus â€œenter.â€
- Counts: â€œtwo peopleâ€ versus â€œtwenty people.â€
- Directions and locations: east/west, left/right, floor and gate numbers.

Do not derive numbers from guessed semantics. If critical content is uncertain, attach an uncertainty cue and offer a repeat/confirm flow. A recognizer score is not a calibrated probability unless explicitly calibrated.

### 9.4 Code switching and language selection

- Default: explicitly selected input language; receiver uses transmitted language, not its UI language.
- Keep English brand/place names in context where supported.
- Mixed-script text may require span-level frontend handling, but script is not a reliable language detector for Hindi versus Marathi.
- Optional language identification runs only if it meets cost and accuracy gates.
- Do not repeatedly switch models mid-utterance on weak evidence.
- If a receiver lacks the pack, return `UNSUPPORTED_LANGUAGE`, provide a recognizable audible failure cue, and retain text. Do not silently read using the wrong language voice.
- **Cross-language translation (Gemma 4 E2B):** Sender-side translation. Sender knows source language reliably; sends both `text` (source) and `translated_text` (target) with `src_lang` and `tgt_lang`. Receiver uses `tgt_lang` to select TTS voice. ~100â€“200 bytes becomes ~400 bytes, still trivially within Bluetooth budget. Translation is explicit, never a hidden fallback.

---

## 10. TTS pipeline and playback

### 10.1 End-to-end receive path

1. Read a bounded frame.
2. Verify session, authentication, authorization, expiry, and replay state.
3. Reassemble complete message where needed.
4. Validate schema, language, content limits, and Unicode.
5. Transactionally deduplicate and persist.
6. Send durable-receipt acknowledgment.
7. Enqueue normal or alert playback.
8. Normalize text with the selected language frontend.
9. Generate the first PCM chunk or first bounded clause.
10. Acquire audio focus and start AudioTrack.
11. Track actual playback progress rather than synthesis completion.
12. Emit playback-started/completed/failed receipts.

### 10.2 Low-latency synthesis

- Prefer a model/runtime with true chunked output when available.
- Otherwise synthesize short clauses sequentially and buffer the next clause while playing the current one.
- Clause-by-clause generation is not acoustic streaming; document prosody and repeated-context costs.
- Select chunk size from actual time-to-first-audio and underrun measurements.
- Use an initial small prebuffer, then adapt within a bound.
- Avoid sentence-level audio concatenation that creates clicks; apply safe short boundary fades only without truncating phonemes.
- Preserve model output sample rate and resample once for the chosen output route if needed.
- Validate PCM range, finite values, duration bounds, and audio format before playback.
- Normalize loudness conservatively; prevent clipping and do not amplify beyond safe route policy.

### 10.3 Voice-note persistence

- Store received text and metadata by default.
- Optionally cache synthesized PCM/compressed local audio for fast replay; this cache never becomes the baseline transmitted payload.
- Cache key includes text, language, model/frontend revision, voice, and synthesis settings.
- Bound cache bytes and retention time.
- Avoid raw PCM persistence for every conversation by default because of storage/privacy cost.
- If regenerating later produces different audio, display model revision and retain the original text.

### 10.4 Alert cache

- Maintain a small reviewed set of generic local earcons and spoken status prompts.
- For predefined alert templates, cache consented recordings or locally generated reviewed audio and include license provenance.
- Version/hash the template dictionary; never reinterpret a mismatched ID as different alert content.
- If a dynamic alert contains a location or number, arbitrary TTS must still speak that variable accurately.
- Report cache-hit versus uncached TTS latency separately.

### 10.5 TTS quality validation

Native listeners should score intelligibility and flow separately. Include arbitrary unseen prose and emergency phrases, names, digits, abbreviations, mixed scripts, punctuation, long messages, and malformed input.

Record pronunciation errors, dropped words, inserted words, repetition, unnatural breaks, clipping, excessive silence, and unsupported character loss. Back-transcribing generated speech with ASR is a diagnostic only, not a substitute for human evaluation.

---

## 11. Push-to-talk and hands-free operation

### 11.1 PTT controller

```text
DISCONNECTED -> CONNECTED_IDLE
CONNECTED_IDLE --press--> REQUESTING_FLOOR
REQUESTING_FLOOR --grant--> CAPTURING
CAPTURING --release--> FINALIZING
FINALIZING --> QUEUED --> AWAITING_RECEIPT --> CONNECTED_IDLE

Any state --link loss--> RECOVERING
Any state --user stop--> STOPPING --> DISCONNECTED
```

- Give capture-start feedback only after the microphone and floor are actually ready.
- If the user speaks during model warm-up, retain bounded pre-roll when possible and clearly signal readiness.
- Use monotonic floor leases; renew only while active.
- Resolve simultaneous requests deterministically using the negotiated coordinator and request ordering.
- Alerts have queue priority but do not bypass authentication.
- Transport acknowledgment must not hold the floor longer than necessary for ordinary conversation.

### 11.2 Hands-free controller

- Each endpoint maintains independent inbound/outbound queues.
- Headset mode: permit capture and playback concurrently after loopback tests.
- Speakerphone mode: use verified AEC and reference-path timing.
- Detect double-talk where possible; do not blindly discard local speech during remote audio.
- If echo suppression fails, switch to clearly announced automatic turn-taking.
- At low bitrate, enforce a bounded turn and expose queue delay.
- Stop microphone and release service resources when the session ends.

### 11.3 Echo-loop prevention

A remote message spoken by TTS must not be recognized and transmitted back indefinitely. Message IDs alone cannot solve this: the echo becomes a new ASR message.

Mitigations, in priority order:

1. Prefer headset validation for simultaneous operation.
2. Use audio-path AEC and correct reference timing where supported.
3. Gate or lower confidence in microphone speech that is explainable by local playback, without suppressing all double-talk.
4. Add a bounded playback tail guard in half-duplex mode.
5. Detect repeated round-trip text patterns as a last-resort alarm, not as the main acoustic solution.
6. Expose and log mode downgrade instead of claiming full-duplex success.

---

## 12. Android services, permissions, and lifecycle

### 12.1 Service design

Use a user-started foreground communication service with only the service types justified by actual operations. Depending on the selected Android API level and design, microphone, media playback, and connected-device types may be appropriate; audit their individual prerequisites. Do not declare `phoneCall` merely because the UX looks like a phone call. [S7]

- Start microphone access while a visible activity has the required permission.
- Display a persistent notification with connected peer, mode, microphone state, and Stop action.
- Handle foreground-service start restrictions and type-specific permissions on newer Android versions.
- Android 15+ audio focus requires the app to be topmost or running a foreground service. [S6]
- Background/boot receivers must not silently start recording; microphone restrictions apply. [S7]
- WorkManager is suitable for deferred cleanup, not real-time continuous audio.
- Use a bounded partial wake lock only when necessary for an active session; release on all error/cancel paths.
- Do not promise survival after force-stop, user revocation, OS kill, or OEM battery restrictions.

### 12.2 Permission matrix

| Capability | Permissions/policy to evaluate | UX behavior |
|---|---|---|
| Microphone | RECORD_AUDIO; appropriate foreground-service declarations | Explain local-only capture and show active state |
| Foreground service | FOREGROUND_SERVICE plus required type permissions on applicable APIs | User starts/stops visible communication session |
| Notifications | POST_NOTIFICATIONS on applicable Android versions | Explain persistent session/alert notifications |
| Local Wi-Fi sockets | INTERNET, network state as needed | Explain permission name does not mean cloud use |
| Wi-Fi Direct | ACCESS_WIFI_STATE, CHANGE_WIFI_STATE, NEARBY_WIFI_DEVICES on newer APIs; legacy location rules | Request only for discovery/connect path |
| Bluetooth 12+ | BLUETOOTH_SCAN, CONNECT, ADVERTISE only as used | Feature-scoped Nearby Devices requests |
| Legacy Bluetooth | Legacy Bluetooth and location requirements as applicable | maxSdk caps and device testing |
| Model import | Storage Access Framework | User-selected files, no broad storage permission |
| QR pairing | CAMERA only if QR scanner enabled | Offer manual verification alternative |
| DND behavior | Explicit notification policy access only if justified | Optional, user-granted; never imply automatic bypass |

Audit Wi-Fi API-specific location requirements instead of blanket-removing location permissions. `neverForLocation` is only appropriate when truthful. Verify current target SDK and behavior on actual build devices. [S8â€“S9]

### 12.3 Lifecycle edge cases

Test rotation, app backgrounding, screen lock, permission revocation, incoming call, alarm, route unplug, Bluetooth disconnect, Wi-Fi group changes, process death, notification dismissal behavior, battery saver, thermal throttling, and low storage.

On recovery:

- Reconnect only under clear user/session policy.
- Never silently resume microphone capture after a stopped/revoked session.
- Restore pending outbox records without automatically replaying expired alerts.
- Treat previously `PLAYING` messages after a crash as ambiguous; do not claim exactly-once audible playback across power loss.

---

## 13. Transport adapters and embedded bridge

### 13.1 Shared adapter contract

Each adapter exposes discovery/connect/disconnect, authenticated-session bootstrap transport, reliable byte/message send, receive stream, negotiated maximum frame size, connection state, and observable link statistics.

Protocol/application logic must not depend on Bluetooth device addresses or Wi-Fi IPs as permanent identity. Persist verified public-key identities instead.

### 13.2 Local Wi-Fi TCP

- First development path: both phones on an isolated local router or a phone-created local hotspot.
- Discover a service using native NSD where available, with manual local address pairing as fallback.
- Use length-prefixed application frames; TCP is a byte stream, not message-oriented.
- Validate a frame's length before allocation and handle partial reads.
- Keep writes bounded; an entire large backlog written to a TCP buffer cannot later be preempted by an alert.
- Connection liveness, application receipts, and replay state remain necessary even though TCP provides ordered transport.

### 13.3 Wi-Fi Direct

- Use native Wi-Fi P2P APIs for peer discovery, group establishment, and connection metadata. [S8]
- Determine group owner dynamically; do not hardcode an assumed IP address.
- Handle denied permissions, unavailable hardware support, stale groups, group owner change, and user cancellation.
- Bind sockets to the intended local network when needed; never depend on a validated internet network.
- Stop continuous discovery after connecting to reduce idle power.

### 13.4 Bluetooth Classic RFCOMM

- Use a fixed app service UUID and secure RFCOMM pairing APIs.
- Separate client connection and server accept paths.
- Cancel discovery before active connection where appropriate.
- Use bounded length-prefixed frames; socket reads can split or coalesce messages.
- Test pairing cancellation, stale bonds, peer reboot, concurrent connections, and reconnection.
- System Bluetooth pairing is useful link protection but does not replace application identity/authorization for distress alerts.

### 13.5 BLE GATT for embedded relays

- Treat BLE as a separate adapter, not a drop-in RFCOMM socket.
- Negotiate ATT MTU when available; use actual usable payload limits.
- Do not assume all phones can advertise or act as a reliable GATT peripheral.
- Define RX/TX characteristics and a capabilities characteristic.
- Fragment authenticated application records for GATT; reassemble within strict byte/count/time limits.
- Use credits or application flow control to avoid overwhelming notification/write queues.
- An ATT indication or write response is not proof that the receiving phone persisted or played the message.

### 13.6 Embedded bridge architecture

```text
Phone A --BLE or Wi-Fi--> Bridge A --external low-rate channel--> Bridge B
                                                               |
                                                            BLE/Wi-Fi
                                                               |
                                                            Phone B
```

For a simple milestone, one bridge can relay between two local endpoints; label that topology accurately. Two bridges are required to demonstrate a separate physical inter-bridge radio link.

Firmware responsibilities:

- Read bounded opaque frames from the phone-side interface.
- Forward over a configured serial/radio link.
- Maintain limited queues and flow control.
- Expose link diagnostics such as delivered bytes, loss/retries, queue depth, RSSI where available, and link uptime.
- Never log plaintext or hold speech models.
- Preserve application IDs and authenticated content unchanged.
- Reject malformed outer framing and advertise supported payload limits.

An ESP32-family board may be suitable, but check the exact variant: not all variants support Bluetooth Classic. Select BLE/Wi-Fi capabilities from the actual datasheet. External sub-GHz/LoRa radio use is optional and requires legal frequency, duty-cycle, power, hardware, and organizer review; do not infer RF requirements from the title alone.

### 13.7 Development link emulator

Build a deterministic in-process/proxy link emulator with configurable byte-rate limits, latency, jitter, loss, disconnection, duplication, and reorder behavior appropriate to each transport layer.

- Emulate a byte stream separately from a lossy datagram/GATT link.
- Use a seeded random generator for reproducibility.
- Count headers, authentication, acknowledgments, and retries.
- Enforce a small token-bucket burst size; a huge burst allowance can make a falsely impressive low-bitrate demo.
- Record emulator configuration alongside every benchmark.

---

## 14. Wire protocol, delivery, and security

### 14.1 Protocol v1 scope

- Two authenticated peers per session.
- Versioned capability negotiation.
- Final text messages, optional template alerts, control frames, and delivery receipts.
- Bounded sizes and queues.
- Message-level deduplication across reconnects.
- Transport-independent application encryption/authentication.
- No arbitrary remote model loading, file execution, URL fetching, or code execution.

### 14.2 Handshake and pairing

1. Establish local transport.
2. Exchange a bounded protocol hello and supported versions.
3. Run a reviewed authenticated key-exchange protocol through an audited open-source library.
4. Verify peer identity via QR or short authentication string in person.
5. Bind the transcript of version/capability negotiation into the authenticated session to prevent downgrade/tampering.
6. Derive separate send/receive keys and counters according to the chosen protocol.
7. Negotiate common languages, payload limits, template revision, mode, and optional compression.
8. Persist trust only after explicit user approval.

Do not design custom cryptographic primitives or use a six-digit code directly as an encryption key. Use reviewed key exchange and SAS/PAKE behavior as appropriate. Resolve exact library, Android compatibility, license, and protocol review before protocol freeze.

### 14.3 Logical message schema

```text
protocol_version
message_type
session_context
message_id                  128-bit random identifier
sender_identity_reference   bound to authenticated peer
sequence_number             per-direction monotonic within session
src_lang                    source language (BCP-47)
tgt_lang                    target language (BCP-47) â€” equals src_lang for same-language
priority                    NORMAL / ALERT
created_time_metadata       optional wall time, not sole freshness authority
remaining_lifetime_ms       bounded age/expiry semantics
utterance_id
segment_index
is_final_segment
flags                       uncertainty, continuation, template, translation, etc.
text_utf8                   source transcript (required)
translated_text_utf8        target translation (optional, present when tgt_lang != src_lang)
template_id + typed slots   alternative to text for alerts
```

This is a **logical schema**, not a claim about exact encoded packet bytes. Encode with compact deterministic integer keys/enums where beneficial. Version and freeze actual framing after serialization tests.

**Wire format for cross-language (Phase 3):** Extend protocol messages with `src_lang`, `tgt_lang`, and optional `translated_text` field. Sender translates, sends both strings â€” ~100â€“200 bytes becomes ~400 bytes, still trivially within Bluetooth budget. Receiving phone's TTS speaks `tgt_lang` text. Loopback test with `LinkProfile.poor` carries over unchanged.

### 14.4 Size limits and framing

Initial protective limits, subject to validated device/link profiles:

- Text content: maximum 4 KiB UTF-8 per logical message; segment ordinary speech much smaller.
- Logical encoded message: maximum 8 KiB including metadata.
- Stream frame: explicit maximum and length prefix; parser rejects oversized lengths before allocation.
- Fragment count and aggregate reassembly memory: bounded per peer.
- Reassembly deadline: finite and tied to declared link profile.
- Unknown major version: reject with clear incompatibility status.
- Unknown required field/feature: reject; unknown optional field: ignore only if schema defines that behavior.
- Control and authentication messages have their own strict caps.

These are DoS protection caps, not acceptable typical message sizes for a 300 bps link.

### 14.5 Fragmentation and cryptography

- Prefer encrypting/authenticating a complete small application record, then transport-fragmenting it. Do not speak or parse its plaintext until full authentication succeeds.
- Bind message/sequence/context information as authenticated metadata according to the chosen protocol.
- If independent authenticated fragments are required for a particular constrained adapter, use the protocol/library's supported construction and account for per-fragment overhead.
- Enforce nonce uniqueness per key and direction; on process restart or reconnect, establish fresh session keys unless safe counter persistence is explicitly implemented and reviewed.
- Retransmissions under the same session resend the same encrypted record rather than encrypting different content with a reused nonce.
- After a new session, re-encrypt pending logical messages under new keys while retaining their application message IDs for deduplication.
- CRC may help detect link framing corruption, but never substitutes for authentication.

### 14.6 Message states

```text
Sender: CAPTURED -> FINALIZED -> PERSISTED -> QUEUED -> SENT
        -> RECEIVED_DURABLY -> PLAYBACK_STARTED -> PLAYBACK_COMPLETED
        -> USER_ACKNOWLEDGED (where required)

Terminal/exception states: EXPIRED, REJECTED, FAILED, CANCELLED, PLAYBACK_UNKNOWN
```

- Receiver emits durable receipt only after a successful transaction.
- Playback completion is derived from playback progress, not from successful TTS generation.
- Human acknowledgment requires a deliberate user action.
- The sender may receive a durable receipt without playback if audio focus or TTS fails.
- Each state transition is idempotent and keyed by peer identity + message ID.

### 14.7 Retry and ordering

- For reliable streams, avoid reinventing a full packet-level ARQ stack. Use application retry after reconnect or missing durable receipt.
- For lossy bridge/GATT profiles, use selective bounded fragment acknowledgment/retry if necessary.
- Retry timeouts must include serialization time at the configured bitrate and estimated RTT; a fixed subsecond timeout is inappropriate for very slow links.
- Apply exponential backoff, retry budget, and expiry; no infinite alerts.
- Deduplicate before enqueueing playback.
- Preserve normal segment order; alerts can bypass queued normal messages at the next bounded scheduling boundary.
- If a missing segment exceeds timeout, expose a gap and ask for retransmission rather than silently concatenating contradictory text.
- Do not promise exactly-once audible output across a crash between speaker output and persisted completion. Use conservative recovery and an â€œalready may have playedâ€ state.

### 14.8 Alert abuse and privacy

- Only trusted, authorized peers can trigger automatic high-priority announcements.
- Rate-limit per peer and provide local mute/revoke/stop controls.
- Validate age/TTL; monotonic local timers are authoritative within a running session.
- On reboot with uncertain time, do not auto-play old emergency alerts until freshness is resolved or the user approves.
- Encrypt local sensitive records if persistence is enabled; manage keys through Android Keystore where applicable.
- Exclude audio/transcripts from telemetry by default.
- Do not collect phone numbers, contacts, GPS, or accounts unless later explicitly required.

---

## 15. Low-bitrate scheduling and backpressure

### 15.1 Correct bandwidth accounting

Measure separately:

1. Transcript UTF-8 bytes.
2. Encoded application message bytes.
3. Encrypted/framed bytes.
4. Acknowledgment/control/retransmission bytes.
5. Transport/link overhead when observable.
6. Physical link capacity versus delivered application goodput.

A comparison with raw PCM is illustrative, not a fair replacement for comparing against an actual low-bitrate speech codec. If presenting a compression claim, define the baseline, included overhead, language, speaking rate, and message length.

### 15.2 Illustrative serialization math

For a hypothetical **240-byte application record including chosen application overhead**, serialization alone is:

- At 300 bps: `240 Ã— 8 / 300 = 6.4 seconds`.
- At 1,200 bps: `240 Ã— 8 / 1,200 = 1.6 seconds`.
- At 9,600 bps: `240 Ã— 8 / 9,600 = 0.2 seconds`.

These are arithmetic examples, not measured message sizes or physical radio airtime. Actual link headers, scheduling, authentication handshake, loss, acknowledgments, and retries can increase time. Do not promise subsecond end-to-end latency at 300 bps for arbitrary sentences.

### 15.3 Sustainability criterion

```text
required_goodput_bps = total_application_wire_bytes_generated * 8 / elapsed_s

stable_queue requires long_run_arrival_rate < long_run_service_rate
```

For hands-free conversation, test both directions and the link's actual duplex behavior. If text generation plus overhead exceeds capacity, queues grow regardless of how fast ASR is.

### 15.4 Scheduling policy

Priority order:

1. Necessary session/security control and delivery control within a capped budget.
2. Authenticated alerts.
3. Final normal text segments.
4. Optional status updates.
5. Nonessential diagnostics.

- Do not transmit every ASR partial on a constrained link.
- Use bounded small frames so alerts are not trapped behind a large queued frame.
- Do not allow application receipts to overwhelm the very link they acknowledge.
- Apply weighted fairness or a maximum alert burst to prevent permanent starvation.
- Stop accepting a new normal turn or announce queue delay when the outbox exceeds the configured budget.
- Never summarize, remove negation, drop numbers, or silently truncate critical content to save bytes.

### 15.5 Compression and template mode

- Begin with plain compact UTF-8 binary messages.
- Evaluate general compression only after measuring real Indic payloads; short messages often become larger.
- Compress before encryption if using a reviewed message format; do not attempt to compress ciphertext.
- Negotiate the compression method and enforce decompressed size limits.
- A predefined alert template can send an ID plus typed slots only when dictionary hashes match.
- If dictionary versions differ, send full text or fail clearly; never reinterpret the same numeric ID.
- Report template-mode savings separately from arbitrary-speech savings.

---

## 16. Alerts, accessibility, and safety

### 16.1 Practical interpretation of â€œnon-interruptibleâ€

**Implementable app-level guarantee:** Once an authorized alert begins, ordinary app messages cannot replace it or lower its priority. The user retains an emergency stop and the OS retains audio/lifecycle control.

**Not guaranteed on stock Android:** Immunity to calls, system audio focus changes, device mute, DND restrictions, safe-volume limits, Bluetooth routing changes, force-stop, power loss, or hardware volume intervention. Android explicitly manages audio focus and may mute playback for incoming calls. [S6]

Document this discrepancy in the proposal and demonstrate the agreed policy. Do not use hidden APIs, accessibility-service misuse, overlays, or device-management abuse to simulate a guarantee.

### 16.2 Volume policy

- User explicitly arms loud alerts during onboarding/session setup.
- Preview the volume using a safe test prompt before use.
- Use the intended audio usage/routing policy and request legitimate audio focus.
- Raise to the maximum permitted **speaker** alert level only within consent and OS restrictions.
- Do not suddenly maximize headset/earpiece volume; route changes require safe handling and may require renewed consent.
- Restore prior app-managed volume state after alert when feasible.
- If focus or playback is denied, vibrate/show a high-priority notification and report playback failure, not success.
- Avoid claiming that choosing `USAGE_ALARM` inherently bypasses DND or system restrictions.

### 16.3 Priority behavior

- Preempt normal queued playback promptly, with a short safe audio fade if currently playing.
- Do not stack multiple simultaneous voices.
- Resume or requeue interrupted normal content at a known boundary after the alert.
- Repeated alert playback requires bounded policy or explicit user request.
- A trusted peer can be revoked locally even during an alert flood.

### 16.4 Inclusive interaction

- Large PTT and SOS targets with distinct shapes and labels.
- Native-script language names, familiar icons, optional spoken prompts.
- Haptic feedback for recording start/end, delivered, error, and alert.
- Color is never the only status signal.
- Support TalkBack labels, large font scaling, high contrast, and one-handed use.
- Offer replay and â€œplease repeatâ€ without requiring typing.
- Keep text visible for users with hearing loss even though speech is the primary communication path.
- Avoid continuous spoken status that masks incoming speech.

### 16.5 Safety handling

- Mark uncertain content rather than inventing a correction.
- Explicit SOS controls must work independently of ASR success through a generic reviewed alert template.
- Do not automatically classify arbitrary words as a high-volume emergency without user-controlled policy.
- Emergency names, directions, and quantities require separate evaluation.
- State that the prototype is not a certified sole channel for life-critical communication.

---

## 17. Model-pack management and offline provisioning

### 17.1 Pack contents

Each signed pack contains:

- Model file(s), tokenizer/vocabulary, frontend/normalizer data, vocoder if required, approved reference voice if required.
- Manifest with model ID, revision, languages, architecture, runtime requirements, input/output rates, files and SHA-256 hashes.
- License texts, attribution, model card snapshot, provenance, and dataset/reference-voice notes.
- A tiny authorized self-test input/output expectation or invariant test.
- Compatibility version and optional measured device-profile metadata.

**Pack types:**
| Pack Type | Format | Size | Runtime | Languages |
|---|---|---|---|---|
| Gemma 4 E2B ASR | `.litertlm` | 2.58 GB | LiteRT-LM | All 10+ (single pack) |
| ONNX CTC ASR (fallback) | `.onnx` + vocab | 45â€“70 MB each | ONNX Runtime | Per-language (9 Indic) |
| TTS (DhVaani/IndicF5) | ONNX + vocoder | 25â€“60 MB each | ONNX Runtime | Per-language |

### 17.2 Import workflow

1. User chooses a local pack through Storage Access Framework.
2. Check available storage including temporary installation overhead.
3. Stream to a staging directory with file-count and byte caps.
4. Defend against zip-slip, path traversal, symlinks, nested archive bombs, and oversized decompression.
5. Verify manifest signature using an embedded release public key; hashes alone do not establish provenance.
6. Verify every listed file and reject unlisted executable content.
7. Validate runtime/frontend compatibility.
8. Run a local smoke test without networking.
9. Atomically activate the new pack.
10. Retain a bounded last-known-good version for rollback.

### 17.3 Distribution profiles

- **Development profile:** Gemma pack (2.58 GB) + 1â€“2 ONNX CTC fallback packs + TTS packs, debug tooling.
- **Competition bundle:** signed APK + Gemma pack + all ten ONNX CTC fallback packs + all TTS packs + source/license package.
- **Operational profile:** user selects needed installed languages; Gemma pack optional (6 GB+ devices), ONNX CTC packs for all languages.

Clarify whether organizers require all ten languages inside a single APK or merely available entirely offline after installation. Pack modularity reduces active memory, not total all-language storage. Gemma pack is single-file for all languages; ONNX CTC is per-language.

### 17.4 Memory residency

- **Gemma 4 E2B:** ~1.1 GB resident on mobile config; 676 MBâ€“1.7 GB peak measured. Load only on 6 GB+ devices (probed via `platform_info`).
- **ONNX CTC fallback:** ~45â€“70 MB per language. Keep one active ASR + one active TTS when combined PSS fits.
- On receive-only/transmit-only devices, unload the unused task model.
- For bidirectional mode, measure both simultaneously; separate low memory results from one-way measurements.
- Evict least-recently-used inactive packs and release native sessions deterministically.
- Measure language-switch and cold-model latency explicitly.
- Thermal/resource fallback must remain visible and must not silently change language or meaning.
- **Backend selection logic:** `platform_info` probes free RAM + GPU delegate; if â‰¥6 GB and GPU delegate available â†’ Gemma; else â†’ ONNX CTC. No inline `Platform.isIOS` checks.

---

## 18. Data collection, training, and evaluation

### 18.1 Data governance

- Use consented recordings and licenses compatible with training, evaluation, redistribution, and deployment.
- Store provenance per utterance, including dataset version and consent category.
- Never assume all corpora from one organization have identical licenses.
- Public/gated datasets can require human agreement before download; provision legally before offline deployment. [S1, S3, S13]
- Do not include real distress calls, personal addresses, or sensitive identities without appropriate authorization.
- Obtain explicit speaker consent for any reference voice; use a fixed neutral project voice where possible.

### 18.2 Dataset candidates

Investigate AI4Bharat IndicVoices/Kathbath/IndicTTS/Rasa and IISc/ARTPARK Vaani resources for language coverage and task suitability. Exact subsets and licenses must be audited before use. Vaani and its benchmark are useful investigation leads, not automatic drop-in training/evaluation assets. [S13]

Maintain separate manifests for training, validation, quantization calibration, held-out benchmark, and live demo prompts.

### 18.3 Pilot evaluation design

Suggested initial collection target, not a statistical adequacy guarantee:

- At least 10 independent speakers per language, approximately 30 short utterances each.
- Additional noisy/channel variants drawn from a held-out subset.
- Native reviewers for every language, not only bilingual team members for the easiest languages.
- A separate unseen live-speaker set for the final demonstration.
- Include distinct accents, ages, pitch ranges, speaking rates, and device positions where ethically and practically feasible.

The pilot establishes feasibility. Expand before making deployment-grade performance claims.

### 18.4 Split integrity

- Split by speaker and recording session; prevent the same original audio or augmented variant crossing splits.
- Keep near-duplicate prompts and synthesized versions out of test leakage paths.
- Freeze a test manifest before tuning.
- Do not tune endpoint thresholds, vocabulary bias, or quantization on final test results.
- Report synthetic, read speech, spontaneous speech, and live microphone results separately.

### 18.5 ASR scoring

```text
WER = (substitutions + deletions + insertions) / reference_word_count
CER = (character_substitutions + deletions + insertions) / reference_character_count
```

- Publish raw and normalized scores with the exact normalization/tokenization recipe.
- Use script-aware character/grapheme conventions and document them.
- Handle empty reference utterances separately; WER denominator is zero for pure silence.
- Report per-language aggregate and per-speaker variability.
- Use speaker-level confidence intervals/bootstrap when sample size permits.
- Do not choose normalization that hides digit or negation errors.

Additional metrics:

- Critical entity exact match and error categories.
- Negation preservation.
- Numeric sequence correctness.
- False transcript rate during silence/noise.
- Endpoint clipped-word rate.
- Language misrouting and unsupported-character events.

### 18.6 TTS listening study

- Blind/randomize model labels and sample ordering.
- Ask native listeners to transcribe or answer factual questions about heard content.
- Score naturalness/flow on a documented 1â€“5 MOS scale separately from intelligibility.
- Include enough listeners and repeated ratings to quantify variability; a few team opinions are not a robust MOS claim.
- Normalize playback conditions and document route, loudness, noise, and hearing accommodations.
- Evaluate cached and dynamic synthesis separately.

### 18.7 End-to-end meaning preservation

A good standalone WER is not enough. Run:

```text
original speaker utterance -> ASR -> transmitted text -> TTS -> native listener
```

Ask the listener to identify who/what/where, counts, direction, negation, and requested action. Score errors introduced by ASR separately from TTS pronunciation/normalization errors.

### 18.8 Training artifacts

Version training config, seed, source revision, data manifests/hashes, preprocessing, augmentation, checkpoints, export commands, quantization calibration, licenses, and evaluation outputs. A model is reproducible only if these dependencies are recorded.

---

## 19. Performance budgets and measurement

### 19.1 Budget interpretation

All values below are **proposed team targets**, not official SIH thresholds and not measured results. Rebaseline after week-one physical-device experiments. Publish a miss honestly rather than relabeling a larger phone as low-end.

### 19.2 Initial resource targets

| Metric | Proposed starting target | Measurement conditions |
|---|---|---|
| Base release APK excluding packs | <= 100 MB | ARM64 build; report ABI variants separately |
| **Gemma 4 E2B ASR pack** | **2.58 GB disk, ~1.1 GB resident** | **LiteRT-LM, 6 GB+ devices only** |
| Active ONNX CTC ASR pack (fallback) | Aim <= 70 MB | Include vocabulary/frontend; per-language |
| Active TTS pack | Aim <= 100 MB | Include vocoder/reference assets; larger needs review |
| Combined steady PSS (Gemma path) | Aim <= 1.5 GB | Active bidirectional session, 6 GB+ phone |
| Combined steady PSS (ONNX CTC path) | Aim <= 500 MB | Active bidirectional session, low-end phone |
| Peak PSS (Gemma) | Aim <= 2.0 GB | Model load + concurrent inference stress |
| Peak PSS (ONNX CTC) | Aim <= 700 MB | Model load + concurrent inference stress |
| Idle VAD/listening CPU | Aim <= 5% of one core equivalent | Connected session, screen off, declared CPU metric |
| Silence ASR invocation | Zero routine ASR calls | Except explicitly measured false triggers |
| **Gemma: Time-to-first-token (TTFT)** | **<= 500 ms p95 (GPU), <= 1200 ms p95 (CPU)** | **Warm, 2â€“4 s utterance, flagship / mid-range** |
| **Gemma: Decode throughput** | **>= 20 tokens/s (GPU), >= 8 tokens/s (CPU)** | **Warm, sustained decode** |
| **ONNX CTC: Warm ASR RTF** | **<= 0.7 desirable; <1 required** | **Actual language/device/concurrency** |
| TTS total synthesis RTF | <= 0.7 desirable; <1 for uninterrupted dynamic output | Actual output duration and device |
| Warm receive-to-first-audio | p95 <= 700 ms | No queue, normal local link, uncached synthesis |
| Endpoint silence delay | Default 450 ms | Report separately from compute |
| Speech-end to first remote audio | p95 <= 2 s stretch target | Warm, short utterance, healthy local link, no congestion |

A combined PSS target includes native runtime, activations, UI, audio, database, and both speech tasks. Separate pack targets are not a guarantee that all-language deployment fits or reaches these budgets. **Gemma path requires 6 GB+ RAM; ONNX CTC path is fallback for <6 GB devices.**

### 19.3 Latency definitions

Capture local monotonic timestamps:

```text
A0 = first acoustic speech sample
A1 = last acoustic speech sample
A2 = endpoint decision
A3 = ASR final result ready (Gemma: TTFT + decode time; CTC: full forward pass)
A4 = message committed to outbox
A5 = first application byte handed to transport
B0 = complete authenticated message available
B1 = TTS scheduled
B2 = first PCM chunk ready
B3 = first sample submitted to output
B4 = first audible output / calibrated audio presentation event
B5 = playback completed
```

Metrics:

- Endpoint delay: `A2 - A1`.
- **Gemma STT finalization: `A3 - A1` = TTFT + token decode time** (no partial hypotheses).
- **ONNX CTC STT finalization: `A3 - A1` = full forward pass time**.
- STT processing RTF (CTC only): model compute wall time / processed input audio duration; disclose repeated-window work.
- **Gemma metrics: TTFT (ms), tokens/s** â€” replaces RTF for autoregressive models.
- Receive-to-PCM: `B2 - B0`.
- Receive-to-audible: `B4 - B0`.
- TTS synthesis RTF: synthesis wall time / generated audio duration.
- End-to-end post-speech lag: `B4 - A1`.
- First-speech to remote-first-audio: `B4 - A0`.
- Queue delay: time waiting before transmission and before synthesis/playback.

`AudioTrack.write()` is not proof that audio has reached the speaker. Use playback timestamps/calibration or external recording where possible.

### 19.4 Cross-device clock handling

Do not subtract raw monotonic timestamps from different phones. They have unrelated clock origins.

Use either:

1. A shared external recording setup capturing source speech and receiver output in one timebase; or
2. Repeated two-way clock-offset estimation, recording RTT/uncertainty and treating asymmetric delays explicitly.

Report timestamp uncertainty. Do not claim millisecond-accurate inter-phone latency from unsynchronized clocks.

### 19.5 Benchmark procedure

1. Record phone model, SoC, RAM, Android version, app/model/runtime revisions, battery level, temperature, and audio route.
2. Use release builds without a debugger for headline performance.
3. Measure cold startup/model load separately.
4. Warm up a declared number of runs.
5. Run identical held-out samples at least enough times to capture variability.
6. Report sample count, failures, p50, p95, and maximum where meaningful.
7. Test isolated ASR, isolated TTS, and concurrent bidirectional workloads.
8. Repeat after sustained operation to reveal thermal throttling.
9. Record idle, capture, inference, transmit, receive, playback, and disconnected power states.
10. Preserve raw JSONL/CSV exports and scripts with benchmark IDs.

### 19.6 Battery and CPU

- Report CPU metric convention: one fully occupied core = 100% if using that normalization.
- Measure screen-off and screen-on separately.
- Compare idle app, active session silence, noisy VAD listening, PTT duty cycle, and continuous exchange.
- Use battery statistics/external power measurement if available; short battery-percentage changes are too coarse for strong claims.
- Avoid promising exact battery life before testing actual devices and radio duty cycles.
- Watch model loading spikes, Wi-Fi discovery loops, wake locks, and simultaneous ASR/TTS thread pools.

### 19.7 Official scoring alignment

- **Accuracy 40%:** prioritize per-language recognition, meaningful content, pronunciation, and flow.
- **Efficiency 20%:** expose total installed storage and true RAM/CPU, not just model file size.
- **Latency 20%:** show cold/warm and low-link-rate measurements, not only cached English speech on Wi-Fi.
- **Unspecified 20%:** request clarification; track robustness, usability, security, and completeness internally without claiming official weights.

---

## 20. UI and interaction specification

### 20.1 Screens

**Onboarding**

- Explain local-only operation and limits.
- Select UI and speaking language independently.
- Import/check models.
- Request microphone and nearby-device permissions only when needed.
- Optional loud-alert consent and test.

**Home / session setup**

- Start nearby session, join session, import language pack.
- Show actual language pack readiness.
- Choose PTT or hands-free; explain full/half-duplex capability.

**Pairing**

- Nearby peers, transport choice, verification code/QR.
- Clear identity verification step before trust.
- Language-capability mismatch surfaced before conversation.

**Conversation**

- Dominant PTT button or hands-free toggle.
- Listening/processing/queued/received/played states.
- Local partial transcript visually distinguished from final text.
- Peer, language, route, battery/thermal warning, and link backlog.
- Replay, repeat request, and accessible stop.

**Alert**

- Deliberate alert action with appropriate anti-accidental trigger.
- Generic SOS template independent of successful speech recognition.
- Speak custom content, send, cancel, and acknowledgment state.

**Language packs**

- Installed languages, versions, disk size, compatible engines.
- Offline import, validate, activate, rollback, delete inactive pack.
- Missing/failed pack explains the reason, not a generic crash.

**Diagnostics**

- User-opt-in benchmark panel with stage latency, queue depth, bytes, RTF, model IDs.
- Export logs locally; no automatic upload.

### 20.2 Interaction rules

- No apparent â€œsentâ€ success before the packet is actually queued/sent; use precise labels.
- No â€œheardâ€ claim from playback-completed receipt.
- Status earcons must be short, recognizable, and user-adjustable.
- Do not make an alert or recording button dependent on small text links.
- Keep native-script font rendering legible at large accessibility sizes.
- A permission denial offers a useful degraded screen, not repeated permission harassment.

---

## 21. Repository, interfaces, and persistence

### 21.1 Proposed repository tree

```text
itantra/
  README.md
  implementation_plan.md
  LICENSE
  NOTICE
  android/
    app/
    core/audio/
    core/asr/
    core/tts/
    core/protocol/
    core/transport/
    core/security/
    core/models/
    core/storage/
    core/metrics/
    feature/onboarding/
    feature/pairing/
    feature/conversation/
    feature/alerts/
    feature/diagnostics/
    native/
  ml/
    configs/
    data_manifests/
    preprocessing/
    training/
    export/
    quantization/
    evaluation/
    golden_tests/
  protocol/
    specification.md
    schemas/
    vectors/
    reference_codec/
  firmware/
    bridge/
    board_profiles/
    tests/
  tools/
    link_emulator/
    benchmark_runner/
    pack_builder/
    license_audit/
  tests/
    audio_fixtures/
    multilingual_text/
    fault_injection/
    e2e/
  docs/
    architecture/
    adr/
    device_matrix.md
    language_coverage.md
    privacy.md
    threat_model.md
    offline_installation.md
    demo_runbook.md
    model_cards/
  reports/
    benchmark_manifests/
    raw/
    summaries/
  release/
    manifests/
    checksums/
```

### 21.2 Kotlin interface sketches

These sketches define intended boundaries, not compile-ready code or claims about any library API.

```kotlin
interface AsrEngine : AutoCloseable {
    suspend fun load(pack: ValidatedModelPack)
    fun recognize(input: Flow<AudioFrame>, request: AsrRequest): Flow<AsrEvent>
    suspend fun cancel(utteranceId: String)
}

interface TtsEngine : AutoCloseable {
    suspend fun load(pack: ValidatedModelPack)
    fun synthesize(request: SynthesisRequest): Flow<PcmChunk>
}

interface TransportAdapter : AutoCloseable {
    val state: StateFlow<LinkState>
    val incoming: Flow<TransportBytes>
    suspend fun connect(peer: PeerEndpoint)
    suspend fun send(bytes: ByteArray)
    suspend fun disconnect()
}

interface MessageRepository {
    suspend fun enqueueOutgoing(message: FinalMessage)
    suspend fun acceptIncomingIfNew(message: AuthenticatedMessage): AcceptResult
    suspend fun updateDelivery(id: String, state: DeliveryState)
}

interface ModelPackManager {
    suspend fun importAndValidate(source: PackSource): PackValidationResult
    suspend fun activate(packId: String)
    suspend fun rollback(language: String, task: ModelTask)
}
```

### 21.3 Persistence schema

**Peer**

- Verified identity/public-key reference, display name, trust status, alert authorization, last connection, revoked flag.

**Message**

- Message ID, peer ID, direction, language, priority, content/template slots, creation metadata, expiry, utterance ID, segment index, status, error code, model revisions.

**DeliveryEvent**

- Message ID, event type, local monotonic/wall metadata, session reference, diagnostic reason.

**ModelPack**

- Pack ID/revision, task, languages, verified signature/hash, bytes, active status, frontend/runtime compatibility.

**BenchmarkRun**

- Run ID, device/model/protocol revisions, profile/config hash, raw artifact path, consent flags.

### 21.4 Transaction rules

- Outgoing message durable insert precedes transmission retry responsibility.
- Incoming insert and deduplication are one transaction with a unique peer/message constraint.
- Receipt state changes cannot move backward except through explicit recovery states.
- Deleting conversation history must not leave sensitive cached audio behind.
- Diagnostic export omits message text unless the user explicitly opts in.

### 21.5 Error taxonomy

`PERMISSION_DENIED`, `MIC_UNAVAILABLE`, `AUDIO_ROUTE_LOST`, `MODEL_MISSING`, `MODEL_CORRUPT`, `MODEL_INCOMPATIBLE`, `UNSUPPORTED_LANGUAGE`, `UNSUPPORTED_TEXT`, `ASR_FAILED`, `TTS_FAILED`, `OUT_OF_MEMORY`, `LINK_LOST`, `QUEUE_FULL`, `AUTH_FAILED`, `PEER_UNTRUSTED`, `PROTOCOL_MISMATCH`, `MESSAGE_EXPIRED`, `PLAYBACK_FOCUS_DENIED`, `PLAYBACK_INTERRUPTED`, `STORAGE_FULL`.

Each error needs: user-facing message, audible/haptic equivalent, retriable/non-retriable classification, privacy-safe log fields, and cleanup action.

---

## 22. Implementation work packages

## 22. Implementation work packages

### WP0 â€” Requirements, device, and license baseline

**Tasks**

- Convert the statement into R01â€“R19 traceability (R19 = cross-language walkie-talkie).
- Send organizer questions from section 29.
- Obtain two low-end (<6 GB), two mid-range (4â€“6 GB), and two high-end (6 GB+) test phones where possible.
- Pin SDK/NDK/toolchain and create release-build CI.
- Create model/source ledger and license policy (Gemma 4 Apache-2.0, DhVaani Apache-2.0, eSpeak NG GPL-3.0 build-time).
- Define baseline benchmark harness and held-out pilot manifests.

**Deliverables:** architecture ADR, device matrix, coverage ledger, compliance checklist.

**Exit gate:** team can build/install a signed local test APK and identify the exact hardest feasibility risks.

### WP1 â€” Gemma 4 E2B validation (Phase 0: 1â€“2 days, zero cost)

**Tasks**

- Install Google AI Edge Gallery from Play Store; open Audio Scribe.
- Transcribe/translate recorded clips in all 10 target languages (hi, gu, mr, kn, ml, ta, te, or, bn, en-IN), especially noisy and code-switched speech.
- Deliverable: go/no-go table of per-language quality (WER, translation accuracy, code-switch handling).
- **Do not skip** â€” audio-language coverage is narrower than 140-language text claim.

**Exit gate:** Gemma 4 E2B passes quality threshold for â‰¥8/10 languages; otherwise fall back to ONNX CTC as primary.

### WP2 â€” Desktop evaluation harness (Phase 1: 3â€“5 days)

**Tasks**

- Use LiteRT-LM CLI/Python API with `litert-community/gemma-4-E2B-it-litert-lm`.
- Run existing captured audio through Gemma; compute WER per language vs IndicConformer baseline.
- Score translation for cross-language pairs (hiâ†”en, bnâ†”hi, etc.).
- Evaluate TranslateGemma (55-language lightweight) as fallback if Gemma built-in translation disappoints.

**Deliverables:** WER/translation tables per language; decision on primary vs fallback engine.

**Exit gate:** Gemma WER competitive with IndicConformer on â‰¥8 languages; translation usable for target pairs.

### WP3 â€” Android integration (Phase 2: 1â€“2 weeks)

**Tasks**

- Add `flutter_gemma` dependency (community Flutter binding for LiteRT-LM).
- Implement `GemmaAsrEngine` beside `OnnxCtcAsrEngine` behind same `AsrEngine` interface.
- Reuse `AudioCapturePlugin` frames â€” audio segment in, JSON `{text, src_lang, translated_text?, tgt_lang?}` out.
- Backend selection in `platform_info` capability probe (free RAM / GPU delegate).
- iOS: `flutter_gemma` covers iOS; LiteRT-LM Swift API is early preview; Dart call sites stay shared.

**Deliverable:** Gemma engine integrated, selectable at runtime based on device capability.

**Exit gate:** Gemma runs on 6 GB+ device; ONNX CTC fallback runs on <6 GB device; both behind same interface.

### WP4 â€” Wire format for cross-language (Phase 3: 2â€“3 days)

**Tasks**

- Extend protocol messages with `src_lang`, `tgt_lang`, optional `translated_text` field.
- Sender translates, sends both strings (~100â€“200 bytes â†’ ~400 bytes, within Bluetooth budget).
- Receiver uses `tgt_lang` to select TTS voice.
- Update `CapabilitiesMessage` to advertise translation support.

**Deliverable:** Cross-language walkie-talkie mode functional.

**Exit gate:** Cross-language loop works end-to-end; same-language mode unchanged.

### WP5 â€” Audio and local loop (formerly WP2)

**Tasks**

- Implement capture ring, resampler, VAD, segment state machine.
- Integrate ASR contract (both Gemma + ONNX CTC) and immutable final events.
- Integrate TTS and AudioTrack with error handling.
- Build local loopback diagnostic using recorded fixtures and live capture.
- Add metrics events and cancellation cleanup tests.

**Deliverable:** one phone captures arbitrary speech and regenerates it locally, fully offline.

**Exit gate:** bounded memory, no UI thread blocking, and no silence hallucination spam.

### WP6 â€” Framed phone-to-phone communication (formerly WP3)

**Tasks**

- Implement mock/loopback transport first.
- Add local Wi-Fi TCP and Bluetooth RFCOMM.
- Add versioned framing, schema validation, IDs, durable outbox/inbox, and receipts.
- Add reviewed authentication/key exchange and pairing.
- Create packet-size, malformed-input, deduplication, and reconnect tests.

**Deliverable:** authenticated arbitrary text exchange with accurate receipt states.

**Exit gate:** no duplicate normal playback during bounded retries and reconnect tests.

### WP7 â€” Two-phone speech walkie-talkie (formerly WP4)

**Tasks**

- Connect ASR final events (both engines) to outbox and received messages to TTS.
- Implement PTT floor controller, release finalization, earcons, and replay.
- Test both directions and swap transmit/receive roles.
- Add endpoint, transport, TTS, and audible latency instrumentation.

**Deliverable:** English/Hindi offline walkie-talkie on both transport paths.

**Exit gate:** repeated unseen live speech, not a fixed demo phrase, traverses the full path.

### WP8 â€” Language coverage and optimization (formerly WP5)

**Tasks**

- Complete each language ledger row through license, export, device, and native-QA gates.
- Optimize quantization/threads/model residency for both Gemma and ONNX CTC.
- Build deterministic text frontends and critical-entity tests.
- Train/fine-tune compact replacements only when necessary and resourced (Lane C).
- Package all validated assets for offline installation.

**Deliverable:** ten-language release candidate or explicit documented blockers.

**Exit gate:** every language passes both arbitrary STT (Gemma or ONNX CTC) and TTS on required device profile.

### WP9 â€” Hands-free and Android hardening (formerly WP6)

**Tasks**

- Add continuous VAD session, dual queues, headset simultaneous operation.
- Test AEC/speakerphone double-talk and loopback protection.
- Implement foreground-service lifecycle and permission flows.
- Handle route/focus/thermal/resource changes.
- Document automatic half-duplex fallback if needed.

**Deliverable:** sustained hands-free exchange with truthful capability labels.

**Exit gate:** no self-amplifying speech loop, silent data loss, or undocumented background recording.

### WP10 â€” Alert and constrained-link robustness (formerly WP7)

**Tasks**

- Add explicit alert arming, trusted-peer authorization, priority queues, and user acknowledgment.
- Implement low-bitrate emulator profiles and queue-based UX.
- Add TTL, replay resistance, bounded retries, and template-version checks.
- Demonstrate platform audio limitations and safe fallback behavior.

**Deliverable:** authenticated high-priority alert flow on constrained links.

**Exit gate:** stale/replayed/untrusted alerts do not auto-announce; normal messages cannot preempt active alerts inside the app.

### WP11 â€” Embedded relay (formerly WP8)

**Tasks**

- Select exact board/interfaces and document topology.
- Implement opaque frame relay with bounded buffers and diagnostics.
- Add BLE fragmentation/credits or local Wi-Fi bridge adapter.
- Validate full phone â†’ bridge â†’ link â†’ bridge/peer â†’ phone loop.
- Account for actual radio/link overhead and regulatory constraints if RF is used.

**Deliverable:** firmware, wiring/setup guide, and measured hardware bridge demo.

**Exit gate:** bridge is demonstrably forwarding real live generated text, not preloaded canned messages.

### WP12 â€” Evaluation and release (formerly WP9)

**Tasks**

- Freeze app/model/protocol versions.
- Run per-language native-speaker benchmark and TTS listening study.
- Run sustained low-end, noisy, low-bitrate, lifecycle, security, and offline tests.
- Build source bundle, licenses, signed APK, packs, checksums, install guide, and demo runbook.
- Rehearse complete offline reinstall and demonstration.
- **Honest metrics update:** Replace "ASR RTF" with TTFT + tokens/s in diagnostics screen; re-run send â‰¤900 ms / phone-to-phone â‰¤1500 ms targets per device tier; declare misses in `requirements_traceability.md`.

**Deliverable:** reproducible final submission with measured results and known limitations.

**Exit gate:** definition of done in section 29 passes; any exception is explicitly disclosed.

---

## 23. Timeline, ownership, and critical path

### 23.1 Suggested six-person ownership

- **A â€” Android/audio lead:** capture, lifecycle, foreground service, playback, routing.
- **B â€” ASR lead:** models, export, quantization, recognition evaluation.
- **C â€” TTS/language lead:** synthesis, frontend, native reviewer coordination, voice licensing.
- **D â€” Transport/security lead:** protocol, pairing, Bluetooth/Wi-Fi, retries.
- **E â€” Embedded/performance lead:** bridge firmware, link emulator, profiling.
- **F â€” QA/product/release lead:** UI integration, test automation, traceability, offline release/demo.

Cross-review: security changes reviewed by D and A; language normalization by C plus native reviewer; model claims by B/C and F; benchmark claims by E and F.

### 23.2 Twelve-week baseline

| Week | Main outcome | Dependencies / gate |
|---|---|---|
| 1 | Device/license baseline; **Gemma Phase 0 validation** (Audio Scribe test all 10 languages); Hindi/English/Odia feasibility | **Gemma go/no-go table**; no model decision without physical device evidence |
| 2 | **Gemma Phase 1 desktop evaluation** (WER vs IndicConformer); Local audio/VAD/ASR/TTS loop; initial native export | **Gemma WER competitive on â‰¥8 langs**; fail/replan if low-end runtime route blocked |
| 3 | **Gemma Phase 2 Android integration** (`flutter_gemma`, `GemmaAsrEngine`); Framed authenticated text over Wi-Fi and Bluetooth | Protocol skeleton and identity verification |
| 4 | **Gemma Phase 3 wire format** (cross-language `src_lang`/`tgt_lang`); Two-phone PTT speech loop; first complete measurements | Unseen arbitrary speech in both directions; same-language + cross-language |
| 5 | Additional language packs (ONNX CTC fallback); frontend regression suite | Language-specific native review |
| 6 | Ten-language feasibility gate; optimize largest blockers (both Gemma + ONNX CTC) | Stop feature expansion if coverage unresolved |
| 7 | Hands-free headset mode; service/lifecycle hardening | Combined ASR/TTS memory and echo tests |
| 8 | Speakerphone/AEC tests; alert and low-bitrate robustness | Explicit full/half-duplex capability decision |
| 9 | Embedded bridge end-to-end; pack installer | Hardware availability and protocol freeze |
| 10 | Frozen evaluation set; broad native-language assessment | No last-minute test-set tuning |
| 11 | Thermal/battery/security/fault-injection release fixes | Re-run affected accuracy and latency tests |
| 12 | Offline installation rehearsal and final submission; **Honest metrics update** (TTFT + tokens/s) | Definition of done / disclosed exceptions |

This schedule assumes access to viable pretrained/exportable assets (Gemma 4 E2B available). Training a missing ten-language model suite can exceed twelve weeks; raise that risk immediately rather than hiding it inside "integration."

### 23.3 Critical path

```text
Gemma Phase 0 validation -> Phase 1 desktop eval -> Phase 2 Android integration
-> Phase 3 cross-language wire -> native accuracy/intelligibility
-> complete two-phone loop (both langs) -> sustained tests
-> frozen evaluation -> offline release bundle
```

UI polish, diagrams, optional translation, and elaborate RF hardware must not displace this path.

### 23.4 First 72 hours

**Day 1:** build/install Android shell; acquire actual phones (include 6 GB+); install Google AI Edge Gallery; run Audio Scribe on all 10 languages; audit licenses (Gemma Apache-2.0); start Odia validation.

**Day 2:** Gemma desktop inference spike (LiteRT-LM CLI); record model bytes/PSS/TTFT/tokens/s; implement frame capture/VAD; exchange arbitrary text over one transport.

**Day 3:** connect one-language speech loop (Gemma on 6 GB+ device); test no-WAN operation; log end-to-end stages (TTFT, tokens/s, send/recv/delta); publish pass/fail evidence and next decisions.

### 23.5 Short hackathon sprint fallback

If only 36â€“48 hours remain, and **only if models and licenses are already validated**:

1. Freeze candidate pack versions (Gemma + ONNX CTC fallback); avoid training a new model.
2. Integrate one transport and PTT first.
3. Demonstrate an arbitrary-speech two-phone loop.
4. Add receipt states, offline evidence, and failure handling.
5. Add existing validated language packs without changing runtime.
6. Demonstrate alerts within platform limits and a deterministic rate-limited link.
7. Document unsupported requirements rather than using cloud or stock proprietary speech engines.

A two-language sprint demo is not equivalent to the requested ten-language deliverable.

---

## 24. Test strategy and acceptance scenarios

### 24.1 Test layers

**Unit:** normalization, endpoint state machine, IDs, schema, TTL, priority, retry logic, deduplication, pack validation, storage transactions.

**Native golden tests:** model frontend parity, logits/text/audio invariants, quantization regression, unsupported operators, deterministic configuration where supported.

**Instrumented Android:** permissions, service lifecycle, capture/playback, model loading, route/focus changes, UI accessibility, process recovery.

**Integration:** both real phones, each transport, embedded bridge, all language packs.

**Fault injection:** disconnects, corrupted packets, duplicate/reordered fragments, low storage, model corruption, OOM pressure, slow inference, audio underrun, queue saturation.

**Human evaluation:** native recognition review, TTS comprehension/flow, inclusive usability and emergency comprehension.

### 24.2 Device and network matrix

Minimum proposed physical-device coverage:

- One genuinely low-end ARM64 phone plus a second low-end vendor when available.
- Two mid-range devices with different OEM audio/Bluetooth behavior.
- Oldest supported Android release and recent releases, including modern foreground-service restrictions.
- Speaker, wired headset where supported, and Bluetooth audio route.
- Bluetooth Classic, local Wi-Fi, Wi-Fi Direct where available, and embedded BLE/Wi-Fi path.

Do not substitute emulator performance for CPU, microphone, radio, or battery measurements.

### 24.3 Link profiles

- Unthrottled local Wi-Fi baseline.
- Bluetooth baseline at measured application goodput.
- Emulated 9,600 bps, 1,200 bps, and 300 bps profiles.
- Added RTT/jitter and burst-loss profiles chosen for the actual target link.
- Disconnection mid-message and after durable receipt but before playback receipt.
- Congestion with a pending normal message followed by an alert.

Specify whether each profile rate is one-way, shared half-duplex, or per-direction, and whether headers are charged against capacity.

### 24.4 Acceptance scenario catalog

| Test ID | Scenario | Expected result |
|---|---|---|
| AT01 | Fresh offline install with supplied APK/packs | No first-use cloud dependency; valid model activation |
| AT02 | Each of ten languages, unseen arbitrary speech | Receiver speaks same-language content; scores recorded |
| **AT02b** | **Cross-language: each of 10 srcÃ¢â€ â€™tgt pairs** | **Receiver speaks translated content in tgt_lang; scores recorded** |
| AT03 | Quiet speech plus pause and PTT release | No clipped start/end; finalization is bounded |
| AT04 | Long utterance past soft/hard cap | Ordered segments, no silent overflow |
| AT05 | Silence/fan noise for sustained period | No repeated hallucinated messages; idle CPU measured |
| AT06 | Language absent on receiver | Explicit error/status; no wrong-language automatic playback |
| AT07 | Bluetooth/Wi-Fi reconnect after send | Durable deduplication; truthful receipt states |
| AT08 | Duplicate normal frame | Single normal enqueue/playback within stable process |
| AT09 | Crash during playback | Ambiguous recovery state; no false exactly-once claim |
| AT10 | Corrupt/truncated/oversized frame | Safe rejection; bounded memory; no crash |
| AT11 | Untrusted or replayed alert | Rejected/rate-limited; no forced announcement |
| AT12 | Alert arrives during normal playback | App-level preemption and visible acknowledgment path |
| AT13 | Call/focus loss during alert | Safe OS-compliant response and interrupted status |
| AT14 | Headset unplug during loud alert | No unsafe route-volume jump |
| AT15 | Hands-free speaker echo | No retransmission feedback loop; downgrade shown if needed |
| AT16 | Simultaneous local/remote speech | Bounded handling and documented double-talk behavior |
| AT17 | 300 bps large ordinary message | Honest queue delay; bounded backlog; no impossible latency claim |
| AT18 | Critical number/negation/name | Native end-to-end comprehension checked |
| AT19 | Missing/corrupt/incompatible model | Safe failure or validated rollback, no cloud fallback |
| AT20 | Full storage during receipt | No durable-receipt success before persistence |
| AT21 | Screen off/background session | Behavior matches permitted foreground-service lifecycle |
| AT22 | User stops/force-stops/revokes mic | Recording stops; no hidden restart |
| AT23 | Sustained low-end bidirectional workload | No OOM/ANR; thermal degradation and RTF recorded |
| AT24 | Template dictionary mismatch | Full text fallback or explicit failure, never wrong phrase |
| AT25 | WAN disabled, local radios enabled | Entire speech loop works with no hosted API |
| AT26 | Embedded relay with live speech | Real text frames and hardware link metrics recorded |
| **AT27** | **Gemma 4 E2B on 6 GB+ device: TTFT + tokens/s** | **p95 TTFT Ã¢â€°Â¤ 500 ms (GPU) / Ã¢â€°Â¤ 1200 ms (CPU); Ã¢â€°Â¥ 20 tok/s (GPU) / Ã¢â€°Â¥ 8 tok/s (CPU)** |
| **AT28** | **Gemma 4 E2B WER per language** | **WER competitive with IndicConformer baseline on Ã¢â€°Â¥8/10 languages** |
| **AT29** | **Gemma 4 E2B translation quality** | **Translation accuracy acceptable for target pairs (hiÃ¢â€ â€en, bnÃ¢â€ â€hi, etc.)** |
| **AT30** | **Backend selection: <6 GB device uses ONNX CTC** | **Automatic fallback to ONNX CTC; no OOM; latency within budget** |
| **AT31** | **Gemma 4 E2B code-switch handling** | **HindiÃ¢â‚¬â€œEnglish code-switch: Devanagari stays Devanagari mid-utterance** |

### 24.5 Security tests

Malformed CBOR, deeply nested structures, oversized length prefixes, UTF-8 corruption, invalid language tags, duplicate IDs, sequence rollback, stale sessions, unauthorized alert priority, nonce/counter restart handling, MITM pairing mismatch, model signature failure, archive traversal, compression bombs, log privacy, and peer revocation.

### 24.6 Regression policy

Every model/frontend/runtime/quantization change reruns relevant language accuracy and TTS tests. Every protocol change reruns vectors/fuzz/reconnect tests. Every audio-path change reruns endpoint, echo, route, and latency tests. â€œOnly a dependency updateâ€ is not exempt.

---

## 25. Risk register and decision gates

| Risk | Severity | Early signal | Mitigation / fallback |
|---|---|---|---|
| No lightweight ten-language ASR route | Critical | Large PSS or poor native accuracy in week 1 | Smaller exact checkpoints/student work; disclose blocker |
| Odia overlooked | Critical | Standard Whisper chosen as universal model | Explicit Odia lane and native reviewer immediately |
| No compliant quality TTS voice | Critical | Missing voice/license/frontend | Audit alternative/train compact voice; fallback is not compliance |
| Quantized export unsupported/slow | High | Missing operators or slower CPU path | Keep reference; choose compatible runtime/model |
| Large multilingual TTS not mobile-ready | High | Long first-audio delay or OOM | Compact per-language route; benchmark fixed-reference export |
| Global non-interruptible audio impossible | High | OS focus/call/DND constraints | Organizer clarification; app-level guarantee only |
| Low-rate link cannot sustain conversation | High | Increasing queue age | Turn limits, compact final text, explicit delay, templates |
| ASR changes emergency meaning | Critical | Number/negation errors | Critical-entity evaluation, repeat/confirm cues, manual SOS |
| Echo creates speech feedback loop | High | Remote text repeatedly returns | AEC/headset, clear half-duplex fallback |
| App killed in background | High | OEM battery/FGS restrictions | User-started service, lifecycle tests, no survival claim |
| Copyleft/noncommercial license conflict | High | Missing license provenance | Release gate and compatible distribution/legal review |
| Gated model unavailable during demo | High | First-run download/token dependency | Pre-provision authorized signed offline packs |
| Duplicate/stale alerts | Critical | Lost receipts/restart/replay | Durable IDs, authorization, TTL, conservative recovery |
| Thermal throttling after warm demo | High | RTF rises during sustained use | Sustained benchmarks, concurrency governor |
| Native reviewer shortage | High | Only team guesses quality | Recruit reviewers early, reduce unsupported claims |
| Hardware bridge delay | Medium | Missing board/unclear radio | Phone loop first, simulator, exact board procurement |
| Metric gaming/unrepresentative results | High | Only cached English/headline averages | Per-language raw evidence, cold/warm separation |

### Go/no-go checkpoints

- **G0, end week 1:** exact model access/license and difficult-language feasibility understood.
- **G1, end week 2:** native low-end speech pipeline works without hidden server/runtime dependency.
- **G2, end week 4:** complete arbitrary two-phone PTT loop works on real hardware.
- **G3, end week 6:** all ten languages have measured viable STT and TTS routes; otherwise full release is blocked.
- **G4, end week 9:** hands-free/alerts/bridge/protocol behavior frozen with truthful limitations.
- **G5, release:** independent offline install and documented acceptance evidence complete.

---

## 26. Release, deployment, and demonstration

### 26.1 Release bundle

- Signed release APK(s) for documented ABIs.
- All ten validated offline model packs or an organizer-approved all-in-one package.
- SHA-256 checksums, signed pack manifest, version manifest.
- App source, firmware source, build instructions, lockfiles, model export/quantization recipes.
- SBOM, licenses, notices, model cards, reference-voice permissions.
- Offline installation/setup guide and troubleshooting.
- Protocol specification and golden vectors.
- Benchmark report with raw data, device matrix, methodology, and limitations.
- Demo runbook, safety note, and requirements traceability.

### 26.2 Offline provisioning rehearsal

1. Factory-clean or uninstall/reset app data on a test phone.
2. Disable mobile data and WAN access.
3. Install APK from local file.
4. Import model packs from local storage/USB/local transfer.
5. Validate packs without contacting model hosts.
6. Pair phones locally and verify identity.
7. Start arbitrary speech exchange in every language.
8. Repeat after reboot and with a different speaker.

Model access agreements and developer dependency acquisition are completed beforehand. Do not claim a fully reproducible offline build unless the required build dependencies are also actually included/cached and tested.

### 26.3 Suggested live demonstration

**Step 1 â€” Offline proof:** show WAN disabled, local radio enabled, model inventory, and no cloud speech engine.

**Step 2 â€” Core loop:** evaluator speaks an unseen sentence into phone A; phone B speaks it. Swap roles.

**Step 3 â€” Language proof:** demonstrate all ten using a concise planned rotation, including Odia and native-script text; keep full evidence available if live time is limited.

**Step 4 â€” Transport proof:** show Bluetooth and Wi-Fi runs; show live bridge path if implemented.

**Step 5 â€” Low-bitrate proof:** apply declared rate profile and show bytes, queue delay, and latency honestly.

**Step 6 â€” Hands-free:** disable PTT, exchange speech automatically, and state headset/speakerphone/full- or half-duplex conditions.

**Step 7 â€” Alert:** trusted peer sends an alert while normal message is queued/playing. Show preemption, consented volume, receipt, and acknowledgment.

**Step 8 â€” Robustness:** disconnect/reconnect and replay duplicate input without duplicate normal announcements.

**Step 9 â€” Metrics:** show per-language/device WER, human intelligibility, model/storage/RAM/CPU, RTF, and stage latency with sources to raw logs.

### 26.4 Honest claims template

> â€œOn [exact device], with [model/runtime revision], [language], [audio route], and [link profile], our held-out test produced [measured result] across [sample count]. All inference ran locally. [Known limitation] remains.â€

Never replace missing measurements with claimed â€œnear-zero latency,â€ â€œ100% accuracy,â€ â€œall devices,â€ â€œguaranteed emergency delivery,â€ or â€œuninterruptible under all conditions.â€

---

## 27. Initial engineering backlog

Effort sizes are relative estimates, not guaranteed durations: S = small isolated task, M = multi-component task, L = substantial integration, XL = research/uncertain.

| ID | Priority | Task | Owner | Size | Depends on | Acceptance |
|---|---|---|---|---|---|---|
| IT-001 | P0 | Device and SDK baseline | A/F | S | â€” | Physical device matrix committed |
| IT-002 | P0 | Model/license coverage ledger | B/C | M | â€” | Ten rows with exact candidate provenance |
| IT-003 | P0 | Odia ASR native feasibility | B | XL | IT-001/002 | Actual phone output, memory, timing |
| IT-004 | P0 | Hindi/English ASR baseline | B | L | IT-001/002 | Unseen audio transcribed offline |
| IT-005 | P0 | Compact TTS/DhVaani export spike | C | XL | IT-001/002 | Native arbitrary synthesis and metrics |
| IT-006 | P0 | Capture ring + resampling | A | M | IT-001 | Golden sample/duration tests pass |
| IT-007 | P0 | VAD and endpoint controller | A | M | IT-006 | Pause/release/clipping tests pass |
| IT-008 | P0 | Local metrics schema/collector | E/F | M | IT-001 | Stage timings exported locally |
| IT-009 | P0 | Protocol framing/schema vectors | D | M | â€” | Round-trip and malformed tests pass |
| IT-010 | P0 | Local TCP adapter | D | M | IT-009 | Arbitrary framed text both directions |
| IT-011 | P0 | Bluetooth RFCOMM adapter | D | M | IT-009 | Pair/connect/reconnect on real phones |
| IT-012 | P0 | Pairing/security library spike | D/A | L | IT-009 | Verified identity + protected records |
| IT-013 | P0 | Durable outbox/inbox and receipts | F/D | M | IT-009 | Transaction/dedup tests pass |
| IT-014 | P0 | TTS AudioTrack playback | A/C | M | IT-005 | First-audio and completion measured |
| IT-015 | P0 | Two-phone PTT integration | A/D/F | L | IT-004/007/010/012/013/014 | Unseen full-loop demonstration |
| IT-016 | P0 | Offline pack import/validation | F | L | IT-002 | Signed local import/rollback |
| IT-017 | P0 | Ten-language frontends | C | XL | IT-002/005 | Native critical-text tests |
| IT-018 | P0 | Remaining ASR language packs | B | XL | IT-002/004 | Every language measured |
| IT-019 | P0 | Remaining TTS language packs | C | XL | IT-005/017 | Every language listener-tested |
| IT-020 | P1 | Hands-free/session floor control | A/D | L | IT-015 | Automatic turns without overflow |
| IT-021 | P1 | Echo/double-talk validation | A/E | XL | IT-020 | No feedback loop; limits documented |
| IT-022 | P0 | Foreground-service lifecycle | A | L | IT-015 | Modern OS permission/background tests |
| IT-023 | P1 | Authenticated alert controller | D/A/F | L | IT-012/013/014 | Priority, expiry, consent, acknowledgment |
| IT-024 | P0 | Low-bitrate emulator/scheduler | E/D | L | IT-009/013 | Byte-charged reproducible profiles |
| IT-025 | P1 | Wi-Fi Direct discovery | D | M | IT-010 | No-WAN P2P pairing on device matrix |
| IT-026 | P1 | BLE/embedded bridge | E/D | L | IT-009/024 | Live generated text relayed |
| IT-027 | P0 | Held-out multilingual benchmark | F/B/C | XL | IT-003/017/018/019 | Per-language raw evidence |
| IT-028 | P0 | Sustained resource profiling | E | L | IT-015/020 | PSS/CPU/thermal/RTF report |
| IT-029 | P0 | Security/fault regression | D/F | L | IT-012/013/016/023 | Abuse/corruption/replay tests |
| IT-030 | P0 | Offline release rehearsal | F/all | M | All release gates | Clean no-WAN install/demo |

**Priority interpretation:** P0 blocks a compliant release; P1 still implements a requested or robustness feature but follows the foundational path. No P1 requirement is silently optional in the final submission.

---

## 28. Configuration and example schemas

### 28.1 Runtime profile example

The following YAML is a proposed app configuration shape, not the input schema of any existing framework.

```yaml
profile_version: 1
profile_name: low_end_initial
speech:
  input_language: hi-IN
  model_input_sample_rate_hz: 16000
  capture_processing_frame_ms: 20
  pre_roll_ms: 250
  post_roll_ms: 150
  endpoint_silence_ms: 450
  minimum_speech_ms: 200
  soft_segment_limit_ms: 8000
  hard_segment_limit_ms: 12000
  transmit_partial_hypotheses: false
runtime:
  asr_threads: 2
  tts_threads: 2
  concurrent_inference_policy: measured_budget
  maximum_active_asr_models: 1
  maximum_active_tts_models: 1
transport:
  preferred: bluetooth_rfcomm
  maximum_text_utf8_bytes: 4096
  maximum_logical_message_bytes: 8192
  priority_scheduling: true
  queue_overflow_policy: pause_capture_with_user_warning
  retry_policy: bitrate_and_rtt_aware
security:
  verified_peers_only: true
  authenticated_alerts_only: true
  fresh_keys_on_reconnect: true
  plaintext_logs: false
privacy:
  persist_raw_microphone_audio: false
  diagnostics_opt_in: true
alerts:
  requires_user_arming: true
  maximum_headset_volume_forcing: false
  respect_os_audio_controls: true
```

The inference governor must constrain combined thread pools. Setting ASR and TTS to two threads each does not establish a total two-thread budget.

### 28.2 Pack-manifest example

```json
{
  "manifest_version": 1,
  "pack_id": "project-asr-hi-candidate",
  "revision": "replace-with-pinned-revision",
  "task": "asr",
  "languages": ["hi-IN"],
  "runtime": "replace-with-validated-runtime",
  "architecture": "replace-with-exact-architecture",
  "input_sample_rate_hz": 16000,
  "quantization": "replace-with-validated-format",
  "frontend_revision": "replace-with-pinned-frontend",
  "files": [
    {
      "path": "model.onnx",
      "bytes": null,
      "sha256": "replace-with-actual-sha256"
    }
  ],
  "weights_license": "pending-review",
  "code_license": "pending-review",
  "source_url": "replace-with-actual-source",
  "signature_file": "manifest.sig",
  "validation_status": "not_release_ready"
}
```

Placeholders are intentional. The pack builder must reject unresolved placeholders or missing byte/hash/license values in a release pack.

### 28.3 Benchmark record example

```json
{
  "schema_version": 1,
  "run_id": "local-generated-run-id",
  "device_model": "actual-device-model",
  "android_api": null,
  "app_revision": "actual-commit",
  "asr_pack_revision": "actual-revision",
  "tts_pack_revision": "actual-revision",
  "language": "or-IN",
  "mode": "ptt",
  "route": "speaker",
  "transport": "bluetooth_rfcomm",
  "link_profile": "actual-profile-id",
  "cold_start": false,
  "audio_duration_ms": null,
  "endpoint_delay_ms": null,
  "asr_finalization_tail_ms": null,
  "tts_first_pcm_ms": null,
  "receive_to_audible_ms": null,
  "end_to_end_post_speech_ms": null,
  "cross_device_clock_uncertainty_ms": null,
  "application_wire_bytes": null,
  "peak_pss_kib": null,
  "result": "not_measured"
}
```

### 28.4 Reviewable implementation pseudocode

```text
on_final_asr(result):
    if result is empty or invalid:
        emit local no-speech/failure feedback
        return
    message = conservative_normalize_and_build_final_message(result)
    persist_outgoing(message)
    schedule_by_priority_and_link_budget(message)

on_received_authenticated_message(message):
    validate_schema_language_size_freshness_and_authorization(message)
    outcome = transactional_insert_if_new(message)
    send_durable_receipt_if_persisted(outcome)
    if outcome == NEW:
        enqueue_for_tts_and_playback(message)
    else:
        resend_known_status_without_duplicate_enqueue()

on_playback_failure(message, reason):
    persist_failure_state(message, reason)
    notify_sender_when_connected(message, reason)
    offer_local_retry_or_repeat_request()
```

Security verification precedes acting on message priority/content; storage failures must not generate successful durable receipts.

---

## 29. Definition of done and organizer questions

### 29.1 Release definition of done

- [ ] All ten requested languages have licensed, pinned, offline STT and TTS assets.
- [ ] Every language passes arbitrary unseen text/speech tests, not just predefined phrases.
- [ ] Exact low-end and mid-range physical devices are documented.
- [ ] App works without WAN, remote APIs, proprietary voice SDKs, or stock external speech-engine dependence.
- [ ] PTT loop works in both directions with pause/release finalization.
- [ ] PTT-off hands-free behavior works and full-/half-duplex conditions are accurately labeled.
- [ ] Bluetooth and Wi-Fi paths have repeatable tests.
- [ ] Embedded relay path is implemented to the organizer-agreed scope.
- [ ] Alerts are authenticated, fresh, prioritized, consented, and user-controllable.
- [ ] Android audio limitations are explicitly accepted/documented; no false global non-interruptibility claim.
- [ ] Model/app/storage/RAM/idle CPU metrics are measured, including all installed packs and active combined mode.
- [ ] Per-language WER/CER, critical-entity accuracy, human TTS intelligibility/flow, RTF, and stage latency are reported.
- [ ] Cold/warm/cache and constrained-link results are separated.
- [ ] Link bytes include necessary overhead and retries within a clearly stated boundary.
- [ ] Queue overflow, packet duplication, replay, expiry, missing models, lifecycle changes, and focus loss fail safely.
- [ ] No echo feedback loop occurs in the claimed hands-free profiles.
- [ ] No hidden recording, plaintext telemetry, or unauthorized voice reference is shipped.
- [ ] Signed release, packs, firmware, source, licenses, checksums, raw benchmarks, and offline guide are complete.
- [ ] A second person can perform a clean offline installation and demonstration from the bundle.
- [ ] Remaining gaps are disclosed instead of silently bypassing requirements.

### 29.2 Questions to send ISRO/SIH organizers

1. The listed weights total 80%. What is the remaining 20%?
2. What exact minimum phone RAM, CPU architecture, Android version, storage, and thermal conditions define â€œlowâ€ and â€œmidâ€ range?
3. What bitrate, payload limit, latency, loss rate, and duplex characteristics represent the target link?
4. Is app-level non-interruptible priority acceptable given stock Android's OS/call/DND controls? Is privileged/system-app deployment actually required?
5. Are open-weight noncommercial models acceptable, or must model weights permit unrestricted open-source redistribution/use?
6. Must all ten languages be included inside one APK, or can signed packs be pre-installed fully offline?
7. Is hands-free automatic half-duplex acceptable, or is simultaneous full-duplex speech capture/playback mandatory?
8. Is same-language speech transport sufficient, or is translation expected? The supplied statement does not explicitly require translation.
9. Is a physical embedded bridge required at evaluation, and is a separate RF link specified?
10. What utterance lengths, accents, noise levels, code-switching patterns, and native-listener protocols will be used?
11. Are cached alert phrases allowed as an optimization if arbitrary offline neural TTS is still implemented and evaluated separately?
12. Does â€œhighest volumeâ€ refer specifically to the loudspeaker, and what safety behavior is expected for headphones?

### 29.3 Final implementation recommendation

Invest first in a **measured, licensed, arbitrary-speech loop on a real low-end phone**, with Odia included in feasibility testing. Keep audio, models, protocol, and transport modular; preserve final text faithfully; make queue delay and uncertainty audible; and build the complete evidence package as the implementation progresses.

The strongest submission is not the one claiming that a single model solves everything. It is the one that can demonstrate exactly which languages, phones, links, and operating conditions workâ€”and explain failures without hiding them.

---

## 30. Source register

Sources below were inspected on **9 September 2026**. They support external technical facts and candidate identification, not the proposed performance targets or project schedule. Websites and model cards can change: pin exact revisions, review complete licenses, and revalidate before implementation. No model inference, Android build, or hardware benchmark was executed while preparing this plan.

- **[S1] AI4Bharat IndicConformer-600M multilingual model card.** Language coverage, architecture, size, MIT declaration, gated access, and model-native usage. https://huggingface.co/ai4bharat/indic-conformer-600m-multilingual
- **[S2] OpenAI Whisper tokenizer source.** Standard language-token mapping; Odia is absent from the inspected mapping. https://github.com/openai/whisper/blob/main/whisper/tokenizer.py
- **[S3] ARTPARK-IISc DhVaani-0.5 model card.** Ten requested languages among 27, Apache-2.0 declaration, reference inputs, listed 491 MB weights, flow-matching architecture, and limitations. https://huggingface.co/ARTPARK-IISc/DhVaani-0.5
- **[S4] AI4Bharat IndicF5 repository.** Listed eleven Indic languages, required reference audio/text, usage. The inspected repository description does not establish all dependency/weight licenses; audit separately. https://github.com/AI4Bharat/IndicF5
- **[S5] eSpeak NG source, language list, and license.** Requested-language identifiers and build-specific availability guidance; GPL obligations. https://github.com/espeak-ng/espeak-ng ; https://github.com/espeak-ng/espeak-ng/blob/master/docs/languages.md ; https://github.com/espeak-ng/espeak-ng/blob/master/COPYING
- **[S6] Android Developers â€” Manage audio focus.** Android 12+ system behavior and Android 15+ top-app/foreground-service requirement. https://developer.android.com/media/optimize/audio-focus
- **[S7] Android Developers â€” Foreground service types.** Microphone permission and while-in-use/background-start restrictions. https://developer.android.com/develop/background-work/services/fgs/service-types
- **[S8] Android Developers â€” Wi-Fi Direct and nearby Wi-Fi permissions.** Local sockets still require INTERNET permission; modern nearby-device permission requirements. https://developer.android.com/develop/connectivity/wifi/wifi-direct ; https://developer.android.com/develop/connectivity/wifi/wifi-permissions
- **[S9] Android Developers â€” Bluetooth permissions.** API-specific scan/connect/advertise and legacy permission guidance. https://developer.android.com/develop/connectivity/bluetooth/bt-permissions
- **[S10] sherpa-onnx official repository and TTS example.** Offline native speech framework, Android support, example model integration; not a guarantee of arbitrary model compatibility. https://github.com/k2-fsa/sherpa-onnx/tree/master ; https://github.com/k2-fsa/sherpa-onnx/blob/master/python-api-examples/offline-tts.py
- **[S11] PyTorch ExecuTorch documentation and PyTorch Mobile status discussion.** Current edge deployment direction and legacy mobile maintenance context. https://docs.pytorch.org/executorch/stable/index.html ; https://discuss.pytorch.org/t/pytorch-mobile-current-status/192040
- **[S12] Meta MMS TTS Odia model card.** CC-BY-NC-4.0 license declaration; requires explicit compliance review rather than assuming unrestricted open-source suitability. https://huggingface.co/facebook/mms-tts-ory
- **[S13] ARTPARK-IISc Vaani dataset and benchmark cards.** Candidate data/evaluation resources; verify exact licenses, access, subsets, and split protocols before use. https://huggingface.co/datasets/ARTPARK-IISc/Vaani ; https://huggingface.co/datasets/ARTPARK-IISc/Vaani-Benchmark-V1.0

**End of implementation_plan.md**


