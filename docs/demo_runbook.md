# Demo runbook

A five-minute demonstration that shows the loop, the metrics, and the failure
behaviour. Rehearse it once; the ordering matters because the strongest
evidence is the measured latency, and that needs a few messages of history
before it means anything.

## Before you start

- [ ] Two phones, both with the APK installed
- [ ] The same ASR and TTS packs on both (Hindi and English is enough)
- [ ] Both phones in aeroplane mode with Wi-Fi on, or paired over Bluetooth
- [ ] Volume up on both
- [ ] A laptop for the link emulator, optional but the most persuasive part

Put both phones in aeroplane mode with mobile data off before the audience is
watching, and say so. The offline claim is the one that invites scepticism, and
it is easiest to settle at the start.

## 1. Connect (30 s)

On phone A: **Host over Wi-Fi**. On phone B: join with A's address.

Both show "Connected". If encryption is on, both show a 6-digit code. Read it
aloud from one phone and have someone confirm it matches the other. Point out
that this is what stops a man-in-the-middle when there is no internet and
therefore no certificate authority.

## 2. The walkie-talkie loop (90 s)

On phone A, hold the large button and say a sentence in Hindi. Release.

What the audience sees: the sentence appears as text on both phones, and phone
B speaks it aloud. Say the number out loud: the wire carried about 40 bytes,
where a second of compressed audio would have been 4-16 kB.

Repeat two or three times, and once in English, to show language switching.

## 3. Alert behaviour (45 s)

Start music on phone B so it holds audio focus. Then on phone A, open **Alerts**
and tap "Send help immediately".

Phone B raises its volume to maximum, vibrates, and announces the alert three
times without being interruptible. Try to interrupt it with a notification: it
continues. Then note that the volume returns to where it was, because raising
system volume permanently would be unacceptable.

## 4. The low-bitrate case (60 s)

This is the part that addresses the problem statement directly.

On the laptop:

```bash
./tools/link_emulator.py --listen 47411 --forward <phone-B-ip>:47311 \
    --bitrate 9600 --latency-ms 150 --jitter-ms 50 --loss 0.03 --seed 42
```

Repoint phone A at the laptop's address and send more messages. They still
arrive. Explain that at 9.6 kbit/s, a one-second audio clip would take four to
thirteen seconds to transmit, while a sentence of text takes about 40
milliseconds.

The `--seed 42` is worth mentioning: the degradation is reproducible, so these
numbers can be re-measured rather than re-anecdoted.

## 5. Metrics (45 s)

Open **Diagnostics** on both phones. Show median and p95 for:

- speech end to transmitted
- received to first audible audio
- the sentence-to-sentence delta between the two phones

Say that these come from the monotonic clock inside each app, so they do not
depend on the two phones' wall clocks agreeing.

Export and render if there is time:

```bash
./tools/benchmark_report.py metrics.json --markdown
```

## 6. Failure behaviour (30 s)

Walk one phone out of range, or turn off its Wi-Fi. The other shows the link
state honestly instead of pretending to be connected. Reconnect and continue.

If asked about duplicates, mention that a retransmitted alert is de-duplicated
by message id and announced once, because on a bad link the packet most likely
to be lost is the receipt, which means retransmission of an already-delivered
message is the normal case.

## Questions to expect

**"Is it really offline?"** Aeroplane mode, plus `OfflineGuard` rejects any
non-private address and any hostname, so there is no DNS and no route to a
cloud API. `OfflineGuardTest` proves it in CI.

**"Why not just send compressed audio?"** Do the arithmetic out loud: at
9.6 kbit/s a one-second Opus frame is several seconds of channel time. Text is
also what makes the message searchable and loggable afterwards.

**"What about Odia?"** IndicConformer covers it for ASR. For TTS, the obvious
Hugging Face model is CC-BY-NC, which is not open source, so it is excluded and
the licence audit fails the build if it reappears. The eSpeak NG `or` voice
generates the grapheme table at build time instead.

**"Does it work on a cheap phone?"** `docs/device_matrix.md` has the measured
budgets for a 2 GB Helio G25 device, which is the tier that matters.

## If something goes wrong

| Symptom | Do this |
| --- | --- |
| No connection | Confirm both phones are on the same Wi-Fi; use the Bluetooth transport as a fallback |
| Nothing is transcribed | Check the microphone permission banner; check a pack is installed for that language |
| Silence on the receiving phone | Check volume and that a TTS pack for the receive language is installed |
| Everything fails | Fall back to the single-device loopback demo, which needs no link at all |
