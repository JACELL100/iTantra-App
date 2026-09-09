import CoreBluetooth
import Flutter
import Foundation

/// Bluetooth Classic RFCOMM does not exist for third-party iOS apps.
///
/// `ExternalAccessory` is the only route to a Classic serial link and it
/// requires MFi certification of the *accessory*, which cannot be obtained
/// for an ordinary phone-to-phone link. Rather than pretend otherwise, this
/// plugin answers on `org.itantra/rfcomm` with a well-defined
/// `unsupported` error, and Dart's `TransportSelector` treats that as the
/// signal to fall back to the BLE GATT bridge (`ble_bridge_transport.dart`)
/// or to Wi-Fi TCP.
///
/// The failure is explicit for a reason: a silent fallback would make an
/// iPhone look like it had connected over Classic Bluetooth when it had not,
/// and the resulting latency numbers would be attributed to the wrong
/// transport.
final class RfcommPlugin: NSObject {

  private static let methodChannelName = "org.itantra/rfcomm"
  private static let eventChannelName = "org.itantra/rfcomm/events"

  private var eventSink: FlutterEventSink?

  init(messenger: FlutterBinaryMessenger) {
    super.init()

    let methods = FlutterMethodChannel(
      name: Self.methodChannelName, binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    let events = FlutterEventChannel(
      name: Self.eventChannelName, binaryMessenger: messenger)
    events.setStreamHandler(self)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listen", "connect", "write":
      result(FlutterError(
        code: "unsupported",
        message:
          "Bluetooth Classic RFCOMM is unavailable on iOS without MFi "
          + "certification. Use the BLE bridge or Wi-Fi transport.",
        details: ["platform": "ios", "fallback": "ble"]))

    case "close":
      // Closing something that was never open is a no-op, not an error, so
      // shared teardown paths in Dart do not need a platform check.
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func detach() {
    eventSink = nil
  }
}

extension RfcommPlugin: FlutterStreamHandler {
  func onListen(
    withArguments arguments: Any?, eventSink: @escaping FlutterEventSink
  ) -> FlutterError? {
    self.eventSink = eventSink
    // Announced immediately so Dart can mark the transport unavailable at
    // startup instead of discovering it when a user presses talk.
    eventSink(["event": "error", "message": "rfcomm-unsupported"])
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
