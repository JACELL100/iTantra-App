# Model preparation

Nothing in this directory runs on the phone. These scripts turn public
checkpoints into `.itpack` files the app can install offline.

## Pipeline

```
checkpoint  --export_*_onnx.py-->  ONNX (INT8)  --pack_builder.py-->  .itpack
                                        |
                                  verify_frontend.py
```

## Order of operations, and why it matters

1. **Export.** `export_asr_onnx.py` or `export_tts_onnx.py`.
2. **Verify the front end.** `verify_frontend.py`. Do not skip this. A feature
   extractor that differs from the training-time one produces a model that
   runs, looks confident, and is wrong, with no error to trace. This is the
   most common and most expensive mistake in on-device ASR.
3. **Build the pack.** `../tools/pack_builder.py build ...`
4. **Audit the licence.** `../tools/license_audit.py --packs 'dist/*.itpack'`
   This is what stops a non-commercial checkpoint from shipping.

## Models used

| Task | Model | Licence |
| --- | --- | --- |
| ASR, 9 Indic languages | [IndicConformer-600M](https://huggingface.co/ai4bharat/indic-conformer-600m-multilingual) | MIT |
| ASR, English | Whisper-small.en or a Conformer English checkpoint | MIT / Apache-2.0 |
| TTS, Indic | [DhVaani-0.5](https://huggingface.co/ARTPARK-IISc/DhVaani-0.5) | Apache-2.0 |
| TTS, Indic alternative | [IndicF5](https://github.com/AI4Bharat/IndicF5) | Permissive |
| Phonemisation, build time only | [eSpeak NG](https://github.com/espeak-ng/espeak-ng) | GPL-3.0 |

`facebook/mms-tts-ory` is deliberately excluded. It is CC-BY-NC-4.0:
open weights, but non-commercial, which is not open source. See
`../docs/language_coverage.md`.

eSpeak NG is invoked as a subprocess to generate grapheme tables. Its output is
data, so the APK stays permissively licensed. Linking it in would relicense the
entire app under GPL-3.0.

## Why INT8 and not float16

The target devices have Cortex-A53 cores with no usable float16 path, so
float16 weights are dequantised at runtime and end up slower than float32.
Dynamic INT8 is roughly 4x smaller and 2-3x faster there, costing about 1-2%
relative word error rate. On a 2 GB phone that trade is what makes the app work
at all.

Transposed convolutions in the vocoder and the Conformer subsampling
convolutions are left in float on purpose: quantising them costs audible
quality or accuracy for a small size saving.

## Requirements

```bash
pip install torch onnx onnxruntime numpy
# plus the toolkit that owns your checkpoint, e.g. nemo_toolkit['asr']
```

`verify_frontend.py` needs only numpy.
