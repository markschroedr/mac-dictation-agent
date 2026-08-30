import CoreML
import DictationServiceProtocol
import FluidAudio
import Foundation

private final class FluidASRService {
    private let modelRoot: URL
    private var manager: AsrManager?
    private var activeSessionID: String?
    private var responseCache: [Int: DictationServiceResponse] = [:]

    init(modelRoot: URL) {
        self.modelRoot = modelRoot
    }

    func handle(_ request: DictationServiceRequest) async -> DictationServiceResponse {
        do {
            switch request.action {
            case .warmup:
                _ = try await loadManager()
                return DictationServiceResponse(id: request.id)
            case .resetSession:
                guard let sessionID = request.sessionID, !sessionID.isEmpty else {
                    throw ServiceError.invalidRequest("resetSession requires sessionID")
                }
                activeSessionID = sessionID
                responseCache.removeAll(keepingCapacity: true)
                return DictationServiceResponse(id: request.id)
            case .transcribe:
                return try await transcribe(request)
            case .shutdown:
                if let manager {
                    await manager.cleanup()
                }
                manager = nil
                return DictationServiceResponse(id: request.id)
            }
        } catch {
            log("request failed action=\(request.action.rawValue) error=\(error)")
            return DictationServiceResponse(id: request.id, error: String(describing: error))
        }
    }

    private func loadManager() async throws -> AsrManager {
        if let manager {
            return manager
        }

        let started = ContinuousClock.now
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let models = try await AsrModels.downloadAndLoad(
            to: modelRoot,
            configuration: configuration,
            version: .v3,
            encoderPrecision: .int8,
            encoderComputeUnits: .all
        )
        let loadedManager = AsrManager(config: .default)
        try await loadedManager.loadModels(models)
        manager = loadedManager
        log("model ready seconds=\(format(started.duration(to: .now))) root=\(modelRoot.path)")
        return loadedManager
    }

    private func transcribe(_ request: DictationServiceRequest) async throws -> DictationServiceResponse {
        guard
            let sessionID = request.sessionID,
            let chunkIndex = request.chunkIndex,
            let path = request.path
        else {
            throw ServiceError.invalidRequest("transcribe requires sessionID, chunkIndex, and path")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw ServiceError.audioMissing(path)
        }

        if activeSessionID != sessionID {
            activeSessionID = sessionID
            responseCache.removeAll(keepingCapacity: true)
        }
        if let cached = responseCache[chunkIndex] {
            log("cache hit session=\(sessionID) chunk=\(chunkIndex)")
            return cached.replacingID(with: request.id)
        }

        let manager = try await loadManager()
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let started = ContinuousClock.now
        let result: ASRResult
        let sourceDuration: Double
        if request.final {
            let converter = AudioConverter(sampleRate: 16_000)
            var samples = try converter.resampleAudioFile(URL(fileURLWithPath: path))
            sourceDuration = Double(samples.count) / 16_000
            samples.append(contentsOf: repeatElement(0, count: 16_000))
            result = try await manager.transcribe(
                samples,
                decoderState: &decoderState,
                language: nil
            )
        } else {
            result = try await manager.transcribe(
                URL(fileURLWithPath: path),
                decoderState: &decoderState,
                language: nil
            )
            sourceDuration = result.duration
        }
        let elapsed = seconds(started.duration(to: .now))
        let response = DictationServiceResponse(
            id: request.id,
            text: result.text,
            rawText: result.text,
            durationSeconds: sourceDuration,
            recognizeSeconds: elapsed,
            speedup: elapsed > 0 ? sourceDuration / elapsed : nil
        )
        responseCache[chunkIndex] = response
        log(
            "transcribed session=\(sessionID) chunk=\(chunkIndex) final=\(request.final) "
                + "audio=\(String(format: "%.3f", sourceDuration))s "
                + "tail_padding=\(request.final ? "1.000s" : "none") "
                + "recognize=\(String(format: "%.3f", elapsed))s chars=\(result.text.count)"
        )
        return response
    }
}

private enum ServiceError: Error, CustomStringConvertible {
    case invalidRequest(String)
    case audioMissing(String)

    var description: String {
        switch self {
        case .invalidRequest(let message):
            return message
        case .audioMissing(let path):
            return "audio file does not exist: \(path)"
        }
    }
}

private func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

private func format(_ duration: Duration) -> String {
    String(format: "%.3f", seconds(duration))
}

private func log(_ message: String) {
    let line = "[FluidDictationService] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

private func writeResponse(_ response: DictationServiceResponse) {
    do {
        var data = try JSONEncoder().encode(response)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    } catch {
        log("response encoding failed error=\(error)")
    }
}

@main
private enum FluidDictationServiceMain {
    static func main() async {
        let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac Dictation Agent/models/fluid-audio", isDirectory: true)
        let modelRoot = ProcessInfo.processInfo.environment["MAC_DICTATION_FLUID_MODEL_ROOT"].map {
            URL(fileURLWithPath: $0)
        } ?? defaultRoot
        let service = FluidASRService(modelRoot: modelRoot)
        let decoder = JSONDecoder()

        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8) else {
                continue
            }
            let request: DictationServiceRequest
            do {
                request = try decoder.decode(DictationServiceRequest.self, from: data)
            } catch {
                log("request decoding failed error=\(error)")
                writeResponse(DictationServiceResponse(id: "unknown", error: "invalid request: \(error)"))
                continue
            }

            let response = await service.handle(request)
            writeResponse(response)
            if request.action == .shutdown {
                break
            }
        }
    }
}
