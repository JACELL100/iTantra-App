import AVFoundation
import Flutter
import Foundation

/// Microphone capture, framed and timestamped on the native side.
///
/// The iOS counterpart of `AudioCapturePlugin.kt`, and deliberately identical
/// in behaviour rather than merely similar: the Dart side must not be able to
/// tell which platform it is on beyond the sample rate it is told to expect.
/// Same 20 ms frame, same monotonic timestamp taken where the samples are read,
/// same "report what was actually opened" contract.
///
/// Three choices worth stating:
///
///  - **`AVAudioSession` mode `.measurement`.** This is the closest iOS has to
///    an unprocessed input: it turns off the system's automatic gain control,
///    noise suppression and echo cancellation. Those are tuned to make a human
///    listener comfortable, and they actively harm an acoustic model, because
///    gain control pumps the noise floor in exactly the pauses where the voice
///    activity detector has to make its decision.
///  - **The hardware rate is reported, not assumed.** `AVAudioSession` fixes
///    the input rate (usually 48 kHz) and an app cannot choose 16 kHz.
///    Resampling once, in Dart, in one place, is easier to keep honest than
///    teaching every device to open at the recogniser's rate.
///  - **Frames are re-chunked to exactly 20 ms.** A tap delivers whatever the
///    hardware hands it, which is neither fixed nor 20 ms. The accumulator
///    below is what makes the two platforms interchangeable.
final class AudioCapturePlugin: NSObject {

  private static let methodChannelName = "org.itantra/audio_capture"
  private static let eventChannelName = "org.itantra/audio_capture/frames"

  /// The frame length the whole pipeline is sized around, in milliseconds.
  private static let frameMillis = 20

  private let engine = AVAudioEngine()

  /// Guards everything below, because the tap callback runs on a real-time
  /// audio thread while `stop` and the event-channel callbacks run on the
  /// platform thread. An `NSLock` rather than a dispatch queue on purpose: the
  /// audio thread must not allocate or block, and a lock held for the few
  /// microseconds it takes to append one frame is the cheapest correct option.
  private let lock = NSLock()

  private var eventSink: FlutterEventSink?
  private var running = false
  private var openFormat: AVAudioFormat?

  /// Samples converted but not yet a whole frame.
  private var pending: [Int16] = []
  private var frameSamples = 0
  private var converter: AVAudioConverter?

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

