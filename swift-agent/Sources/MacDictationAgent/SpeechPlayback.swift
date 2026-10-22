import AVFoundation
import Foundation

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

struct SpeechPlaybackSnapshot {
    let title: String
    let position: Double
    let duration: Double
    let playing: Bool
    let generating: Bool
    let replay: Bool
    let visible: Bool
    let failure: String?
}

/// One disk-backed recording supports streaming playback, seek, and replay without holding the full audio in RAM.
/// Stop affects playback only. Generation continues so the final MP3 remains complete.
final class SpeechPlayback: @unchecked Sendable {
    private let audio = DispatchQueue(label: "com.markschroedr.mac-dictation.speech-player")
    private let files = DispatchQueue(label: "com.markschroedr.mac-dictation.speech-files")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let metrics: TTSRunMetrics
    private let title: String
    private let archiveURL: URL
    private let spoolDirectory: URL
    private let spoolURL: URL
    private let writer: FileHandle
    private let reader: FileHandle
    // Audio queue only. Completion callbacks from obsolete schedules carry an old epoch.
    private var totalFrames = 0
    private var scheduledFrame = 0
    private var positionFrame = 0
    private var queuedFrames = 0
    private var epoch = 0
    private var playing: Bool
    private var paused = false
    private var complete = false
    private var failure: String?
    private var endedAt: Date?
    // Files queue only; parallel provider completions may arrive out of order.
    private var ready: [Int: URL] = [:]
    private var nextFile = 1
    private var decodeFailure: Error?

