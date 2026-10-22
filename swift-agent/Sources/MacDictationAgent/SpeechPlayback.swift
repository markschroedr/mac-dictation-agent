import AVFoundation
import Foundation

/// All playback uses mono float buffers at 24 kHz. API PCM remains s16le at the same rate.
enum SpeechPCM {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    // Unknown RIFF/data lengths are intentional for HTTP streaming WAV, not archival WAV files.
    static let streamingWaveHeader = Data([
        0x52, 0x49, 0x46, 0x46, 0xff, 0xff, 0xff, 0xff,
        0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20,
        16, 0, 0, 0, 1, 0, 1, 0,
        0xc0, 0x5d, 0, 0, 0x80, 0xbb, 0, 0, 2, 0, 16, 0,
        0x64, 0x61, 0x74, 0x61, 0xff, 0xff, 0xff, 0xff
    ])

    static func buffer(_ pcm: Data) throws -> AVAudioPCMBuffer {
        guard pcm.count.isMultiple(of: 2), !pcm.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count / 2)) else {
            throw ClipboardTTSError.invalidResponse("Invalid speech PCM")
        }
        buffer.frameLength = buffer.frameCapacity
        pcm.withUnsafeBytes { bytes in
            for index in 0..<Int(buffer.frameLength) {
                let sample = bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                buffer.floatChannelData![0][index] = Float(Int16(littleEndian: sample)) / 32768
            }
        }
        return buffer
    }
}

/// One controllable player for streamed Phonon PCM and ordered cloud/Supertonic files.
/// Only two seconds of decoded audio may be queued; Pause cannot grow an unbounded buffer.
final class SpeechPlayback: @unchecked Sendable {
    private let condition = NSCondition()
    private let files = DispatchQueue(label: "com.markschroedr.mac-dictation.speech-files")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let metrics: TTSRunMetrics
    private var queuedFrames = 0
    private var started = false
    private var paused = false
    private var stopped = false
    private var finished = false
    private var failure: String?
    // Accessed only on files queue.
    private var ready: [Int: URL] = [:]
    private var nextFile = 1

    init(metrics: TTSRunMetrics) {
        self.metrics = metrics
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: SpeechPCM.format)
    }

    var state: String {
        condition.lock()
        defer { condition.unlock() }
        if stopped || (finished && queuedFrames == 0) { return "stopped" }
        return paused ? "paused" : "playing"
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        condition.lock()
        defer { condition.unlock() }
        while !stopped && queuedFrames >= 48_000 { condition.wait() }
        guard !stopped else { throw CancellationError() }
        if !started {
            try engine.start()
            started = true
            metrics.markPlayerLaunch()
        }
        let frames = Int(buffer.frameLength)
        queuedFrames += frames
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.condition.lock()
            if !self.stopped {
                self.queuedFrames -= frames
                self.metrics.markPlayingObserved()
                self.metrics.markPlaybackProgressObserved()
                if self.finished && self.queuedFrames == 0 {
                    self.files.async { self.stop() }
                }
            }
            self.condition.broadcast()
            self.condition.unlock()
        }
        if !paused && !player.isPlaying { player.play() }
    }

    /// Parallel cloud completions enter here; only contiguous file indices are scheduled.
    func accept(index: Int, url: URL) {
        files.async {
            self.ready[index] = url
            do {
                while let url = self.ready.removeValue(forKey: self.nextFile) {
                    if self.state == "stopped" { self.ready.removeAll(); return }
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let raw = directory.appendingPathComponent("audio.pcm")
                    try TTSStreamPCM.decode(url, to: raw)
                    let file = try FileHandle(forReadingFrom: raw)
                    defer { try? file.close() }
                    while let data = try file.read(upToCount: 3_840), !data.isEmpty {
                        try self.append(SpeechPCM.buffer(data))
                    }
                    self.nextFile += 1
                }
            } catch is CancellationError {
                self.ready.removeAll()
            } catch {
                self.abort(error: "Speech playback failed: \(error)")
                logEvent("speech playback failed error=\(error)")
            }
        }
    }

    func finish() {
        files.async {
            self.condition.lock()
            self.finished = true
            let drained = self.queuedFrames == 0
            self.condition.broadcast()
            self.condition.unlock()
            if drained { self.stop() }
        }
    }

    func togglePause() {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped && !(finished && queuedFrames == 0) else { return }
        paused.toggle()
        if started {
            if paused { player.pause() } else { player.play() }
        }
    }

    func stop() { abort() }

    func abort(error: String? = nil) {
        condition.lock()
        guard !stopped else { condition.unlock(); return }
        stopped = true
        failure = error
        queuedFrames = 0
        condition.broadcast()
        condition.unlock()
        // Never hold condition while stop invokes buffer completion callbacks.
        player.stop()
        engine.stop()
    }

    func waitUntilFinished() -> String? {
        condition.lock()
        while !stopped && !(finished && queuedFrames == 0) { condition.wait() }
        let error = failure
        condition.unlock()
        return error
    }

    deinit { player.stop(); engine.stop() }
}
