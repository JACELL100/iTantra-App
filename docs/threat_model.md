# Threat model

The app is used in alert and distress scenarios, so "it usually works" is not
an acceptable security posture. This file states what is defended, what is not,
and why.

## Assets

1. **Message content.** Recognised speech, possibly a distress call with a
   location in it.
2. **Message integrity.** A forged or altered alert is worse than a lost one.
3. **Availability of the alert path.** An attacker who can prevent a distress
   announcement has achieved the most damaging outcome available.
4. **Audio and transcripts at rest** on the device.

## Adversaries

| Adversary | Capability | Defence |
| --- | --- | --- |
| Passive eavesdropper on Wi-Fi or Bluetooth | Reads frames | AES-256-GCM with per-session ECDH keys; no key is ever persisted |
| Active man-in-the-middle during pairing | Intercepts and substitutes public keys | 6-digit short authentication string compared out of band on both screens |
| Impostor peer | Connects and injects messages | Session keys are bound to the verified pairing; unauthenticated frames fail GCM and are dropped |
| Replay attacker | Re-sends a captured frame | Per-direction keys and counter nonces; 10-minute message-id de-duplication |
| Malicious peer sending malformed frames | Tries to crash or exhaust memory | Length checked against the protocol limit before allocation; strict decode; unknown severity degrades to `WARNING` |
| Another app on the device | Reads storage or backups | App-private storage; all backup and device-transfer rules exclude everything |
| Someone with physical access to an unlocked phone | Reads history | Not defended by the app; relies on device lock. Stated plainly rather than overclaimed |

## Design decisions that follow

**Ephemeral keys only.** Nothing to steal from storage after a session ends,
and no long-term identity to compromise. The cost is that pairing must be
re-verified each session, which takes about five seconds.

**Separate keys per direction.** Derived with distinct labels from the same
shared secret. This makes reflecting a sender's own message back at them
impossible by construction rather than by check.

**Order-independent SAS.** Both phones compute the same digits regardless of
who dialled, so the verification instruction is simply "do the numbers match",
with no role to explain.

**Severity degrades downward.** A corrupted severity byte decodes as `WARNING`.
An attacker who can flip bits should not be able to trigger a maximum-volume,
non-interruptible announcement.

**Length before allocation.** A 6-byte header claiming 16 MB is rejected as a
protocol error. This is the cheapest denial-of-service to close and the easiest
to get wrong.

**No DNS, no hostnames.** `OfflineGuard` accepts only numeric private and
link-local addresses. This enforces the offline requirement and removes name
resolution from the trust surface in one step.

**Store before speaking.** An incoming alert is persisted before synthesis, so
a crash mid-announcement does not lose the message.

## Explicit non-goals

- **Anonymity.** The link reveals that two devices are talking. Hiding that
  needs traffic analysis resistance and costs bandwidth this link does not have.
- **Jamming resistance.** Radio-layer denial of service is out of scope for an
  application.
- **Forward secrecy across sessions beyond ephemeral keys.** Keys are already
  per-session; there is no ratchet within a session because sessions are short.
- **Protection against a compromised OS.** A rooted device can read the
  microphone directly.
- **Encryption when the bridge is used.** The bridge relays opaque frames, so
  end-to-end encryption still works phone-to-phone. But the Wi-Fi soft AP
  passphrase is a shared default: it prevents accidental association, not an
  attacker.

## Residual risks worth stating

1. **Users skipping SAS verification.** The strongest cryptography in the app
   is defeated by tapping through the code comparison. Mitigation is UI: the
   digits are large and the screen says what a mismatch means.
2. **Transcripts persist by default.** Useful for an incident record, a
   liability if the phone is lost. Retention is bounded and the history can be
   cleared, but the default keeps data.
3. **Unencrypted mode exists.** For bridge and diagnostic scenarios where the
   peer cannot do ECDH. The UI must show clearly when a session is unencrypted;
   silently falling back would be the worst possible behaviour.
