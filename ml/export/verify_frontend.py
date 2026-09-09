#!/usr/bin/env python3
"""Verifies the Kotlin log-mel front end against the Python reference.

This is the single highest-value script in the repository, and the reason is
unglamorous: if the on-device feature extractor differs from the one used
during training, the model still runs, still produces confident-looking text,
and is simply wrong. There is no crash to debug. A one-off window function or a
missing dither can cost ten points of word error rate.

So the contract is fixed here in one place and checked numerically:

    16 kHz mono, 25 ms window (400 samples), 10 ms hop (160 samples),
    512-point FFT, 80 mel bins, 20-7600 Hz, Hann window, natural log,
    per-utterance mean/variance normalisation.

Usage
-----
    # Compare against features dumped by the app's debug build
    ./verify_frontend.py --wav sample.wav --kotlin-features kotlin_mel.bin

    # Just print the reference features for a fixture
    ./verify_frontend.py --wav sample.wav --dump reference_mel.bin

Requires numpy only.
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
import wave
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16_000
WINDOW_SAMPLES = 400
HOP_SAMPLES = 160
FFT_SIZE = 512
MEL_BINS = 80
MEL_LOW_HZ = 20.0
MEL_HIGH_HZ = 7600.0
# Matches LogMelFeatureExtractor: guards log(0) without shifting quiet frames.
LOG_EPSILON = 1e-10


def hz_to_mel(hz: float) -> float:
    # Slaney/HTK-style formula; must match the Kotlin implementation exactly.
    return 2595.0 * math.log10(1.0 + hz / 700.0)


def mel_to_hz(mel: float) -> float:
    return 700.0 * (10.0 ** (mel / 2595.0) - 1.0)


def mel_filterbank() -> np.ndarray:
    """Triangular filterbank, shape (MEL_BINS, FFT_SIZE // 2 + 1)."""
    bins = FFT_SIZE // 2 + 1
    low_mel = hz_to_mel(MEL_LOW_HZ)
    high_mel = hz_to_mel(MEL_HIGH_HZ)
    points = np.linspace(low_mel, high_mel, MEL_BINS + 2)
    hz_points = np.array([mel_to_hz(m) for m in points])
    fft_bins = np.floor((FFT_SIZE + 1) * hz_points / SAMPLE_RATE).astype(int)
    fft_bins = np.clip(fft_bins, 0, bins - 1)

    filters = np.zeros((MEL_BINS, bins), dtype=np.float64)
    for m in range(1, MEL_BINS + 1):
        left, centre, right = fft_bins[m - 1], fft_bins[m], fft_bins[m + 1]
        if centre == left:
            centre = left + 1
        if right <= centre:
            right = centre + 1
        for k in range(left, min(centre, bins)):
            filters[m - 1, k] = (k - left) / max(1, centre - left)
        for k in range(centre, min(right, bins)):
            filters[m - 1, k] = (right - k) / max(1, right - centre)
    return filters


def read_wav_mono16(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as handle:
        if handle.getsampwidth() != 2:
            raise SystemExit("expected 16-bit PCM")
        if handle.getframerate() != SAMPLE_RATE:
            raise SystemExit(
                f"expected {SAMPLE_RATE} Hz, got {handle.getframerate()}; "
                "resample before comparing, or the test proves nothing"
            )
        frames = handle.readframes(handle.getnframes())
        data = np.frombuffer(frames, dtype="<i2").astype(np.float64)
        if handle.getnchannels() == 2:
            data = data.reshape(-1, 2).mean(axis=1)
    return data / 32768.0


def log_mel(samples: np.ndarray, apply_cmvn: bool = True) -> np.ndarray:
    """Reference features, shape (frames, MEL_BINS)."""
    if len(samples) < WINDOW_SAMPLES:
        samples = np.pad(samples, (0, WINDOW_SAMPLES - len(samples)))

    window = np.hanning(WINDOW_SAMPLES + 1)[:WINDOW_SAMPLES]  # periodic Hann
    filters = mel_filterbank()

    frame_count = 1 + (len(samples) - WINDOW_SAMPLES) // HOP_SAMPLES
    features = np.zeros((frame_count, MEL_BINS), dtype=np.float64)

    for index in range(frame_count):
        start = index * HOP_SAMPLES
        frame = samples[start : start + WINDOW_SAMPLES] * window
        padded = np.zeros(FFT_SIZE)
        padded[:WINDOW_SAMPLES] = frame
        spectrum = np.fft.rfft(padded)
        power = np.abs(spectrum) ** 2
        features[index] = np.log(np.maximum(filters @ power, LOG_EPSILON))

    if apply_cmvn:
        # Per-utterance normalisation, which is what makes the model robust to
        # different microphones and gain settings across phones.
        mean = features.mean(axis=0, keepdims=True)
        std = features.std(axis=0, keepdims=True)
        features = (features - mean) / np.maximum(std, 1e-5)

    return features


def load_kotlin_dump(path: Path) -> np.ndarray:
    """Reads the debug dump written by LogMelFeatureExtractor.

    Format: int32 frames, int32 mel bins, then frames*bins float32, all little
    endian.
    """
    raw = path.read_bytes()
    frames, bins = struct.unpack_from("<ii", raw, 0)
    values = np.frombuffer(raw, dtype="<f4", count=frames * bins, offset=8)
    return values.reshape(frames, bins).astype(np.float64)


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify the on-device log-mel front end")
    parser.add_argument("--wav", type=Path, required=True, help="16 kHz mono 16-bit WAV")
    parser.add_argument("--kotlin-features", type=Path, help="dump produced by the Android debug build")
    parser.add_argument("--dump", type=Path, help="write reference features here")
    parser.add_argument("--tolerance", type=float, default=1e-3, help="max absolute difference")
    parser.add_argument("--no-cmvn", action="store_true", help="skip mean/variance normalisation")
    args = parser.parse_args()

    samples = read_wav_mono16(args.wav)
    reference = log_mel(samples, apply_cmvn=not args.no_cmvn)
    print(f"reference: {reference.shape[0]} frames x {reference.shape[1]} mel bins")

    if args.dump:
        with args.dump.open("wb") as handle:
            handle.write(struct.pack("<ii", *reference.shape))
            handle.write(reference.astype("<f4").tobytes())
        print(f"wrote {args.dump}")

    if not args.kotlin_features:
        return 0

    candidate = load_kotlin_dump(args.kotlin_features)
    print(f"kotlin:    {candidate.shape[0]} frames x {candidate.shape[1]} mel bins")

    if candidate.shape != reference.shape:
        print(
            "FAIL shape mismatch. A frame-count difference usually means the "
            "padding or hop differs, not the filterbank.",
            file=sys.stderr,
        )
        return 1

    difference = np.abs(candidate - reference)
    max_difference = float(difference.max())
    mean_difference = float(difference.mean())
    worst_frame = int(difference.max(axis=1).argmax())

    print(f"max |diff| = {max_difference:.6f} (frame {worst_frame})")
    print(f"mean |diff| = {mean_difference:.6f}")

    if max_difference > args.tolerance:
        print(
            f"FAIL exceeds tolerance {args.tolerance}. Check, in this order: "
            "window type (periodic vs symmetric Hann), FFT normalisation, "
            "mel formula, and whether CMVN was applied on both sides.",
            file=sys.stderr,
        )
        return 1

    print("OK front ends agree within tolerance")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
