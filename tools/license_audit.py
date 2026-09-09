#!/usr/bin/env python3
"""Checks that every shipped component is open source and redistributable.

The rules are explicit: open-source only, no proprietary or commercial voice
SDKs. Two traps make this worth automating rather than asserting in a slide:

- Several excellent Indic TTS checkpoints are CC-BY-NC (non-commercial). They
  are open weights but not open source, and shipping one would disqualify the
  submission. `facebook/mms-tts-ory` is the specific one that catches teams
  working on Odia.
- eSpeak NG is GPL-3.0. Using it as a build-time phonemiser is fine; linking
  it into the APK would put the whole app under GPL-3.0.

Usage
-----
    ./license_audit.py --packs dist/*.itpack --gradle app/build.gradle.kts

Exit code 1 means something disallowed is present.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import zipfile
from pathlib import Path

# Permissive licences that may ship inside the APK or a pack.
ALLOWED = {
    "MIT",
    "APACHE-2.0",
    "BSD-2-CLAUSE",
    "BSD-3-CLAUSE",
    "CC0-1.0",
    "CC-BY-4.0",
    "ISC",
    "UNLICENSE",
}

# Open source, but incompatible with shipping a permissively licensed APK.
# Allowed as build-time tools only.
BUILD_TIME_ONLY = {
    "GPL-2.0": "copyleft; would relicense the app if linked",
    "GPL-3.0": "copyleft; eSpeak NG is fine as an offline build tool, not as a runtime library",
    "AGPL-3.0": "network copyleft",
}

# Not open source in the sense the rules require.
DISALLOWED = {
    "CC-BY-NC-4.0": "non-commercial: open weights but not open source",
    "CC-BY-NC-SA-4.0": "non-commercial",
    "CC-BY-NC-ND-4.0": "non-commercial and no derivatives",
    "PROPRIETARY": "closed source",
    "UNKNOWN": "unstated licence cannot be assumed permissive",
}

# Dependency coordinates that indicate a proprietary or cloud voice SDK. The
# rules ban these outright, and a stray transitive dependency is easy to miss.
FORBIDDEN_COORDINATES = (
    "com.google.android.gms:play-services-mlkit",
    "com.google.mlkit:",
    "com.google.cloud:google-cloud-speech",
    "com.google.cloud:google-cloud-texttospeech",
    "com.microsoft.cognitiveservices",
    "com.amazonaws:aws-android-sdk-polly",
    "com.amazonaws:aws-android-sdk-transcribe",
    "ai.picovoice:",
    "com.openai",
    "io.elevenlabs",
)


def audit_pack(path: Path) -> list[str]:
    problems: list[str] = []
    try:
        with zipfile.ZipFile(path) as archive:
            manifest = json.loads(archive.read("manifest.json"))
    except (KeyError, zipfile.BadZipFile) as exc:
        return [f"{path.name}: cannot read manifest ({exc})"]

    licence = str(manifest.get("licence", "UNKNOWN")).strip().upper()
    pack_id = manifest.get("packId", path.name)

    if licence in DISALLOWED:
        problems.append(f"{pack_id}: licence {licence} is not allowed ({DISALLOWED[licence]})")
    elif licence in BUILD_TIME_ONLY:
        problems.append(
            f"{pack_id}: licence {licence} cannot ship inside a pack ({BUILD_TIME_ONLY[licence]})"
        )
    elif licence not in ALLOWED:
        problems.append(f"{pack_id}: licence {licence} is not on the reviewed allow list")

    if not manifest.get("sourceUrl"):
        # Attribution requires a verifiable origin for every weight file.
        problems.append(f"{pack_id}: no sourceUrl recorded")

    if not problems:
        print(f"  OK   {pack_id}: {licence}")
    return problems


def audit_gradle(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    problems = [
        f"{path}: references forbidden dependency {coordinate}"
        for coordinate in FORBIDDEN_COORDINATES
        if coordinate in text
    ]

    # A network-capable inference dependency is not proof of a violation, but
    # it is worth flagging so a reviewer can confirm nothing calls out.
    for suspicious in ("retrofit", "okhttp3:okhttp", "grpc"):
        if re.search(rf"\b{re.escape(suspicious)}\b", text, re.IGNORECASE):
            print(f"  note {path.name}: contains '{suspicious}'; confirm it is not used for inference")

    if not problems:
        print(f"  OK   {path.name}: no proprietary voice SDKs")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit iTantra licences")
    parser.add_argument("--packs", nargs="*", default=[], help=".itpack files to check")
    parser.add_argument("--gradle", nargs="*", default=[], help="Gradle files to check")
    args = parser.parse_args()

    if not args.packs and not args.gradle:
        parser.error("nothing to audit: pass --packs and/or --gradle")

    problems: list[str] = []

    if args.packs:
        print("model packs:")
        for pattern in args.packs:
            for path in sorted(Path().glob(pattern)) or [Path(pattern)]:
                if path.exists():
                    problems += audit_pack(path)
                else:
                    problems.append(f"{path}: not found")

    if args.gradle:
        print("build files:")
        for pattern in args.gradle:
            for path in sorted(Path().glob(pattern)) or [Path(pattern)]:
                if path.exists():
                    problems += audit_gradle(path)
                else:
                    problems.append(f"{path}: not found")

    print()
    if problems:
        print(f"{len(problems)} problem(s) found:", file=sys.stderr)
        for problem in problems:
            print(f"  FAIL {problem}", file=sys.stderr)
        return 1

    print("all shipped components are permissively licensed and attributable")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
