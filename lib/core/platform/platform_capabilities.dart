import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../util/log.dart';

/// What the host platform can actually do.
///
/// The values come from native code rather than from `Platform.isIOS` checks
/// scattered through the codebase, for two reasons. First, some of these are
/// device- and OS-version-dependent, not platform-dependent. Second, keeping
/// the answers in one place means the UI can *tell the user the truth* about
/// a limitation instead of failing silently when they need it most - which,
/// for a distress alert, is the whole point.
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.platform,
    required this.osVersion,
    required this.deviceModel,
    required this.canForceAlertVolume,
    required this.alertIgnoresSilentSwitch,
    required this.supportsRfcommClassic,
    required this.supportsBleBridge,
    required this.supportsWifiTcp,
    required this.canHostSoftAp,
    required this.backgroundAudioMode,
  });

  /// `"android"` or `"ios"`.
  final String platform;
  final String osVersion;
  final String deviceModel;

  /// Whether an alert can be forced to a known-audible level.
  ///
  /// True on Android, which exposes the alarm stream and `setStreamVolume`.
  /// False on iOS, where a third-party app cannot change the output volume
  /// at all. When this is false the UI must warn the user, because "alert
  /// messages will be announced at the highest volume" cannot be guaranteed.
  final bool canForceAlertVolume;

  /// Whether an alert is heard on a device whose ringer is silenced.
  ///
  /// True on both platforms, by different means: Android's alarm stream
  /// bypasses the ringer, and iOS's `.playback` category ignores the mute
  /// switch.
  final bool alertIgnoresSilentSwitch;

  /// Bluetooth Classic RFCOMM. Android only; iOS restricts Classic serial
  /// links to MFi-certified accessories.
  final bool supportsRfcommClassic;

  final bool supportsBleBridge;
  final bool supportsWifiTcp;

  /// Whether the device can *create* the local network rather than only join
  /// one. Android can via Wi-Fi Direct / local-only hotspot; iOS cannot, so
  /// in a mixed pair the Android phone must host.
  final bool canHostSoftAp;

  /// Whether audio keeps running with the screen off.
  final bool backgroundAudioMode;

  bool get isIOS => platform == 'ios';
  bool get isAndroid => platform == 'android';

  /// True when alert loudness depends on the user's volume setting, so the
  /// UI should say so rather than imply a guarantee it cannot keep.
  bool get alertVolumeIsAdvisory => !canForceAlertVolume;

  /// Conservative defaults used if the platform channel is unavailable, for
  /// example in unit tests. Assumes the *weaker* platform so nothing
  /// over-promises.
  static PlatformCapabilities fallback() => PlatformCapabilities(
        platform: Platform.isIOS ? 'ios' : 'android',
        osVersion: 'unknown',
        deviceModel: 'unknown',
        canForceAlertVolume: false,
        alertIgnoresSilentSwitch: false,
        supportsRfcommClassic: false,
        supportsBleBridge: true,
        supportsWifiTcp: true,
        canHostSoftAp: false,
        backgroundAudioMode: true,
      );

  static PlatformCapabilities _fromMap(Map<Object?, Object?> map) {
    bool flag(String key, {bool orElse = false}) =>
        (map[key] as bool?) ?? orElse;
    String text(String key) => (map[key] as String?) ?? 'unknown';

    return PlatformCapabilities(
      platform: text('platform'),
      osVersion: text('osVersion'),
      deviceModel: text('deviceModel'),
      canForceAlertVolume: flag('canForceAlertVolume'),
      alertIgnoresSilentSwitch: flag('alertIgnoresSilentSwitch'),
      supportsRfcommClassic: flag('supportsRfcommClassic'),
      supportsBleBridge: flag('supportsBleBridge', orElse: true),
      supportsWifiTcp: flag('supportsWifiTcp', orElse: true),
      canHostSoftAp: flag('canHostSoftAp'),
      backgroundAudioMode: flag('backgroundAudioMode', orElse: true),
    );
  }
}

/// Loads [PlatformCapabilities] from the host, once.
class PlatformInfo {
  PlatformInfo({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('org.itantra/platform_info');

  final MethodChannel _channel;
  PlatformCapabilities? _cached;

  PlatformCapabilities? get cached => _cached;

  Future<PlatformCapabilities> load() async {
    final PlatformCapabilities? existing = _cached;
    if (existing != null) return existing;

    try {
      final Map<Object?, Object?>? map =
          await _channel.invokeMapMethod<Object?, Object?>('capabilities');
      if (map == null) throw MissingPluginException('no capabilities');
      final PlatformCapabilities loaded = PlatformCapabilities._fromMap(map);
      _cached = loaded;
      ItLog.i('platform',
          '${loaded.platform} ${loaded.osVersion} on ${loaded.deviceModel}');
      return loaded;
    } catch (error) {
      // Falling back rather than throwing: a missing capability probe must
      // not stop the app from working as a radio.
      ItLog.w('platform', 'capability probe failed ($error); using fallback');
      final PlatformCapabilities loaded = PlatformCapabilities.fallback();
      _cached = loaded;
      return loaded;
    }
  }

  /// Current output volume, 0..1, or null where the platform does not report
  /// it. Shown in diagnostics so a demo can prove whether a device is loud
  /// enough for alerts.
  Future<double?> outputVolume() async {
    try {
      return await _channel.invokeMethod<double>('outputVolume');
    } catch (_) {
      return null;
    }
  }
}
