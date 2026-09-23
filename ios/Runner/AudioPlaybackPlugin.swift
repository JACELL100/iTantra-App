import AVFoundation
import Flutter
import Foundation

/// Streaming PCM playback with audio-session control.
///
/// The iOS counterpart of `AudioPlaybackPlugin.kt`, and the reason it is native
/// code at all is alerts. To be heard one must:
///
///  - take the audio session exclusively, so other audio is interrupted;
///  - play through a category that ignores the ringer switch, so a silenced
///    phone still speaks;
///  - route to the loudspeaker for an alert, which is the only part of "play
///    at maximum volume" iOS allows a third-party app to influence. Raising
///    the output volume itself is not possible for any app on this platform,
///    which is why `PlatformInfoPlugin` reports `canForceAlertVolume: false`
///    and the UI says so rather than promising otherwise;
///  - report the monotonic instant the first samples became audible, which is
///    one end of the measured phone-to-phone latency.
///
/// Ordinary messages share the path with a non-alert category, so a voice note
/// does not seize the session from someone's navigation prompt.
final class AudioPlaybackPlugin: NSObject {

  private static let channelName = "org.itantra/audio_playback"

  /// Serial: scheduling and teardown must not interleave, or a chunk can be
  /// scheduled onto a node that has already been stopped.
  private let queue = DispatchQueue(label: "org.itantra.playback")
  private let drainQueue = DispatchQueue(label: "org.itantra.playback.drain")

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()

  private var session: Int = 0
  private var priority: String = "normal"

  private var format: AVAudioFormat?
  private var rendered: AVAudioFramePosition = 0
  private var started = false
  private var reportedAudible = false

  /// Guards the polling loop when a drain is asked to wait for audio that will
  /// never arrive because the session was torn down underneath it.
  private var generation = 0

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    engine.attach(player)

