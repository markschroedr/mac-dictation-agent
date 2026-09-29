import AppKit
import AVFoundation
import Foundation
import NaturalLanguage
import Network

struct TTSMetricSnapshot: Codable {
    let generationToFirstAudioReadySeconds: Double?
    let generationToPlayerLaunchSeconds: Double?
    let generationToPlayingObservedSeconds: Double?
    let generationToPlaybackProgressObservedSeconds: Double?
    let totalGenerationSeconds: Double?
}

struct TTSBenchmarkOutput: Codable {
    let provider: String
    let language: String
    let play: Bool
    let characterCount: Int
    let wordCount: Int
    let chunkCount: Int
    let outputPath: String
    let metrics: TTSMetricSnapshot
}

final class TTSRunMetrics: @unchecked Sendable {
    private let condition = NSCondition()
    private let provider: TTSProvider
    private let start = DispatchTime.now().uptimeNanoseconds
    private var events: [String: Double] = [:]

    init(provider: TTSProvider) { self.provider = provider }

    func markFirstAudioReady() { mark("first_audio_ready") }
    func markPlayerLaunch() { mark("player_launch_requested") }
    func markPlayingObserved() { mark("playing_observed") }
    func markPlaybackProgressObserved() { mark("playback_progress_observed") }
    func markGenerationCompleted() { mark("generation_complete") }

    private func mark(_ name: String) {
        condition.lock()
        guard events[name] == nil else { condition.unlock(); return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        events[name] = elapsed
        condition.broadcast()
        condition.unlock()
        logEvent("tts metric provider=\(provider.rawValue) event=\(name) generation_elapsed=\(String(format: "%.3f", elapsed))s")
    }

    func waitForPlayingObservation(timeout: TimeInterval) {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while events["playback_progress_observed"] == nil && Date() < deadline {
            condition.wait(until: deadline)
        }
    }

    func snapshot() -> TTSMetricSnapshot {
        condition.lock()
        defer { condition.unlock() }
        return TTSMetricSnapshot(
            generationToFirstAudioReadySeconds: events["first_audio_ready"],
            generationToPlayerLaunchSeconds: events["player_launch_requested"],
            generationToPlayingObservedSeconds: events["playing_observed"],
            generationToPlaybackProgressObservedSeconds: events["playback_progress_observed"],
            totalGenerationSeconds: events["generation_complete"]
        )
    }
}

struct ProgressiveTTSChunker {
    static func chunks(text: String, maximumCharacters: Int) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var units: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { units.append(sentence) }
            return true
        }
        if units.isEmpty { units = [text] }
        var result: [String] = []
        var index = 0
        while index < units.count {
            let bounds: (minimum: Int, maximum: Int) = switch result.count {
            case 0: (15, 30)
            case 1: (40, 70)
            case 2: (100, 160)
            case 3: (180, 280)
            case 4: (280, 420)
            default: (400, 600)
            }
            var current = ""
            var count = 0
            while index < units.count {
                let unit = units[index]
                let words = unit.split(whereSeparator: \.isWhitespace)
                let candidate = current.isEmpty ? unit : current + " " + unit
                if count + words.count <= bounds.maximum && candidate.count <= maximumCharacters {
                    current = candidate
                    count += words.count
                    index += 1
                    if count >= bounds.minimum { break }
                } else if !current.isEmpty {
                    // Prefer a short complete sentence over cutting the next sentence merely to fill a quota.
                    break
                } else {
                    var end = unit.startIndex
                    var accepted = 0
                    for word in words.prefix(bounds.maximum) {
                        if unit.distance(from: unit.startIndex, to: word.endIndex) > maximumCharacters { break }
                        end = word.endIndex
                        accepted += 1
                    }
                    if accepted == 0 {
                        end = unit.index(unit.startIndex, offsetBy: min(maximumCharacters, unit.count))
                    }
                    current = String(unit[..<end])
                    let remainder = unit[end...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if remainder.isEmpty { index += 1 } else { units[index] = remainder }
                    break
                }
            }
            result.append(current)
        }
        return result
    }
}

