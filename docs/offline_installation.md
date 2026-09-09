# Offline installation

The app must work with no internet, and so must getting it onto a device. This
is the procedure for a machine and phones that have never been online.

## What you need

- The APK (`app-lean-release.apk` or `app-bundle-release.apk`)
- One or more `.itpack` model packs
- A USB cable, or a microSD card, or Bluetooth file transfer between phones

## Which flavour

| Flavour | Contains | Use when |
| --- | --- | --- |
| `lean` | No models. About 10-12 MB. | Normal deployment. Packs are copied separately, so the APK is small enough to send over Bluetooth. |
| `bundle` | Models compiled in as assets, installed on first launch | Demo devices, where a single install with no extra steps matters |

## Installing the app

```bash
adb install -r app-lean-release.apk
```

Or copy the APK to the phone and open it from the file manager, allowing
installation from unknown sources when prompted.

## Installing model packs

Three routes, in order of convenience:

**1. ADB push**

```bash
adb push asr-hi.itpack /sdcard/Download/
adb push tts-hi.itpack /sdcard/Download/
```

Then open each file from the phone's file manager. The app registers the
`.itpack` extension and installs it.

**2. SD card or USB OTG**

Copy the packs onto removable storage, insert it, and open the files from the
file manager.

**3. Phone to phone over Bluetooth**

Send the `.itpack` files from a phone that already has them. Packs are
checksum-verified on install, so an interrupted transfer is rejected rather
than silently installed corrupt.

## What installation does

1. The zip is extracted to a staging directory, with canonical-path checks so a
   crafted archive cannot write outside the app's storage.
2. Every file's SHA-256 is compared against the manifest. Any mismatch aborts.
3. Required files for the task are checked (`model.onnx` plus `tokens.txt` for
   ASR, `graphemes.tsv` for TTS).
4. The staged directory replaces the existing pack atomically, keeping a
   `.backup-` copy until the swap succeeds, so a failed install never leaves a
   half-updated pack.

A verification failure is reported with the file that failed, not as a generic
error.

## Verifying before you leave the office

```bash
./tools/pack_builder.py verify dist/asr-hi.itpack
./tools/license_audit.py --packs 'dist/*.itpack' --gradle app/build.gradle.kts
```

The licence audit matters: it is what catches a non-commercial checkpoint
before it ships rather than after.

## Confirming the device is genuinely offline

```bash
adb shell svc data disable
adb shell svc wifi disable   # re-enable Wi-Fi for the Wi-Fi transport demo
```

Then run a full send-and-receive loop. Everything must still work. If any step
fails with aeroplane mode on, something in the pipeline is reaching out and
needs finding.

## Building the APK where there is no network

Gradle needs its dependencies. On a connected machine, once:

```bash
./gradlew --write-verification-metadata sha256 assembleLeanRelease
```

Then copy the Gradle cache (`~/.gradle/caches/modules-2`) to the offline
machine and build with `--offline`. Without this the first build fails on
dependency resolution, which is the single most common surprise when moving to
an air-gapped machine.