  // MARK: - Method channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      do {
        let format = try start()
        result([
          "sampleRateHz": Int(format.sampleRate),
          "channels": Int(format.channelCount),
        ])
      } catch {
        result(Self.failure(error))
      }

    case "stop":
      stop()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func failure(_ error: Error) -> FlutterError {
    FlutterError(
      code: "capture",
      message: "The microphone could not be opened: \(error.localizedDescription)",
      details: nil)
  }

  // MARK: - Capture

  @discardableResult
  private func start() throws -> AVAudioFormat {
    lock.lock()
    let alreadyOpen = running
    let existing = openFormat
    lock.unlock()

    if alreadyOpen, let existing { return existing }

    let session = AVAudioSession.sharedInstance()
    // `.measurement` disables system signal processing; see the class comment.
    // `.allowBluetooth` keeps a headset usable, which is also the reliable
    // configuration for simultaneous capture and playback.
    try session.setCategory(
      .playAndRecord,
      mode: .measurement,
      options: [.allowBluetooth, .defaultToSpeaker])
    try session.setActive(true, options: [])

    let input = engine.inputNode
    // Asking for nil means "the hardware's own format", which is the only
    // format this node accepts.
    let tapFormat = input.outputFormat(forBus: 0)
    guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
      throw NSError(
        domain: "org.itantra.capture", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "no microphone input is available"])
    }

    // Mono Int16 at the hardware rate: format and channel conversion only, no
    // sample-rate conversion. Built once per capture, so the tap callback does
    // no format analysis at all.
    guard
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: tapFormat.sampleRate,
        channels: 1,
        interleaved: true)
    else {
      throw NSError(
        domain: "org.itantra.capture", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "could not build a capture format"])
    }

    let built = AVAudioConverter(from: tapFormat, to: outputFormat)

    lock.lock()
    converter = built
    frameSamples = max(1, Int(tapFormat.sampleRate) * Self.frameMillis / 1000)
    pending.removeAll(keepingCapacity: true)
    openFormat = outputFormat
    running = true
    lock.unlock()

    // 1600 frames is about 33 ms at 48 kHz: small enough to keep the input path
    // short, large enough that the tap is not woken every few samples.
    input.installTap(onBus: 0, bufferSize: 1600, format: tapFormat) {
      [weak self] buffer, _ in
      self?.consume(buffer)
    }

    engine.prepare()
    do {
      try engine.start()
    } catch {
      // Leave nothing half-open: a failed start must not leave a tap behind, or
      // the next attempt installs a second one and the input is doubled.
      input.removeTap(onBus: 0)
      lock.lock()
      running = false
      converter = nil
      openFormat = nil
      lock.unlock()
      throw error
    }

    return outputFormat
  }

  /// Converts one tap buffer and emits every whole frame it completes.
  private func consume(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    defer { lock.unlock() }

    guard running, let converter else { return }

    let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
    guard
      let converted = AVAudioPCMBuffer(
        pcmFormat: converter.outputFormat, frameCapacity: capacity)
    else { return }

    var supplied = false
    var conversionError: NSError?
    let status = converter.convert(to: converted, error: &conversionError) {
      _, outStatus in
      if supplied {
        // Nothing left in this tap buffer. `.noDataNow` rather than
        // `.endOfStream`, because more buffers are coming on the next callback.
        outStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      outStatus.pointee = .haveData
      return buffer
    }

    guard status == .haveData || status == .inputRanDry else { return }
    guard converted.frameLength > 0, let channel = converted.int16ChannelData else {
      return
    }

    // The clock is read here, where the samples were just read, rather than
    // after the frame has crossed the platform channel: taking it later would
    // fold Dart's scheduling jitter into a number the evaluation scores.
    // `uptimeNanoseconds` is monotonic and, unlike a wall clock, cannot be
    // moved under us mid-session.
    let micros = Int64(DispatchTime.now().uptimeNanoseconds / 1000)

    let samples = channel[0]
    let count = Int(converted.frameLength)
    var offset = 0

    while offset < count {
      let take = min(frameSamples - pending.count, count - offset)
      pending.append(
        contentsOf: UnsafeBufferPointer(start: samples + offset, count: take))
      offset += take

      if pending.count == frameSamples {
        emit(pending, micros: micros)
        pending.removeAll(keepingCapacity: true)
      }
    }
  }

  private func emit(_ samples: [Int16], micros: Int64) {
    // `eventSink` is read under the lock, but the call itself happens on the
    // main thread, because Flutter's channel expects its sink to be used from
    // one thread and the audio thread is not a place to encode a message.
    guard let sink = eventSink else { return }

    let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    let payload: [String: Any] = [
      "pcm": FlutterStandardTypedData(bytes: bytes),
      "monotonicMicros": micros,
    ]

    DispatchQueue.main.async {
      sink(payload)
    }
  }

  private func stop() {
    lock.lock()
    let wasRunning = running
    running = false
    converter = nil
    openFormat = nil
    pending.removeAll(keepingCapacity: false)
    lock.unlock()

    guard wasRunning else { return }

    // Removed outside the lock: `removeTap` waits for any in-flight callback to
    // return, and that callback needs the lock.
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()

    // The session is deliberately left active. Whether it should be turned off
    // is a decision for playback or for the next capture, not for teardown, and
    // deactivating here would cut off a message that is still draining.
  }
}

// MARK: - Event channel

extension AudioCapturePlugin: FlutterStreamHandler {

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    lock.lock()
    eventSink = events
    lock.unlock()

    // The subscription and the method call can arrive in either order; a
    // capture that is already open is adopted rather than restarted, because
    // two taps on one input bus is undefined behaviour.
    do {
      _ = try start()
    } catch {
      return Self.failure(error)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    lock.lock()
    eventSink = nil
    lock.unlock()
    stop()
    return nil
  }

  /// Called when the app is being torn down.
  func detach() {
    lock.lock()
    eventSink = nil
    lock.unlock()
    stop()
  }
}