    init(metrics: TTSRunMetrics, title: String, archiveURL: URL, autoplay: Bool) throws {
        self.metrics = metrics
        self.title = title
        self.archiveURL = archiveURL
        playing = autoplay
        spoolDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString)")
        spoolURL = spoolDirectory.appendingPathComponent("audio.pcm")
        try FileManager.default.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: spoolURL.path, contents: nil)
        writer = try FileHandle(forWritingTo: spoolURL)
        reader = try FileHandle(forReadingFrom: spoolURL)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: SpeechPCM.format)
    }

    var snapshot: SpeechPlaybackSnapshot {
        audio.sync {
            SpeechPlaybackSnapshot(
                title: title, position: Double(positionFrame) / 24_000, duration: Double(totalFrames) / 24_000,
                playing: playing, generating: !complete && failure == nil,
                replay: complete && !playing && !paused,
                visible: endedAt.map { Date().timeIntervalSince($0) < 60 } ?? true,
                failure: failure
            )
        }
    }

    var state: String {
        audio.sync { playing ? "playing" : paused ? "paused" : "stopped" }
    }

    var cancelled: Bool { audio.sync { failure != nil } }

    func append(_ pcm: Data) throws {
        try audio.sync {
            guard failure == nil, !complete else { throw CancellationError() }
            guard pcm.count.isMultiple(of: 2) else {
                throw ClipboardTTSError.invalidResponse("Incomplete PCM sample")
            }
            try writer.write(contentsOf: pcm)
            totalFrames += pcm.count / 2
        }
        audio.async { self.pump() }
    }

    private func pump() {
        guard playing, failure == nil else { return }
        do {
            while queuedFrames < 12_000 && scheduledFrame < totalFrames {
                let frames = min(1_920, totalFrames - scheduledFrame)
                try reader.seek(toOffset: UInt64(scheduledFrame * 2))
                guard let pcm = try reader.read(upToCount: frames * 2), pcm.count == frames * 2 else {
                    throw ClipboardTTSError.invalidResponse("Speech recording is incomplete")
                }
                let buffer = try SpeechPCM.buffer(pcm)
                if !engine.isRunning {
                    try engine.start()
                    metrics.markPlayerLaunch()
                }
                let end = scheduledFrame + frames
                let currentEpoch = epoch
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard let self else { return }
                    self.audio.async {
                        guard currentEpoch == self.epoch else { return }
                        self.queuedFrames -= frames
                        self.positionFrame = end
                        self.metrics.markPlayingObserved()
                        self.metrics.markPlaybackProgressObserved()
                        self.pump()
                    }
                }
                scheduledFrame = end
                queuedFrames += frames
            }
            if queuedFrames > 0 && !player.isPlaying { player.play() }
            if complete && queuedFrames == 0 && scheduledFrame == totalFrames {
                playing = false
                endedAt = Date()
                engine.stop()
            }
        } catch { fail(error) }
    }

    func accept(index: Int, url: URL) {
        files.async {
            guard self.decodeFailure == nil else { return }
            self.ready[index] = url
            do {
                while let url = self.ready.removeValue(forKey: self.nextFile) {
                    let raw = self.spoolDirectory.appendingPathComponent("decode-\(self.nextFile).pcm")
                    defer { try? FileManager.default.removeItem(at: raw) }
                    try TTSStreamPCM.decode(url, to: raw)
                    let file = try FileHandle(forReadingFrom: raw)
                    defer { try? file.close() }
                    while let data = try file.read(upToCount: 3_840), !data.isEmpty { try self.append(data) }
                    self.nextFile += 1
                }
            } catch {
                self.decodeFailure = error
                self.abort(error: "Speech decoding failed: \(error)")
            }
        }
    }

    /// Wait for all provider files to decode, then encode the complete PCM exactly once.
    /// MP3 creation does not block the player's audio queue.
    func finish() throws -> URL {
        try files.sync {
            if let error = decodeFailure { throw error }
            guard ready.isEmpty else { throw ClipboardTTSError.invalidResponse("Missing speech chunk") }
        }
        try audio.sync {
            guard failure == nil, totalFrames > 0 else {
                throw ClipboardTTSError.invalidResponse(failure ?? "Speech contained no audio")
            }
            try writer.synchronize()
            complete = true
            if !playing && !paused { endedAt = Date() }
            pump()
        }
        let temporary = archiveURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let result = runProcessCapturingOutput(ffmpegExecutablePath(), [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "s16le", "-ar", "24000", "-ac", "1",
            "-i", spoolURL.path, "-c:a", "libmp3lame", "-b:a", "128k", temporary.path
        ])
        guard result.status == 0 else {
            throw ClipboardTTSError.requestFailed("Could not save speech MP3: \(result.output)")
        }
        try FileManager.default.moveItem(at: temporary, to: archiveURL)
        return archiveURL
    }

    private func reset(to frame: Int) {
        epoch += 1
        player.stop()
        queuedFrames = 0
        scheduledFrame = frame
        positionFrame = frame
    }

    func togglePause() {
        audio.async {
            guard self.failure == nil else { return }
            if self.playing {
                self.playing = false
                self.paused = true
                self.player.pause()
            } else {
                if !self.paused { self.reset(to: 0) }
                self.playing = true
                self.paused = false
                self.endedAt = nil
                self.pump()
            }
        }
    }

    func seek(to seconds: Double) {
        audio.async {
            guard seconds.isFinite, self.totalFrames > 0, self.failure == nil else { return }
            let target = Int(min(max(0, seconds), Double(self.totalFrames) / 24_000) * 24_000)
            self.reset(to: min(target, self.totalFrames))
            if !self.playing { self.paused = true }
            self.endedAt = nil
            self.pump()
        }
    }

    func skip(by seconds: Double) { seek(to: snapshot.position + seconds) }

    func stop() {
        audio.async {
            self.reset(to: 0)
            self.playing = false
            self.paused = false
            if self.complete { self.endedAt = Date() }
            self.engine.stop()
        }
    }

    private func fail(_ error: Error) {
        failure = String(describing: error)
        playing = false
        paused = false
        endedAt = Date()
        reset(to: positionFrame)
        engine.stop()
        logEvent("speech playback failed error=\(error)")
    }

    func abort(error: String? = nil) {
        audio.async { self.fail(ClipboardTTSError.requestFailed(error ?? "Speech request replaced")) }
    }

    func waitUntilFinished() -> String? {
        // CLI-only wait. UI lifetime is owned by the menu and its replay expiry.
        while true {
            let value = snapshot
            if !value.playing && !value.generating && !audio.sync(execute: { paused }) { return value.failure }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    deinit {
        player.stop()
        engine.stop()
        try? writer.close()
        try? reader.close()
        try? FileManager.default.removeItem(at: spoolDirectory)
    }
}
