import AVFoundation
import Flutter
import Foundation

/// iOS side of the `com.airfi.talkback/audio` MethodChannel — full-duplex
/// intercom over ONE shared AVAudioEngine.
///
/// Dart wire format is Int16 PCM, 8 kHz mono (G.711A conversion happens in
/// Dart). Internally the engine runs Float32 with converters at both ends.
///
/// Key design vs the prior multi-engine app: the mic tap is installed BEFORE
/// the engine starts, so input + output HAL units arm together — that's the
/// condition the input pull needs. Voice-processing (VPIO) is enabled for HW
/// echo-cancellation and reliable input arming. The tap runs continuously; the
/// `isRecording` flag only gates whether captured frames are forwarded to Dart,
/// so toggling talk never restarts the engine (no route churn, no dead tap).
final class TalkbackAudioPlugin {
  private let channel: FlutterMethodChannel
  private let engine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()

  private var wireFormat: AVAudioFormat?       // Int16 8k mono (Dart-facing)
  private var processingFormat: AVAudioFormat? // Float32 8k mono (mixer)
  private var playbackConverter: AVAudioConverter? // wire -> processing
  private var recordConverter: AVAudioConverter?   // mic native -> wire

  private var sampleRate: Double = 8000
  private var channelCount: UInt32 = 1
  private var isRecording = false
  private var playbackVolume: Float = 1.0
  private var tapInstalled = false
  private var tapFireCount = 0

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.airfi.talkback/audio", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  // MARK: - Dispatch

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      let a = call.arguments as? [String: Any]
      let sr = (a?["sampleRate"] as? NSNumber)?.doubleValue ?? 8000
      let ch = (a?["channels"] as? NSNumber)?.uint32Value ?? 1
      if let reason = initializeAudio(sampleRate: sr, channels: ch) {
        result(FlutterError(code: "INIT_FAILED", message: reason, details: nil))
      } else {
        result(true)
      }
    case "startRecording": result(startRecording())
    case "stopRecording": result(stopRecording())
    case "playAudio":
      guard let a = call.arguments as? [String: Any],
            let d = a["audioData"] as? FlutterStandardTypedData else { result(false); return }
      result(playAudio(data: d.data))
    case "stopPlayback": result(true)
    case "setVolume":
      let v = ((call.arguments as? [String: Any])?["volume"] as? NSNumber)?.intValue ?? 100
      result(setVolume(v))
    case "enableSpeaker":
      let e = ((call.arguments as? [String: Any])?["enable"] as? Bool) ?? true
      result(enableSpeaker(e))
    case "release":
      releaseAudio(); result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Lifecycle

