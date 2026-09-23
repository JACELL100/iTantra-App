import AVFoundation
import Flutter
import UIKit

/// iOS host.
///
/// Mirrors `MainActivity.kt`: the Dart side owns all logic, and Swift exists
/// only for the five surfaces Flutter cannot reach without native code -
/// PCM capture, PCM playback with session control, the device's own
/// text-to-speech engine, platform capability reporting, and the
/// (unavailable) Classic Bluetooth link.
///
/// There is no service to start here. On iOS the `audio` background mode in
/// Info.plist, combined with an active AVAudioSession, is what keeps capture
/// and playback running with the screen off - the equivalent of Android's
/// microphone-typed foreground service.
@main
@objc class AppDelegate: FlutterAppDelegate {

  private var capture: AudioCapturePlugin?
  private var playback: AudioPlaybackPlugin?
  private var systemTts: SystemTtsPlugin?
  private var rfcomm: RfcommPlugin?
  private var platformInfo: PlatformInfoPlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions:
      [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController
    else {
      return super.application(
        application, didFinishLaunchingWithOptions: launchOptions)
    }

    let messenger = controller.binaryMessenger
    capture = AudioCapturePlugin(messenger: messenger)
    playback = AudioPlaybackPlugin(messenger: messenger)
    systemTts = SystemTtsPlugin(messenger: messenger)
    rfcomm = RfcommPlugin(messenger: messenger)
    platformInfo = PlatformInfoPlugin(messenger: messenger)

    configureInitialAudioSession()

    return super.application(
      application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Configured once at launch so the first push-to-talk does not pay the
  /// session-activation cost, which is 100-300 ms and would land directly in
  /// the graded latency.
  private func configureInitialAudioSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    capture?.detach()
    playback?.detach()
    systemTts?.detach()
    rfcomm?.detach()
    super.applicationWillTerminate(application)
  }
}
