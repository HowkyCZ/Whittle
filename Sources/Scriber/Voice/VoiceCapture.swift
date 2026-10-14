import AVFoundation
import Foundation
import ScriberCore

/// Continuous capture with energy-based VAD.
/// Publishes live levels so the UI can show whether audio is actually arriving.
final class VoiceCapture {
    /// A finished clip: its number, its audio (nil when it was only a click or breath), and how long the
    /// voice in it lasted without the trailing pause, in ms. Every clip that started is reported, in order.
    var onClip: ((_ id: Int, _ audio: AVAudioPCMBuffer?, _ voicedMs: Int, _ loudness: NoiseFilter.Loudness?) -> Void)?
    /// The clip so far, every `partialEveryMs` while someone is talking, for live words.
    var onPartial: ((_ id: Int, _ audio: AVAudioPCMBuffer) -> Void)?
    /// Called on the voice queue with instantaneous RMS (0…~0.5 typical for speech) and the voice split into
    /// four pitch bands, each 0…1 against its own background, for the mic's sound lines.
    var onLevel: ((Float, [Double]) -> Void)?
    private let bands = SoundBands()
    /// Human-readable diagnostics for the UI.
    var onInfo: ((String) -> Void)?
    var onSpeechStart: ((_ id: Int) -> Void)?
    /// `emitted` is false when the clip was dropped as noise.
    var onSpeechEnd: ((_ emitted: Bool) -> Void)?

    /// When someone is talking, judged against the room's background noise. A pause of 1.6 s closes a clip.
    private var gate = SpeechGate()
    /// Audio kept from just before the voice got loud enough, so first syllables aren't clipped.
    var preRollMs: Int = 400
    /// Clips with less voice than this are clicks, not words.
    var minimumVoiceMs: Int = 150
    var partialEveryMs: Int = 800

    private let engine = AVAudioEngine()
    private var isRunning = false
    private var accumulating = false
    private var chunks: [AVAudioPCMBuffer] = []
    private var preRoll: [AVAudioPCMBuffer] = []
    private var convertFailures = 0
    /// The clip being recorded, or the last one; numbered from 1 each time the mic starts.
    private var clipID = 0
    private var sinceSnapshotMs = 0
    private let queue = DispatchQueue(label: "scriber.voice")
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var levelTick: Int = 0

    var inputDeviceName: String {
        Self.defaultInputDeviceName() ?? "(unknown input)"
    }

