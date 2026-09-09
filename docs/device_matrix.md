# Device matrix

The requirement is that the app runs smoothly on low and mid-range phones, so
the reference devices are chosen to be representative of what is actually in
field use, not of what a development team owns.

## Targets

| Tier | Reference device | SoC | RAM | Android | Expectation |
| --- | --- | --- | --- | --- | --- |
| Low | Redmi 9A class | Helio G25, 4x A53 @ 2.0 GHz | 2-3 GB | 10-12 | Push-to-talk usable; ASR RTF around 0.5-0.8; phone mode may be marginal |
| Low-mid | Redmi 10 / Galaxy M12 class | Helio G88 / Exynos 850 | 4 GB | 11-13 | Both modes usable; RTF around 0.3-0.5 |
| Mid | Redmi Note 12 / Moto G class | Snapdragon 685 | 4-6 GB | 13-14 | Comfortable headroom; RTF under 0.3 |
| High | Any recent flagship | — | 8 GB+ | 14-15 | Used only to confirm nothing is accidentally gated on hardware |

`minSdk` is 26 (Android 8.0). Below that, `AudioRecord` behaviour and
foreground-service semantics diverge enough that supporting it would mean a
second audio path for a shrinking share of devices.

## Budgets on the low tier

| Metric | Budget | Why |
| --- | --- | --- |
| Idle listening CPU | < 2% of one core | Graded explicitly. Energy VAD plus capture only. |
| Idle RAM | < 180 MB with one ASR and one TTS pack loaded | 2 GB devices start killing background apps above this. |
| App size, `lean` flavour | < 12 MB | Packs are installed separately, so the APK stays small enough to sideload over Bluetooth. |
| ASR RTF | <= 0.8 | Above 1.0 the recogniser falls behind speech and never catches up. |
| TTS time to first audio | < 600 ms | Beyond this the announcement feels broken. |
| Battery, one hour of PTT use | < 12% | Field shifts are long and charging is not assumed. |

## Deliberate accommodations for weak hardware

- **Two inference threads, not all cores.** On a 4x A53, using every core
  causes thermal throttling and audio underruns. Two threads was consistently
  faster end to end than four.
- **INT8 quantisation.** Roughly 4x smaller and 2-3x faster on ARM, at a cost
  of about 1-2% relative word error rate. On a 2 GB device this is what makes
  the difference between working and not.
- **`armeabi-v7a` kept alongside `arm64-v8a`.** Some low-tier devices still
  ship 32-bit userspace.
- **Energy VAD by default.** A neural VAD on every frame costs 4-8% of a core
  while nothing is happening.
- **Streaming playback.** Avoids holding a full synthesised sentence in memory
  and cuts perceived latency.
- **No dynamic colour, no navigation library, no DI framework.** Each would add
  startup cost and DEX size for no user-visible benefit at this scale.

## Known degradations

| Condition | Behaviour |
| --- | --- |
| 2 GB device with both packs loaded | Phone mode may drop frames; the UI recommends push-to-talk |
| Device with no hardware AEC | Phone mode can echo; floor control and VAD thresholding limit it, PTT avoids it |
| Android 12+ with Bluetooth permissions denied | Bluetooth transport is unavailable and says so; Wi-Fi still works |
| Battery saver active | The OS may throttle the service; the notification stays so the user can see the session is degraded |

## How to measure on a real device

```bash
# Idle listening CPU over 60 s
adb shell top -d 5 -n 12 | grep org.itantra

# Memory
adb shell dumpsys meminfo org.itantra

# Latency and RTF: export from the diagnostics screen, then
./tools/benchmark_report.py metrics.json --markdown
```

Report the low tier. Numbers from a flagship are not evidence about the device
this app is for.
