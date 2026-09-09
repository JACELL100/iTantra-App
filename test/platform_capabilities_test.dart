import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/core/platform/platform_capabilities.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('org.itantra/platform_info');

  void mock(Map<String, Object?>? reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'capabilities') return reply;
      if (call.method == 'outputVolume') return 0.5;
      return null;
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('PlatformCapabilities', () {
    test('reads the Android capability set', () async {
      mock(<String, Object?>{
        'platform': 'android',
        'osVersion': '14',
        'deviceModel': 'Test Device',
        'canForceAlertVolume': true,
        'alertIgnoresSilentSwitch': true,
        'supportsRfcommClassic': true,
        'supportsBleBridge': true,
        'supportsWifiTcp': true,
        'canHostSoftAp': true,
        'backgroundAudioMode': true,
      });

      final PlatformCapabilities caps = await PlatformInfo(
        channel: channel,
      ).load();

      expect(caps.isAndroid, isTrue);
      expect(caps.canForceAlertVolume, isTrue);
      // On Android the alert-volume promise in the problem statement is a
      // guarantee, not advice.
      expect(caps.alertVolumeIsAdvisory, isFalse);
      expect(caps.supportsRfcommClassic, isTrue);
    });

    test('reads the iOS capability set and marks alert volume advisory',
        () async {
      mock(<String, Object?>{
        'platform': 'ios',
        'osVersion': '17.5',
        'deviceModel': 'iPhone',
        'canForceAlertVolume': false,
        'alertIgnoresSilentSwitch': true,
        'supportsRfcommClassic': false,
        'supportsBleBridge': true,
        'supportsWifiTcp': true,
        'canHostSoftAp': false,
        'backgroundAudioMode': true,
      });

      final PlatformCapabilities caps = await PlatformInfo(
        channel: channel,
      ).load();

      expect(caps.isIOS, isTrue);
      // The two real iOS limitations, asserted so a future change cannot
      // quietly start over-promising.
      expect(caps.alertVolumeIsAdvisory, isTrue);
      expect(caps.supportsRfcommClassic, isFalse);
      expect(caps.canHostSoftAp, isFalse);
      // What iOS can still guarantee.
      expect(caps.alertIgnoresSilentSwitch, isTrue);
      expect(caps.supportsBleBridge, isTrue);
    });

    test('falls back conservatively when the probe fails', () async {
      mock(null);

      final PlatformCapabilities caps = await PlatformInfo(
        channel: channel,
      ).load();

      // The fallback must never claim a capability it has not verified: a
      // false promise about alert loudness is worse than a warning.
      expect(caps.canForceAlertVolume, isFalse);
      expect(caps.supportsRfcommClassic, isFalse);
    });

    test('caches the result', () async {
      int calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls++;
        return <String, Object?>{
          'platform': 'android',
          'osVersion': '14',
          'deviceModel': 'Test',
          'canForceAlertVolume': true,
          'alertIgnoresSilentSwitch': true,
          'supportsRfcommClassic': true,
          'supportsBleBridge': true,
          'supportsWifiTcp': true,
          'canHostSoftAp': true,
          'backgroundAudioMode': true,
        };
      });

      final PlatformInfo info = PlatformInfo(channel: channel);
      await info.load();
      await info.load();

      expect(calls, 1);
    });
  });
}
