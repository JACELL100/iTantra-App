#!/usr/bin/env python3
"""Low-bitrate link emulator for iTantra.

Sits between two TCP endpoints and degrades the link on purpose: fixed delay,
jitter, packet loss, reordering, and a hard bandwidth ceiling.

The reason this exists: on a desk, over Wi-Fi, everything works. The metrics
that are actually graded (latency delta, real-time factor, behaviour under
loss) only become visible on a bad link, and "go stand behind a concrete wall"
is not a repeatable test. This makes a 9.6 kbit/s lossy channel reproducible
from the command line.

Usage
-----
    # Emulate a narrowband link in front of a phone listening on 47311
    ./link_emulator.py --listen 47411 --forward 192.168.4.2:47311 \\
        --bitrate 9600 --latency-ms 120 --jitter-ms 40 --loss 0.02

Then point the dialling phone at this host on port 47411 instead.

Standard library only, so it runs on any machine with Python 3.9+ and no
network access for installs.
"""

from __future__ import annotations

import argparse
import random
import socket
import threading
import time
from dataclasses import dataclass

HEADER_SIZE = 6
MAGIC = b"IT"


@dataclass
class Profile:
    bitrate: int
    latency_ms: float
    jitter_ms: float
    loss: float
    reorder: float

    def transmit_seconds(self, size_bytes: int) -> float:
        """Serialisation delay: the part people forget when they only add latency."""
        if self.bitrate <= 0:
            return 0.0
        return (size_bytes * 8) / self.bitrate

    def propagation_seconds(self) -> float:
        jitter = random.uniform(-self.jitter_ms, self.jitter_ms) if self.jitter_ms else 0.0
        return max(0.0, (self.latency_ms + jitter) / 1000.0)


class Stats:
    def __init__(self) -> None:
        self.frames = 0
        self.dropped = 0
        self.reordered = 0
        self.bytes = 0
        self._lock = threading.Lock()

    def record(self, size: int, dropped: bool, reordered: bool) -> None:
        with self._lock:
            self.frames += 1
            self.bytes += size
            if dropped:
                self.dropped += 1
            if reordered:
                self.reordered += 1

    def render(self) -> str:
        with self._lock:
            if self.frames == 0:
                return "no frames yet"
            return (
                f"frames={self.frames} bytes={self.bytes} "
                f"dropped={self.dropped} ({100 * self.dropped / self.frames:.1f}%) "
                f"reordered={self.reordered}"
            )


def read_frame(sock: socket.socket) -> bytes | None:
    """Reads one length-prefixed iTantra frame, resynchronising on the magic."""
    header = b""
    while len(header) < HEADER_SIZE:
        chunk = sock.recv(HEADER_SIZE - len(header))
        if not chunk:
            return None
        header += chunk
        # Resynchronise rather than mangling the rest of the stream.
        while len(header) >= 2 and header[:2] != MAGIC:
            header = header[1:]
            extra = sock.recv(1)
            if not extra:
                return None
            header += extra

    length = (header[3] << 16) | (header[4] << 8) | header[5]
    payload = b""
    while len(payload) < length:
        chunk = sock.recv(length - len(payload))
        if not chunk:
            return None
        payload += chunk
    return header + payload


def pump(src: socket.socket, dst: socket.socket, profile: Profile, stats: Stats, label: str) -> None:
    pending: list[tuple[float, bytes]] = []
    try:
        while True:
            frame = read_frame(src)
            if frame is None:
                break

            if profile.loss and random.random() < profile.loss:
                stats.record(len(frame), dropped=True, reordered=False)
                continue

            delay = profile.propagation_seconds() + profile.transmit_seconds(len(frame))
            reordered = bool(profile.reorder) and random.random() < profile.reorder
            if reordered:
                # Hold this frame and let the next one overtake it.
                pending.append((time.monotonic() + delay + 0.05, frame))
                stats.record(len(frame), dropped=False, reordered=True)
                continue

            time.sleep(delay)
            dst.sendall(frame)
            stats.record(len(frame), dropped=False, reordered=False)

            now = time.monotonic()
            ready = [item for item in pending if item[0] <= now]
            for _, held in ready:
                dst.sendall(held)
            pending = [item for item in pending if item[0] > now]
    except OSError:
        pass
    finally:
        for _, held in pending:
            try:
                dst.sendall(held)
            except OSError:
                break
        print(f"[{label}] closed: {stats.render()}")
        for s in (src, dst):
            try:
                s.close()
            except OSError:
                pass


def main() -> None:
    parser = argparse.ArgumentParser(description="Degrade a TCP link for iTantra testing")
    parser.add_argument("--listen", type=int, required=True, help="local port to accept on")
    parser.add_argument("--forward", required=True, help="host:port to forward to")
    parser.add_argument("--bitrate", type=int, default=9600, help="bits per second ceiling")
    parser.add_argument("--latency-ms", type=float, default=100.0)
    parser.add_argument("--jitter-ms", type=float, default=30.0)
    parser.add_argument("--loss", type=float, default=0.01, help="0.0-1.0")
    parser.add_argument("--reorder", type=float, default=0.0, help="0.0-1.0")
    parser.add_argument("--seed", type=int, default=None, help="fix for reproducible runs")
    args = parser.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    host, _, port = args.forward.partition(":")
    profile = Profile(
        bitrate=args.bitrate,
        latency_ms=args.latency_ms,
        jitter_ms=args.jitter_ms,
        loss=args.loss,
        reorder=args.reorder,
    )

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("0.0.0.0", args.listen))
    listener.listen(2)
    print(
        f"emulating {profile.bitrate} bit/s, {profile.latency_ms} ms "
        f"+/-{profile.jitter_ms} ms, {profile.loss:.1%} loss on port {args.listen}"
    )

    while True:
        client, addr = listener.accept()
        print(f"accepted {addr}")
        try:
            upstream = socket.create_connection((host, int(port)), timeout=5)
        except OSError as exc:
            print(f"upstream unreachable: {exc}")
            client.close()
            continue
        client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        upstream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        stats_up, stats_down = Stats(), Stats()
        threading.Thread(
            target=pump, args=(client, upstream, profile, stats_up, "up"), daemon=True
        ).start()
        threading.Thread(
            target=pump, args=(upstream, client, profile, stats_down, "down"), daemon=True
        ).start()


if __name__ == "__main__":
    main()
