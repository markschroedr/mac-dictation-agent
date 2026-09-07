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
            let minimum = result.isEmpty ? 15 : result.count == 1 ? 40 : 80
            let maximum = result.isEmpty ? 30 : result.count == 1 ? 70 : 140
            var current = ""
            var count = 0
            while index < units.count {
                let unit = units[index]
                let words = unit.split(whereSeparator: \.isWhitespace)
                let candidate = current.isEmpty ? unit : current + " " + unit
                if count + words.count <= maximum && candidate.count <= maximumCharacters {
                    current = candidate
                    count += words.count
                    index += 1
                    if count >= minimum { break }
                } else if !current.isEmpty {
                    // Prefer a short complete sentence over cutting the next sentence merely to fill a quota.
                    break
                } else {
                    var end = unit.startIndex
                    var accepted = 0
                    for word in words.prefix(maximum) {
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

/// VLC receives a complete ordered playlist once. Each loopback URL waits for its audio file.
/// Chunk completion only answers HTTP requests; it never sends another player command.
final class ProgressiveVLCPlayback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.markschroedr.mac-dictation.tts-http")
    private let condition = NSCondition()
    private let listener: NWListener
    private let metrics: TTSRunMetrics
    private let playlistURL: URL
    private let token = UUID().uuidString
    private let chunkCount: Int
    private let audioExtension: String
    private var port: UInt16?
    private var ready: [Int: URL] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var waiting: [ObjectIdentifier: (NWConnection, Int, Bool)] = [:]
    private var launched = false
    private var ended = false
    private var failure: String?
    private var lastDelivered = false

    init(runDirectory: URL, provider: TTSProvider, metrics: TTSRunMetrics, chunkCount: Int) throws {
        self.metrics = metrics
        self.chunkCount = chunkCount
        audioExtension = provider.audioExtension
        playlistURL = runDirectory.appendingPathComponent("live.m3u")
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
        guard let boundPort else {
            listener.cancel()
            throw ClipboardTTSError.requestFailed(error ?? "Could not start local TTS playback server")
        }
        let playlist = "#EXTM3U\n" + (1...chunkCount).map {
            "http://127.0.0.1:\(boundPort)/\(token)/\($0).\(audioExtension)"
        }.joined(separator: "\n") + "\n"
        try playlist.write(to: playlistURL, atomically: true, encoding: .utf8)
    }

    func accept(index: Int, url: URL) throws {
        let shouldLaunch = queue.sync {
            ready[index] = url
            for (id, entry) in waiting where entry.1 == index {
                waiting.removeValue(forKey: id)
                respond(entry.0, index: index, head: entry.2)
            }
            if index == 1 && !launched { launched = true; return true }
            return false
        }
        guard shouldLaunch else { return }
        let result = runProcessCapturingOutput("/usr/bin/open", ["-b", "org.videolan.vlc", playlistURL.path])
        guard result.status == 0 else {
            abort(error: "Could not open VLC: \(result.output)")
            throw ClipboardTTSError.requestFailed("Could not open VLC: \(result.output)")
        }
        metrics.markPlayerLaunch()
        DispatchQueue.global(qos: .utility).async { self.observePlayback() }
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

    deinit { listener.cancel() }

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
                  let index = (1...self.chunkCount).first(where: {
                      fields[1] == "/\(self.token)/\($0).\(self.audioExtension)"
                  }) else {
                self.send(connection, status: "404 Not Found", data: Data(), head: false)
                return
            }
            let head = fields[0] == "HEAD"
            if self.ready[index] != nil { self.respond(connection, index: index, head: head) }
            else { self.waiting[ObjectIdentifier(connection)] = (connection, index, head) }
        }
    }

    private func respond(_ connection: NWConnection, index: Int, head: Bool) {
        do {
            guard let url = ready[index] else { return }
            let data = try Data(contentsOf: url)
            send(connection, status: "200 OK", data: data, head: head, index: index)
        } catch {
            logEvent("tts playback read failed index=\(index) error=\(error)")
            send(connection, status: "500 Internal Server Error", data: Data(), head: head)
        }
    }

    private func send(_ connection: NWConnection, status: String, data: Data, head: Bool, index: Int? = nil) {
        let mime = audioExtension == "mp3" ? "audio/mpeg" : "audio/wav"
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        if !head { response.append(data) }
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            guard let self else { connection.cancel(); return }
            if error == nil, !head, let index {
                logEvent("tts playback player=vlc event=chunk_delivered index=\(index)")
                if index == self.chunkCount {
                    self.condition.lock()
                    self.lastDelivered = true
                    self.condition.broadcast()
                    self.condition.unlock()
                }
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
