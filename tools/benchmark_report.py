#!/usr/bin/env python3
"""Turns exported iTantra metrics into the numbers the rubric asks for.

The evaluation is 40% accuracy, 20% latency, 20% efficiency, and the latency
portion names specific quantities: STT delay, TTS delay, real-time factor, and
the delta between a sentence being spoken on one phone and starting to play on
the other. This script computes exactly those from a metrics export, so the
submission reports measurements rather than impressions.

Input is the JSON written by the diagnostics screen ('Export metrics'):

    {
      "timelines": [
        {"messageId": "...", "sendLatencyMs": 380, "receiveLatencyMs": 240,
         "deltaMs": 620, "audioDurationMs": 1800, "asrComputeMs": 300,
         "ttsComputeMs": 210, "synthesisedMs": 1600}
      ],
      "counters": {"inbound_duplicate": 1},
      "device": {"model": "...", "soc": "...", "ramMb": 3072}
    }

Usage
-----
    ./benchmark_report.py metrics.json --markdown > docs/results.md
    ./benchmark_report.py metrics.json --wer-reference ref.txt --wer-hypothesis hyp.txt

Standard library only.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import unicodedata
from pathlib import Path

# Targets from the implementation plan, restated here so the script can say
# "pass" or "fail" instead of leaving the reader to compare numbers by eye.
TARGETS = {
    "send_p95_ms": 900,
    "receive_p95_ms": 700,
    "delta_p95_ms": 1500,
    "asr_rtf": 0.6,
    "tts_rtf": 0.5,
}


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


def summarise(values: list[float]) -> dict[str, float | None]:
    if not values:
        return {"count": 0, "median": None, "p95": None, "max": None}
    return {
        "count": len(values),
        "median": statistics.median(values),
        "p95": percentile(values, 0.95),
        "max": max(values),
    }


def normalise_for_wer(text: str) -> list[str]:
    """NFC, case-folded, punctuation-stripped tokens.

    Indic scripts encode the same syllable more than one way, so comparing raw
    strings inflates the error rate for reasons that have nothing to do with
    the model. NFC normalisation is not optional here.
    """
    normalised = unicodedata.normalize("NFC", text).casefold()
    cleaned = "".join(
        " " if unicodedata.category(ch).startswith("P") else ch for ch in normalised
    )
    return cleaned.split()


def word_error_rate(reference: str, hypothesis: str) -> tuple[float, int, int]:
    ref = normalise_for_wer(reference)
    hyp = normalise_for_wer(hypothesis)
    if not ref:
        return (0.0 if not hyp else 1.0), 0, len(hyp)

    # Standard Levenshtein over words, two rows only: transcripts are short but
    # there can be thousands of them.
    previous = list(range(len(hyp) + 1))
    for i, ref_word in enumerate(ref, start=1):
        current = [i] + [0] * len(hyp)
        for j, hyp_word in enumerate(hyp, start=1):
            cost = 0 if ref_word == hyp_word else 1
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        previous = current
    distance = previous[-1]
    return distance / len(ref), distance, len(ref)


def compute_wer(reference_path: Path, hypothesis_path: Path) -> dict[str, float]:
    ref_lines = reference_path.read_text(encoding="utf-8").splitlines()
    hyp_lines = hypothesis_path.read_text(encoding="utf-8").splitlines()
    if len(ref_lines) != len(hyp_lines):
        print(
            f"warning: {len(ref_lines)} reference lines vs {len(hyp_lines)} hypotheses; "
            "comparing the common prefix",
            file=sys.stderr,
        )
    pairs = list(zip(ref_lines, hyp_lines))
    total_distance = 0
    total_words = 0
    for reference, hypothesis in pairs:
        _, distance, words = word_error_rate(reference, hypothesis)
        total_distance += distance
        total_words += words
    # Corpus WER is the aggregate ratio, not the mean of per-line rates: a
    # three-word utterance should not carry the same weight as a long one.
    return {
        "utterances": len(pairs),
        "wer": (total_distance / total_words) if total_words else 0.0,
        "words": total_words,
    }


def build_report(data: dict) -> dict:
    timelines = data.get("timelines", [])

    send = [t["sendLatencyMs"] for t in timelines if t.get("sendLatencyMs") is not None]
    receive = [t["receiveLatencyMs"] for t in timelines if t.get("receiveLatencyMs") is not None]
    delta = [t["deltaMs"] for t in timelines if t.get("deltaMs") is not None]

    asr_rtf = [
        t["asrComputeMs"] / t["audioDurationMs"]
        for t in timelines
        if t.get("asrComputeMs") and t.get("audioDurationMs")
    ]
    tts_rtf = [
        t["ttsComputeMs"] / t["synthesisedMs"]
        for t in timelines
        if t.get("ttsComputeMs") and t.get("synthesisedMs")
    ]

    report = {
        "device": data.get("device", {}),
        "messages": len(timelines),
        "send_latency_ms": summarise(send),
        "receive_latency_ms": summarise(receive),
        "end_to_end_delta_ms": summarise(delta),
        "asr_rtf": summarise(asr_rtf),
        "tts_rtf": summarise(tts_rtf),
        "counters": data.get("counters", {}),
    }

    checks = {}
    for key, target, actual in (
        ("send_p95_ms", TARGETS["send_p95_ms"], report["send_latency_ms"]["p95"]),
        ("receive_p95_ms", TARGETS["receive_p95_ms"], report["receive_latency_ms"]["p95"]),
        ("delta_p95_ms", TARGETS["delta_p95_ms"], report["end_to_end_delta_ms"]["p95"]),
        ("asr_rtf", TARGETS["asr_rtf"], report["asr_rtf"]["median"]),
        ("tts_rtf", TARGETS["tts_rtf"], report["tts_rtf"]["median"]),
    ):
        checks[key] = {
            "target": target,
            "actual": actual,
            "pass": None if actual is None else actual <= target,
        }
    report["checks"] = checks
    return report


def render_markdown(report: dict) -> str:
    device = report.get("device", {})
    lines = [
        "# iTantra measured results",
        "",
        f"Device: {device.get('model', 'unknown')} "
        f"({device.get('soc', 'unknown SoC')}, {device.get('ramMb', '?')} MB RAM)",
        f"Messages analysed: {report['messages']}",
        "",
        "| Metric | Median | p95 | Max | Target (p95) | Verdict |",
        "| --- | --- | --- | --- | --- | --- |",
    ]

    def fmt(value: float | None, suffix: str = "") -> str:
        return "-" if value is None else f"{value:.0f}{suffix}" if suffix == " ms" else f"{value:.2f}"

    rows = [
        ("Speech end to transmitted", "send_latency_ms", "send_p95_ms", " ms"),
        ("Received to first audio", "receive_latency_ms", "receive_p95_ms", " ms"),
        ("Sentence-to-sentence delta", "end_to_end_delta_ms", "delta_p95_ms", " ms"),
        ("ASR real-time factor", "asr_rtf", "asr_rtf", ""),
        ("TTS real-time factor", "tts_rtf", "tts_rtf", ""),
    ]
    for label, key, check_key, suffix in rows:
        stats = report[key]
        check = report["checks"][check_key]
        verdict = "n/a" if check["pass"] is None else ("pass" if check["pass"] else "FAIL")
        lines.append(
            f"| {label} | {fmt(stats['median'], suffix)} | {fmt(stats['p95'], suffix)} | "
            f"{fmt(stats['max'], suffix)} | {check['target']}{suffix} | {verdict} |"
        )

    if report.get("counters"):
        lines += ["", "## Counters", ""]
        for name, value in sorted(report["counters"].items()):
            lines.append(f"- `{name}`: {value}")

    if report.get("wer") is not None:
        lines += [
            "",
            "## Accuracy",
            "",
            f"- Word error rate: {report['wer']['wer']:.1%} "
            f"over {report['wer']['utterances']} utterances "
            f"({report['wer']['words']} reference words)",
        ]

    lines += [
        "",
        "Latencies are measured from the monotonic clock inside the app, not from "
        "wall clock timestamps, so they are unaffected by clock skew between the "
        "two phones.",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarise iTantra metrics")
    parser.add_argument("metrics", help="metrics JSON exported from the app")
    parser.add_argument("--markdown", action="store_true", help="emit Markdown instead of JSON")
    parser.add_argument("--wer-reference", type=Path, help="reference transcripts, one per line")
    parser.add_argument("--wer-hypothesis", type=Path, help="recognised transcripts, one per line")
    args = parser.parse_args()

    data = json.loads(Path(args.metrics).read_text(encoding="utf-8"))
    report = build_report(data)

    if args.wer_reference and args.wer_hypothesis:
        report["wer"] = compute_wer(args.wer_reference, args.wer_hypothesis)

    if args.markdown:
        sys.stdout.write(render_markdown(report))
    else:
        json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")

    failed = [name for name, check in report["checks"].items() if check["pass"] is False]
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