enum JoinedTTSWriter {
    static func write(chunks: [URL], provider: TTSProvider, to outputURL: URL) throws {
        guard let first = chunks.first else {
            throw ClipboardTTSError.invalidResponse("TTS produced no audio chunks")
        }
        if chunks.count == 1 {
            try FileManager.default.copyItem(at: first, to: outputURL)
            return
        }
        if provider.isLocal {
            let input = try AVAudioFile(forReading: first)
            let output = try AVAudioFile(forWriting: outputURL, settings: input.fileFormat.settings)
            for url in chunks {
                let file = try AVAudioFile(forReading: url)
                guard file.processingFormat == input.processingFormat,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
                    throw ClipboardTTSError.invalidResponse("TTS chunks used incompatible audio formats")
                }
                while file.framePosition < file.length {
                    try file.read(into: buffer)
                    try output.write(from: buffer)
                }
            }
            return
        }
        // Independent MP3s have their own duration/seek headers. A container export produces
        // one correctly seekable recording instead of concatenating incompatible file headers.
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ClipboardTTSError.invalidResponse("Could not create joined audio track")
        }
        var position = CMTime.zero
        for url in chunks {
            let asset = AVURLAsset(url: url)
            guard let source = asset.tracks(withMediaType: .audio).first else {
                throw ClipboardTTSError.invalidResponse("TTS chunk contains no audio track")
            }
            let duration = asset.duration
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: position)
            position = CMTimeAdd(position, duration)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ClipboardTTSError.invalidResponse("Could not create joined audio exporter")
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        let completed = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { completed.signal() }
        completed.wait()
        guard exporter.status == .completed else {
            throw exporter.error ?? ClipboardTTSError.invalidResponse("Could not export joined audio")
        }
    }
}

enum TTSStreamPCM {
    // Mono 48 kHz signed 16-bit PCM. Unknown lengths allow playback before generation ends.
    static let waveHeader = Data([
        0x52, 0x49, 0x46, 0x46, 0xff, 0xff, 0xff, 0xff, // RIFF
        0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20, // WAVEfmt
        16, 0, 0, 0, 1, 0, 1, 0,
        0x80, 0xbb, 0, 0, 0, 0x77, 1, 0, 2, 0, 16, 0,
        0x64, 0x61, 0x74, 0x61, 0xff, 0xff, 0xff, 0xff, // data
    ])

    static func decode(_ source: URL, to destination: URL) throws {
        let asset = AVURLAsset(url: source)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw ClipboardTTSError.invalidResponse("TTS chunk contains no audio track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? ClipboardTTSError.invalidResponse("Could not decode TTS chunk")
        }
        defer { reader.cancelReading() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetDataBuffer(sample) else {
                throw ClipboardTTSError.invalidResponse("TTS decoder returned no PCM samples")
            }
            var data = Data(count: CMBlockBufferGetDataLength(buffer))
            let status = data.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else {
                throw ClipboardTTSError.invalidResponse("Could not copy TTS PCM samples")
            }
            try file.write(contentsOf: data)
        }
        guard reader.status == .completed else {
            throw reader.error ?? ClipboardTTSError.invalidResponse("Incomplete TTS PCM decoding")
        }
    }
}