  /// Returns nil on success, else a human-readable failure reason (surfaced to
  /// Dart as a FlutterError so the in-app error shows the real cause).
  private func initializeAudio(sampleRate sr: Double, channels ch: UInt32) -> String? {
    releaseAudio()
    sampleRate = sr > 0 ? sr : 8000
    channelCount = ch >= 2 ? 2 : 1

    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .voiceChat,
                              options: [.defaultToSpeaker, .allowBluetooth])
      try session.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      let r = "session error: \(error.localizedDescription)"
      diag(r); return r
    }

    guard let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                   channels: channelCount, interleaved: true),
          let processing = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: channelCount, interleaved: false) else {
      let r = "format build failed"; diag(r); return r
    }
    wireFormat = wire
    processingFormat = processing
    playbackConverter = AVAudioConverter(from: wire, to: processing)

    let input = engine.inputNode
    // Voice processing: HW echo cancellation + reliably arms the input HAL.
    // Must be set while the engine is stopped. Best-effort — fall back if it
    // throws (older HW / unusual routes).
    if #available(iOS 13.0, *) {
      do { try input.setVoiceProcessingEnabled(true) }
      catch { diag("VPIO enable failed (continuing): \(error.localizedDescription)") }
    }

    if playerNode.engine != nil { engine.detach(playerNode) }
    engine.attach(playerNode)
    engine.connect(playerNode, to: engine.mainMixerNode, format: processing)
    engine.mainMixerNode.outputVolume = playbackVolume

    // prepare() arms the IO units so inputNode reports its real hardware format.
    // Enabling VPIO can leave outputFormat at 0 Hz until the graph is prepared,
    // which made the pre-start tap install fail. Prepare first, then tap.
    engine.prepare()

    // Install the mic tap BEFORE first start so input + output arm together.
    if !installRecordTap() {
      let r = "tap install failed (inputSR=\(input.outputFormat(forBus: 0).sampleRate))"
      diag(r); return r
    }

    do { try engine.start() }
    catch { let r = "engine start error: \(error.localizedDescription)"; diag(r); return r }
    playerNode.play()
    diag("initialized inputSR=\(input.outputFormat(forBus: 0).sampleRate) cat=\(session.category.rawValue)")
    return nil
  }

  private func releaseAudio() {
    if tapInstalled, engine.inputNode.engine != nil {
      engine.inputNode.removeTap(onBus: 0)
    }
    tapInstalled = false
    isRecording = false
    if playerNode.engine != nil {
      if playerNode.isPlaying { playerNode.stop() }
      engine.detach(playerNode)
    }
    if engine.isRunning { engine.stop() }
    if #available(iOS 13.0, *) {
      try? engine.inputNode.setVoiceProcessingEnabled(false)
    }
    recordConverter = nil
    let session = AVAudioSession.sharedInstance()
    try? session.setActive(false, options: .notifyOthersOnDeactivation)
    // Hand back as .playback so live ATP tiles can re-activate their audio.
    try? session.setCategory(.playback)
  }

  // MARK: - Recording (tap always runs; flag gates forwarding)

  private func startRecording() -> Bool {
    // Self-heal: the engine or tap can be torn down between initialize() and the
    // first talk press (route change, session interruption, ATP tile grabbing
    // the audio session). Re-arm rather than fail with tx=false.
    if !tapInstalled {
      if !installRecordTap() { diag("startRecording: tap reinstall failed"); return false }
    }
    if !engine.isRunning {
      engine.prepare()
      do { try engine.start() }
      catch { diag("startRecording: engine restart error: \(error.localizedDescription)"); return false }
    }
    isRecording = true
    diag("startRecording OK engineRunning=\(engine.isRunning) tapInstalled=\(tapInstalled)")
    return true
  }

  private func stopRecording() -> Bool {
    isRecording = false
    return true
  }

  @discardableResult
  private func installRecordTap() -> Bool {
    guard let wire = wireFormat else { return false }
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0 else { return false }
    if tapInstalled { input.removeTap(onBus: 0) }
    recordConverter = AVAudioConverter(from: inputFormat, to: wire)
    tapFireCount = 0
    input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
      guard let self = self, let conv = self.recordConverter, let wire = self.wireFormat else { return }
      if self.tapFireCount < 3 {
        self.tapFireCount += 1
        let n = self.tapFireCount, f = buffer.frameLength
        DispatchQueue.main.async { [weak self] in
          self?.channel.invokeMethod("tbDiag", arguments: "TAP FIRED #\(n) frames=\(f)")
        }
      }
      guard self.isRecording else { return } // captured but not transmitting
      let ratio = wire.sampleRate / buffer.format.sampleRate
      let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
      guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity) else { return }
      var consumed = false
      var err: NSError?
      let status = conv.convert(to: out, error: &err) { _, s in
        if consumed { s.pointee = .noDataNow; return nil }
        consumed = true; s.pointee = .haveData; return buffer
      }
      if status == .error || err != nil { return }
      self.sendChunk(buffer: out)
    }
    tapInstalled = true
    return true
  }

  private func sendChunk(buffer: AVAudioPCMBuffer) {
    guard let ch0 = buffer.int16ChannelData else { return }
    let frames = Int(buffer.frameLength)
    let cc = Int(buffer.format.channelCount)
    let byteCount = frames * cc * MemoryLayout<Int16>.size
    if byteCount == 0 { return }
    var data = Data(count: byteCount)
    data.withUnsafeMutableBytes { raw in
      guard let dst = raw.bindMemory(to: Int16.self).baseAddress else { return }
      if cc == 1 { memcpy(dst, ch0[0], byteCount) }
      else { for fr in 0..<frames { for c in 0..<cc { dst[fr*cc+c] = ch0[c][fr] } } }
    }
    let typed = FlutterStandardTypedData(bytes: data)
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod("onAudioChunk", arguments: typed)
    }
  }

  // MARK: - Playback

  private func playAudio(data: Data) -> Bool {
    guard playerNode.engine != nil, let wire = wireFormat,
          let processing = processingFormat, let conv = playbackConverter,
          !data.isEmpty else { return false }
    let bpf = Int(wire.streamDescription.pointee.mBytesPerFrame)
    guard bpf > 0 else { return false }
    let frames = AVAudioFrameCount(data.count / bpf)
    if frames == 0 { return false }
    guard let inBuf = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: frames) else { return false }
    inBuf.frameLength = frames
    data.withUnsafeBytes { raw in
      guard let src = raw.baseAddress, let dst = inBuf.int16ChannelData?.pointee else { return }
      memcpy(dst, src, data.count)
    }
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: frames) else { return false }
    var consumed = false
    var err: NSError?
    let status = conv.convert(to: outBuf, error: &err) { _, s in
      if consumed { s.pointee = .noDataNow; return nil }
      consumed = true; s.pointee = .haveData; return inBuf
    }
    if status == .error || err != nil { return false }
    if !engine.isRunning { do { try engine.start() } catch { return false } }
    if playerNode.engine == nil { return false }
    if !playerNode.isPlaying { playerNode.play() }
    playerNode.scheduleBuffer(outBuf, completionHandler: nil)
    return true
  }

  private func setVolume(_ v: Int) -> Bool {
    playbackVolume = Float(max(0, min(100, v))) / 100.0
    if engine.isRunning { engine.mainMixerNode.outputVolume = playbackVolume }
    return true
  }

  private func enableSpeaker(_ on: Bool) -> Bool {
    do { try AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none); return true }
    catch { return false }
  }

  private func diag(_ s: String) {
    NSLog("[Talkback] \(s)")
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod("tbDiag", arguments: s)
    }
  }
}
