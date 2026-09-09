# Language coverage and model choices

Ten languages are required: Hindi, Gujarati, Marathi, Kannada, Malayalam,
Tamil, Telugu, Odia, Bengali, English. No single open-source model covers all
ten for both tasks, so coverage is assembled from several, each verified for
licence as well as accuracy.

## Speech to text

| Language | Model | Licence | Notes |
| --- | --- | --- | --- |
| hi, bn, mr, gu, kn, ml, ta, te, or | AI4Bharat IndicConformer-600M (multilingual) | MIT | Covers 22 Indic languages including Odia. Exported per-language to ONNX and INT8-quantised so each pack stays a few tens of megabytes. |
| en-IN | Whisper-small.en or a Conformer English checkpoint | MIT / Apache-2.0 | IndicConformer does not include English, so English needs its own pack. |

**Why not Whisper for everything:** the Whisper tokenizer has no Odia language
token. Odia is explicitly required, so Whisper alone cannot satisfy the brief
regardless of how well it does on the other nine.

## Text to speech

| Language | Model | Licence | Notes |
| --- | --- | --- | --- |
| 9 Indic languages | ARTPARK-IISc DhVaani-0.5 | Apache-2.0 | ZipVoice-based, 123M parameters. Needs a reference audio clip, which ships inside the pack as a fixed speaker. |
| Alternative, 11 languages | AI4Bharat IndicF5 | Permissive | Higher quality, larger. No English. |
| en-IN | VITS / Piper English voice | MIT | Small and fast; English needs its own voice regardless of which Indic model is chosen. |

**Excluded on licence grounds:** `facebook/mms-tts-ory` is CC-BY-NC-4.0. It is
the obvious Odia TTS candidate and it is open weights, but non-commercial is
not open source, so it cannot ship. `tools/license_audit.py` fails the build if
it appears in a pack. This is the trap most Odia work falls into.

**eSpeak NG** (GPL-3.0) is used as a build-time phonemiser only. Its `or`
voice generates the Odia grapheme-to-phoneme table baked into the pack.
Linking it into the APK would relicense the whole app under GPL-3.0.

## Script handling

Each language uses a different script, and three details cause most bugs:

1. **Normalisation.** The same syllable can be encoded more than one way.
   Everything is normalised to NFC on both the ASR output and the TTS input.
   Without this, word error rate is inflated for reasons unrelated to the model.
2. **Conjuncts.** Indic scripts form ligatures with the virama. Grapheme
   clusters, not code points, are the unit of text handling.
3. **Numerals.** Both Latin and native digits appear in real text.
   `NumberNormalizer` expands both into words in the target language, using the
   Indian numbering system (lakh, crore) rather than the Western one.

## Pack sizes, measured after INT8 quantisation

| Pack | Approximate size |
| --- | --- |
| ASR, one language | 45-70 MB |
| TTS, one language | 25-60 MB |
| VAD, neural (optional) | 2 MB |

A usable two-language install is roughly 150 MB. All ten languages in both
directions is roughly 700 MB, which is why the `lean` flavour ships no packs
and the app installs them from local files, and why the `bundle` flavour is
intended for demo devices only.

## Adding a language

1. Export the model to ONNX with `ml/export/`.
2. Verify the feature front end matches with `ml/export/verify_frontend.py`.
   Skipping this step produces a model that runs and is quietly wrong.
3. Build the pack with `tools/pack_builder.py`.
4. Run `tools/license_audit.py` before shipping it.
5. Add the tag to `ui/Languages.kt` with its endonym, so the language appears
   written in its own script.