    let channel = FlutterMethodChannel(
      name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  // MARK: - Method channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "start":
      guard let requested = arguments["session"] as? Int else {
        result(FlutterError(code: "args", message: "session is required", details: nil))
        return
      }
      let level = arguments["priority"] as? String ?? "normal"
      result(["granted": start(session: requested, priority: level)])

    case "write":
      guard
        let requested = arguments["session"] as? Int,
        let typed = arguments["pcm"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "args", message: "session and pcm are required", details: nil))
        return
      }
      let rate = arguments["sampleRateHz"] as? Int ?? 22050
      let last = arguments["last"] as? Bool ?? false

      // A late write from a session that was pre-empted. Dropped rather than
      // played, or an interrupted message would resume behind the alert that
      // replaced it.
      guard requested == session else {
        result(["audible": Int64(0)])
        return
      }
      result(["audible": write(typed.data, sampleRateHz: rate, last: last)])

    case "drain":
      // Waits for the buffer to empty, which is what stops the microphone
      // reopening over the tail of a sentence. It must not run on the platform
      // thread, and it must not run on the scheduling queue either, or the
      // next chunk would be stuck behind it.
      scheduleDrain()
      result(nil)

    case "stop":
      release()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Session control

  private func start(session requested: Int, priority requested_priority: String) -> Bool {
    let isAlert = requested_priority == "distress" || requested_priority == "warning"

    if started {
      // A warning does not pre-empt a distress call already in progress.
      if priority == "distress" && requested_priority != "distress" {
        return false
      }
      release()
    }

    do {
      try activateSession(isAlert: isAlert, priority: requested_priority)
    } catch {
      // A refused session is not a reason to stay silent for an alert: the
      // engine below will still play into whatever category is active.
      if !isAlert {
        return false
      }
    }

    session = requested
    priority = requested_priority
    reportedAudible = false
    rendered = 0
    started = true
    generation += 1
    return true
  }

  /// Configures the shared audio session for the kind of message about to play.
  private func activateSession(isAlert: Bool, priority: String) throws {
    let audioSession = AVAudioSession.sharedInstance()

    if isAlert {
      // `.playback` is the only category that reliably ignores the ringer
      // switch, and it is what makes an alert audible on a silenced phone.
      try audioSession.setCategory(
        .playback, mode: .default, options: [.duckOthers])
      // Distress goes to the loudspeaker regardless of what is plugged in or
      // paired: a message routed to a headset nobody is wearing is a message
      // that was never delivered. A warning follows whatever route the user
      // chose, because it is not an emergency.
      if priority == "distress" {
        try? audioSession.overrideOutputAudioPort(.speaker)
      }
    } else {
      // `.playAndRecord` because capture must be able to resume the moment the
      // floor changes hands, and switching category mid-session is what causes
      // the audible click this avoids.
      try audioSession.setCategory(
        .playAndRecord,
        mode: .default,
        options: [.allowBluetooth, .defaultToSpeaker])
    }

    try audioSession.setActive(true, options: [])
  }

  // MARK: - Writing

  /// Converts one Int16 chunk and schedules it, returning the monotonic
  /// microsecond at which sound actually started, or `0` for every chunk after
  /// the first.
  ///
  /// It must be an integer. This value is the far end of the measured
  /// phone-to-phone latency and Dart reads it as one; the Android plugin
  /// returning a boolean here once cost a `TypeError` on the first chunk of
  /// every message.
  private func write(_ data: Data, sampleRateHz rate: Int, last: Bool) -> Int64 {
    guard started else { return 0 }

    let sampleCount = data.count / MemoryLayout<Int16>.size
    guard sampleCount > 0 else {
      // An empty final chunk still marks the end of an utterance, so the tail
      // wait is still scheduled even though there are no samples to play.
      if last { scheduleDrain() }
      return 0
    }

    guard
      let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(rate),
        channels: 1,
        interleaved: false)
    else { return 0 }

    if format?.sampleRate != audioFormat.sampleRate {
      // The synthesiser's rate changed between messages; the graph has to be
      // reconnected, because a node's format is fixed when it is connected.
      // Disconnecting first avoids a stale connection being left in place.
      if format != nil {
        engine.disconnectNodeOutput(player)
      }
      format = audioFormat
      engine.connect(player, to: engine.mainMixerNode, format: audioFormat)
    }

    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(sampleCount))
    else { return 0 }
    buffer.frameLength = AVAudioFrameCount(sampleCount)

    guard let destination = buffer.floatChannelData?[0] else { return 0 }

    data.withUnsafeBytes { raw in
      // Assembled byte by byte rather than with `bindMemory`, which is only
      // defined on correctly aligned memory and `Data` makes no such promise.
      // The wire format is little-endian because the Dart side writes it with a
      // `ByteData` view of an `Int16List`, so the order is fixed rather than
      // host-dependent.
      for index in 0..<sampleCount {
        let low = UInt16(raw[index * 2])
        let high = UInt16(raw[index * 2 + 1])
        let value = Int16(bitPattern: low | (high << 8))
        // 32768 rather than 32767 so -32768 maps to exactly -1.0.
        destination[index] = Float(value) / 32768.0
      }
    }

    return schedule(buffer)
  }

  private func schedule(_ buffer: AVAudioPCMBuffer) -> Int64 {
    if !engine.isRunning {
      // Also the self-healing path: a phone call or another app can take the
      // session away, which stops the engine without telling us. Restarting on
      // the next chunk means the message continues rather than going silent.
      do {
        engine.prepare()
        try engine.start()
      } catch {
        return 0
      }
    }

    if !player.isPlaying {
      player.play()
    }

    player.scheduleBuffer(buffer) { [weak self] in
      guard let self else { return }
      self.queue.async {
        self.rendered += AVAudioFramePosition(buffer.frameLength)
      }
    }

    var audibleMicros: Int64 = 0
    if !reportedAudible {
      reportedAudible = true
      audibleMicros = Int64(DispatchTime.now().uptimeNanoseconds / 1000)
    }

    // The Dart controller issues its own drain after the chunk stream ends.
    // Scheduling one here as well means the tail is still awaited if that call
    // is ever skipped, and because it runs on the drain queue rather than the
    // platform thread it cannot stall the UI. Two concurrent drains are
    // harmless: both are only waiting for the same playback head to catch up.
    if last { scheduleDrain() }

    return audibleMicros
  }

  private func scheduleDrain() {
    let expected = generation
    drainQueue.async { [weak self] in
      self?.drain(generation: expected)
    }
  }

  /// Blocks until the scheduled audio has been rendered.
  ///
  /// Polls the node's own sample position rather than sleeping for a computed
  /// duration: a fixed sleep either truncates the tail of a word or adds dead
  /// air, and the position is ground truth.
  private func drain(generation expected: Int) {
    let deadline = Date().addingTimeInterval(30)

    while true {
      var done = false
      var total: AVAudioFramePosition = 0

      queue.sync {
        total = rendered
        if let nodeTime = player.lastRenderTime,
          let playerTime = player.playerTime(forNodeTime: nodeTime)
        {
          done = playerTime.sampleTime >= total
        } else {
          // The node has been stopped, so everything it was given has either
          // played or been discarded.
          done = !player.isPlaying
        }
      }

      if done || expected != generation || Date() > deadline {
        return
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  // MARK: - Teardown

  private func release() {
    queue.sync {
      generation += 1
      started = false
      player.stop()
      engine.stop()
      format = nil
      rendered = 0
      reportedAudible = false
      session = 0
      priority = "normal"
    }

    let audioSession = AVAudioSession.sharedInstance()
    // Best effort: another component may already own the session. Failing to
    // deactivate is not a reason to leave the engine running.
    try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
  }

  func detach() {
    release()
  }
}
