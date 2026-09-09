#!/usr/bin/env python3
"""Exports a VITS-family TTS checkpoint to ONNX and builds its grapheme table.

The app expects this contract, matching OnnxVitsTtsEngine:

    inputs :  input          int64   [1, tokens]
              input_lengths  int64   [1]
              scales         float32 [3]   (noise, length, noise_w)
    output :  audio          float32 [1, 1, samples]

The scales vector is why speaking rate is adjustable at runtime without
re-exporting: index 1 is the inverse of the rate.

It also writes `graphemes.tsv`, the grapheme-to-token mapping the phonemiser
uses on device. For Odia the table is generated with eSpeak NG (GPL-3.0) as a
build-time tool: its output is data, so the APK stays permissively licensed.
Linking eSpeak into the app would relicense everything under GPL-3.0.

Usage
-----
    ./export_tts_onnx.py --checkpoint dhvaani-0.5.pt --language or \\
        --reference-audio speaker.wav --out ../exported/tts-or

Run on a workstation. Requires torch and onnx.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import unicodedata
from pathlib import Path

OUTPUT_SAMPLE_RATE = 22_050

# Defaults chosen to match the app: OnnxVitsTtsEngine sends (0.667, 1/rate, 0.8).
DEFAULT_NOISE_SCALE = 0.667
DEFAULT_NOISE_W = 0.8

# eSpeak NG voice codes for the languages that need generated phoneme tables.
ESPEAK_VOICES = {
    "hi": "hi",
    "bn": "bn",
    "gu": "gu",
    "kn": "kn",
    "ml": "ml",
    "mr": "mr",
    "or": "or",
    "ta": "ta",
    "te": "te",
    "en": "en-us",
}


def phonemise(text: str, voice: str) -> str | None:
    """Runs eSpeak NG as a subprocess. Returns None if it is unavailable."""
    try:
        result = subprocess.run(
            ["espeak-ng", "-v", voice, "-q", "--ipa", text],
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        )
    except (FileNotFoundError, subprocess.SubprocessError):
        return None
    return result.stdout.strip()


def build_grapheme_table(out_dir: Path, language: str, symbols: list[str]) -> Path:
    """Writes graphemes.tsv: grapheme, token id, optional IPA.

    The token ids come from the checkpoint's own symbol list, so this file is a
    faithful record of the model's vocabulary rather than a guess. Getting the
    order wrong produces speech that is fluent and says the wrong thing.
    """
    voice = ESPEAK_VOICES.get(language)
    path = out_dir / "graphemes.tsv"
    unavailable_warned = False

    with path.open("w", encoding="utf-8") as handle:
        handle.write("# grapheme\ttoken_id\tipa\n")
        for index, symbol in enumerate(symbols):
            ipa = ""
            if voice and symbol.strip() and not symbol.startswith("<"):
                produced = phonemise(symbol, voice)
                if produced is None and not unavailable_warned:
                    print(
                        "note: espeak-ng not found; writing the table without IPA. "
                        "The app can still map graphemes, but stress and schwa "
                        "handling will be poorer."
                    )
                    unavailable_warned = True
                ipa = produced or ""
            normalised = unicodedata.normalize("NFC", symbol)
            handle.write(f"{normalised}\t{index}\t{ipa}\n")

    print(f"wrote {path} ({len(symbols)} symbols)")
    return path


def export(args: argparse.Namespace) -> int:
    try:
        import torch
    except ImportError:
        print("error: torch is required for export", file=sys.stderr)
        return 2

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    float_model = out_dir / "model.fp32.onnx"
    final_model = out_dir / "model.onnx"

    print(f"loading {args.checkpoint}")
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)

    model = checkpoint["model"] if isinstance(checkpoint, dict) and "model" in checkpoint else checkpoint
    if not hasattr(model, "eval"):
        print(
            "error: the checkpoint is a state dict, not a model. Instantiate the "
            "model class from its repository and load_state_dict before exporting.",
            file=sys.stderr,
        )
        return 2
    model.eval()

    symbols = list(getattr(model, "symbols", [])) or list(
        checkpoint.get("symbols", []) if isinstance(checkpoint, dict) else []
    )
    if not symbols:
        print("error: no symbol list found in the checkpoint", file=sys.stderr)
        return 2

    tokens = torch.randint(1, len(symbols), (1, 24), dtype=torch.long)
    lengths = torch.tensor([tokens.shape[1]], dtype=torch.long)
    scales = torch.tensor([DEFAULT_NOISE_SCALE, 1.0, DEFAULT_NOISE_W], dtype=torch.float32)

    inputs = (tokens, lengths, scales)
    input_names = ["input", "input_lengths", "scales"]

    if args.reference_audio:
        # ZipVoice-style models (DhVaani) need a reference clip. Baking one in
        # gives a fixed speaker, which is what an alert system wants: a
        # recognisable, consistent voice rather than a random one per session.
        shutil.copy(args.reference_audio, out_dir / "reference.wav")
        print(f"copied reference speaker audio into the pack")

    print("exporting to ONNX with dynamic token and sample axes")
    torch.onnx.export(
        model,
        inputs,
        str(float_model),
        input_names=input_names,
        output_names=["audio"],
        dynamic_axes={
            "input": {1: "tokens"},
            "audio": {2: "samples"},
        },
        opset_version=17,
        do_constant_folding=True,
    )
    print(f"wrote {float_model} ({float_model.stat().st_size / 1e6:.1f} MB)")

    if args.quantise:
        try:
            from onnxruntime.quantization import QuantType, quantize_dynamic
        except ImportError:
            print("error: onnxruntime is required for quantisation", file=sys.stderr)
            return 2

        print("quantising to INT8")
        # The vocoder's transposed convolutions are left alone deliberately:
        # quantising them introduces audible metallic artefacts, which matters
        # more here than the megabytes saved, because legibility is 40% of the
        # score.
        quantize_dynamic(
            model_input=str(float_model),
            model_output=str(final_model),
            weight_type=QuantType.QInt8,
            op_types_to_quantize=["MatMul", "Gemm"],
            extra_options={"MatMulConstBOnly": True},
        )
        before = float_model.stat().st_size / 1e6
        after = final_model.stat().st_size / 1e6
        print(f"{before:.1f} MB -> {after:.1f} MB")
    else:
        shutil.copy(float_model, final_model)

    if not args.keep_fp32:
        float_model.unlink()

    build_grapheme_table(out_dir, args.language, symbols)

    metadata = {
        "task": "TTS",
        "language": args.language,
        "outputSampleRateHz": args.sample_rate,
        "quantisation": "int8-dynamic" if args.quantise else "none",
        "scales": {"noise": DEFAULT_NOISE_SCALE, "length": "1 / speakingRate", "noiseW": DEFAULT_NOISE_W},
        "requiresReferenceAudio": bool(args.reference_audio),
    }
    (out_dir / "export.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    print(
        "\nListen to the output before shipping. Word error rate says nothing "
        "about whether synthesised speech is pleasant to hear, and legibility "
        "is 40% of the score."
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Export a TTS checkpoint to ONNX")
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--language", required=True, choices=sorted(ESPEAK_VOICES))
    parser.add_argument("--reference-audio", help="speaker clip for ZipVoice-style models")
    parser.add_argument("--sample-rate", type=int, default=OUTPUT_SAMPLE_RATE)
    parser.add_argument("--out", required=True)
    parser.add_argument("--no-quantise", dest="quantise", action="store_false")
    parser.add_argument("--keep-fp32", action="store_true")
    parser.set_defaults(quantise=True)
    return export(parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