/// One open-ended WAV response keeps VLC's decoder and audio output open across chunks.
/// Readiness only extends the response; it never sends another player command.
final class ProgressiveVLCPlayback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.markschroedr.mac-dictation.tts-http")
    private let condition = NSCondition()
    private let listener: NWListener
    private let metrics: TTSRunMetrics
    private let token = UUID().uuidString
    private let pcmDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-dictation-tts-\(UUID().uuidString)", isDirectory: true)
    private let chunkCount: Int
    private var port: UInt16?
    private var ready: [Int: URL] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var waiting: [ObjectIdentifier: (NWConnection, Int)] = [:]
    private var launched = false
    private var ended = false
    private var failure: String?
    private var lastDelivered = false

    init(metrics: TTSRunMetrics, chunkCount: Int) throws {
        self.metrics = metrics
        self.chunkCount = chunkCount
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc") != nil else {
            throw ClipboardTTSError.requestFailed("VLC is required for progressive playback")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.condition.lock()
            switch state {
            case .ready: self.port = self.listener.port?.rawValue
            case .failed(let error): self.failure = "\(error)"
            default: break
            }
            self.condition.broadcast()
            self.condition.unlock()
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = ObjectIdentifier(connection)
            self.connections[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.forget(connection) }
                if case .cancelled = state { self?.forget(connection) }
            }
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
        condition.lock()
        let deadline = Date().addingTimeInterval(5)
        while port == nil && failure == nil && Date() < deadline { condition.wait(until: deadline) }
        let boundPort = port
        let error = failure
        condition.unlock()
        guard boundPort != nil else {
            listener.cancel()
            throw ClipboardTTSError.requestFailed(error ?? "Could not start local TTS playback server")
        }
        try FileManager.default.createDirectory(at: pcmDirectory, withIntermediateDirectories: true)
    }

    func accept(index: Int, url: URL) throws {
        let pcmURL = pcmDirectory.appendingPathComponent("\(index).pcm")
        try TTSStreamPCM.decode(url, to: pcmURL)
        let shouldLaunch = queue.sync {
            condition.lock()
            let stopped = ended
            condition.unlock()
            guard !stopped else { return false }
            ready[index] = pcmURL
            for (id, entry) in waiting where entry.1 == index {
                waiting.removeValue(forKey: id)
                sendChunk(entry.0, index: index)
            }
            if index == 1 && !launched { launched = true; return true }
            return false
        }
        guard shouldLaunch else { return }
        let result = runProcessCapturingOutput("/usr/bin/open", ["-b", "org.videolan.vlc", playbackURL.absoluteString])
        guard result.status == 0 else {
            abort(error: "Could not open VLC: \(result.output)")
            throw ClipboardTTSError.requestFailed("Could not open VLC: \(result.output)")
        }
        metrics.markPlayerLaunch()
        DispatchQueue.global(qos: .utility).async { self.observePlayback() }
    }

    var playbackURL: URL {
        URL(string: "http://127.0.0.1:\(port!)/\(token)/audio.wav")!
    }

    func finish(expectedChunkCount: Int) {
        logEvent("tts playback player=vlc event=all_chunks_ready chunks=\(expectedChunkCount)")
    }

    func abort(error: String? = nil) {
        condition.lock()
        ended = true
        failure = error
        condition.broadcast()
        condition.unlock()
        listener.cancel()
        queue.async {
            for connection in self.connections.values { connection.cancel() }
            self.waiting.removeAll()
        }
    }

    func waitUntilFinished() -> String? {
        while true {
            condition.lock()
            if lastDelivered || ended {
                let error = failure
                condition.unlock()
                return error
            }
            condition.wait(until: Date().addingTimeInterval(0.5))
            condition.unlock()
            // This is only the CLI lifetime. Pause preserves the item; Stop removes it.
            let state = playerState()
            if state.status == 0 {
                let value = state.output.trimmingCharacters(in: .newlines)
                let fields = value.components(separatedBy: "\t")
                if value == "none" || (fields.count == 3 && !fields[2].contains("/\(token)/")) {
                    return nil
                }
            }
        }
    }

    deinit {
        listener.cancel()
        try? FileManager.default.removeItem(at: pcmDirectory)
    }

    private func forget(_ connection: NWConnection) {
        connection.stateUpdateHandler = nil
        let id = ObjectIdentifier(connection)
        connections.removeValue(forKey: id)
        waiting.removeValue(forKey: id)
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] bytes, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = data
            if let bytes { request.append(bytes) }
            guard request.count <= 16_384, error == nil else { connection.cancel(); return }
            guard let header = String(data: request, encoding: .utf8), header.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { self.receive(connection, data: request) }
                return
            }
            let fields = header.components(separatedBy: "\r\n")[0].split(separator: " ")
            guard fields.count == 3, fields[0] == "GET" || fields[0] == "HEAD",
                  fields[1] == "/\(self.token)/audio.wav" else {
                self.endResponse(connection, data: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                return
            }
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nAccept-Ranges: none\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
            if fields[0] == "HEAD" {
                self.endResponse(connection, data: response)
                return
            }
            response.append(TTSStreamPCM.waveHeader)
            connection.send(content: response, completion: .contentProcessed { [weak self] error in
                guard let self else { connection.cancel(); return }
                if error != nil { connection.cancel(); self.forget(connection); return }
                self.sendChunk(connection, index: 1)
            })
        }
    }

    private func sendChunk(_ connection: NWConnection, index: Int) {
        guard connections[ObjectIdentifier(connection)] != nil else { return }
        guard index <= chunkCount else {
            endResponse(connection, data: nil, completed: true)
            return
        }
        guard let url = ready[index] else {
            waiting[ObjectIdentifier(connection)] = (connection, index)
            return
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { connection.cancel(); return }
                if error != nil { connection.cancel(); self.forget(connection); return }
                logEvent("tts playback player=vlc event=chunk_delivered index=\(index)")
                self.sendChunk(connection, index: index + 1)
            })
        } catch {
            abort(error: "Could not read TTS stream chunk: \(error)")
        }
    }

    private func endResponse(_ connection: NWConnection, data: Data?, completed: Bool = false) {
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self else { connection.cancel(); return }
            if error == nil && completed {
                self.condition.lock()
                self.lastDelivered = true
                self.condition.broadcast()
                self.condition.unlock()
            }
            connection.cancel()
            self.forget(connection)
        })
    }

    private func playerState() -> ProcessRunResult {
        runProcessCapturingOutput("/usr/bin/osascript", ["-e", """
        if application id "org.videolan.vlc" is not running then return "none"
        tell application id "org.videolan.vlc"
            try
                return (playing as text) & tab & (current time as text) & tab & (path of current item)
            on error
                return "none"
            end try
        end tell
        """])
    }

    private func observePlayback() {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            condition.lock()
            let stopped = ended
            condition.unlock()
            if stopped { return }
            let state = playerState()
            if state.status != 0 {
                logEvent("tts playback observation unavailable: \(state.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                return
            }
            let fields = state.output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
            if fields.count == 3 && fields[0] == "true" && fields[2].contains("/\(token)/") {
                metrics.markPlayingObserved()
                if (Int(fields[1]) ?? 0) > 0 { metrics.markPlaybackProgressObserved(); return }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
