import AppKit
import AVFoundation
import Foundation
import NaturalLanguage

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

enum TTSStreamPCM {
    static func decode(_ source: URL, to destination: URL) throws {
        let asset = AVURLAsset(url: source)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw ClipboardTTSError.invalidResponse("TTS chunk contains no audio track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 24_000,
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
