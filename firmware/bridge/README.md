# iTantra embedded bridge (ESP32)

This firmware is optional. The two-phone walkie-talkie loop works without it.
The bridge exists for the deployment the problem statement mentions explicitly:
streaming recognised text to "a wifi/Bluetooth connected embedded device"
rather than to a second handset.

## What it does

It is a dumb relay with one job: move iTantra frames between a BLE GATT link
(phone side) and a TCP socket (installation side).

```
phone  --BLE GATT-->  ESP32 bridge  --TCP 47311-->  radio set / logger / second phone
```

It validates the 6-byte frame header and nothing else. It never parses message
contents, for two reasons:

- the payload can be end-to-end encrypted between the two phones, so the
  bridge could not read it even if it wanted to;
- a relay that understood message fields would need reflashing every time the
  protocol gained one.

## Why an ESP32

Wi-Fi and Bluetooth on a single die for a few hundred rupees, and an
Arduino core under Apache-2.0/LGPL, which keeps the entire deliverable
open source as the rules require.

## Build and flash

Requires [PlatformIO](https://platformio.org/) (Apache-2.0).

```bash
cd firmware/bridge
pio run                 # compile
pio run --target upload  # flash over USB
pio device monitor       # 115200 baud
```

## Using it

1. Flash and power the board. It comes up as a Wi-Fi access point
   `iTantra-Bridge` (passphrase `itantra-local`) at `192.168.4.1`, and
   advertises over BLE as `iTantra Bridge`.
2. Point the receiving side at `192.168.4.1:47311` (in the app: join over
   Wi-Fi).
3. On the sending phone, connect to the BLE bridge from the Talk screen.

No internet connection is used or required at any point.

## GATT contract

| Role | UUID | Properties |
| --- | --- | --- |
| Service | `6f1d9b30-4c8a-4a4e-9a0f-1b7c5d2e8a11` | — |
| Phone to bridge | `6f1d9b31-...` | write, write-no-response |
| Bridge to phone | `6f1d9b32-...` | notify |

The MTU is requested at 185 bytes and falls back to the 23-byte default, so
frames are written in chunks and reassembled by header length on both sides.

## Known limits

- One BLE peer and one TCP peer at a time. A many-to-many net needs an
  addressing scheme the protocol does not yet define.
- Throughput is roughly 2-4 kB/s in practice, which is why
  `BleBridgeTransport` caps frames at 2 kB rather than the protocol's 8 kB:
  a large frame would occupy the link long enough to delay an alert.
- The soft-AP passphrase is a shared default. It protects against accidental
  association, not against an attacker; message confidentiality comes from the
  end-to-end session keys, not from Wi-Fi.
