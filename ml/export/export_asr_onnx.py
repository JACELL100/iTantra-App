#!/usr/bin/env python3
"""Exports an IndicConformer CTC checkpoint to INT8 ONNX for on-device use.

The app expects a fixed contract, and it is worth stating up front because the
export is the only place it can be broken:

    inputs :  audio_signal  float32 [1, mel_bins, frames]
              length        int64   [1]
    output :  logprobs      float32 [1, frames, vocab]

plus a `tokens.txt` with one token per line, blank first, matching the CTC
vocabulary order. `CtcDecoder` assumes index 0 is blank.

Quantisation is dynamic INT8, not float16. On the ARM Cortex-A53 cores in the
target devices there is no usable float16 path, so float16 would be dequantised
at runtime and end up slower than float32. INT8 is roughly 4x smaller and 2-3x
faster there, for about 1-2% relative word error rate.

Usage
-----
    ./export_asr_onnx.py --checkpoint indic-conformer-600m.nemo \\
        --language hi --out ../exported/asr-hi

Requires torch, onnx, onnxruntime and the toolkit that owns the checkpoint.
Run this on a workstation; nothing here runs on the phone.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

MEL_BINS = 80
SAMPLE_RATE = 16_000


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
    # NeMo checkpoints expose an ONNX exporter directly; a plain state dict
    # needs the model class, which is why the toolkit import is not optional.
    try:
        import nemo.collections.asr as nemo_asr

        model = nemo_asr.models.ASRModel.restore_from(args.checkpoint, map_location="cpu")
        model.eval()
        if hasattr(model, "cur_decoder"):
            # IndicConformer ships both CTC and RNNT heads. CTC is the one the
            # app decodes, and it is also the cheaper of the two on device.
            model.cur_decoder = "ctc"
        if args.language:
            # Multilingual checkpoints need the language selected before export,
            # otherwise the exported graph carries every language's head.
            try:
                model.set_language(args.language)
            except AttributeError:
                print(f"note: checkpoint has no set_language; assuming {args.language} is implicit")
        tokens = list(model.decoder.vocabulary)
        model.export(str(float_model))
    except ImportError:
        print(
            "error: could not import nemo. Install the toolkit that owns this "
            "checkpoint, or export with torch.onnx.export against the model class.",
            file=sys.stderr,
        )
        return 2

    print(f"wrote {float_model}")

    # Blank must be index 0 because CtcDecoder hardcodes that. Writing it here
    # rather than assuming it keeps the assumption in one place.
    tokens_path = out_dir / "tokens.txt"
    with tokens_path.open("w", encoding="utf-8") as handle:
        handle.write("<blk>\n")
        for token in tokens:
            handle.write(f"{token}\n")
    print(f"wrote {tokens_path} ({len(tokens) + 1} entries, blank at index 0)")

    if args.quantise:
        try:
            from onnxruntime.quantization import QuantType, quantize_dynamic
        except ImportError:
            print("error: onnxruntime is required for quantisation", file=sys.stderr)
            return 2

        print("quantising to INT8 (dynamic, per-channel weights)")
        quantize_dynamic(
            model_input=str(float_model),
            model_output=str(final_model),
            weight_type=QuantType.QInt8,
            # Convolutions in the Conformer subsampling block lose noticeable
            # accuracy under dynamic quantisation, so they stay float.
            op_types_to_quantize=["MatMul", "Gemm", "Attention"],
            extra_options={"MatMulConstBOnly": True},
        )
        before = float_model.stat().st_size / 1e6
        after = final_model.stat().st_size / 1e6
        print(f"{before:.1f} MB -> {after:.1f} MB ({before / after:.1f}x smaller)")
    else:
        shutil.copy(float_model, final_model)

    if not args.keep_fp32:
        float_model.unlink()

    metadata = {
        "task": "ASR",
        "language": args.language,
        "melBins": MEL_BINS,
        "inputSampleRateHz": SAMPLE_RATE,
        "quantisation": "int8-dynamic" if args.quantise else "none",
        "inputs": {"audio_signal": [1, MEL_BINS, "frames"], "length": [1]},
        "outputs": {"logprobs": [1, "frames", len(tokens) + 1]},
    }
    (out_dir / "export.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    print(
        "\nNext: verify the feature front end before trusting this model.\n"
        "  ./verify_frontend.py --wav fixture.wav --kotlin-features kotlin_mel.bin\n"
        "A mismatched front end produces confident, wrong transcripts with no crash."
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Export an ASR checkpoint to ONNX")
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--language", help="language code to select on a multilingual checkpoint")
    parser.add_argument("--out", required=True)
    parser.add_argument("--no-quantise", dest="quantise", action="store_false")
    parser.add_argument("--keep-fp32", action="store_true")
    parser.set_defaults(quantise=True)
    return export(parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
