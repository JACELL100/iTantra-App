# Privacy

The app listens to people, sometimes in emergencies. The privacy design is
simple enough to state in one sentence: **voice never leaves the device, and
text only ever goes to the phone you paired with.**

## What is processed and where

| Data | Where it is processed | Where it goes |
| --- | --- | --- |
| Microphone audio | On device, in memory | Nowhere. It is never written to disk and never transmitted. |
| Recognised text | On device | Only to the paired peer, encrypted when a session is encrypted |
| Received text | On device | Stored locally, synthesised locally |
| Model packs | Local files | Never phone home; no update check exists |
| Metrics | On device | Only exported when the user taps Export |

There is no analytics SDK, no crash reporter, no telemetry, and no advertising
identifier. `OfflineGuard` restricts outbound connections to numeric private
and link-local addresses, so "we do not call the cloud" is enforced in code
rather than asserted in documentation.

## Audio retention

Captured audio exists only in the endpointer's ring buffer and the array handed
to the recogniser, and both are released as soon as recognition returns. No
recording is ever persisted. This is a deliberate constraint: a saved recording
is a liability with no operational benefit once the text exists.

## Text retention

Messages are stored so an incident can be reviewed afterwards, and because a
distress message must survive the app being killed mid-announcement.

- Storage is app-private, and Room's default file permissions apply.
- History is bounded and old rows are pruned.
- The user can clear history.
- Backups and device transfer exclude everything
  (`res/xml/data_extraction_rules.xml`), so transcripts never leave via a cloud
  backup.

## Disclosure while recording

The foreground service notification is always visible while a session is
active, and its subtext says when the microphone is in use. This is required by
Android for microphone foreground services, and it is also the honest thing to
do: a device that can hear you should say so.

## Permissions and why each exists

| Permission | Why |
| --- | --- |
| `RECORD_AUDIO` | The core function. Without it the app cannot work. |
| `MODIFY_AUDIO_SETTINGS` | Raise volume for a distress announcement, then restore it |
| `VIBRATE` | Alert the user when audio alone may not be noticed |
| `POST_NOTIFICATIONS` | The service notification and alert notifications |
| `FOREGROUND_SERVICE` + microphone/mediaPlayback/connectedDevice types | Keep the loop alive with the screen off |
| `INTERNET`, Wi-Fi state | Local sockets on the same Wi-Fi or a Wi-Fi Direct group. `INTERNET` is the permission Android requires for any TCP socket, including a purely local one. |
| `NEARBY_WIFI_DEVICES` | Peer discovery on Android 13+, declared `neverForLocation` |
| `ACCESS_FINE_LOCATION` (maxSdk 32) | Required by older Android for Wi-Fi and BLE scanning. Capped so newer devices never request location. |
| Bluetooth scan/connect/advertise | Pairing and the RFCOMM/BLE transports |

The app requests no contacts, no storage, no camera, and no location on modern
Android.

## What a user should be told

1. Your voice is converted to text on your own phone and the audio is deleted
   immediately.
2. The text is sent only to the phone you paired with.
3. Messages you receive are saved on your phone until you clear them.
4. Nothing is sent over the internet, and the app works with mobile data and
   Wi-Fi internet turned off entirely.

## Honest limitations

- An unencrypted session is possible for bridge and diagnostic use. The UI must
  show it clearly; silently falling back would be indefensible.
- Anyone with your unlocked phone can read the message history.
- The recogniser can mis-transcribe. Stored text is a record of what the model
  heard, not of what was said, and should not be treated as a verbatim
  transcript in any consequential setting.
