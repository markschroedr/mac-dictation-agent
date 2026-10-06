import Foundation

public enum DictationServiceAction: String, Codable, Sendable {
    case warmup
    case resetSession
    case transcribe
    case shutdown
}

public struct DictationServiceRequest: Codable, Sendable {
    public let id: String
    public let action: DictationServiceAction
    public let sessionID: String?
    public let chunkIndex: Int?
    public let path: String?
    public let final: Bool

    public init(
        id: String = UUID().uuidString,
        action: DictationServiceAction,
        sessionID: String? = nil,
        chunkIndex: Int? = nil,
        path: String? = nil,
        final: Bool = false
    ) {
        self.id = id
        self.action = action
        self.sessionID = sessionID
        self.chunkIndex = chunkIndex
        self.path = path
        self.final = final
    }
}

public struct DictationTextSegment: Codable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct DictationServiceResponse: Codable, Sendable {
    public let id: String
    public let text: String?
    public let rawText: String?
    public let segments: [DictationTextSegment]?
    public let durationSeconds: Double?
    public let recognizeSeconds: Double?
    public let speedup: Double?
    public let error: String?

    public init(
        id: String,
        text: String? = nil,
        rawText: String? = nil,
        segments: [DictationTextSegment]? = nil,
        durationSeconds: Double? = nil,
        recognizeSeconds: Double? = nil,
        speedup: Double? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.text = text
        self.rawText = rawText
        self.segments = segments
        self.durationSeconds = durationSeconds
        self.recognizeSeconds = recognizeSeconds
        self.speedup = speedup
        self.error = error
    }

    public func replacingID(with id: String) -> DictationServiceResponse {
        DictationServiceResponse(
            id: id,
            text: text,
            rawText: rawText,
            segments: segments,
            durationSeconds: durationSeconds,
            recognizeSeconds: recognizeSeconds,
            speedup: speedup,
            error: error
        )
    }
}
