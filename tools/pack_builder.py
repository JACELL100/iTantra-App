#!/usr/bin/env python3
"""Builds an iTantra model pack (.itpack) from a directory.

A pack is just a zip with a manifest and a checksum for every file. The app
refuses to load a pack whose hashes do not match, which is what lets model
files be side-loaded over USB or SD card on a device that has never touched the
internet: integrity does not depend on the transport.

Usage
-----
    ./pack_builder.py build \\
        --source ml/exported/asr-hi \\
        --pack-id asr-indicconformer-hi \\
        --task ASR \\
        --languages hi-IN \\
        --display-name "Hindi speech recognition" \\
        --licence MIT \\
        --source-url https://huggingface.co/ai4bharat/indic-conformer-600m-multilingual \\
        --out dist/asr-hi.itpack

    ./pack_builder.py verify dist/asr-hi.itpack

Standard library only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import zipfile
from pathlib import Path

MANIFEST_NAME = "manifest.json"

# Mirrors ModelPackManager: a pack missing these is unusable at runtime, and
# failing here is far cheaper than failing on a phone in the field.
REQUIRED_FILES = {
    "ASR": ("model.onnx", "tokens.txt"),
    "TTS": ("model.onnx", "graphemes.tsv"),
    "VAD": ("model.onnx",),
}


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def build(args: argparse.Namespace) -> int:
    source = Path(args.source)
    if not source.is_dir():
        print(f"error: {source} is not a directory", file=sys.stderr)
        return 2

    task = args.task.upper()
    if task not in REQUIRED_FILES:
        print(f"error: unknown task {task}", file=sys.stderr)
        return 2

    files = sorted(p for p in source.rglob("*") if p.is_file() and p.name != MANIFEST_NAME)
    names = {p.relative_to(source).as_posix() for p in files}

    missing = [name for name in REQUIRED_FILES[task] if name not in names]
    if missing:
        print(f"error: {task} pack is missing {', '.join(missing)}", file=sys.stderr)
        return 2

    checksums = {p.relative_to(source).as_posix(): sha256_of(p) for p in files}
    size_bytes = sum(p.stat().st_size for p in files)

    manifest = {
        "packId": args.pack_id,
        "revision": args.revision,
        "task": task,
        "displayName": args.display_name,
        "languageTags": args.languages,
        "inputSampleRateHz": args.input_sample_rate,
        "melBins": args.mel_bins,
        "outputSampleRateHz": args.output_sample_rate,
        "licence": args.licence,
        "sourceUrl": args.source_url,
        "sizeBytes": size_bytes,
        "sha256": checksums,
    }

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    # Deflate, not store: ONNX weights compress by 5-15%, and every megabyte
    # matters when packs are copied by hand onto low-end phones.
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(MANIFEST_NAME, json.dumps(manifest, indent=2, ensure_ascii=False))
        for path in files:
            archive.write(path, path.relative_to(source).as_posix())

    print(f"wrote {out} ({out.stat().st_size / 1e6:.1f} MB packed, {size_bytes / 1e6:.1f} MB unpacked)")
    for name, digest in checksums.items():
        print(f"  {digest[:12]}  {name}")
    return 0


def verify(args: argparse.Namespace) -> int:
    pack = Path(args.pack)
    with zipfile.ZipFile(pack) as archive:
        try:
            manifest = json.loads(archive.read(MANIFEST_NAME))
        except KeyError:
            print("error: pack has no manifest.json", file=sys.stderr)
            return 2

        expected = manifest.get("sha256", {})
        if not expected:
            print("error: manifest lists no checksums", file=sys.stderr)
            return 2

        problems = []
        for name, digest in expected.items():
            try:
                actual = hashlib.sha256(archive.read(name)).hexdigest()
            except KeyError:
                problems.append(f"missing file {name}")
                continue
            if actual != digest:
                problems.append(f"checksum mismatch for {name}")

        extras = [
            name
            for name in archive.namelist()
            if name != MANIFEST_NAME and not name.endswith("/") and name not in expected
        ]
        if extras:
            # An unlisted file would be installed but unverified.
            problems.extend(f"unlisted file {name}" for name in extras)

    print(f"pack: {manifest.get('packId')} rev {manifest.get('revision')}")
    print(f"task: {manifest.get('task')}  languages: {', '.join(manifest.get('languageTags', []))}")
    print(f"licence: {manifest.get('licence')}")
    if problems:
        for problem in problems:
            print(f"  FAIL {problem}")
        return 1
    print("  OK all files verified")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="iTantra model pack tool")
    sub = parser.add_subparsers(dest="command", required=True)

    build_parser = sub.add_parser("build", help="create a .itpack")
    build_parser.add_argument("--source", required=True)
    build_parser.add_argument("--pack-id", required=True)
    build_parser.add_argument("--task", required=True, choices=["ASR", "TTS", "VAD", "asr", "tts", "vad"])
    build_parser.add_argument("--languages", required=True, nargs="+")
    build_parser.add_argument("--display-name", required=True)
    build_parser.add_argument("--licence", required=True)
    build_parser.add_argument("--source-url", required=True)
    build_parser.add_argument("--revision", type=int, default=1)
    build_parser.add_argument("--input-sample-rate", type=int, default=16000)
    build_parser.add_argument("--mel-bins", type=int, default=80)
    build_parser.add_argument("--output-sample-rate", type=int, default=22050)
    build_parser.add_argument("--out", required=True)
    build_parser.set_defaults(func=build)

    verify_parser = sub.add_parser("verify", help="check a .itpack")
    verify_parser.add_argument("pack")
    verify_parser.set_defaults(func=verify)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