    func start() throws {
        guard !isRunning else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 30)
            if !granted { throw VoiceError.micDenied }
        default:
            throw VoiceError.micDenied
        }

        // Prefer the hardware input format. Querying before start can return 0 Hz on some macOS versions —
        // so we start the engine first, then install the tap.
        engine.reset()
        let input = engine.inputNode
        input.removeTap(onBus: 0)

        engine.prepare()
        try engine.start()

        var hwFormat = input.inputFormat(forBus: 0)
        if hwFormat.sampleRate < 1 || hwFormat.channelCount < 1 {
            hwFormat = input.outputFormat(forBus: 0)
        }
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            engine.stop()
            throw VoiceError.badFormat("Input format is invalid (0 Hz). Check System Settings → Sound → Input.")
        }

        let mono16k = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        targetFormat = mono16k
        converter = AVAudioConverter(from: hwFormat, to: mono16k)

        let device = inputDeviceName
        onInfo?("Mic: \(device) · \(Int(hwFormat.sampleRate)) Hz · \(hwFormat.channelCount) ch")

        // Install tap using the hardware format (nil = node's format). Never pass a mismatched format.
        // The engine reuses the tap's buffer, so copy it before handing it to another queue.
        input.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, _ in
            guard let self, let copy = Self.copy(buffer) else { return }
            self.queue.async { self.process(copy) }
        }

        queue.sync {
            accumulating = false
            chunks.removeAll()
            preRoll.removeAll()
            gate = SpeechGate()
            convertFailures = 0
            clipID = 0
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        isRunning = false
        queue.sync {
            accumulating = false
            chunks.removeAll()
            preRoll.removeAll()
            _ = gate.forceEnd()
            converter = nil
        }
    }

    /// Ends the clip being recorded now instead of waiting for a pause. Calls back with the last clip's number.
    func finalizeNow(then completion: @escaping (Int) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.accumulating, let voiced = self.gate.forceEnd() {
                self.emit(voicedMs: voiced)
            }
            completion(self.clipID)
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else {
            convertFailures += 1
            if convertFailures == 1 || convertFailures % 200 == 0 {
                onInfo?("Audio conversion failed (\(convertFailures)×) — no audio reaches Whisper")
            }
            return
        }
        let energy = rms(converted)

        let samples = Array(UnsafeBufferPointer(start: converted.floatChannelData?[0], count: Int(converted.frameLength)))
        let bandLevels = bands.levels(samples, sampleRate: converted.format.sampleRate)
        levelTick += 1
        if levelTick % 2 == 0 {
            onLevel?(energy, bandLevels)
        }

        let frameMs = max(Int((Double(converted.frameLength) / max(converted.format.sampleRate, 1)) * 1000), 1)

        switch gate.feed(energy, ms: frameMs) {
        case .started:
            clipID += 1
            onInfo?("Speech detected (level \(Self.formatLevel(energy)), bar \(Self.formatLevel(gate.startThreshold)), "
                + "background \(Self.formatLevel(gate.noiseFloor))) · clip \(clipID)")
            onSpeechStart?(clipID)
            chunks = preRoll
            preRoll.removeAll()
            sinceSnapshotMs = 0
            accumulating = true
            chunks.append(converted)
            snapshotIfDue(frameMs)
        case .ended(let voiced):
            chunks.append(converted)
            emit(voicedMs: voiced)
        case .none where accumulating:
            chunks.append(converted)
            snapshotIfDue(frameMs)
        case .none:
            preRoll.append(converted)
            var kept = preRoll.reduce(0) { $0 + Int($1.frameLength) }
            let limit = Int(converted.format.sampleRate) * preRollMs / 1000
            while kept > limit, preRoll.count > 1 {
                kept -= Int(preRoll.removeFirst().frameLength)
            }
        }
    }

    /// A copy the engine can't overwrite.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            let stride = buffer.format.isInterleaved ? channels : 1
            for c in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                dst[c].update(from: src[c], count: frames * stride)
            }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            let stride = buffer.format.isInterleaved ? channels : 1
            for c in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                dst[c].update(from: src[c], count: frames * stride)
            }
        } else {
            return nil
        }
        return copy
    }

    /// The clip so far, for live words, while the speaker is still going.
    private func snapshotIfDue(_ frameMs: Int) {
        sinceSnapshotMs += frameMs
        guard onPartial != nil, sinceSnapshotMs >= partialEveryMs, gate.voicedMs >= 300, gate.pauseMs < 500,
              let snapshot = merge(chunks) else { return }
        sinceSnapshotMs = 0
        onPartial?(clipID, snapshot)
    }

    private func emit(voicedMs voiced: Int) {
        guard accumulating else { return }
        let id = clipID
        let merged = chunks.isEmpty ? nil : merge(chunks)
        chunks.removeAll()
        accumulating = false

        guard let merged else {
            onInfo?("Clip \(id) dropped (no convertible audio)")
            onSpeechEnd?(false)
            onClip?(id, nil, 0, nil)
            return
        }
        // Clicks and breaths: too little voice to be words. Short bursts are how "No" hallucinations start.
        if voiced < minimumVoiceMs {
            onInfo?("Clip \(id) dropped (only \(voiced)ms of voice)")
            onSpeechEnd?(false)
            onClip?(id, nil, voiced, nil)
            return
        }
        // Taps and knocks can hold a clip open for seconds; the clip as a whole is still far quieter than talking.
        let loudness = NoiseFilter.Loudness(rms: rms(merged), background: gate.noiseFloor)
        if NoiseFilter.isTooQuiet(loudness) {
            onInfo?("Clip \(id) dropped (too quiet for speech: rms \(Self.formatLevel(loudness.rms)), "
                + "background \(Self.formatLevel(loudness.background)))")
            onSpeechEnd?(false)
            onClip?(id, nil, 0, loudness)
            return
        }

        let durationMs = Int((Double(merged.frameLength) / merged.format.sampleRate) * 1000)
        onInfo?("Clip \(id) ready · \(durationMs)ms · \(voiced)ms voice · rms \(Self.formatLevel(loudness.rms))")
        onSpeechEnd?(true)
        onClip?(id, merged, voiced, loudness)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let targetFormat else { return nil }
        let ratio = targetFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else { return nil }

        // One continuous stream: the resampler keeps its state between buffers, so no samples are lost at the seams.
        var error: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        converter.convert(to: out, error: &error, withInputFrom: inputBlock)
        if let error {
            onInfo?("Audio convert error: \(error.localizedDescription)")
            return nil
        }
        guard out.frameLength > 0 else { return nil }
        return out
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }

        if let data = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<n {
                let v = data[i]
                sum += v * v
            }
            return sqrt(sum / Float(n))
        }

        // Some hardware formats are Int16
        if let data = buffer.int16ChannelData?[0] {
            var sum: Float = 0
            for i in 0..<n {
                let v = Float(data[i]) / Float(Int16.max)
                sum += v * v
            }
            return sqrt(sum / Float(n))
        }

        return 0
    }

    private func merge(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = buffers.first else { return nil }
        let total = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard total > 0,
              let out = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(total)),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = AVAudioFrameCount(total)
        var offset = 0
        for b in buffers {
            guard let src = b.floatChannelData?[0] else { continue }
            let count = Int(b.frameLength)
            dst.advanced(by: offset).update(from: src, count: count)
            offset += count
        }
        return out
    }

    static func formatLevel(_ energy: Float) -> String {
        String(format: "%.4f", energy)
    }

    static func defaultInputDeviceName() -> String? {
        // Prefer AVCaptureDevice discovery for a readable name matching System Settings.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        if let def = AVCaptureDevice.default(for: .audio) {
            return def.localizedName
        }
        return discovery.devices.first?.localizedName
    }
}

enum VoiceError: LocalizedError {
    case micDenied
    case badFormat(String)

    var errorDescription: String? {
        switch self {
        case .micDenied:
            return "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .badFormat(let message):
            return message
        }
    }
}
