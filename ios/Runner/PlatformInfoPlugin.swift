import AVFoundation
import Flutter
import Foundation
import UIKit

/// Reports what this platform can and cannot actually do, so Dart adapts at
/// runtime instead of hard-coding `Platform.isIOS` checks throughout the
/// codebase.
///
/// The two fields that matter are `canForceAlertVolume` and
/// `supportsRfcommClassic`, both false on iOS. Dart uses them to decide
/// whether to show the "alerts may be quiet" warning and whether to offer
/// Bluetooth Classic in the transport picker. Answering honestly here is
/// what keeps the UI truthful on both platforms.
final class PlatformInfoPlugin: NSObject {

  private static let channelName = "org.itantra/platform_info"

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    let channel = FlutterMethodChannel(
      name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      result([
        "platform": "ios",
        "osVersion": UIDevice.current.systemVersion,
        "deviceModel": UIDevice.current.model,
        // iOS has no alarm stream and no volume-setting API for third-party
        // apps. An alert can duck other audio and ignore the mute switch,
        // but it plays at whatever level the user has set.
        "canForceAlertVolume": false,
        // .playback ignores the ringer switch, which is the one meaningful
        // guarantee available.
        "alertIgnoresSilentSwitch": true,
        // MFi-only; see RfcommPlugin.
        "supportsRfcommClassic": false,
        "supportsBleBridge": true,
        "supportsWifiTcp": true,
        // iOS cannot create a hotspot programmatically; it can only join one.
        "canHostSoftAp": false,
        // The `audio` background mode keeps the session alive; there is no
        // foreground-service equivalent and none is needed.
        "backgroundAudioMode": true,
      ])

    case "outputVolume":
      // Surfaced in diagnostics so a demo can show whether the device is
      // actually loud enough for alerts to be relied on.
      result(Double(AVAudioSession.sharedInstance().outputVolume))

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
