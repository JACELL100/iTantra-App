import AVFoundation
import Flutter

/// The device's own voice, behind `itantra/system_tts`.
///
/// The iOS counterpart of `SystemTtsPlugin.kt`, and it exists for the same
/// reason: a fresh install has to be able to speak before the user has
/// downloaded a voice pack.
///
/// The two platforms hand back audio differently, so this one returns raw
/// little-endian PCM and the Android one returns a WAV file. That difference is
/// contained in the Dart decoder, which accepts both - putting it here would
/// mean an `#if os` in the middle of the audio path.
///
/// `write(_:toBufferCallback:)` is used rather than `speak(_:)` so the audio
/// comes back as samples and can go through the app's own playback path. That
/// keeps one code path for playback, one place that handles audio focus and one
/// place that measures how long the sound took to start.
final class SystemTtsPlugin: NSObject {
  private let channel: FlutterMethodChannel
  private let synthesizer = AVSpeechSynthesizer()

  /// Buffers accumulated for the utterance currently being written.
  private var captured = Data()
  private var capturedSampleRate: Double = 0
  private var pending: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "itantra/system_tts", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  func detach() {
    channel.setMethodCallHandler(nil)
    synthesizer.stopSpeaking(at: .immediate)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "probe":
      probe(call, result: result)
    case "prepare":
      // Nothing to start: AVSpeechSynthesizer is ready on construction. Voice
      // data is downloaded by the system when a voice is first used, which is
      // why probe() is the honest answer to "can this phone speak Hindi".
      result(nil)
    case "synthesize":
      synthesize(call, result: result)
    case "stop":
      synthesizer.stopSpeaking(at: .immediate)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Reports which of the app's languages have an installed system voice.
  private func probe(_ call: FlutterMethodCall, result: FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    let candidates = arguments?["candidates"] as? [String] ?? []

    let installed = Set(
      AVSpeechSynthesisVoice.speechVoices().map {
        Self.canonical($0.language)
      })

    let usable = candidates.filter { installed.contains(Self.canonical($0)) }

    result([
      "available": !AVSpeechSynthesisVoice.speechVoices().isEmpty,
      "languages": usable,
    ])
  }

  private func synthesize(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    let text = (arguments?["text"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let tag = arguments?["languageTag"] as? String ?? "en-IN"
    let rate = arguments?["rate"] as? Double ?? 1.0

    guard !text.isEmpty else {
      result(
        FlutterError(code: "empty", message: "there is no text to speak", details: nil))
      return
    }

    if pending != nil {
      // Only one utterance is in flight at a time in this app, and overlapping
      // writes would interleave their buffers into a single nonsense waveform.
      result(
        FlutterError(
          code: "busy", message: "the device voice is already speaking", details: nil))
      return
    }

    guard let voice = Self.voice(for: tag) else {
      result(
        FlutterError(
          code: "missing-data",
          message:
            "this phone has no voice installed for \(tag). Add one in Settings, "
            + "Accessibility, Spoken Content, or install a voice pack.",
          details: nil))
      return
    }

    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    // AVSpeechUtterance's rate is 0...1 with 0.5 as the default, while this
    // app speaks in multiplier form. Converting rather than clamping, so a
    // slower alert rate survives the round trip.
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(min(max(rate, 0.25), 2.0))

    captured.removeAll(keepingCapacity: true)
    capturedSampleRate = 0
    pending = result

    synthesizer.write(utterance) { [weak self] buffer in
      guard let self else { return }
      guard let pcm = buffer as? AVAudioPCMBuffer else {
        self.finish(error: nil)
        return
      }

      if pcm.frameLength == 0 {
        // A zero-length buffer is the documented end-of-utterance marker.
        self.finish(error: nil)
        return
      }

      self.append(pcm)
    }
  }

  private func append(_ buffer: AVAudioPCMBuffer) {
    let format = buffer.format
    if capturedSampleRate == 0 {
      capturedSampleRate = format.sampleRate
    }

    let frames = Int(buffer.frameLength)
    let channels = Int(format.channelCount)

    if let float = buffer.floatChannelData {
      // Float32, interleaving down to mono as it goes.
      var out = [Int16](repeating: 0, count: frames)
      for channel in 0..<channels {
        let data = float[channel]
        for frame in 0..<frames {
          out[frame] = Self.clip(data[frame] / Float(channels))
        }
      }
      out.withUnsafeBufferPointer { captured.append(Data(buffer: $0)) }
      return
    }

    if let short = buffer.int16ChannelData {
      var out = [Int16](repeating: 0, count: frames)
      for channel in 0..<channels {
        let data = short[channel]
        for frame in 0..<frames {
          out[frame] = Int16(Int32(data[frame]) / Int32(channels))
        }
      }
      out.withUnsafeBufferPointer { captured.append(Data(buffer: $0)) }
    }
  }

  private func finish(error: FlutterError?) {
    // The completion callback fires on an audio thread; the platform channel
    // must be answered on the main one.
    DispatchQueue.main.async { [weak self] in
      guard let self, let callback = self.pending else { return }
      self.pending = nil

      if let error {
        callback(error)
        return
      }
      guard self.capturedSampleRate > 0, !self.captured.isEmpty else {
        callback(
          FlutterError(
            code: "empty", message: "the device voice produced no audio", details: nil))
        return
      }

      callback([
        "pcm": FlutterStandardTypedData(bytes: self.captured),
        "sampleRateHz": Int(self.capturedSampleRate),
      ])
      self.captured.removeAll(keepingCapacity: false)
    }
  }

  private static func clip(_ sample: Float) -> Int16 {
    let scaled = sample * 32767
    if scaled >= 32767 { return 32767 }
    if scaled <= -32768 { return -32768 }
    return Int16(scaled)
  }

  /// Finds a voice for a BCP-47 tag, falling back to the language without its
  /// region and then to the system default.
  ///
  /// Region matters: an `en-GB` request on a phone that only has `en-US`
  /// should still speak rather than report a missing voice, but an `hi-IN`
  /// request must not silently be answered by an English voice.
  private static func voice(for tag: String) -> AVSpeechSynthesisVoice? {
    let canonical = Self.canonical(tag)
    if let exact = AVSpeechSynthesisVoice(language: canonical),
      Self.canonical(exact.language) == canonical
    {
      return exact
    }

    let language = String(canonical.split(separator: "-").first ?? "")
    let sameLanguage = AVSpeechSynthesisVoice.speechVoices().first {
      Self.canonical($0.language).hasPrefix(language + "-")
    }
    return sameLanguage
  }

  private static func canonical(_ tag: String) -> String {
    tag.replacingOccurrences(of: "_", with: "-").lowercased()
  }
}
