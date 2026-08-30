import Foundation

public enum LocalTTSServiceAction: String, Codable, Sendable {
    case health
    case synthesize
    case unload
    case shutdown
}

public enum LocalTTSLanguage: String, Codable, Sendable, CaseIterable {
    case english
    case german
}

public struct LocalTTSServiceRequest: Codable, Sendable {
    public let id: String
    public let action: LocalTTSServiceAction
    public let input: String?
    public let language: LocalTTSLanguage?
    public let voice: String?
    public let outputPath: String?

    public init(
        id: String = UUID().uuidString,
        action: LocalTTSServiceAction,
        input: String? = nil,
        language: LocalTTSLanguage? = nil,
        voice: String? = nil,
        outputPath: String? = nil
    ) {
        self.id = id
        self.action = action
        self.input = input
        self.language = language
        self.voice = voice
        self.outputPath = outputPath
    }
}

public struct LocalTTSServiceResponse: Codable, Sendable {
    public let id: String
    public let outputPath: String?
    public let byteCount: Int?
    public let loadedLanguage: LocalTTSLanguage?
    public let loadSeconds: Double?
    public let synthesizeSeconds: Double?
    public let error: String?

    public init(
        id: String,
        outputPath: String? = nil,
        byteCount: Int? = nil,
        loadedLanguage: LocalTTSLanguage? = nil,
        loadSeconds: Double? = nil,
        synthesizeSeconds: Double? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.outputPath = outputPath
        self.byteCount = byteCount
        self.loadedLanguage = loadedLanguage
        self.loadSeconds = loadSeconds
        self.synthesizeSeconds = synthesizeSeconds
        self.error = error
    }
}
