import Foundation
import Network

let phononTTSClient = LocalTTSClient(configuration: LocalTTSClientConfiguration(
    displayName: "Phonon 40M", logName: "phonon-tts-service",
    executable: phononTTSServiceExecutable, modelRoot: phononTTSModelRoot,
    modelRootEnvironmentVariable: "HF_HUB_CACHE"
))

enum PhononSpeechError: Error { case busy }

/// UI and HTTP share exactly one on-demand worker. Reject overlap rather than queue stale speech.
final class PhononSpeech: @unchecked Sendable {
    static let shared = PhononSpeech()
    private let gate = NSLock()

    func stream(text: String, language: TTSLanguage, voice: String?,
                cancelled: (() -> Bool)? = nil, receive: (Data) throws -> Void) throws {
        guard gate.try() else { throw PhononSpeechError.busy }
        defer { gate.unlock() }
        try phononTTSClient.stream(text: text, language: language, voiceID: voice,
                                   cancelled: cancelled, receive: receive)
    }
}

/// Loopback API returns audio only: no server-side playback or playback controls.
func streamPhononHTTP(body: Data, connection: NWConnection) {
    struct Input: Decodable {
        let input: String
        let model: String?
        let language: String?
        let voice: String?
        let response_format: String?
    }
    func respondError(_ status: Int, _ message: String) {
        let body = try! JSONSerialization.data(withJSONObject: ["error": ["message": message]])
        var data = Data("HTTP/1.1 \(status) Error\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
    guard let input = try? JSONDecoder().decode(Input.self, from: body),
          !input.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          input.input.count <= 100_000,
          input.model == nil || ["phonon", "phonon-40m"].contains(input.model!),
          input.voice == nil || ["default", "male"].contains(input.voice!),
          input.response_format == nil || ["pcm", "wav"].contains(input.response_format!) else {
        respondError(400, "Provide input (1-100000 characters), model phonon, voice default/male, response_format pcm/wav")
        return
    }
    let selected: TTSLanguage
    switch input.language ?? "auto" {
    case "auto": selected = .auto
    case "en", "english": selected = .english
    case "de", "german": selected = .german
    default: respondError(400, "language must be auto, de, or en"); return
    }
    let language = selected.resolved(for: input.input, germanOrEnglishOnly: true)
    guard language != .auto else { respondError(400, "Could not detect German or English"); return }
    let wav = (input.response_format ?? "wav") == "wav"
    var started = false
    let began = ProcessInfo.processInfo.systemUptime
    // Bounded sends apply backpressure; failure aborts this synthesis, never another consumer's request.
    func send(_ data: Data) throws {
        let done = DispatchSemaphore(value: 0)
        let result = SynchronizedBox<NWError?>(nil)
        connection.send(content: data, completion: .contentProcessed { failure in
            result.set(failure)
            done.signal()
        })
        guard done.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
        if let failure = result.value() { throw failure }
    }
    func chunk(_ pcm: Data) throws {
        var data = Data("\(String(pcm.count, radix: 16))\r\n".utf8)
        data.append(pcm)
        data.append(Data("\r\n".utf8))
        try send(data)
    }
    do {
        try PhononSpeech.shared.stream(text: input.input, language: language, voice: input.voice) { pcm in
            if !started {
                started = true
                try send(Data(("HTTP/1.1 200 OK\r\nContent-Type: \(wav ? "audio/wav" : "application/octet-stream")\r\n"
                    + "Transfer-Encoding: chunked\r\nCache-Control: no-store\r\nConnection: close\r\n"
                    + "X-Audio-Sample-Rate: 24000\r\nX-Audio-Channels: 1\r\nX-Audio-Format: s16le\r\n"
                    + "X-Audio-Language: \(language.xaiCode)\r\n\r\n").utf8))
                if wav { try chunk(SpeechPCM.streamingWaveHeader) }
                logEvent("phonon API first_pcm_seconds=\(ProcessInfo.processInfo.systemUptime - began)")
            }
            try chunk(pcm)
        }
        if started {
            try send(Data("0\r\n\r\n".utf8))
            connection.cancel()
        } else {
            respondError(500, "Model produced no audio")
        }
    } catch {
        if started {
            // No terminating chunk: clients can distinguish a truncated stream from successful completion.
            connection.cancel()
        } else {
            respondError(error is PhononSpeechError ? 429 : 500, String(describing: error))
        }
        logEvent("phonon API ended error=\(error)")
    }
}
