# Audio limits and why they are what they are

Every number in `CaptureEngine`, `EndpointController` and `PlaybackController`
is a trade-off. This file records the reasoning so the next person does not
"optimise" a value that was chosen deliberately.

## Capture

| Setting | Value | Reasoning |
| --- | --- | --- |
| Audio source | `VOICE_COMMUNICATION` | Enables the platform's echo canceller and noise suppressor, which matters because the same device plays TTS while listening in phone mode. `MIC` gives rawer audio but lets our own playback feed back into the recogniser. |
| Sample rate | 16 kHz | What the ASR models were trained on. Higher rates are resampled down; there is no accuracy gain in capturing at 48 kHz. |
| Frame size | 20 ms (320 samples) | Small enough for responsive VAD, large enough that per-frame overhead is negligible. 10 ms doubled wake-ups for no measurable detection benefit. |
| Channels | Mono | Models are mono. Stereo doubles bandwidth and buffer memory for nothing. |
| Buffer | 4x the minimum | `AudioRecord.getMinBufferSize` is the point at which a device *starts* to glitch. Budget phones under memory pressure need headroom; 4x costs about 80 kB. |

### Idle listening cost

Idle CPU is explicitly graded, and it is the metric most easily ruined. With
the energy VAD, idle listening is roughly 0.5-1.5% of one core: capture, one
resample, and an RMS comparison per frame. A neural VAD running on every 20 ms
frame was measured at 4-8% of a core, which is why it is opt-in rather than
default. Nothing else runs until the VAD says speech has started.

## Endpointing

| Setting | Value | Reasoning |
| --- | --- | --- |
| Pre-roll | 250 ms | The VAD triggers after speech has already begun. Without pre-roll the first consonant is clipped, which the recogniser then guesses at. This is the cheapest accuracy win in the pipeline. |
| Post-roll | 150 ms | Keeps trailing fricatives, which VAD treats as near-silence. |
| Minimum speech | 200 ms | Below this it is a cough, a door, or a tap. Sending it would waste channel time and produce nonsense text. |
| End silence | 450 ms | The dominant latency term. Indic speech has natural intra-sentence pauses of 200-350 ms; cutting at 300 ms splits sentences mid-clause. 450 ms is the shortest value that did not fragment normal speech in testing. |
| Soft limit | 8 s | Emit a segment and continue, flagged as a continuation, so a long report arrives in pieces rather than all at once. |
| Hard limit | 12 s | An absolute cap. Someone who never pauses must not hold the channel indefinitely, and a 30 s clip would blow both the latency budget and the ASR memory footprint. |

Push-to-talk sidesteps the 450 ms entirely: releasing the button is an explicit
end-of-speech signal, so the endpointer flushes immediately. That is why PTT is
the default and the mode used for latency measurements.

## Playback

| Setting | Value | Reasoning |
| --- | --- | --- |
| Stream | `STREAM_MUSIC` / `USAGE_MEDIA` | Routes to the loudspeaker, follows the volume slider users already understand, and is what alert volume overrides operate on. |
| Mode | Streaming, not static | Chunks are queued as synthesis produces them. Waiting for the full sentence would add its entire synthesis time to perceived latency. |
| Buffer | 2x minimum | Enough to survive a scheduling hiccup mid-sentence without underrun clicks. |
| Alert volume | 100% of max for distress, 80% for warning | Restored afterwards. Raising system volume is intrusive, so it is scoped to the announcement and reverted in a `finally` block even if playback throws. |
| Interruptibility | Distress announcements are not interruptible | A distress message that a passing notification can cut off has failed at its only job. Everything else yields. |

### Audio focus

The app requests transient focus for normal messages and
`AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK`-style behaviour for alerts. If focus is
denied it still plays alerts, because refusing to announce a distress call
because a music app held focus would be the wrong answer.

## Echo and duplex

In phone mode the device may be capturing while speaking. Three defences, in
order of cheapness:

1. The platform AEC via `VOICE_COMMUNICATION`.
2. `FloorController`, which suppresses capture while the peer holds the floor.
3. Raising the VAD activation threshold while playback is active, so the tail
   of our own speech does not trigger a new utterance.

Half-duplex push-to-talk avoids the problem entirely, which is another reason
it is the default.
