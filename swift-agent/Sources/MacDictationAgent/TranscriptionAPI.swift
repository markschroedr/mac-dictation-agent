import Foundation
import Network

let transcriptionAPIPort = ProcessInfo.processInfo.environment["MAC_DICTATION_API_PORT"] ?? "8767"
private let maxTranscriptionUploadBytes = 25 * 1024 * 1024

/// Loopback OpenAI-compatible transcription endpoint for local tools. It shares the
/// hotkey-dictation helper, so requests queue behind dictation chunks and reuse its idle shutdown.
final class TranscriptionAPIServer: @unchecked Sendable {
    private let asr: FluidDictationClient
    private let queue = DispatchQueue(label: "com.markschroedr.mac-dictation.transcription-api")
    private var listener: NWListener?

    init(asr: FluidDictationClient) {
        self.asr = asr
    }

    func start() {
        guard let port = NWEndpoint.Port(transcriptionAPIPort) else {
            logEvent("transcription API disabled; invalid port=\(transcriptionAPIPort)")
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: logEvent("transcription API listening url=http://127.0.0.1:\(transcriptionAPIPort)")
                case .failed(let error): logEvent("transcription API failed error=\(error)")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            logEvent("transcription API failed error=\(error)")
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] bytes, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let bytes { buffer.append(bytes) }
            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                if complete { connection.cancel() } else { self.receive(connection, buffer: buffer) }
            case .invalid(let status, let message):
                self.respond(connection, .error(status, message))
            case .complete(let request):
                DispatchQueue.global(qos: .userInitiated).async {
                    self.respond(connection, self.handle(request))
                }
            }
        }
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .json(HealthBody())
        case ("POST", "/v1/audio/transcriptions"):
            return transcribe(request)
        default:
            return .error(404, "not found")
        }
    }

    private func transcribe(_ request: HTTPRequest) -> HTTPResponse {
        let fields = multipartFields(request.body, contentType: request.headers["content-type"])
        guard let upload = fields["file"], !upload.data.isEmpty else {
            return .error(400, "multipart field 'file' with audio is required")
        }
        // OpenAI semantics: json carries only the text; verbose_json adds metadata.
        let format = fields["response_format"].flatMap { String(data: $0.data, encoding: .utf8) } ?? "json"
        guard ["json", "text", "verbose_json"].contains(format) else {
            return .error(400, "unsupported response_format: \(format)")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-dictation-api-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { asr.scheduleShutdown() }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // CoreAudio infers the container from the extension, so keep the upload's.
            let fileExtension = ((upload.filename ?? "") as NSString).pathExtension
            let audioURL = directory.appendingPathComponent(fileExtension.isEmpty ? "upload" : "upload.\(fileExtension)")
            try upload.data.write(to: audioURL)
            let started = CFAbsoluteTimeGetCurrent()
            let response = try asr.transcribe(
                sessionID: "api-\(UUID().uuidString)",
                chunkIndex: 1,
                audioURL: audioURL,
                final: true
            )
            let text = sanitize(response.text ?? "")
            logEvent(
                "transcription API request end bytes=\(upload.data.count) "
                    + "audio=\(String(format: "%.3f", response.duration_seconds ?? 0))s "
                    + "total=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - started))s chars=\(text.count)"
            )
            switch format {
            case "text": return HTTPResponse(status: 200, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
            case "verbose_json": return .json(VerboseTranscriptionBody(duration: response.duration_seconds, text: text))
            default: return .json(TranscriptionBody(text: text))
            }
        } catch {
            logEvent("transcription API request failed error=\(error)")
            return .error(500, "\(error)", type: "server_error")
        }
    }

    private func respond(_ connection: NWConnection, _ response: HTTPResponse) {
        let status = response.status
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 411: reason = "Length Required"
        case 413: reason = "Payload Too Large"
        case 431: reason = "Request Header Fields Too Large"
        default: reason = "Internal Server Error"
        }
        var data = Data(
            "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n".utf8
        )
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func json<Value: Encodable>(_ value: Value) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "application/json", body: encode(value))
    }

    static func error(_ status: Int, _ message: String, type: String = "invalid_request_error") -> HTTPResponse {
        HTTPResponse(
            status: status,
            contentType: "application/json",
            body: encode(ErrorBody(error: .init(message: message, type: type)))
        )
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    enum Parse {
        case incomplete
        case invalid(Int, String)
        case complete(HTTPRequest)
    }

    static func parse(_ data: Data) -> Parse {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 16_384 ? .invalid(431, "request headers are too large") : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid(400, "request headers are not UTF-8")
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3 else { return .invalid(400, "invalid request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil {
            return .invalid(411, "chunked request bodies are not supported; send Content-Length")
        }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
            return .invalid(400, "invalid Content-Length")
        }
        guard length <= maxTranscriptionUploadBytes else { return .invalid(413, "audio upload exceeds 25 MB") }
        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        let path = requestLine[1].split(separator: "?", maxSplits: 1)[0]
        return .complete(HTTPRequest(
            method: String(requestLine[0]),
            path: String(path),
            headers: headers,
            body: Data(data[bodyStart..<(bodyStart + length)])
        ))
    }
}

private func multipartFields(_ body: Data, contentType: String?) -> [String: (filename: String?, data: Data)] {
    guard let contentType, contentType.lowercased().hasPrefix("multipart/form-data"),
          let boundaryStart = contentType.range(of: "boundary=", options: .caseInsensitive) else {
        return [:]
    }
    let boundary = contentType[boundaryStart.upperBound...]
        .split(separator: ";")[0]
        .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    let delimiter = Data("--\(boundary)".utf8)
    let headerSeparator = Data("\r\n\r\n".utf8)
    var fields: [String: (filename: String?, data: Data)] = [:]
    var cursor = body.startIndex
    while let start = body.range(of: delimiter, in: cursor..<body.endIndex),
          let next = body.range(of: delimiter, in: start.upperBound..<body.endIndex) {
        let part = body[start.upperBound..<next.lowerBound]
        if let headerEnd = part.range(of: headerSeparator),
           let partHeaders = String(data: part[part.startIndex..<headerEnd.lowerBound], encoding: .utf8),
           let name = headerValue("name", in: partHeaders) {
            // The CRLF before the next delimiter belongs to the delimiter, not the field.
            let content = part[headerEnd.upperBound..<part.endIndex].dropLast(2)
            fields[name] = (headerValue("filename", in: partHeaders), Data(content))
        }
        cursor = next.lowerBound
    }
    return fields
}

private func headerValue(_ name: String, in headers: String) -> String? {
    // The leading space keeps "name" from matching inside "filename".
    guard let start = headers.range(of: " \(name)=\"", options: .caseInsensitive),
          let end = headers[start.upperBound...].firstIndex(of: "\"") else {
        return nil
    }
    return String(headers[start.upperBound..<end])
}

private struct HealthBody: Encodable {
    let ok = true
    let service = "mac-dictation-agent"
    let backend = "fluid-audio-parakeet-v3"
}

private struct TranscriptionBody: Encodable {
    let text: String
}

private struct VerboseTranscriptionBody: Encodable {
    let task = "transcribe"
    let duration: Double?
    let text: String
}

private struct ErrorBody: Encodable {
    struct Detail: Encodable {
        let message: String
        let type: String
    }

    let error: Detail
}

private func encode<Value: Encodable>(_ value: Value) -> Data {
    (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
}
