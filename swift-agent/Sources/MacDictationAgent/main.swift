import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreGraphics
import Darwin
import DictationServiceProtocol
import Foundation
import NaturalLanguage
import LocalTTSServiceProtocol
import UniformTypeIdentifiers

setbuf(stdout, nil)
setbuf(stderr, nil)

let agentRoot = ProcessInfo.processInfo.environment["MAC_DICTATION_AGENT_ROOT"].map {
    URL(fileURLWithPath: $0)
} ?? FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Mac Dictation Agent/runtime")
let applicationSupportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Mac Dictation Agent", isDirectory: true)
let dataRoot = ProcessInfo.processInfo.environment["MAC_DICTATION_DATA_ROOT"].map {
    URL(fileURLWithPath: $0)
} ?? applicationSupportRoot
let workerDir = agentRoot.appendingPathComponent("asr_worker")
let logDir = dataRoot.appendingPathComponent("logs")
let debugAudioDir = dataRoot.appendingPathComponent("recordings/debug")
let dictationRecoveryDir = dataRoot.appendingPathComponent("recordings/recovery")
let ttsAudioDir = dataRoot.appendingPathComponent("tts-audio")
let ttsEnvFile = dataRoot.appendingPathComponent("tts.env")
let dictationTranscriptsDir = dataRoot.appendingPathComponent("transcripts/dictation")
let manualTranscriptsDir = dataRoot.appendingPathComponent("transcripts/manual-files")
let bundledPermanentTranscriberDataRoot = dataRoot.appendingPathComponent("permanent-transcriber")
let bundledPermanentTranscriberRoot = agentRoot.appendingPathComponent("vendor/permanent-transcriber")
let permanentTranscriberCodeRoot = ProcessInfo.processInfo.environment["MAC_DICTATION_PERMANENT_TRANSCRIBER_CODE_ROOT"].map {
    URL(fileURLWithPath: $0)
} ?? bundledPermanentTranscriberRoot
let permanentTranscriberDataRoot = ProcessInfo.processInfo.environment["MAC_DICTATION_PERMANENT_TRANSCRIBER_DATA_ROOT"].map {
    URL(fileURLWithPath: $0)
} ?? ProcessInfo.processInfo.environment["PERMANENT_TRANSCRIBER_ROOT"].map {
    URL(fileURLWithPath: $0)
} ?? bundledPermanentTranscriberDataRoot
let permanentTranscriberExecutable = permanentTranscriberCodeRoot.appendingPathComponent(".venv/bin/permanent-transcriber")
let permanentTranscriberStorageDir = permanentTranscriberDataRoot.appendingPathComponent("storage")
let sharedModelRoot = ProcessInfo.processInfo.environment["MAC_DICTATION_MODEL_ROOT"].map {
    URL(fileURLWithPath: $0)
} ?? permanentTranscriberStorageDir.appendingPathComponent("models")
let fluidModelRoot = ProcessInfo.processInfo.environment["MAC_DICTATION_FLUID_MODEL_ROOT"].map {
    URL(fileURLWithPath: $0)
} ?? applicationSupportRoot.appendingPathComponent("models/fluid-audio", isDirectory: true)
let fluidServiceExecutable = ProcessInfo.processInfo.environment["MAC_DICTATION_FLUID_SERVICE_BIN"].map {
    URL(fileURLWithPath: $0)
} ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FluidDictationService")
let systemAudioHelperExecutable = ProcessInfo.processInfo.environment["MAC_DICTATION_SYSTEM_AUDIO_HELPER"].map {
    URL(fileURLWithPath: $0)
} ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SystemAudioCapture")
let supertonicTTSServiceExecutable = ProcessInfo.processInfo.environment[
    "MAC_DICTATION_SUPERTONIC_TTS_SERVICE_BIN"
].map {
    URL(fileURLWithPath: $0)
} ?? agentRoot.appendingPathComponent(
    "supertonic_worker/.venv/bin/supertonic-tts-worker"
)
let supertonicTTSModelRoot = ProcessInfo.processInfo.environment[
    "MAC_DICTATION_SUPERTONIC_TTS_MODEL_ROOT"
].map {
    URL(fileURLWithPath: $0)
} ?? applicationSupportRoot.appendingPathComponent(
    "models/supertonic-3",
    isDirectory: true
)
let permanentTranscriberTranscriptRoot = permanentTranscriberStorageDir.appendingPathComponent("transcripts")
let permanentTranscriberModeDefaultsKey = "permanentTranscriberMode"
let asrPort = ProcessInfo.processInfo.environment["MAC_DICTATION_ASR_PORT"] ?? "8766"
let asrBaseURL = "http://127.0.0.1:\(asrPort)"
let chunkSeconds = 20.0
let finalChunkPostrollSeconds = 0.45
let asrIdleShutdownSeconds = Double(ProcessInfo.processInfo.environment["MAC_DICTATION_ASR_IDLE_SECONDS"] ?? "") ?? 60.0
let asrWarmupTimeoutSeconds = Double(ProcessInfo.processInfo.environment["MAC_DICTATION_ASR_WARMUP_TIMEOUT_SECONDS"] ?? "") ?? 60.0
let asrTranscribeTimeoutFloorSeconds = Double(ProcessInfo.processInfo.environment["MAC_DICTATION_ASR_TRANSCRIBE_TIMEOUT_FLOOR_SECONDS"] ?? "") ?? 12.0
let asrTranscribeTimeoutCeilingSeconds = Double(ProcessInfo.processInfo.environment["MAC_DICTATION_ASR_TRANSCRIBE_TIMEOUT_CEILING_SECONDS"] ?? "") ?? 30.0
let fluidIdleShutdownSeconds = Double(ProcessInfo.processInfo.environment["MAC_DICTATION_FLUID_IDLE_SECONDS"] ?? "") ?? 60.0
let localTTSIdleShutdownSeconds = Double(
    ProcessInfo.processInfo.environment["MAC_DICTATION_TTS_IDLE_SECONDS"] ?? ""
) ?? 300.0
let fluidWarmupTimeoutSeconds = Double(ProcessInfo.processInfo.environment["MAC_DICTATION_FLUID_WARMUP_TIMEOUT_SECONDS"] ?? "") ?? 600.0
let fluidSessionPrepareTimeoutSeconds = Double(
    ProcessInfo.processInfo.environment["MAC_DICTATION_FLUID_SESSION_PREPARE_TIMEOUT_SECONDS"] ?? ""
) ?? (fluidWarmupTimeoutSeconds + 10.0)
let fluidTranscribeTimeoutSeconds = Double(ProcessInfo.processInfo.environment["MAC_DICTATION_FLUID_TRANSCRIBE_TIMEOUT_SECONDS"] ?? "") ?? 30.0
let audioInputDefaultsKey = "audioInputName"
let retainSuccessfulAudioDefaultsKey = "retainSuccessfulDictationAudio"
let recoveryRetentionHoursDefaultsKey = "dictationRecoveryRetentionHours"
let defaultRecoveryRetentionHours = 24
let launchAgentLabel = ProcessInfo.processInfo.environment["MAC_DICTATION_LAUNCH_AGENT_LABEL"]
    ?? "com.markschroedr.mac-dictation"
let launchAgentPlist = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
let agentStartedAt = DispatchTime.now().uptimeNanoseconds

func isoTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

func logEvent(_ message: String) {
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - agentStartedAt) / 1_000_000_000
    print("[\(isoTimestamp(Date())) +\(String(format: "%.3f", elapsed))s] \(message)")
}

enum RecoveryRetentionPreference {
    static let choices: [(hours: Int, title: String)] = [
        (24, "24 Hours"),
        (24 * 7, "7 Days"),
        (24 * 30, "30 Days"),
        (0, "Forever"),
    ]

    static var hours: Int {
        if let configured = UserDefaults.standard.object(forKey: recoveryRetentionHoursDefaultsKey) as? NSNumber {
            return max(0, configured.intValue)
        }
        // The former checkbox meant unlimited successful-audio retention. Preserve that
        // explicit choice without rewriting the live preference domain during migration.
        if UserDefaults.standard.bool(forKey: retainSuccessfulAudioDefaultsKey) {
            return 0
        }
        return defaultRecoveryRetentionHours
    }

    static func setHours(_ hours: Int) {
        UserDefaults.standard.set(max(0, hours), forKey: recoveryRetentionHoursDefaultsKey)
    }
}

@discardableResult
func runProcess(_ executable: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        fputs("process failed: \(executable) \(arguments.joined(separator: " ")): \(error)\n", stderr)
        return 1
    }
}

func processOutput(_ executable: String, _ arguments: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    } catch {
        return ""
    }
}

struct ProcessRunResult {
    let status: Int32
    let output: String
}

final class SynchronizedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    func set(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func value() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

func runProcessCapturingOutput(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String]? = nil,
    currentDirectory: URL? = nil
) -> ProcessRunResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    process.currentDirectoryURL = currentDirectory
    if let environment {
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            merged[key] = value
        }
        process.environment = merged
    }
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessRunResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    } catch {
        return ProcessRunResult(status: 1, output: "\(error)")
    }
}

enum TTSProvider: String, Sendable {
    case supertonic
    case inworld
    case xai

    var displayName: String {
        switch self {
        case .supertonic:
            return "Supertonic 3 (local)"
        case .inworld:
            return "Inworld"
        case .xai:
            return "Grok/xAI"
        }
    }

    var secretName: String? {
        switch self {
        case .supertonic:
            return nil
        case .inworld:
            return "INWORLD_API_KEY"
        case .xai:
            return "XAI_API_KEY"
        }
    }

    var maxChunkCharacters: Int {
        switch self {
        case .supertonic:
            return 5_000
        case .inworld:
            return 1900
        case .xai:
            return 15000
        }
    }

    var audioExtension: String {
        switch self {
        case .supertonic:
            return "wav"
        case .inworld, .xai:
            return "mp3"
        }
    }

    var isLocal: Bool {
        self == .supertonic
    }

    var maxConcurrentRequests: Int {
        switch self {
        case .supertonic:
            return 1
        case .inworld:
            return 10
        case .xai:
            return 4
        }
    }

    func supports(_ language: TTSLanguage) -> Bool {
        language != .auto || self != .supertonic
    }
}

enum TTSLanguage: String, CaseIterable, Sendable {
    case auto
    case english
    case german

    static let defaultsKey = "ttsLanguage"

    var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .english:
            return "English"
        case .german:
            return "German"
        }
    }

    var inworldCode: String? {
        switch self {
        case .auto:
            return nil
        case .english:
            return "en-US"
        case .german:
            return "de-DE"
        }
    }

    var xaiCode: String {
        switch self {
        case .auto:
            return "auto"
        case .english:
            return "en"
        case .german:
            return "de"
        }
    }

    var defaultInworldVoiceID: String {
        switch self {
        case .auto:
            return "Duncan"
        case .english:
            return "Duncan"
        case .german:
            return "Tobias"
        }
    }

    var defaultXAIVoiceID: String {
        switch self {
        case .auto:
            return "sal"
        case .english:
            return "rex"
        case .german:
            return "sal"
        }
    }

    func resolved(for text: String) -> TTSLanguage {
        guard self == .auto else {
            return self
        }
        let sample = String(text.prefix(4000))
        guard let detected = NLLanguageRecognizer.dominantLanguage(for: sample) else {
            return .auto
        }
        switch detected {
        case .english:
            return .english
        case .german:
            return .german
        default:
            return .auto
        }
    }

    static func current() -> TTSLanguage {
        guard
            let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
            let language = TTSLanguage(rawValue: rawValue)
        else {
            return .auto
        }
        return language
    }

    static func setCurrent(_ language: TTSLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
    }
}

enum QuickTTSPreset: String, CaseIterable {
    case supertonicM1, inworldConfigured, xaiLeo

    var provider: TTSProvider {
        switch self {
        case .supertonicM1: return .supertonic
        case .inworldConfigured: return .inworld
        case .xaiLeo: return .xai
        }
    }

    var voiceID: String? {
        switch self {
        case .supertonicM1: return "M1"
        case .inworldConfigured: return nil
        case .xaiLeo: return "leo"
        }
    }

    var displayName: String {
        switch self {
        case .supertonicM1: return "Supertonic 3 — M1 (local)"
        case .inworldConfigured: return "Inworld — Configured Voice (cloud)"
        case .xaiLeo: return "Grok/xAI — Leo (cloud)"
        }
    }

    static func current() -> QuickTTSPreset? {
        UserDefaults.standard.string(forKey: "quickTTSPreset").flatMap(QuickTTSPreset.init(rawValue:))
    }
}

enum ClipboardTTSError: Error, CustomStringConvertible {
    case emptyClipboard
    case alreadyRunning
    case missingSecret(String)
    case requestFailed(String)
    case invalidResponse(String)

    var description: String {
        switch self {
        case .emptyClipboard:
            return "Clipboard is empty"
        case .alreadyRunning:
            return "TTS generation is already running"
        case .missingSecret(let name):
            return "\(name) is not set"
        case .requestFailed(let message):
            return message
        case .invalidResponse(let message):
            return message
        }
    }
}

struct TTSRunResult {
    let openURL: URL
    let runDir: URL
    let chunkCount: Int
    let characterCount: Int
    let metrics: TTSRunMetrics
}

private struct RemoteTTSChunkJob: Sendable {
    let index: Int
    let text: String
    let outputURL: URL
}

private final class RemoteTTSBatchState: @unchecked Sendable {
    private let lock = NSLock()
    private let jobs: [RemoteTTSChunkJob]
    private var nextJobIndex = 0
    private var completedCount = 0
    private var byteCounts: [Int: Int] = [:]
    private var firstError: Error?

    init(jobs: [RemoteTTSChunkJob]) {
        self.jobs = jobs
    }

    func claimJob() -> RemoteTTSChunkJob? {
        lock.lock()
        defer { lock.unlock() }
        guard firstError == nil, nextJobIndex < jobs.count else {
            return nil
        }
        let job = jobs[nextJobIndex]
        nextJobIndex += 1
        return job
    }

    func recordSuccess(index: Int, byteCount: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        byteCounts[index] = byteCount
        completedCount += 1
        return completedCount
    }

    func recordFailure(_ error: Error) {
        lock.lock()
        if firstError == nil {
            firstError = error
        }
        lock.unlock()
    }

    func validatedByteCounts() throws -> [Int: Int] {
        lock.lock()
        defer { lock.unlock() }
        if let firstError {
            throw firstError
        }
        guard byteCounts.count == jobs.count else {
            throw ClipboardTTSError.invalidResponse(
                "TTS generation ended before every chunk completed"
            )
        }
        return byteCounts
    }
}

final class SecretResolver {
    static func value(for key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }

        for path in candidateEnvFiles() {
            if let value = value(for: key, in: path) {
                return value
            }
        }

        return nil
    }

    private static func candidateEnvFiles() -> [URL] {
        [ttsEnvFile]
    }

    private static func value(for key: String, in fileURL: URL) -> String? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let equalsIndex = line.firstIndex(of: "=") else {
                continue
            }
            let parsedKey = line[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard parsedKey == key else {
                continue
            }
            var value = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

struct LocalTTSClientConfiguration {
    let displayName: String
    let logName: String
    let executable: URL
    let modelRoot: URL
    let modelRootEnvironmentVariable: String
}

enum LocalTTSClientError: Error, CustomStringConvertible {
    case requestFailed(String)
    case serviceError(String)

    var description: String {
        switch self {
        case .requestFailed(let message), .serviceError(let message):
            return message
        }
    }
}

final class LocalTTSClient {
    private let configuration: LocalTTSClientConfiguration
    private let lock = NSRecursiveLock()
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var idleShutdownWorkItem: DispatchWorkItem?
    private var activityGeneration = 0

    init(configuration: LocalTTSClientConfiguration) {
        self.configuration = configuration
    }

    func synthesize(
        text: String,
        language: TTSLanguage,
        voiceID: String? = nil,
        outputURL: URL
    ) throws -> Int {
        cancelIdleShutdown()
        let serviceLanguage: LocalTTSLanguage
        switch language {
        case .english:
            serviceLanguage = .english
        case .german:
            serviceLanguage = .german
        case .auto:
            throw LocalTTSClientError.requestFailed(
                "\(configuration.displayName) requires English or German after language resolution"
            )
        }
        let requestBody = LocalTTSServiceRequest(
            action: .synthesize,
            input: text,
            language: serviceLanguage,
            voice: voiceID,
            outputPath: outputURL.path
        )

        var lastError: Error?
        for attempt in 1...2 {
            do {
                let response = try request(requestBody, timeout: 1_800)
                if let error = response.error {
                    throw LocalTTSClientError.serviceError(error)
                }
                guard
                    response.outputPath == outputURL.path,
                    FileManager.default.fileExists(atPath: outputURL.path)
                else {
                    throw LocalTTSClientError.requestFailed(
                        "\(configuration.displayName) did not produce the requested output file"
                    )
                }
                let byteCount = if let responseByteCount = response.byteCount {
                    responseByteCount
                } else {
                    try Data(contentsOf: outputURL).count
                }
                logEvent(
                    "\(configuration.displayName) request complete language="
                        + "\(serviceLanguage.rawValue) load="
                        + "\(Self.formatSeconds(response.loadSeconds)) synthesize="
                        + "\(Self.formatSeconds(response.synthesizeSeconds))"
                )
                scheduleIdleShutdown()
                return byteCount
            } catch let error as LocalTTSClientError {
                lastError = error
                if case .serviceError = error {
                    throw error
                }
                restart(reason: "request attempt \(attempt) failed")
            } catch {
                lastError = error
                restart(reason: "request attempt \(attempt) failed")
            }
        }
        throw lastError ?? LocalTTSClientError.requestFailed(
            "\(configuration.displayName) failed without an error"
        )
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        cancelIdleShutdownLocked()
        guard let process, process.isRunning else {
            clearProcessLocked()
            return
        }
        logEvent(
            "\(configuration.displayName) service shutdown requested pid=\(process.processIdentifier)"
        )
        _ = try? request(
            LocalTTSServiceRequest(action: .shutdown),
            timeout: 10
        )
        if process.isRunning {
            process.terminate()
        }
        clearProcessLocked()
    }

    private func request(
        _ request: LocalTTSServiceRequest,
        timeout: Double
    ) throws -> LocalTTSServiceResponse {
        lock.lock()
        defer { lock.unlock() }
        try ensureProcessLocked()
        guard let inputHandle, let outputHandle else {
            throw LocalTTSClientError.requestFailed(
                "\(configuration.displayName) pipes are unavailable"
            )
        }

        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
        let responseData = try readLine(
            from: outputHandle.fileDescriptor,
            timeout: timeout
        )
        let response = try JSONDecoder().decode(
            LocalTTSServiceResponse.self,
            from: responseData
        )
        guard response.id == request.id else {
            throw LocalTTSClientError.requestFailed(
                "\(configuration.displayName) response mismatch expected=\(request.id) "
                    + "actual=\(response.id)"
            )
        }
        return response
    }

    private func ensureProcessLocked() throws {
        if let process, process.isRunning {
            return
        }
        clearProcessLocked()
        guard FileManager.default.isExecutableFile(
            atPath: configuration.executable.path
        ) else {
            throw LocalTTSClientError.requestFailed(
                "\(configuration.displayName) service is missing or not executable: "
                    + configuration.executable.path
            )
        }

        try FileManager.default.createDirectory(
            at: logDir,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: configuration.modelRoot,
            withIntermediateDirectories: true
        )
        let serviceLogURL = logDir.appendingPathComponent(
            "\(configuration.logName).log"
        )
        if !FileManager.default.fileExists(atPath: serviceLogURL.path) {
            FileManager.default.createFile(
                atPath: serviceLogURL.path,
                contents: nil
            )
        }
        let serviceErrorHandle = try FileHandle(
            forWritingTo: serviceLogURL
        )
        try serviceErrorHandle.seekToEnd()

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let serviceProcess = Process()
        serviceProcess.executableURL = configuration.executable
        serviceProcess.standardInput = inputPipe
        serviceProcess.standardOutput = outputPipe
        serviceProcess.standardError = serviceErrorHandle
        var environment = ProcessInfo.processInfo.environment
        environment[configuration.modelRootEnvironmentVariable] =
            configuration.modelRoot.path
        serviceProcess.environment = environment
        try serviceProcess.run()

        process = serviceProcess
        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
        errorHandle = serviceErrorHandle
        logEvent(
            "\(configuration.displayName) service launched pid=\(serviceProcess.processIdentifier)"
        )
    }

    private func readLine(
        from fileDescriptor: Int32,
        timeout: Double
    ) throws -> Data {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while accumulated.count <= 1_048_576 {
            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            guard remaining > 0 else {
                throw LocalTTSClientError.requestFailed(
                    "\(configuration.displayName) response timed out"
                )
            }
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let milliseconds = Int32(
                min(Double(Int32.max), ceil(remaining * 1_000))
            )
            let pollResult = Darwin.poll(
                &descriptor,
                1,
                milliseconds
            )
            if pollResult < 0 && errno == EINTR {
                continue
            }
            guard pollResult > 0 else {
                throw LocalTTSClientError.requestFailed(
                    pollResult == 0
                        ? "\(configuration.displayName) response timed out"
                        : "\(configuration.displayName) poll failed errno=\(errno)"
                )
            }
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    fileDescriptor,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            guard bytesRead > 0 else {
                throw LocalTTSClientError.requestFailed(
                    "\(configuration.displayName) service closed its response pipe"
                )
            }
            accumulated.append(buffer, count: bytesRead)
            if let newline = accumulated.firstIndex(of: 0x0A) {
                return Data(accumulated[..<newline])
            }
        }
        throw LocalTTSClientError.requestFailed(
            "\(configuration.displayName) response exceeded 1 MB"
        )
    }

    private func restart(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        cancelIdleShutdownLocked()
        logEvent("\(configuration.displayName) service restart reason=\(reason)")
        if let process, process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 2
            ) {
                if process.isRunning {
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
        }
        clearProcessLocked()
    }

    private func cancelIdleShutdown() {
        lock.lock()
        defer { lock.unlock() }
        cancelIdleShutdownLocked()
    }

    private func cancelIdleShutdownLocked() {
        idleShutdownWorkItem?.cancel()
        idleShutdownWorkItem = nil
        activityGeneration += 1
    }

    private func scheduleIdleShutdown() {
        lock.lock()
        defer { lock.unlock() }
        cancelIdleShutdownLocked()
        guard localTTSIdleShutdownSeconds > 0 else {
            return
        }
        let expectedGeneration = activityGeneration
        let item = DispatchWorkItem { [weak self] in
            self?.shutdownIfIdle(expectedGeneration: expectedGeneration)
        }
        idleShutdownWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + localTTSIdleShutdownSeconds,
            execute: item
        )
        logEvent(
            "\(configuration.displayName) idle shutdown scheduled after "
                + "\(String(format: "%.0f", localTTSIdleShutdownSeconds))s"
        )
    }

    private func shutdownIfIdle(expectedGeneration: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard
            activityGeneration == expectedGeneration,
            idleShutdownWorkItem != nil
        else {
            return
        }
        idleShutdownWorkItem = nil
        guard let process, process.isRunning else {
            clearProcessLocked()
            return
        }
        logEvent(
            "\(configuration.displayName) idle shutdown pid=\(process.processIdentifier)"
        )
        process.terminate()
        clearProcessLocked()
    }

    private func clearProcessLocked() {
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        process = nil
    }

    private static func formatSeconds(_ value: Double?) -> String {
        guard let value else {
            return "cached"
        }
        return "\(String(format: "%.3f", value))s"
    }
}

extension LocalTTSClient: @unchecked Sendable {}

final class ClipboardTTSManager {
    private let lock = NSLock()
    private var isRunning = false
    private var latestPlayback: ProgressiveVLCPlayback?
    private let queue = DispatchQueue(label: "com.markschroedr.mac-dictation.tts", qos: .userInitiated)
    private let supertonic = LocalTTSClient(
        configuration: LocalTTSClientConfiguration(
            displayName: "Supertonic 3",
            logName: "supertonic-tts-service",
            executable: supertonicTTSServiceExecutable,
            modelRoot: supertonicTTSModelRoot,
            modelRootEnvironmentVariable: "MAC_DICTATION_SUPERTONIC_TTS_MODEL_ROOT"
        )
    )

    func speakClipboard(
        provider: TTSProvider,
        voiceID: String? = nil,
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void,
        completion: @escaping @Sendable (_ errorDescription: String?) -> Void
    ) {
        queue.async {
            do {
                let text = try self.clipboardText()
                let selectedLanguage = TTSLanguage.current()
                let result = try self.generateSpeech(
                    text: text,
                    provider: provider,
                    language: selectedLanguage,
                    voiceID: voiceID,
                    play: true,
                    progress: progress
                )
                logEvent("tts finished provider=\(provider.rawValue) selected_language=\(selectedLanguage.rawValue) chars=\(result.characterCount) chunks=\(result.chunkCount) open=\(result.openURL.path)")
                completion(nil)
            } catch {
                playErrorSound()
                logEvent("tts failed provider=\(provider.rawValue) error=\(error)")
                completion(String(describing: error))
            }
        }
    }

    func generateSpeech(
        text: String,
        provider: TTSProvider,
        language: TTSLanguage,
        voiceID: String? = nil,
        play: Bool,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) throws -> TTSRunResult {
        lock.lock()
        if isRunning {
            lock.unlock()
            throw ClipboardTTSError.alreadyRunning
        }
        isRunning = true
        lock.unlock()
        defer {
            lock.lock()
            isRunning = false
            lock.unlock()
        }

        let sourceText = normalizedInput(text)
        guard !sourceText.isEmpty else {
            throw ClipboardTTSError.emptyClipboard
        }
        guard provider.supports(language) else {
            throw ClipboardTTSError.invalidResponse(
                "\(provider.displayName) requires English or German; Auto is not supported"
            )
        }
        let effectiveLanguage = language.resolved(for: sourceText)
        guard !provider.isLocal || effectiveLanguage != .auto else {
            throw ClipboardTTSError.invalidResponse(
                "\(provider.displayName) could not resolve the text as English or German"
            )
        }
        let apiKey: String?
        if let secretName = provider.secretName {
            guard let resolved = SecretResolver.value(for: secretName) else {
                throw ClipboardTTSError.missingSecret(secretName)
            }
            apiKey = resolved
        } else {
            apiKey = nil
        }

        try FileManager.default.createDirectory(at: ttsAudioDir, withIntermediateDirectories: true)
        let stamp = Self.timestamp()
        let languageLabel = language == effectiveLanguage ? language.rawValue : "\(language.rawValue)-\(effectiveLanguage.rawValue)"
        let runDir = ttsAudioDir.appendingPathComponent("\(stamp)-\(provider.rawValue)-\(languageLabel)")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

        let metrics = TTSRunMetrics(provider: provider)
        let chunks = ProgressiveTTSChunker.chunks(
            text: sourceText,
            maximumCharacters: provider.maxChunkCharacters
        )
        let playback = play
            ? try ProgressiveVLCPlayback(
                metrics: metrics,
                chunkCount: chunks.count
            )
            : nil
        lock.lock()
        let previousPlayback = latestPlayback
        latestPlayback = playback
        lock.unlock()
        previousPlayback?.abort()
        logEvent(
            "tts start provider=\(provider.rawValue) selected_language=\(language.rawValue) "
                + "effective_language=\(effectiveLanguage.rawValue) chars=\(sourceText.count) "
                + "chunks=\(chunks.count) chunk_words=\(chunks.map { $0.split(whereSeparator: \Character.isWhitespace).count })"
        )
        progress?(0, chunks.count)

        let onChunkReady: @Sendable (Int, URL) throws -> Void = { index, url in
            if index == 1 {
                metrics.markFirstAudioReady()
            }
            try playback?.accept(index: index, url: url)
        }

        let chunkFiles: [URL]
        do {
            if provider.isLocal {
                chunkFiles = try synthesizeLocalChunks(
                    chunks,
                    provider: provider,
                    language: effectiveLanguage,
                    voiceID: voiceID,
                    runDir: runDir,
                    progress: progress,
                    onChunkReady: onChunkReady
                )
            } else {
                guard let apiKey else {
                    throw ClipboardTTSError.invalidResponse(
                        "\(provider.displayName) API key was not resolved"
                    )
                }
                chunkFiles = try synthesizeRemoteChunks(
                    chunks,
                    provider: provider,
                    language: effectiveLanguage,
                    voiceID: voiceID,
                    apiKey: apiKey,
                    runDir: runDir,
                    progress: progress,
                    onChunkReady: onChunkReady
                )
            }
        } catch {
            playback?.abort(error: "TTS generation failed: \(error)")
            throw error
        }

        let openURL = runDir.appendingPathComponent(
            "audio.\(chunks.count > 1 && !provider.isLocal ? "m4a" : provider.audioExtension)"
        )
        do {
            try JoinedTTSWriter.write(
                chunks: chunkFiles,
                provider: provider,
                to: openURL
            )
        } catch {
            playback?.abort(error: "Could not join TTS audio: \(error)")
            throw error
        }
        playback?.finish(expectedChunkCount: chunkFiles.count)
        metrics.markGenerationCompleted()
        lock.lock()
        latestPlayback = playback
        lock.unlock()

        return TTSRunResult(
            openURL: openURL,
            runDir: runDir,
            chunkCount: chunks.count,
            characterCount: sourceText.count,
            metrics: metrics
        )
    }

    private func synthesizeLocalChunks(
        _ chunks: [String],
        provider: TTSProvider,
        language: TTSLanguage,
        voiceID: String?,
        runDir: URL,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?,
        onChunkReady: @Sendable (_ index: Int, _ url: URL) throws -> Void
    ) throws -> [URL] {
        var chunkFiles: [URL] = []
        for (offset, chunk) in chunks.enumerated() {
            let index = offset + 1
            let chunkURL = chunkURL(
                in: runDir,
                index: index,
                extension: provider.audioExtension
            )
            let byteCount = try supertonic.synthesize(
                text: chunk,
                language: language,
                voiceID: voiceID,
                outputURL: chunkURL
            )
            chunkFiles.append(chunkURL)
            try onChunkReady(index, chunkURL)
            logChunkCompletion(
                provider: provider,
                index: index,
                total: chunks.count,
                byteCount: byteCount
            )
            progress?(index, chunks.count)
        }
        return chunkFiles
    }

    private func synthesizeRemoteChunks(
        _ chunks: [String],
        provider: TTSProvider,
        language: TTSLanguage,
        voiceID: String?,
        apiKey: String,
        runDir: URL,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?,
        onChunkReady: @escaping @Sendable (_ index: Int, _ url: URL) throws -> Void
    ) throws -> [URL] {
        let jobs = chunks.enumerated().map { offset, text in
            let index = offset + 1
            return RemoteTTSChunkJob(
                index: index,
                text: text,
                outputURL: chunkURL(
                    in: runDir,
                    index: index,
                    extension: provider.audioExtension
                )
            )
        }
        let state = RemoteTTSBatchState(jobs: jobs)
        let workerCount = min(provider.maxConcurrentRequests, jobs.count)
        let group = DispatchGroup()

        for _ in 0..<workerCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                while let job = state.claimJob() {
                    do {
                        let audioData = try self.synthesizeRemote(
                            chunk: job.text,
                            provider: provider,
                            language: language,
                            voiceID: voiceID,
                            apiKey: apiKey
                        )
                        try audioData.write(to: job.outputURL, options: .atomic)
                        try onChunkReady(job.index, job.outputURL)
                        let completed = state.recordSuccess(
                            index: job.index,
                            byteCount: audioData.count
                        )
                        self.logChunkCompletion(
                            provider: provider,
                            index: job.index,
                            total: chunks.count,
                            byteCount: audioData.count
                        )
                        progress?(completed, chunks.count)
                    } catch {
                        state.recordFailure(error)
                        return
                    }
                }
            }
        }

        group.wait()
        _ = try state.validatedByteCounts()
        return jobs.map(\.outputURL)
    }

    private func chunkURL(
        in runDir: URL,
        index: Int,
        extension audioExtension: String
    ) -> URL {
        runDir.appendingPathComponent(
            String(format: "chunk-%03d.%@", index, audioExtension)
        )
    }

    private func logChunkCompletion(
        provider: TTSProvider,
        index: Int,
        total: Int,
        byteCount: Int
    ) {
        logEvent(
            "tts chunk provider=\(provider.rawValue) index=\(index)/\(total) bytes=\(byteCount)"
        )
    }

    func waitForPlayback() -> String? {
        lock.lock()
        let playback = latestPlayback
        lock.unlock()
        return playback?.waitUntilFinished()
    }

    func shutdown() {
        lock.lock()
        let playback = latestPlayback
        lock.unlock()
        playback?.abort(error: "TTS manager shut down")
        supertonic.shutdown()
    }

    private func clipboardText() throws -> String {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            throw ClipboardTTSError.emptyClipboard
        }
        return text
    }

    private func normalizedInput(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func synthesizeRemote(
        chunk text: String,
        provider: TTSProvider,
        language: TTSLanguage,
        voiceID: String?,
        apiKey: String
    ) throws -> Data {
        switch provider {
        case .supertonic:
            throw ClipboardTTSError.invalidResponse(
                "\(provider.displayName) must use the local service"
            )
        case .inworld:
            return try synthesizeInworld(text: text, language: language, voiceOverride: voiceID, apiKey: apiKey)
        case .xai:
            return try synthesizeXAI(text: text, language: language, voiceOverride: voiceID, apiKey: apiKey)
        }
    }

    private func synthesizeInworld(text: String, language: TTSLanguage, voiceOverride: String?, apiKey: String) throws -> Data {
        let voiceID = voiceOverride ?? configuredVoiceID(
            keys: [
                "MAC_DICTATION_INWORLD_\(language.rawValue.uppercased())_VOICE_ID",
                "MAC_DICTATION_INWORLD_VOICE_ID",
            ],
            defaultVoiceID: language.defaultInworldVoiceID
        )
        logEvent("tts request provider=inworld language=\(language.rawValue) voice=\(voiceID)")
        let modelID = ProcessInfo.processInfo.environment["MAC_DICTATION_INWORLD_TTS_MODEL"] ?? "inworld-tts-1.5-max"
        var payload: [String: Any] = [
            "text": text,
            "voiceId": voiceID,
            "modelId": modelID,
            "speakingRate": 1.0,
            "temperature": 1.27,
            "timestampType": "WORD",
            "applyTextNormalization": "ON",
            "audioConfig": [
                "encoding": "MP3",
                "sampleRateHz": 44100,
            ],
        ]
        if let languageCode = language.inworldCode {
            payload["language"] = languageCode
        }
        let data = try requestJSON(
            url: URL(string: "https://api.inworld.ai/tts/v1/voice")!,
            headers: [
                "Authorization": "Basic \(apiKey)",
                "Content-Type": "application/json",
            ],
            payload: payload
        )
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let audioContent = object["audioContent"] as? String,
            let audio = Data(base64Encoded: audioContent)
        else {
            throw ClipboardTTSError.invalidResponse("Inworld response did not include audioContent")
        }
        return audio
    }

    private func synthesizeXAI(text: String, language: TTSLanguage, voiceOverride: String?, apiKey: String) throws -> Data {
        let voiceID = voiceOverride ?? configuredVoiceID(
            keys: [
                "MAC_DICTATION_XAI_\(language.rawValue.uppercased())_VOICE_ID",
                "MAC_DICTATION_XAI_VOICE_ID",
            ],
            defaultVoiceID: language.defaultXAIVoiceID
        )
        logEvent("tts request provider=xai language=\(language.rawValue) voice=\(voiceID)")
        let payload: [String: Any] = [
            "text": text,
            "voice_id": voiceID,
            "language": language.xaiCode,
            "output_format": [
                "codec": "mp3",
                "sample_rate": 24000,
                "bit_rate": 128000,
            ],
        ]
        return try requestJSON(
            url: URL(string: "https://api.x.ai/v1/tts")!,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
            ],
            payload: payload
        )
    }

    private func configuredVoiceID(keys: [String], defaultVoiceID: String) -> String {
        for key in keys {
            if let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return defaultVoiceID
    }

    private func requestJSON(url: URL, headers: [String: String], payload: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: payload)
        var lastError: Error?
        for attempt in 0..<4 {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.httpBody = body
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let (data, statusCode, error) = perform(request: request, timeout: 122)
            if let error {
                lastError = error
            } else if let statusCode, (200..<300).contains(statusCode), let data, !data.isEmpty {
                return data
            } else if let statusCode, statusCode == 429 || (500..<600).contains(statusCode) {
                lastError = ClipboardTTSError.requestFailed("TTS server returned HTTP \(statusCode)")
            } else {
                let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                throw ClipboardTTSError.requestFailed("TTS request failed HTTP \(statusCode ?? 0): \(bodyText.prefix(500))")
            }

            if attempt < 3 {
                Thread.sleep(forTimeInterval: pow(2.0, Double(attempt)))
            }
        }
        throw ClipboardTTSError.requestFailed("TTS request failed after retries: \(lastError?.localizedDescription ?? "unknown error")")
    }

    private func perform(request: URLRequest, timeout: TimeInterval) -> (Data?, Int?, Error?) {
        let semaphore = DispatchSemaphore(value: 0)
        let result = HTTPResultBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            result.set(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode, error: error)
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return (nil, nil, ClipboardTTSError.requestFailed("TTS request timed out"))
        }
        return result.snapshot()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}

extension ClipboardTTSManager: @unchecked Sendable {}

final class HTTPResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var statusCode: Int?
    private var error: Error?

    func set(data: Data?, statusCode: Int?, error: Error?) {
        lock.lock()
        self.data = data
        self.statusCode = statusCode
        self.error = error
        lock.unlock()
    }

    func snapshot() -> (Data?, Int?, Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (data, statusCode, error)
    }
}

final class AudioRecorder {
    private final class PCMBufferSlot {
        let bytes: UnsafeMutableRawPointer
        let capacity: Int
        var byteCount = 0
        var packetCount: UInt32 = 0
        var segmentID: UInt64 = 0

        init(capacity: Int) {
            self.capacity = capacity
            bytes = UnsafeMutableRawPointer.allocate(
                byteCount: capacity,
                alignment: MemoryLayout<Int16>.alignment
            )
        }

        deinit {
            bytes.deallocate()
        }
    }

    private struct SegmentWriterState {
        let url: URL
        let file: AudioFileID
        var packetIndex: Int64 = 0
        var capturedBytes: UInt64 = 0
        var capturedPackets: UInt64 = 0
        var firstWriteError: OSStatus?
    }

    private struct FinalizedSegment {
        let url: URL
        let capturedBytes: UInt64
        let capturedPackets: UInt64
        let droppedBuffers: UInt64
        let writeError: OSStatus?
    }

    private let lock = NSLock()
    private let writerQueue = DispatchQueue(
        label: "com.markschroedr.mac-dictation.audio-writer",
        qos: .userInitiated
    )
    private var queue: AudioQueueRef?
    private var isStopping = false
    private(set) var currentURL: URL?
    private var currentDeviceName = "system default"
    private var currentSegmentID: UInt64 = 0
    private var nextSegmentID: UInt64 = 1
    private var ringSlots: [PCMBufferSlot] = []
    private var ringReadIndex: UInt64 = 0
    private var ringWriteIndex: UInt64 = 0
    private var writerScheduled = false
    private var segmentDroppedBuffers: UInt64 = 0
    private var capturedBytes: UInt64 = 0
    private var capturedPackets: UInt64 = 0
    private var firstBufferAt: CFAbsoluteTime?
    private var recordingStartedAt: CFAbsoluteTime = 0
    private var writerSegments: [UInt64: SegmentWriterState] = [:]
    private var format = AudioStreamBasicDescription(
        mSampleRate: 16_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        mBytesPerPacket: 2,
        mFramesPerPacket: 1,
        mBytesPerFrame: 2,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 16,
        mReserved: 0
    )
    private let startupFrameTimeoutSeconds = 0.75
    private let bufferCount = 3
    private let bufferDurationSeconds = 0.08
    private let ringSlotCount = 128

    func preflight() {
        let started = CFAbsoluteTimeGetCurrent()
        let device = AudioInputDeviceSelection.current()
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        logEvent("audio preflight end recorder=audioqueue input=\(device.logDescription) elapsed=\(String(format: "%.3f", elapsed))s")
    }

    func start(outputDirectory: URL? = nil, filename: String? = nil) throws -> URL {
        var lastError: Error?
        for attempt in 1...2 {
            do {
                let url = try startOnce(attempt: attempt, outputDirectory: outputDirectory, filename: filename)
                if attempt > 1 {
                    logEvent("audio recorder start recovered attempt=\(attempt)")
                }
                return url
            } catch {
                lastError = error
                logEvent("audio recorder start attempt=\(attempt) failed error=\(error)")
                cleanupCurrentRecording(removeFile: outputDirectory == nil)
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.10)
                }
            }
        }
        throw lastError ?? AudioRecorderError.noAudioFramesAfterStart(timeoutSeconds: startupFrameTimeoutSeconds)
    }

    private func startOnce(attempt: Int, outputDirectory: URL?, filename: String?) throws -> URL {
        let started = CFAbsoluteTimeGetCurrent()
        cleanupCurrentRecording(removeFile: outputDirectory == nil)
        let url = try newAudioURL(outputDirectory: outputDirectory, filename: filename)
        let device = AudioInputDeviceSelection.current()
        var localFormat = format
        var localQueue: AudioQueueRef?
        var localFile: AudioFileID?
        var localSegmentID: UInt64 = 0

        let createQueueStatus = AudioQueueNewInput(
            &localFormat,
            audioQueueInputHandler,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &localQueue
        )
        guard createQueueStatus == noErr, let localQueue else {
            throw AudioRecorderError.audioQueueFailed(operation: "AudioQueueNewInput", status: createQueueStatus)
        }

        do {
            if let uid = device.uid {
                try setAudioQueueDevice(queue: localQueue, uid: uid)
            }

            let createFileStatus = AudioFileCreateWithURL(
                url as CFURL,
                kAudioFileWAVEType,
                &localFormat,
                .eraseFile,
                &localFile
            )
            guard createFileStatus == noErr, let localFile else {
                throw AudioRecorderError.audioQueueFailed(operation: "AudioFileCreateWithURL", status: createFileStatus)
            }

            let bufferByteSize = UInt32(localFormat.mSampleRate * Double(localFormat.mBytesPerFrame) * bufferDurationSeconds)
            for _ in 0..<bufferCount {
                var buffer: AudioQueueBufferRef?
                let allocateStatus = AudioQueueAllocateBuffer(localQueue, bufferByteSize, &buffer)
                guard allocateStatus == noErr, let buffer else {
                    throw AudioRecorderError.audioQueueFailed(operation: "AudioQueueAllocateBuffer", status: allocateStatus)
                }
                let enqueueStatus = AudioQueueEnqueueBuffer(localQueue, buffer, 0, nil)
                guard enqueueStatus == noErr else {
                    throw AudioRecorderError.audioQueueFailed(operation: "AudioQueueEnqueueBuffer", status: enqueueStatus)
                }
            }

            lock.lock()
            localSegmentID = nextSegmentID
            nextSegmentID += 1
            queue = localQueue
            isStopping = false
            currentURL = url
            currentDeviceName = device.logDescription
            currentSegmentID = localSegmentID
            ringSlots = (0..<ringSlotCount).map { _ in PCMBufferSlot(capacity: Int(bufferByteSize)) }
            ringReadIndex = 0
            ringWriteIndex = 0
            writerScheduled = false
            segmentDroppedBuffers = 0
            capturedBytes = 0
            capturedPackets = 0
            firstBufferAt = nil
            recordingStartedAt = started
            lock.unlock()

            writerQueue.sync {
                writerSegments[localSegmentID] = SegmentWriterState(url: url, file: localFile)
            }

            let startStatus = AudioQueueStart(localQueue, nil)
            guard startStatus == noErr else {
                throw AudioRecorderError.audioQueueFailed(operation: "AudioQueueStart", status: startStatus)
            }
        } catch {
            lock.lock()
            if queue == localQueue {
                queue = nil
                isStopping = false
                currentURL = nil
                currentSegmentID = 0
                ringReadIndex = 0
                ringWriteIndex = 0
                writerScheduled = false
                capturedBytes = 0
                capturedPackets = 0
                firstBufferAt = nil
            }
            lock.unlock()
            AudioQueueDispose(localQueue, true)
            if localSegmentID != 0 {
                writerQueue.sync {
                    if let segment = writerSegments.removeValue(forKey: localSegmentID) {
                        AudioFileClose(segment.file)
                    }
                }
            } else if let localFile {
                AudioFileClose(localFile)
            }
            if outputDirectory == nil {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }

        logEvent("audio recorder queue started attempt=\(attempt) input=\(device.logDescription) elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - started))s")
        guard waitForCapturedBytes(timeoutSeconds: startupFrameTimeoutSeconds) else {
            throw AudioRecorderError.noAudioFramesAfterStart(timeoutSeconds: startupFrameTimeoutSeconds)
        }
        lock.lock()
        let firstBufferLatency = firstBufferAt.map { $0 - recordingStartedAt } ?? -1
        lock.unlock()
        logEvent("audio recorder first buffer total_latency=\(String(format: "%.3f", firstBufferLatency))s")
        return url
    }

    func rotate(outputDirectory: URL? = nil, filename: String? = nil, context: String = "rotation") throws -> URL? {
        lock.lock()
        guard queue != nil, let completedURL = currentURL else {
            lock.unlock()
            return nil
        }
        let completedSegmentID = currentSegmentID
        var localFormat = format
        lock.unlock()

        let nextURL = try newAudioURL(outputDirectory: outputDirectory, filename: filename)
        var nextFile: AudioFileID?
        let createFileStatus = AudioFileCreateWithURL(
            nextURL as CFURL,
            kAudioFileWAVEType,
            &localFormat,
            .eraseFile,
            &nextFile
        )
        guard createFileStatus == noErr, let nextFile else {
            throw AudioRecorderError.audioQueueFailed(operation: "AudioFileCreateWithURL(rotation)", status: createFileStatus)
        }

        lock.lock()
        let nextID = nextSegmentID
        nextSegmentID += 1
        lock.unlock()
        writerQueue.sync {
            writerSegments[nextID] = SegmentWriterState(url: nextURL, file: nextFile)
        }

        lock.lock()
        guard queue != nil, currentSegmentID == completedSegmentID else {
            lock.unlock()
            writerQueue.sync {
                if let segment = writerSegments.removeValue(forKey: nextID) {
                    AudioFileClose(segment.file)
                }
            }
            if outputDirectory == nil {
                try? FileManager.default.removeItem(at: nextURL)
            }
            return nil
        }
        let completedWriteIndex = ringWriteIndex
        let droppedBuffers = segmentDroppedBuffers
        currentSegmentID = nextID
        currentURL = nextURL
        segmentDroppedBuffers = 0
        capturedBytes = 0
        capturedPackets = 0
        lock.unlock()

        let finalized = writerQueue.sync {
            finalizeSegment(
                id: completedSegmentID,
                through: completedWriteIndex,
                droppedBuffers: droppedBuffers
            )
        }
        logFinalizedSegment(finalized, context: context)
        guard hasCapturedAudio(at: completedURL) else {
            throw AudioRecorderError.noAudioCaptured(completedURL)
        }
        return completedURL
    }

    func stop(postrollSeconds: Double = 0, context: String = "stop") throws -> URL? {
        guard currentURL != nil else { return nil }
        if postrollSeconds > 0 {
            Thread.sleep(forTimeInterval: postrollSeconds)
        }
        return try stopCurrentProcess(context: context)
    }

    private func newAudioURL(outputDirectory: URL?, filename: String?) throws -> URL {
        guard let outputDirectory else {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("mac-dictation-\(UUID().uuidString).wav")
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let baseName = filename ?? "mac-dictation-\(UUID().uuidString).wav"
        let requestedURL = outputDirectory.appendingPathComponent(baseName)
        guard FileManager.default.fileExists(atPath: requestedURL.path) else {
            return requestedURL
        }
        let stem = requestedURL.deletingPathExtension().lastPathComponent
        let ext = requestedURL.pathExtension
        let recoveredName = ext.isEmpty
            ? "\(stem)-retry-\(UUID().uuidString)"
            : "\(stem)-retry-\(UUID().uuidString).\(ext)"
        return outputDirectory.appendingPathComponent(recoveredName)
    }

    private func cleanupCurrentRecording(removeFile: Bool) {
        let url = stopQueueWithoutValidation(context: "cleanup")
        if removeFile, let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func stopCurrentProcess(context: String) throws -> URL {
        guard let completedURL = stopQueueWithoutValidation(context: context) else {
            throw AudioRecorderError.noAudioCaptured(FileManager.default.temporaryDirectory)
        }
        guard hasCapturedAudio(at: completedURL) else {
            throw AudioRecorderError.noAudioCaptured(completedURL)
        }
        return completedURL
    }

    private func stopQueueWithoutValidation(context: String) -> URL? {
        lock.lock()
        let url = currentURL
        let localQueue = queue
        if localQueue != nil {
            isStopping = true
        }
        lock.unlock()

        guard let localQueue else { return url }
        let stopStatus = AudioQueueStop(localQueue, true)
        if stopStatus != noErr {
            logEvent("audio recorder queue stop failed status=\(stopStatus)")
        }

        lock.lock()
        let completedSegmentID = currentSegmentID
        let completedWriteIndex = ringWriteIndex
        let droppedBuffers = segmentDroppedBuffers
        let deviceName = currentDeviceName
        currentURL = nil
        queue = nil
        isStopping = false
        currentSegmentID = 0
        segmentDroppedBuffers = 0
        capturedBytes = 0
        capturedPackets = 0
        firstBufferAt = nil
        lock.unlock()

        AudioQueueDispose(localQueue, true)
        let finalized = writerQueue.sync {
            finalizeSegment(
                id: completedSegmentID,
                through: completedWriteIndex,
                droppedBuffers: droppedBuffers
            )
        }
        logFinalizedSegment(finalized, context: "\(context) input=\(deviceName)")

        lock.lock()
        ringReadIndex = 0
        ringWriteIndex = 0
        writerScheduled = false
        ringSlots.removeAll(keepingCapacity: false)
        lock.unlock()

        if let url {
            logEvent("audio recorder queue stopped input=\(deviceName) path=\(url.path)")
        }
        return url
    }

    private func waitForCapturedBytes(timeoutSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            lock.lock()
            let hasBytes = capturedBytes > 0
            let stillRunning = queue != nil
            lock.unlock()
            if !stillRunning {
                return false
            }
            if hasBytes {
                return true
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return false
    }

    fileprivate func handleInputBuffer(queue callbackQueue: AudioQueueRef, buffer: AudioQueueBufferRef, packetCount callbackPacketCount: UInt32) {
        let byteCount = buffer.pointee.mAudioDataByteSize
        guard byteCount > 0 else {
            _ = AudioQueueEnqueueBuffer(callbackQueue, buffer, 0, nil)
            return
        }

        var shouldScheduleWriter = false
        lock.lock()
        guard queue == callbackQueue, currentSegmentID != 0, !ringSlots.isEmpty else {
            lock.unlock()
            _ = AudioQueueEnqueueBuffer(callbackQueue, buffer, 0, nil)
            return
        }
        if firstBufferAt == nil {
            firstBufferAt = CFAbsoluteTimeGetCurrent()
        }
        var packetsToWrite = callbackPacketCount
        if packetsToWrite == 0 {
            packetsToWrite = byteCount / format.mBytesPerPacket
        }
        if ringWriteIndex - ringReadIndex >= UInt64(ringSlots.count) {
            segmentDroppedBuffers += 1
        } else {
            let slot = ringSlots[Int(ringWriteIndex % UInt64(ringSlots.count))]
            if Int(byteCount) > slot.capacity {
                segmentDroppedBuffers += 1
            } else {
                memcpy(slot.bytes, buffer.pointee.mAudioData, Int(byteCount))
                slot.byteCount = Int(byteCount)
                slot.packetCount = packetsToWrite
                slot.segmentID = currentSegmentID
                ringWriteIndex += 1
                shouldScheduleWriter = !writerScheduled
                writerScheduled = true
            }
            capturedBytes += UInt64(byteCount)
            capturedPackets += UInt64(packetsToWrite)
        }
        lock.unlock()

        lock.lock()
        let shouldReenqueue = queue == callbackQueue && !isStopping
        lock.unlock()
        if shouldReenqueue {
            let enqueueStatus = AudioQueueEnqueueBuffer(callbackQueue, buffer, 0, nil)
            if enqueueStatus != noErr {
                logEvent("audio recorder enqueue failed status=\(enqueueStatus)")
            }
        }
        if shouldScheduleWriter {
            writerQueue.async { [weak self] in
                self?.drainAvailableBuffers()
            }
        }
    }

    private func drainAvailableBuffers() {
        lock.lock()
        let targetWriteIndex = ringWriteIndex
        lock.unlock()
        drainBuffers(through: targetWriteIndex)

        lock.lock()
        if ringReadIndex < ringWriteIndex {
            lock.unlock()
            writerQueue.async { [weak self] in
                self?.drainAvailableBuffers()
            }
        } else {
            writerScheduled = false
            lock.unlock()
        }
    }

    private func drainBuffers(through targetWriteIndex: UInt64) {
        while true {
            lock.lock()
            guard ringReadIndex < targetWriteIndex, !ringSlots.isEmpty else {
                lock.unlock()
                return
            }
            let slot = ringSlots[Int(ringReadIndex % UInt64(ringSlots.count))]
            let byteCount = UInt32(slot.byteCount)
            let packetCount = slot.packetCount
            let segmentID = slot.segmentID
            let bytes = slot.bytes
            lock.unlock()

            if var segment = writerSegments[segmentID] {
                var packetsToWrite = packetCount
                let writeStatus = AudioFileWritePackets(
                    segment.file,
                    false,
                    byteCount,
                    nil,
                    segment.packetIndex,
                    &packetsToWrite,
                    bytes
                )
                if writeStatus == noErr {
                    segment.packetIndex += Int64(packetsToWrite)
                    segment.capturedBytes += UInt64(byteCount)
                    segment.capturedPackets += UInt64(packetsToWrite)
                } else if segment.firstWriteError == nil {
                    segment.firstWriteError = writeStatus
                }
                writerSegments[segmentID] = segment
            } else {
                logEvent("audio writer missing segment id=\(segmentID)")
            }

            lock.lock()
            ringReadIndex += 1
            lock.unlock()
        }
    }

    private func finalizeSegment(
        id: UInt64,
        through targetWriteIndex: UInt64,
        droppedBuffers: UInt64
    ) -> FinalizedSegment? {
        guard id != 0 else { return nil }
        drainBuffers(through: targetWriteIndex)
        guard let segment = writerSegments.removeValue(forKey: id) else { return nil }
        let closeStatus = AudioFileClose(segment.file)
        let writeError = segment.firstWriteError ?? (closeStatus == noErr ? nil : closeStatus)
        return FinalizedSegment(
            url: segment.url,
            capturedBytes: segment.capturedBytes,
            capturedPackets: segment.capturedPackets,
            droppedBuffers: droppedBuffers,
            writeError: writeError
        )
    }

    private func logFinalizedSegment(_ segment: FinalizedSegment?, context: String) {
        guard let segment else { return }
        logEvent(
            "audio segment finalized context=\(context) packets=\(segment.capturedPackets) "
                + "bytes=\(segment.capturedBytes) dropped_buffers=\(segment.droppedBuffers) "
                + "path=\(segment.url.path)"
        )
        if segment.droppedBuffers > 0 {
            fputs(
                "audio capture dropped \(segment.droppedBuffers) buffers; retained audio may be incomplete: \(segment.url.path)\n",
                stderr
            )
        }
        if let writeError = segment.writeError {
            fputs("audio writer failed status=\(writeError) path=\(segment.url.path)\n", stderr)
        }
    }

    private func setAudioQueueDevice(queue: AudioQueueRef, uid: String) throws {
        var cfUID = uid as CFString
        let status = withUnsafePointer(to: &cfUID) { pointer in
            AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, pointer, UInt32(MemoryLayout<CFString>.size))
        }
        guard status == noErr else {
            throw AudioRecorderError.audioQueueFailed(operation: "AudioQueueSetProperty(CurrentDevice)", status: status)
        }
    }

    private func hasCapturedAudio(at url: URL) -> Bool {
        if let stats = wavStats(url), stats.durationSeconds > 0.05 {
            return true
        }
        return (fileSize(url) ?? 0) > 4096
    }

    private func fileSize(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.uint64Value
    }
}

extension AudioRecorder: @unchecked Sendable {}

enum AudioRecorderError: Error, CustomStringConvertible {
    case noAudioFramesAfterStart(timeoutSeconds: Double)
    case noAudioCaptured(URL)
    case audioQueueFailed(operation: String, status: OSStatus)

    var description: String {
        switch self {
        case .noAudioFramesAfterStart(let timeoutSeconds):
            return "audio queue started but delivered no input frames within \(String(format: "%.2f", timeoutSeconds))s"
        case .noAudioCaptured(let url):
            return "no audio frames captured at \(url.path)"
        case .audioQueueFailed(let operation, let status):
            return "\(operation) failed status=\(status)"
        }
    }
}

private func audioQueueInputHandler(
    userData: UnsafeMutableRawPointer?,
    queue: AudioQueueRef,
    buffer: AudioQueueBufferRef,
    startTime: UnsafePointer<AudioTimeStamp>,
    packetCount: UInt32,
    packetDescriptions: UnsafePointer<AudioStreamPacketDescription>?
) {
    guard let userData else { return }
    let recorder = Unmanaged<AudioRecorder>.fromOpaque(userData).takeUnretainedValue()
    recorder.handleInputBuffer(queue: queue, buffer: buffer, packetCount: packetCount)
}

struct AudioInputDeviceSelection {
    let uid: String?
    let name: String
    let usesSystemDefault: Bool
    let preferenceValue: String

    var logDescription: String {
        if usesSystemDefault {
            return "system default (\(name))"
        }
        if let uid {
            return "\(name) uid=\(uid)"
        }
        return name
    }

    static func current() -> AudioInputDeviceSelection {
        let preference = currentPreference()
        if preference == ":default" || preference == "default" {
            return builtInInputDevice()
                ?? systemDefaultInputDevice().map {
                    AudioInputDeviceSelection(uid: nil, name: $0.name, usesSystemDefault: true, preferenceValue: ":default")
                }
                ?? AudioInputDeviceSelection(uid: nil, name: "unknown", usesSystemDefault: true, preferenceValue: ":default")
        }

        if preference == ":system-default" {
            return systemDefaultInputDevice().map {
                AudioInputDeviceSelection(uid: nil, name: $0.name, usesSystemDefault: true, preferenceValue: ":system-default")
            } ?? AudioInputDeviceSelection(uid: nil, name: "unknown", usesSystemDefault: true, preferenceValue: ":system-default")
        }

        let requested = preference.hasPrefix(":") ? String(preference.dropFirst()) : preference
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        if let index = Int(requested), devices.indices.contains(index) {
            let device = devices[index]
            return AudioInputDeviceSelection(uid: device.uniqueID, name: device.localizedName, usesSystemDefault: false, preferenceValue: device.uniqueID)
        }
        if let device = devices.first(where: { $0.localizedName == requested || $0.uniqueID == requested }) {
            return AudioInputDeviceSelection(uid: device.uniqueID, name: device.localizedName, usesSystemDefault: false, preferenceValue: device.uniqueID)
        }
        logEvent("audio input '\(preference)' not found; falling back to system default")
        return systemDefaultInputDevice().map {
            AudioInputDeviceSelection(uid: nil, name: $0.name, usesSystemDefault: true, preferenceValue: ":default")
        } ?? AudioInputDeviceSelection(uid: nil, name: "unknown", usesSystemDefault: true, preferenceValue: ":default")
    }

    static func allOptions() -> [AudioInputDeviceSelection] {
        let defaultOption = builtInInputDevice()
            ?? systemDefaultInputDevice().map {
                AudioInputDeviceSelection(uid: nil, name: $0.name, usesSystemDefault: true, preferenceValue: ":default")
            }
            ?? AudioInputDeviceSelection(uid: nil, name: "System Default", usesSystemDefault: true, preferenceValue: ":default")
        let systemDefaultName = systemDefaultInputDevice()?.name ?? "System Default"
        let systemDefaultOption = AudioInputDeviceSelection(uid: nil, name: systemDefaultName, usesSystemDefault: true, preferenceValue: ":system-default")
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices.map {
            AudioInputDeviceSelection(uid: $0.uniqueID, name: $0.localizedName, usesSystemDefault: false, preferenceValue: $0.uniqueID)
        }
        return [defaultOption, systemDefaultOption] + devices
    }

    static func currentPreference() -> String {
        if let environmentValue = ProcessInfo.processInfo.environment["MAC_DICTATION_AUDIO_INPUT"], !environmentValue.isEmpty {
            return environmentValue
        }
        return UserDefaults.standard.string(forKey: audioInputDefaultsKey) ?? ":default"
    }

    static func setCurrentPreference(_ value: String) {
        UserDefaults.standard.set(value, forKey: audioInputDefaultsKey)
    }

    private static func systemDefaultInputDevice() -> AudioInputDeviceSelection? {
        if let device = AVCaptureDevice.default(for: .audio) {
            return AudioInputDeviceSelection(uid: device.uniqueID, name: device.localizedName, usesSystemDefault: false, preferenceValue: device.uniqueID)
        }
        return nil
    }

    private static func builtInInputDevice() -> AudioInputDeviceSelection? {
        coreAudioInputDevices().first(where: { $0.transportType == kAudioDeviceTransportTypeBuiltIn }).map {
            AudioInputDeviceSelection(uid: $0.uid, name: $0.name, usesSystemDefault: false, preferenceValue: ":default")
        }
    }
}

private struct CoreAudioInputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32
}

private func coreAudioInputDevices() -> [CoreAudioInputDevice] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
        return []
    }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else { return [] }
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
        return []
    }
    return deviceIDs.compactMap { deviceID in
        guard hasInputStreams(deviceID),
              let uid = coreAudioStringProperty(deviceID, kAudioDevicePropertyDeviceUID),
              let name = coreAudioStringProperty(deviceID, kAudioObjectPropertyName),
              let transportType = coreAudioUInt32Property(deviceID, kAudioDevicePropertyTransportType)
        else {
            return nil
        }
        return CoreAudioInputDevice(id: deviceID, uid: uid, name: name, transportType: transportType)
    }
}

private func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr && dataSize > 0
}

private func coreAudioStringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value) == noErr else {
        return nil
    }
    return value?.takeUnretainedValue() as String?
}

private func coreAudioUInt32Property(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var dataSize = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value) == noErr else {
        return nil
    }
    return value
}

struct TranscriptionResponse: Decodable {
    let text: String?
    let raw_text: String?
    let duration_seconds: Double?
    let recognize_seconds: Double?
    let speedup: Double?
    let error: String?
}

enum ASRClientError: Error, CustomStringConvertible {
    case requestFailed(String)
    case workerError(String)

    var description: String {
        switch self {
        case .requestFailed(let message):
            return message
        case .workerError(let message):
            return message
        }
    }
}

final class FluidDictationClient {
    private let lock = NSRecursiveLock()
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var idleShutdownWorkItem: DispatchWorkItem?
    private var generation = 0

    func warmupSync() {
        logEvent("Fluid ASR warmup begin")
        let started = CFAbsoluteTimeGetCurrent()
        do {
            _ = try request(
                DictationServiceRequest(action: .warmup),
                timeout: fluidWarmupTimeoutSeconds
            )
            logEvent("Fluid ASR warmup end request=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - started))s")
        } catch {
            logEvent("Fluid ASR warmup failed error=\(error)")
            restartService(reason: "warmup failed")
        }
    }

    func resetSession(_ sessionID: String) {
        logEvent("Fluid ASR reset begin session=\(sessionID)")
        do {
            _ = try request(
                DictationServiceRequest(action: .resetSession, sessionID: sessionID),
                timeout: 8
            )
        } catch {
            logEvent("Fluid ASR reset failed session=\(sessionID) error=\(error)")
            restartService(reason: "reset failed")
        }
        logEvent("Fluid ASR reset end session=\(sessionID)")
    }

    func transcribe(
        sessionID: String,
        chunkIndex: Int,
        audioURL: URL,
        final: Bool = false
    ) throws -> TranscriptionResponse {
        logEvent("Fluid ASR request begin session=\(sessionID) chunk=\(chunkIndex) final=\(final)")
        let requestBody = DictationServiceRequest(
            action: .transcribe,
            sessionID: sessionID,
            chunkIndex: chunkIndex,
            path: audioURL.path,
            final: final
        )
        var lastError: Error?
        for attempt in 1...2 {
            let started = CFAbsoluteTimeGetCurrent()
            do {
                let response = try request(requestBody, timeout: fluidTranscribeTimeoutSeconds)
                if let error = response.error {
                    throw ASRClientError.workerError(error)
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                logEvent(
                    "Fluid ASR request end session=\(sessionID) chunk=\(chunkIndex) "
                        + "attempt=\(attempt) total=\(String(format: "%.3f", elapsed))s"
                )
                return TranscriptionResponse(
                    text: response.text,
                    raw_text: response.rawText,
                    duration_seconds: response.durationSeconds,
                    recognize_seconds: response.recognizeSeconds,
                    speedup: response.speedup,
                    error: response.error
                )
            } catch {
                lastError = error
                logEvent(
                    "Fluid ASR request failed session=\(sessionID) chunk=\(chunkIndex) "
                        + "attempt=\(attempt) error=\(error)"
                )
                restartService(reason: "transcribe request failed")
            }
        }
        throw lastError ?? ASRClientError.requestFailed("Fluid ASR failed without an error")
    }

    func scheduleShutdown() {
        lock.lock()
        cancelScheduledShutdownLocked()
        generation += 1
        let expectedGeneration = generation
        let item = DispatchWorkItem { [weak self] in
            self?.shutdownIfIdle(expectedGeneration: expectedGeneration)
        }
        idleShutdownWorkItem = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + fluidIdleShutdownSeconds,
            execute: item
        )
        logEvent("Fluid ASR idle shutdown scheduled after \(String(format: "%.0f", fluidIdleShutdownSeconds))s")
    }

    func cancelScheduledShutdownForActivity() {
        lock.lock()
        cancelScheduledShutdownLocked()
        generation += 1
        lock.unlock()
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        if idleShutdownWorkItem != nil {
            generation += 1
        }
        cancelScheduledShutdownLocked()
        shutdownLocked()
    }

    private func request(
        _ request: DictationServiceRequest,
        timeout: Double
    ) throws -> DictationServiceResponse {
        lock.lock()
        defer { lock.unlock() }
        if idleShutdownWorkItem != nil {
            generation += 1
        }
        cancelScheduledShutdownLocked()
        try ensureProcessLocked()
        guard let inputHandle, let outputHandle else {
            throw ASRClientError.requestFailed("Fluid ASR pipes are unavailable")
        }

        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
        let responseData = try readLine(from: outputHandle.fileDescriptor, timeout: timeout)
        let response = try JSONDecoder().decode(DictationServiceResponse.self, from: responseData)
        guard response.id == request.id else {
            throw ASRClientError.requestFailed(
                "Fluid ASR response mismatch expected=\(request.id) actual=\(response.id)"
            )
        }
        return response
    }

    private func ensureProcessLocked() throws {
        if let process, process.isRunning {
            return
        }
        clearProcessLocked()
        guard FileManager.default.isExecutableFile(atPath: fluidServiceExecutable.path) else {
            throw ASRClientError.requestFailed(
                "Fluid ASR service is missing or not executable: \(fluidServiceExecutable.path)"
            )
        }

        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fluidModelRoot, withIntermediateDirectories: true)
        let serviceLogURL = logDir.appendingPathComponent("fluid-dictation-service.log")
        if !FileManager.default.fileExists(atPath: serviceLogURL.path) {
            FileManager.default.createFile(atPath: serviceLogURL.path, contents: nil)
        }
        let serviceErrorHandle = try FileHandle(forWritingTo: serviceLogURL)
        try serviceErrorHandle.seekToEnd()

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let serviceProcess = Process()
        serviceProcess.executableURL = fluidServiceExecutable
        serviceProcess.standardInput = inputPipe
        serviceProcess.standardOutput = outputPipe
        serviceProcess.standardError = serviceErrorHandle
        var environment = ProcessInfo.processInfo.environment
        environment["MAC_DICTATION_FLUID_MODEL_ROOT"] = fluidModelRoot.path
        serviceProcess.environment = environment
        try serviceProcess.run()

        process = serviceProcess
        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
        errorHandle = serviceErrorHandle
        generation += 1
        logEvent("Fluid ASR service launched pid=\(serviceProcess.processIdentifier)")
    }

    private func readLine(from fileDescriptor: Int32, timeout: Double) throws -> Data {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while accumulated.count <= 1_048_576 {
            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            guard remaining > 0 else {
                throw ASRClientError.requestFailed("Fluid ASR response timed out")
            }
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min(Double(Int32.max), ceil(remaining * 1000)))
            let pollResult = Darwin.poll(&descriptor, 1, milliseconds)
            if pollResult < 0 && errno == EINTR {
                continue
            }
            guard pollResult > 0 else {
                throw ASRClientError.requestFailed(
                    pollResult == 0 ? "Fluid ASR response timed out" : "Fluid ASR poll failed errno=\(errno)"
                )
            }
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            guard bytesRead > 0 else {
                throw ASRClientError.requestFailed("Fluid ASR service closed its response pipe")
            }
            accumulated.append(buffer, count: bytesRead)
            if let newline = accumulated.firstIndex(of: 0x0A) {
                return Data(accumulated[..<newline])
            }
        }
        throw ASRClientError.requestFailed("Fluid ASR response exceeded 1 MB")
    }

    private func restartService(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        logEvent("Fluid ASR service restart reason=\(reason)")
        terminateProcessLocked()
    }

    private func shutdownIfIdle(expectedGeneration: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else {
            logEvent("Fluid ASR idle shutdown skipped; generation changed")
            return
        }
        idleShutdownWorkItem = nil
        shutdownLocked()
    }

    private func shutdownLocked() {
        guard let process, process.isRunning else {
            clearProcessLocked()
            return
        }
        logEvent("Fluid ASR service shutdown requested pid=\(process.processIdentifier)")
        do {
            _ = try request(DictationServiceRequest(action: .shutdown), timeout: 10)
        } catch {
            logEvent("Fluid ASR graceful shutdown failed error=\(error)")
        }
        if process.isRunning {
            process.terminate()
        }
        clearProcessLocked()
    }

    private func terminateProcessLocked() {
        if let process, process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning {
                    logEvent("Fluid ASR service force killing pid=\(pid)")
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
        }
        clearProcessLocked()
    }

    private func clearProcessLocked() {
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        process = nil
        generation += 1
    }

    private func cancelScheduledShutdownLocked() {
        idleShutdownWorkItem?.cancel()
        idleShutdownWorkItem = nil
    }
}

extension FluidDictationClient: @unchecked Sendable {}

final class MLXASRClient {
    private var workerProcess: Process?
    private let lifecycleLock = NSLock()
    private var warmupGroup: DispatchGroup?
    private var idleShutdownWorkItem: DispatchWorkItem?
    private var workerGeneration = 0

    func ensureRunning() {
        cancelScheduledShutdownForActivity()
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        if health() {
            logEvent("ASR health ok")
            return
        }

        let started = CFAbsoluteTimeGetCurrent()
        if let process = workerProcess, process.isRunning {
            logEvent("ASR worker already running; waiting for health pid=\(process.processIdentifier)")
        } else {
            logEvent("ASR worker cold start begin")
            startWorker()
        }

        for _ in 0..<300 {
            if health() {
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                logEvent("ASR worker health ready after \(String(format: "%.3f", elapsed))s")
                return
            }
            if let process = workerProcess, !process.isRunning {
                logEvent("ASR worker exited before health pid=\(process.processIdentifier) status=\(process.terminationStatus)")
                workerProcess = nil
                workerGeneration += 1
                logEvent("ASR worker cold start begin")
                startWorker()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        logEvent("ASR worker health not ready after \(String(format: "%.3f", elapsed))s")
    }

    func warmup() {
        let group = DispatchGroup()
        lifecycleLock.lock()
        warmupGroup = group
        lifecycleLock.unlock()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            self.warmupSync()
            group.leave()
            self.lifecycleLock.lock()
            if self.warmupGroup === group {
                self.warmupGroup = nil
            }
            self.lifecycleLock.unlock()
        }
    }

    func warmupSync() {
        logEvent("ASR warmup begin")
        ensureRunning()
        let started = CFAbsoluteTimeGetCurrent()
        do {
            _ = try postJSON(path: "/warmup", body: Data(), timeout: asrWarmupTimeoutSeconds)
        } catch {
            logEvent("ASR warmup failed error=\(error)")
            restartWorker(reason: "warmup failed")
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        logEvent("ASR warmup end request=\(String(format: "%.3f", elapsed))s")
    }

    func resetSession(_ sessionID: String) {
        logEvent("ASR reset begin session=\(sessionID)")
        ensureRunning()
        let body = try! JSONSerialization.data(withJSONObject: ["session_id": sessionID])
        do {
            _ = try postJSON(path: "/reset-session", body: body, timeout: 8)
        } catch {
            logEvent("ASR reset failed session=\(sessionID) error=\(error)")
            restartWorker(reason: "reset failed")
        }
        logEvent("ASR reset end session=\(sessionID)")
    }

    func transcribe(sessionID: String, chunkIndex: Int, audioURL: URL, final: Bool = false) throws -> TranscriptionResponse {
        logEvent("ASR transcribe request begin session=\(sessionID) chunk=\(chunkIndex)")
        ensureRunning()
        let body = try JSONSerialization.data(withJSONObject: [
            "session_id": sessionID,
            "chunk_index": chunkIndex,
            "path": audioURL.path,
            "final": final,
        ])
        let audioSeconds = wavStats(audioURL)?.durationSeconds ?? chunkSeconds
        let timeout = transcribeTimeoutSeconds(audioSeconds: audioSeconds)
        var lastError: Error?
        for attempt in 1...2 {
            let started = CFAbsoluteTimeGetCurrent()
            do {
                let data = try postJSON(path: "/transcribe-path", body: body, timeout: timeout)
                let response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
                if let error = response.error {
                    throw ASRClientError.workerError(error)
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                logEvent("ASR transcribe request end session=\(sessionID) chunk=\(chunkIndex) attempt=\(attempt) http=\(String(format: "%.3f", elapsed))s")
                return response
            } catch {
                lastError = error
                logEvent("ASR transcribe request failed session=\(sessionID) chunk=\(chunkIndex) attempt=\(attempt) timeout=\(String(format: "%.1f", timeout))s error=\(error)")
                restartWorker(reason: "transcribe request failed")
                if attempt < 2 {
                    ensureRunning()
                }
            }
        }
        throw lastError ?? ASRClientError.requestFailed("ASR transcribe failed without an error")
    }

    func shutdown() {
        shutdown(expectedPID: nil, expectedGeneration: nil)
    }

    private func shutdown(expectedPID: Int32?, expectedGeneration: Int?) {
        cancelScheduledShutdown()
        lifecycleLock.lock()
        if let expectedGeneration, workerGeneration != expectedGeneration {
            lifecycleLock.unlock()
            logEvent("ASR worker idle shutdown skipped; worker generation changed")
            return
        }
        if let expectedPID {
            guard let process = workerProcess, process.processIdentifier == expectedPID else {
                lifecycleLock.unlock()
                logEvent("ASR worker idle shutdown skipped; worker changed")
                return
            }
        } else if expectedGeneration != nil {
            guard workerProcess == nil else {
                lifecycleLock.unlock()
                logEvent("ASR worker idle shutdown skipped; worker ownership changed")
                return
            }
        }
        let group = warmupGroup
        lifecycleLock.unlock()
        if let group {
            _ = group.wait(timeout: .now() + 5)
        }
        if let expectedPID {
            lifecycleLock.lock()
            if let expectedGeneration, workerGeneration != expectedGeneration {
                lifecycleLock.unlock()
                logEvent("ASR worker idle shutdown skipped after warmup; worker generation changed")
                return
            }
            guard let process = workerProcess, process.processIdentifier == expectedPID else {
                lifecycleLock.unlock()
                logEvent("ASR worker idle shutdown skipped after warmup; worker changed")
                return
            }
            lifecycleLock.unlock()
        } else if let expectedGeneration {
            lifecycleLock.lock()
            guard workerProcess == nil, workerGeneration == expectedGeneration else {
                lifecycleLock.unlock()
                logEvent("ASR worker idle shutdown skipped after warmup; worker generation changed")
                return
            }
            lifecycleLock.unlock()
        }
        guard health() else { return }
        logEvent("ASR worker shutdown requested")
        _ = try? postJSON(path: "/shutdown", body: Data(), timeout: 5)
    }

    func scheduleShutdown() {
        cancelScheduledShutdown()
        logEvent("ASR worker left for service-owned idle exit after \(String(format: "%.0f", asrIdleShutdownSeconds))s")
    }

    func cancelScheduledShutdown() {
        lifecycleLock.lock()
        let item = idleShutdownWorkItem
        idleShutdownWorkItem = nil
        lifecycleLock.unlock()
        item?.cancel()
    }

    func cancelScheduledShutdownForActivity() {
        lifecycleLock.lock()
        let item = idleShutdownWorkItem
        idleShutdownWorkItem = nil
        workerGeneration += 1
        lifecycleLock.unlock()
        item?.cancel()
    }

    private func health() -> Bool {
        guard let url = URL(string: "\(asrBaseURL)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.25
        let semaphore = DispatchSemaphore(value: 0)
        let ok = SynchronizedBox(false)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                ok.set(true)
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 0.4)
        return ok.value()
    }

    private func startWorker() {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("asr-worker.log")
        let process = Process()
        process.currentDirectoryURL = workerDir
        process.executableURL = URL(fileURLWithPath: uvExecutablePath())
        process.arguments = [
            "run", "uvicorn", "server:app",
            "--host", "127.0.0.1",
            "--port", asrPort,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PERMANENT_TRANSCRIBER_ROOT"] = permanentTranscriberDataRoot.path
        environment["HF_HOME"] = sharedModelRoot.appendingPathComponent("huggingface").path
        environment["HUGGINGFACE_HUB_CACHE"] = sharedModelRoot.appendingPathComponent("huggingface/hub").path
        environment["XDG_CACHE_HOME"] = sharedModelRoot.appendingPathComponent("xdg-cache").path
        environment["MAC_DICTATION_MLX_CACHE"] = sharedModelRoot.appendingPathComponent("mlx-cache").path
        process.environment = environment
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
            workerProcess = process
            workerGeneration += 1
            logEvent("ASR worker process launched pid=\(process.processIdentifier)")
        } catch {
            fputs("failed to start ASR worker: \(error)\n", stderr)
        }
    }

    private func transcribeTimeoutSeconds(audioSeconds: Double) -> Double {
        max(asrTranscribeTimeoutFloorSeconds, min(asrTranscribeTimeoutCeilingSeconds, audioSeconds * 1.5 + 8.0))
    }

    private func restartWorker(reason: String) {
        lifecycleLock.lock()
        let process = workerProcess
        workerProcess = nil
        workerGeneration += 1
        lifecycleLock.unlock()

        guard let process else { return }
        let pid = process.processIdentifier
        if process.isRunning {
            logEvent("ASR worker terminating reason=\(reason) pid=\(pid)")
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning {
                    logEvent("ASR worker force killing pid=\(pid)")
                    _ = runProcess("/bin/kill", ["-9", "\(pid)"])
                }
            }
        }
    }

    private func postJSON(path: String, body: Data, timeout: Double) throws -> Data {
        guard let url = URL(string: "\(asrBaseURL)\(path)") else {
            throw ASRClientError.requestFailed("invalid ASR URL: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.isEmpty ? "{}".data(using: .utf8) : body

        let semaphore = DispatchSemaphore(value: 0)
        let responseBox = SynchronizedBox<(data: Data, error: Error?)>((Data(), nil))
        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            responseBox.set((data ?? Data(), error))
            semaphore.signal()
        }
        task.resume()
        let waitResult = semaphore.wait(timeout: .now() + timeout + 2)
        if waitResult == .timedOut {
            task.cancel()
            throw ASRClientError.requestFailed("ASR request timed out: \(path)")
        }
        let response = responseBox.value()
        if let requestError = response.error {
            throw ASRClientError.requestFailed("ASR request failed: \(requestError)")
        }
        if response.data.isEmpty {
            throw ASRClientError.requestFailed("ASR request returned empty response: \(path)")
        }
        return response.data
    }
}

extension MLXASRClient: @unchecked Sendable {}

func uvExecutablePath() -> String {
    let homeLocal = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/uv")
        .path
    for path in ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", homeLocal] {
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
    }
    return "/opt/homebrew/bin/uv"
}

func ffmpegExecutablePath() -> String {
    for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
    }
    return "/opt/homebrew/bin/ffmpeg"
}

func timestampForFilename() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return formatter.string(from: Date())
}

@discardableResult
func saveTranscript(_ text: String, in directory: URL, prefix: String) -> URL? {
    let cleanText = sanitize(text)
    guard !cleanText.isEmpty else { return nil }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(timestampForFilename())-\(prefix).txt")
        try "\(cleanText)\n".write(to: url, atomically: true, encoding: .utf8)
        logEvent("transcript saved path=\(url.path)")
        return url
    } catch {
        fputs("transcript save failed: \(error)\n", stderr)
        return nil
    }
}

func appendText(_ text: String, to url: URL) {
    guard let data = text.data(using: .utf8) else { return }
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    } catch {
        fputs("append text failed: \(error)\n", stderr)
    }
}

func appendJSONLine(_ object: [String: Any], to url: URL) {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if let line = String(data: data, encoding: .utf8) {
            appendText("\(line)\n", to: url)
        }
    } catch {
        fputs("append jsonl failed: \(error)\n", stderr)
    }
}

struct TranscriptRecord {
    let transcriptURL: URL
    let sourceURL: URL
    let modifiedAt: Date
    let preview: String
}

func transcriptRecords(in directory: URL, transcriptName: String? = nil, limit: Int = 5) -> [TranscriptRecord] {
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var records: [TranscriptRecord] = []
    for entry in entries {
        let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
        let transcriptURL: URL
        let sourceURL: URL
        if let transcriptName {
            guard values?.isDirectory == true else { continue }
            let candidate = entry.appendingPathComponent(transcriptName)
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            transcriptURL = candidate
            sourceURL = entry
        } else {
            guard entry.pathExtension.lowercased() == "txt" else { continue }
            transcriptURL = entry
            sourceURL = entry
        }
        let modifiedAt = (try? transcriptURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? values?.contentModificationDate
            ?? .distantPast
        var preview = transcriptPreview(transcriptURL)
        if preview.isEmpty {
            guard transcriptName != nil else { continue }
            preview = "Transcript pending"
        }
        records.append(TranscriptRecord(transcriptURL: transcriptURL, sourceURL: sourceURL, modifiedAt: modifiedAt, preview: preview))
    }

    return records.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit).map { $0 }
}

func recursiveTranscriptRecords(in directory: URL, extensions allowedExtensions: Set<String> = ["md", "txt"], limit: Int = 5) -> [TranscriptRecord] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var records: [TranscriptRecord] = []
    for case let file as URL in enumerator {
        guard allowedExtensions.contains(file.pathExtension.lowercased()) else { continue }
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { continue }
        let preview = transcriptPreview(file)
        guard !preview.isEmpty else { continue }
        records.append(TranscriptRecord(
            transcriptURL: file,
            sourceURL: file,
            modifiedAt: values?.contentModificationDate ?? .distantPast,
            preview: preview
        ))
    }
    return records.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit).map { $0 }
}

func transcriptPreview(_ url: URL, maxBytes: Int = 4096, maxWords: Int = 14) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
    try? handle.close()
    let text = sanitize(String(data: data, encoding: .utf8) ?? "")
    guard !text.isEmpty else { return "" }
    let words = text.split(separator: " ").prefix(maxWords).joined(separator: " ")
    if words.count < text.count {
        return "\(words)..."
    }
    return words
}

func fullTranscript(at url: URL) -> String? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        return nil
    }
    let cleanText = sanitize(text)
    return cleanText.isEmpty ? nil : cleanText
}

enum ManualTranscriptionError: Error, CustomStringConvertible {
    case conversionFailed(Int32)

    var description: String {
        switch self {
        case .conversionFailed(let status):
            return "ffmpeg conversion failed status=\(status)"
        }
    }
}

final class ManualAudioTranscriber {
    private let asr: MLXASRClient
    private let queue = DispatchQueue(label: "com.markschroedr.mac-dictation.manual-transcriber", qos: .userInitiated)

    init(asr: MLXASRClient) {
        self.asr = asr
    }

    @MainActor
    func selectAndTranscribe() {
        let panel = NSOpenPanel()
        panel.title = "Transcribe Audio File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["wav", "m4a", "mp3", "aac", "flac", "ogg", "opus", "aiff", "aif", "caf", "mp4", "mov"]
            .compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let inputURL = panel.url else {
            return
        }

        playStartSound()
        queue.async {
            do {
                let text = try self.transcribe(inputURL: inputURL)
                DispatchQueue.main.async {
                    copyToClipboard(text)
                    playStopSound()
                    let alert = NSAlert()
                    alert.messageText = "Audio Transcribed"
                    alert.informativeText = "Transcript copied to clipboard and saved."
                    alert.alertStyle = .informational
                    alert.runModal()
                }
            } catch {
                DispatchQueue.main.async {
                    playErrorSound()
                    let alert = NSAlert()
                    alert.messageText = "Audio Transcription Failed"
                    alert.informativeText = "\(error)"
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
    }

    func transcribe(inputURL: URL) throws -> String {
        let wavURL = try convertForASR(inputURL)
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            asr.scheduleShutdown()
        }
        let sessionID = UUID().uuidString
        asr.resetSession(sessionID)
        asr.warmupSync()
        let response = try asr.transcribe(sessionID: sessionID, chunkIndex: 1, audioURL: wavURL)
        let text = sanitize(response.text ?? "")
        _ = saveTranscript(text, in: manualTranscriptsDir, prefix: "file")
        return text
    }

    private func convertForASR(_ inputURL: URL) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-dictation-manual-\(UUID().uuidString).wav")
        let status = runProcess(ffmpegExecutablePath(), [
            "-hide_banner", "-loglevel", "error", "-y",
            "-i", inputURL.path,
            "-ac", "1",
            "-ar", "16000",
            "-sample_fmt", "s16",
            outputURL.path,
        ])
        guard status == 0 else {
            throw ManualTranscriptionError.conversionFailed(status)
        }
        return outputURL
    }
}

extension ManualAudioTranscriber: @unchecked Sendable {}

enum PermanentTranscriberMode: String, CaseIterable {
    case relaxedOnly
    case quickAndRelaxed

    var displayName: String {
        switch self {
        case .relaxedOnly:
            return "Canonical Only"
        case .quickAndRelaxed:
            return "Quick + Canonical"
        }
    }

    static func current() -> PermanentTranscriberMode {
        guard
            let rawValue = UserDefaults.standard.string(forKey: permanentTranscriberModeDefaultsKey),
            let mode = PermanentTranscriberMode(rawValue: rawValue)
        else {
            return .relaxedOnly
        }
        return mode
    }

    static func setCurrent(_ mode: PermanentTranscriberMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: permanentTranscriberModeDefaultsKey)
    }
}

struct PermanentTranscriberStatus {
    let captureRunning: Bool
    let captureHealthy: Bool
    let captureError: String?
    let includesSystemAudio: Bool
    let quickRunning: Bool
    let relaxedRunning: Bool

    var isRunning: Bool {
        captureRunning || quickRunning || relaxedRunning
    }
}

struct PermanentTranscriberDevice {
    let index: Int
    let name: String
    let isDefaultInput: Bool
    let isPreferred: Bool
}

enum PermanentTranscriberError: Error, CustomStringConvertible, Sendable {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

final class PermanentTranscriberController {
    private let queue = DispatchQueue(label: "com.markschroedr.mac-dictation.permanent-transcriber-controller", qos: .utility)

    func status() -> PermanentTranscriberStatus {
        let result = runTool(["status"])
        guard
            result.status == 0,
            let data = result.output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return PermanentTranscriberStatus(
                captureRunning: false,
                captureHealthy: false,
                captureError: "Could not read permanent-transcriber status",
                includesSystemAudio: true,
                quickRunning: false,
                relaxedRunning: false
            )
        }
        let capture = object["capture"] as? [String: Any]
        let workers = object["workers"] as? [String: Any]
        let quick = workers?["quick"] as? [String: Any]
        let relaxed = workers?["relaxed"] as? [String: Any]
        return PermanentTranscriberStatus(
            captureRunning: capture?["running"] as? Bool ?? false,
            captureHealthy: capture?["healthy"] as? Bool ?? false,
            captureError: capture?["error"] as? String,
            includesSystemAudio: capture?["include_system_audio"] as? Bool ?? true,
            quickRunning: quick?["running"] as? Bool ?? false,
            relaxedRunning: relaxed?["running"] as? Bool ?? false
        )
    }

    func devices() -> [PermanentTranscriberDevice] {
        let result = runTool(["devices"])
        guard
            result.status == 0,
            let data = result.output.data(using: .utf8),
            let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        return rows.compactMap { row in
            guard
                let index = row["index"] as? Int,
                let name = row["name"] as? String
            else {
                return nil
            }
            return PermanentTranscriberDevice(
                index: index,
                name: name,
                isDefaultInput: row["is_default_input"] as? Bool ?? false,
                isPreferred: row["is_preferred"] as? Bool ?? false
            )
        }
    }

    func refreshStatus(completion: @escaping @MainActor @Sendable (PermanentTranscriberStatus) -> Void) {
        queue.async {
            let status = self.status()
            Task { @MainActor in
                completion(status)
            }
        }
    }

    func refreshDevices(completion: @escaping @MainActor @Sendable ([PermanentTranscriberDevice]) -> Void) {
        queue.async {
            let devices = self.devices()
            Task { @MainActor in
                completion(devices)
            }
        }
    }

    func start(mode: PermanentTranscriberMode, completion: @escaping @MainActor @Sendable (Result<Void, PermanentTranscriberError>) -> Void) {
        queue.async {
            let outcome: Result<Void, PermanentTranscriberError>
            do {
                try self.requireMicrophoneAccess()
                if self.includesSystemAudio() {
                    try self.requireSystemAudioAccess()
                }
                var args = ["start"]
                if mode == .quickAndRelaxed {
                    args.append("--quick")
                }
                let result = self.runTool(args)
                if result.status == 0 {
                    outcome = .success(())
                } else {
                    outcome = .failure(.failed(result.output.isEmpty ? "permanent-transcriber start failed" : result.output))
                }
            } catch let error as PermanentTranscriberError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.failed(String(describing: error)))
            }
            Task { @MainActor in
                completion(outcome)
            }
        }
    }

    func stop(completion: @escaping @MainActor @Sendable (Result<Void, PermanentTranscriberError>) -> Void) {
        queue.async {
            let result = self.runTool(["stop"])
            Task { @MainActor in
                if result.status == 0 {
                    completion(.success(()))
                } else {
                    completion(.failure(.failed(result.output.isEmpty ? "permanent-transcriber stop failed" : result.output)))
                }
            }
        }
    }

    func includesSystemAudio() -> Bool {
        let result = runTool(["capture-settings"])
        guard result.status == 0,
              let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return true }
        return object["include_system_audio"] as? Bool ?? true
    }

    func setSystemAudio(enabled: Bool, completion: @escaping @MainActor @Sendable (Result<Void, PermanentTranscriberError>) -> Void) {
        queue.async {
            let result = self.runTool(["system-audio", enabled ? "true" : "false"])
            Task { @MainActor in
                if result.status == 0 {
                    completion(.success(()))
                } else {
                    completion(.failure(.failed(result.output.isEmpty ? "could not update system audio setting" : result.output)))
                }
            }
        }
    }

    func setDevice(index: Int, completion: @escaping @MainActor @Sendable (Result<Void, PermanentTranscriberError>) -> Void) {
        queue.async {
            let result = self.runTool(["set-device", "\(index)"])
            Task { @MainActor in
                if result.status == 0 {
                    completion(.success(()))
                } else {
                    completion(.failure(.failed(result.output.isEmpty ? "permanent-transcriber set-device failed" : result.output)))
                }
            }
        }
    }

    private func runTool(_ arguments: [String]) -> ProcessRunResult {
        guard FileManager.default.isExecutableFile(atPath: permanentTranscriberExecutable.path) else {
            return ProcessRunResult(
                status: 1,
                output: "Missing permanent-transcriber executable at \(permanentTranscriberExecutable.path)"
            )
        }
        return runProcessCapturingOutput(
            permanentTranscriberExecutable.path,
            arguments,
            environment: sharedPermanentTranscriberEnvironment(),
            currentDirectory: permanentTranscriberCodeRoot
        )
    }

    private func requireSystemAudioAccess() throws {
        guard FileManager.default.isExecutableFile(atPath: systemAudioHelperExecutable.path) else {
            throw PermanentTranscriberError.failed("System audio capture helper is missing. Reinstall Mac Dictation Agent.")
        }
        // The status menu asks on the main thread as soon as system audio is selected.
        if CGPreflightScreenCaptureAccess() {
            return
        }
        throw PermanentTranscriberError.failed(
            "System audio access was not granted. Enable Mac Dictation in System Settings > Privacy & Security > Screen & System Audio Recording, then restart the app."
        )
    }

    private func requireMicrophoneAccess() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted:
            throw PermanentTranscriberError.failed(
                "Microphone access is disabled for Mac Dictation. Enable it in System Settings > Privacy & Security > Microphone."
            )
        case .notDetermined:
            let result = MicrophonePermissionResult()
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                result.set(granted)
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 60) == .success else {
                throw PermanentTranscriberError.failed("Timed out waiting for macOS microphone permission")
            }
            guard result.value else {
                throw PermanentTranscriberError.failed(
                    "Microphone access was not granted. Enable Mac Dictation in System Settings > Privacy & Security > Microphone."
                )
            }
        @unknown default:
            throw PermanentTranscriberError.failed("Unknown macOS microphone permission state")
        }
    }
}

extension PermanentTranscriberController: @unchecked Sendable {}

final class MicrophonePermissionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return granted
    }

    func set(_ value: Bool) {
        lock.lock()
        granted = value
        lock.unlock()
    }
}

func sharedPermanentTranscriberEnvironment() -> [String: String] {
    [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "MAC_DICTATION_AGENT_ROOT": agentRoot.path,
        "MAC_DICTATION_ASR_PORT": asrPort,
        "MAC_DICTATION_ASR_WORKER_DIR": workerDir.path,
        "MAC_DICTATION_DATA_ROOT": dataRoot.path,
        "MAC_DICTATION_MODEL_ROOT": sharedModelRoot.path,
        "MAC_DICTATION_MLX_CACHE": sharedModelRoot.appendingPathComponent("mlx-cache").path,
        "PERMANENT_TRANSCRIBER_ROOT": permanentTranscriberDataRoot.path,
        "MAC_DICTATION_SYSTEM_AUDIO_HELPER": systemAudioHelperExecutable.path,
        "HF_HOME": sharedModelRoot.appendingPathComponent("huggingface").path,
        "HUGGINGFACE_HUB_CACHE": sharedModelRoot.appendingPathComponent("huggingface/hub").path,
        "XDG_CACHE_HOME": sharedModelRoot.appendingPathComponent("xdg-cache").path,
    ]
}

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let asr: MLXASRClient
    private let tts: ClipboardTTSManager
    private let manualTranscriber: ManualAudioTranscriber
    private let permanentTranscriber: PermanentTranscriberController
    private let statusItem: NSStatusItem
    private let appStatusItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
    private let quickTTSItem = NSMenuItem(title: "Quick Speak Clipboard…", action: #selector(speakClipboardQuick), keyEquivalent: "")
    private var quickVoiceItems: [QuickTTSPreset: NSMenuItem] = [:]
    private let startAtLoginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
    private let permanentTranscriberStatusItem = NSMenuItem(title: "Status: Stopped", action: nil, keyEquivalent: "")
    private let permanentTranscriberModeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
    private let permanentTranscriberControlItem = NSMenuItem(title: "Start Continuous Recording", action: #selector(togglePermanentTranscriber), keyEquivalent: "")
    private let permanentTranscriberDeviceItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
    private let permanentSystemAudioItem = NSMenuItem(
        title: "Include System Audio",
        action: #selector(togglePermanentSystemAudio),
        keyEquivalent: ""
    )
    private let openPermanentFolderItem = NSMenuItem(title: "Open Recording Folder", action: #selector(openPermanentTranscriberFolder), keyEquivalent: "")
    private let recentDictationsItem = NSMenuItem(title: "Dictations", action: nil, keyEquivalent: "")
    private let recentPermanentRelaxedItem = NSMenuItem(title: "Continuous - Canonical", action: nil, keyEquivalent: "")
    private let recentPermanentQuickItem = NSMenuItem(title: "Continuous - Quick", action: nil, keyEquivalent: "")
    private let recentManualItem = NSMenuItem(title: "Audio Files", action: nil, keyEquivalent: "")
    private let recentTTSAudioItem = NSMenuItem(title: "Recent Audio", action: nil, keyEquivalent: "")
    private let microphoneItem = NSMenuItem(title: "Dictation Microphone", action: nil, keyEquivalent: "")
    private let recoveryRetentionItem = NSMenuItem(title: "Recovery Audio Retention", action: nil, keyEquivalent: "")
    private var recoveryRetentionItems: [Int: NSMenuItem] = [:]
    private let ttsStatusItem = NSMenuItem(title: "TTS: Idle", action: nil, keyEquivalent: "")
    private var ttsActionItems: [TTSProvider: NSMenuItem] = [:]
    private var ttsLanguageItems: [TTSLanguage: NSMenuItem] = [:]
    private var permanentModeItems: [PermanentTranscriberMode: NSMenuItem] = [:]
    private var isInteractiveRecording = false
    private var isPermanentRecording = false
    private var systemAudioAccessRequested = false
    private var permanentTranscriberStatus = PermanentTranscriberStatus(
        captureRunning: false,
        captureHealthy: false,
        captureError: nil,
        includesSystemAudio: true,
        quickRunning: false,
        relaxedRunning: false
    )
    private var permanentTranscriberDevices: [PermanentTranscriberDevice] = []
    private var permanentTranscriberRefreshInFlight = false
    private var permanentTranscriberDevicesRefreshInFlight = false
    private var isInteractiveProcessing = false
    private var isPermanentProcessing = false
    private var isTTSProcessing = false
    private var selectedMicrophoneName = "Default microphone"

    init(asr: MLXASRClient, tts: ClipboardTTSManager) {
        self.asr = asr
        self.tts = tts
        self.manualTranscriber = ManualAudioTranscriber(asr: asr)
        self.permanentTranscriber = PermanentTranscriberController()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configure()
    }

    private func configure() {
        updateStatusIcon()

        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "Mac Dictation Agent", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        appStatusItem.isEnabled = false
        menu.addItem(appStatusItem)
        let hint = NSMenuItem(title: "Hold Control+Shift to dictate", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        quickTTSItem.target = self
        menu.addItem(quickTTSItem)
        updateQuickVoice()

        let transcribeAudioFile = NSMenuItem(title: "Transcribe Audio File...", action: #selector(transcribeAudioFile), keyEquivalent: "")
        transcribeAudioFile.target = self
        menu.addItem(transcribeAudioFile)

        let speakClipboardItem = NSMenuItem(title: "Speak Clipboard", action: nil, keyEquivalent: "")
        let speakClipboardMenu = NSMenu()
        let speakSupertonic = NSMenuItem(
            title: "Speak with Supertonic 3",
            action: #selector(speakClipboardWithSupertonic),
            keyEquivalent: ""
        )
        speakSupertonic.target = self
        speakClipboardMenu.addItem(speakSupertonic)
        ttsActionItems[.supertonic] = speakSupertonic

        let speakInworld = NSMenuItem(title: "Speak with Inworld", action: #selector(speakClipboardWithInworld), keyEquivalent: "")
        speakInworld.target = self
        speakClipboardMenu.addItem(speakInworld)
        ttsActionItems[.inworld] = speakInworld

        let speakXAI = NSMenuItem(title: "Speak with Grok/xAI", action: #selector(speakClipboardWithXAI), keyEquivalent: "")
        speakXAI.target = self
        speakClipboardMenu.addItem(speakXAI)
        ttsActionItems[.xai] = speakXAI

        speakClipboardMenu.addItem(.separator())
        let quickVoice = NSMenuItem(title: "Quick Voice", action: nil, keyEquivalent: "")
        let quickVoiceMenu = NSMenu()
        for preset in QuickTTSPreset.allCases {
            let item = NSMenuItem(title: preset.displayName, action: #selector(selectQuickVoice), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            quickVoiceMenu.addItem(item)
            quickVoiceItems[preset] = item
        }
        quickVoice.submenu = quickVoiceMenu
        speakClipboardMenu.addItem(quickVoice)
        let setup = NSMenuItem(title: "Set Up Voices and API Keys…", action: #selector(openTTSSetup), keyEquivalent: "")
        setup.target = self
        speakClipboardMenu.addItem(setup)
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for language in TTSLanguage.allCases {
            let item = NSMenuItem(title: language.displayName, action: #selector(selectTTSLanguage), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            languageMenu.addItem(item)
            ttsLanguageItems[language] = item
        }
        languageItem.submenu = languageMenu
        speakClipboardMenu.addItem(languageItem)

        ttsStatusItem.isEnabled = false
        ttsStatusItem.isHidden = true
        speakClipboardMenu.addItem(ttsStatusItem)

        speakClipboardMenu.addItem(.separator())
        speakClipboardMenu.addItem(recentTTSAudioItem)

        let openAudioFolder = NSMenuItem(title: "Open Audio Folder", action: #selector(openTTSAudioFolder), keyEquivalent: "")
        openAudioFolder.target = self
        speakClipboardMenu.addItem(openAudioFolder)
        speakClipboardItem.submenu = speakClipboardMenu
        menu.addItem(speakClipboardItem)

        let continuousRecordingItem = NSMenuItem(title: "Continuous Recording", action: nil, keyEquivalent: "")
        let continuousRecordingMenu = NSMenu()
        permanentTranscriberControlItem.target = self
        continuousRecordingMenu.addItem(permanentTranscriberControlItem)
        permanentTranscriberStatusItem.isEnabled = false
        continuousRecordingMenu.addItem(permanentTranscriberStatusItem)
        continuousRecordingMenu.addItem(.separator())

        let modeMenu = NSMenu()
        for mode in PermanentTranscriberMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(selectPermanentTranscriberMode), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            modeMenu.addItem(item)
            permanentModeItems[mode] = item
        }
        permanentTranscriberModeItem.submenu = modeMenu
        continuousRecordingMenu.addItem(permanentTranscriberModeItem)
        continuousRecordingMenu.addItem(permanentTranscriberDeviceItem)
        permanentSystemAudioItem.target = self
        continuousRecordingMenu.addItem(permanentSystemAudioItem)

        continuousRecordingMenu.addItem(.separator())
        openPermanentFolderItem.target = self
        continuousRecordingMenu.addItem(openPermanentFolderItem)
        continuousRecordingItem.submenu = continuousRecordingMenu
        menu.addItem(continuousRecordingItem)

        menu.addItem(.separator())

        let recentTranscriptsItem = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        let recentTranscriptsMenu = NSMenu()
        recentTranscriptsMenu.addItem(recentDictationsItem)
        recentTranscriptsMenu.addItem(recentManualItem)
        recentTranscriptsMenu.addItem(.separator())
        recentTranscriptsMenu.addItem(recentPermanentRelaxedItem)
        recentTranscriptsMenu.addItem(recentPermanentQuickItem)
        recentTranscriptsItem.submenu = recentTranscriptsMenu
        menu.addItem(recentTranscriptsItem)

        let openRecoveryFolder = NSMenuItem(title: "Open Dictation Recovery", action: #selector(openRecoveryFolder), keyEquivalent: "")
        openRecoveryFolder.target = self
        menu.addItem(openRecoveryFolder)

        let openDataFolder = NSMenuItem(title: "Open Data Folder", action: #selector(openDataFolder), keyEquivalent: "")
        openDataFolder.target = self
        menu.addItem(openDataFolder)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()
        settingsMenu.addItem(microphoneItem)

        let recoveryRetentionMenu = NSMenu()
        for choice in RecoveryRetentionPreference.choices {
            let item = NSMenuItem(title: choice.title, action: #selector(selectRecoveryRetention), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.hours
            recoveryRetentionMenu.addItem(item)
            recoveryRetentionItems[choice.hours] = item
        }
        recoveryRetentionItem.submenu = recoveryRetentionMenu
        settingsMenu.addItem(recoveryRetentionItem)

        let diagnosticsItem = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        let diagnosticsMenu = NSMenu()
        let openLogFolder = NSMenuItem(title: "Open Log Folder", action: #selector(openLogFolder), keyEquivalent: "")
        openLogFolder.target = self
        diagnosticsMenu.addItem(openLogFolder)
        let stopWorker = NSMenuItem(title: "Stop Background ASR", action: #selector(stopASRWorker), keyEquivalent: "")
        stopWorker.target = self
        diagnosticsMenu.addItem(stopWorker)
        diagnosticsItem.submenu = diagnosticsMenu
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(diagnosticsItem)
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        startAtLoginItem.target = self
        menu.addItem(startAtLoginItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Mac Dictation Agent", action: #selector(quitAgent), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateStartAtLoginState()
        updateRecoveryRetentionState()
        updateTTSLanguageState()
        applyPermanentTranscriberState(permanentTranscriberStatus)
        updatePermanentTranscriberModeState()
        updatePermanentSystemAudioState(permanentTranscriberStatus)
        rebuildRecentMenus()
        rebuildMicrophoneMenu()
        rebuildPermanentTranscriberDeviceMenu(devices: permanentTranscriberDevices)
        refreshPermanentTranscriberState()
        refreshPermanentTranscriberDevices()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateQuickVoice()
        rebuildRecentMenus()
        rebuildMicrophoneMenu()
        rebuildPermanentTranscriberDeviceMenu(devices: permanentTranscriberDevices)
        applyPermanentTranscriberState(permanentTranscriberStatus)
        updatePermanentTranscriberModeState()
        updatePermanentSystemAudioState(permanentTranscriberStatus)
        updateRecoveryRetentionState()
        refreshPermanentTranscriberState()
        refreshPermanentTranscriberDevices()
    }

    func openForPreview(with event: NSEvent, in view: NSView) {
        guard let menu = statusItem.menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    func setInteractiveRecording(_ active: Bool) {
        isInteractiveRecording = active
        updateStatusIcon()
    }

    func setInteractiveProcessing(_ active: Bool) {
        isInteractiveProcessing = active
        updateStatusIcon()
    }

    @objc private func toggleStartAtLogin() {
        setStartAtLogin(enabled: !isStartAtLoginEnabled())
        updateStartAtLoginState()
    }

    @objc private func selectRecoveryRetention(_ sender: NSMenuItem) {
        guard let hours = sender.representedObject as? Int else { return }
        RecoveryRetentionPreference.setHours(hours)
        updateRecoveryRetentionState()
        logEvent("dictation recovery retention selected hours=\(hours)")
    }

    @objc private func stopASRWorker() {
        asr.shutdown()
    }

    @objc private func speakClipboardWithSupertonic() {
        startTTS(provider: .supertonic)
    }

    @objc private func speakClipboardWithInworld() {
        startTTS(provider: .inworld)
    }

    @objc private func speakClipboardWithXAI() {
        startTTS(provider: .xai)
    }

    @objc private func selectQuickVoice(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = QuickTTSPreset(rawValue: raw) else { return }
        UserDefaults.standard.set(preset.rawValue, forKey: "quickTTSPreset")
        updateQuickVoice()
    }

    private func updateQuickVoice() {
        let current = QuickTTSPreset.current()
        quickTTSItem.title = current.map { "Quick Speak — \($0.displayName)" } ?? "Quick Speak Clipboard…"
        for (preset, item) in quickVoiceItems {
            item.state = preset == current ? .on : .off
        }
    }

    @objc private func speakClipboardQuick() {
        guard let preset = QuickTTSPreset.current() else {
            let alert = NSAlert()
            alert.messageText = "Choose a Quick Voice first"
            alert.informativeText = "Select a voice under Speak Clipboard → Quick Voice. Cloud voices send clipboard text to the selected provider only when you start speaking."
            alert.runModal()
            return
        }
        startTTS(provider: preset.provider, voiceID: preset.voiceID)
    }

    @objc private func openTTSSetup() {
        let alert = NSAlert()
        alert.messageText = "Set up text-to-speech"
        alert.informativeText = "Local speech: install uv and ffmpeg, then run Install Optional Tools.command from the download. Supertonic downloads its model on first use.\n\nCloud speech: add INWORLD_API_KEY or XAI_API_KEY to the dedicated key file. Cloud voices send your clipboard text to that provider.\n\nChoose a Quick Voice from the Speak Clipboard menu. No provider is selected automatically."
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Edit API Keys")
        alert.addButton(withTitle: "Setup Guide")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            do {
                try FileManager.default.createDirectory(at: ttsEnvFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: ttsEnvFile.path) {
                    let template = "# Optional cloud speech credentials. Keep this file private.\n# INWORLD_API_KEY=\n# XAI_API_KEY=\n"
                    guard FileManager.default.createFile(atPath: ttsEnvFile.path, contents: Data(template.utf8), attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                NSWorkspace.shared.open(ttsEnvFile)
            } catch {
                let failure = NSAlert(error: error)
                failure.runModal()
            }
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://github.com/markschroedr/mac-dictation-agent/blob/main/docs/USAGE.md#text-to-speech")!)
        default: break
        }
    }

    private func startTTS(provider: TTSProvider, voiceID: String? = nil) {
        guard !isTTSProcessing else {
            return
        }
        if provider.isLocal && !FileManager.default.isExecutableFile(atPath: supertonicTTSServiceExecutable.path) {
            openTTSSetup()
            return
        }
        if let key = provider.secretName, SecretResolver.value(for: key) == nil {
            openTTSSetup()
            return
        }
        let language = TTSLanguage.current()
        guard provider.supports(language) else {
            playErrorSound()
            ttsStatusItem.title = "TTS: Choose English or German for \(provider.displayName)"
            ttsStatusItem.isHidden = false
            return
        }

        isTTSProcessing = true
        ttsStatusItem.title = "TTS: Starting \(provider.displayName)..."
        ttsStatusItem.toolTip = nil
        ttsStatusItem.isHidden = false
        updateTTSActionState()
        updateStatusIcon()

        tts.speakClipboard(
            provider: provider,
            voiceID: voiceID,
            progress: { [weak self] completed, total in
                DispatchQueue.main.async {
                    guard let self, self.isTTSProcessing else { return }
                    self.ttsStatusItem.title = completed == 0
                        ? "TTS: Starting \(provider.displayName)..."
                        : "TTS: \(provider.displayName) \(completed)/\(total)"
                    self.statusItem.button?.toolTip = completed == 0
                        ? "Generating speech"
                        : "Generating speech (\(completed)/\(total))"
                }
            },
            completion: { [weak self] errorDescription in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isTTSProcessing = false
                    if let errorDescription {
                        self.ttsStatusItem.title = "TTS failed - see log"
                        self.ttsStatusItem.toolTip = errorDescription
                        self.ttsStatusItem.isHidden = false
                    } else {
                        self.ttsStatusItem.title = "TTS: Ready"
                        self.ttsStatusItem.toolTip = nil
                        self.ttsStatusItem.isHidden = true
                    }
                    self.updateTTSActionState()
                    self.updateStatusIcon()
                }
            }
        )
    }

    @objc private func transcribeAudioFile() {
        manualTranscriber.selectAndTranscribe()
    }

    @objc private func togglePermanentTranscriber() {
        let status = permanentTranscriberStatus
        if status.isRunning {
            permanentTranscriber.stop { [weak self] result in
                self?.handlePermanentTranscriberResult(result)
                self?.refreshPermanentTranscriberState()
            }
        } else {
            let mode = PermanentTranscriberMode.current()
            permanentTranscriber.start(mode: mode) { [weak self] result in
                self?.handlePermanentTranscriberResult(result)
                self?.refreshPermanentTranscriberState()
            }
        }
    }

    @objc private func openPermanentTranscriberFolder() {
        NSWorkspace.shared.open(permanentTranscriberDataRoot)
    }

    @objc private func openRecoveryFolder() {
        try? FileManager.default.createDirectory(at: dictationRecoveryDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dictationRecoveryDir)
    }

    @objc private func openDataFolder() {
        try? FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dataRoot)
    }

    @objc private func openLogFolder() {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logDir)
    }

    @objc private func openRecentTTSAudio(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func copyTranscriptFromMenu(_ sender: NSMenuItem) {
        guard
            let path = sender.representedObject as? String,
            let text = fullTranscript(at: URL(fileURLWithPath: path))
        else {
            playErrorSound()
            return
        }
        copyToClipboard(text)
        playStopSound()
        logEvent("recent transcript copied chars=\(text.count) path=\(path)")
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let preference = sender.representedObject as? String else { return }
        AudioInputDeviceSelection.setCurrentPreference(preference)
        rebuildMicrophoneMenu()
        logEvent("audio input selected preference=\(preference)")
    }

    @objc private func selectPermanentTranscriberMode(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let mode = PermanentTranscriberMode(rawValue: rawValue)
        else {
            return
        }
        PermanentTranscriberMode.setCurrent(mode)
        updatePermanentTranscriberModeState()
        logEvent("permanent transcriber mode selected mode=\(mode.rawValue)")
    }

    @objc private func togglePermanentSystemAudio() {
        guard !permanentTranscriberStatus.isRunning else { return }
        let enabled = !permanentTranscriberStatus.includesSystemAudio
        permanentTranscriber.setSystemAudio(enabled: enabled) { [weak self] result in
            self?.handlePermanentTranscriberResult(result)
            self?.refreshPermanentTranscriberState()
        }
    }

    @objc private func selectPermanentTranscriberDevice(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        permanentTranscriber.setDevice(index: index) { [weak self] result in
            self?.handlePermanentTranscriberResult(result)
            self?.refreshPermanentTranscriberDevices()
        }
    }

    @objc private func selectTTSLanguage(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let language = TTSLanguage(rawValue: rawValue)
        else {
            return
        }
        TTSLanguage.setCurrent(language)
        updateTTSLanguageState()
        updateTTSActionState()
        logEvent("tts language selected language=\(language.rawValue)")
    }

    @objc private func openTTSAudioFolder() {
        try? FileManager.default.createDirectory(at: ttsAudioDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ttsAudioDir)
    }

    @objc private func quitAgent() {
        asr.shutdown()
        tts.shutdown()
        runProcess("/bin/launchctl", ["bootout", "gui/\(getuid())", launchAgentPlist.path])
        NSApp.terminate(nil)
    }

    private func updateStartAtLoginState() {
        startAtLoginItem.state = isStartAtLoginEnabled() ? .on : .off
    }

    private func updateRecoveryRetentionState() {
        let hours = RecoveryRetentionPreference.hours
        for (choiceHours, item) in recoveryRetentionItems {
            item.state = choiceHours == hours ? .on : .off
        }
        if let choice = RecoveryRetentionPreference.choices.first(where: { $0.hours == hours }) {
            recoveryRetentionItem.title = "Recovery Audio Retention — \(choice.title)"
        } else {
            recoveryRetentionItem.title = "Recovery Audio Retention — \(hours) Hours"
        }
    }

    private func updateTTSLanguageState() {
        let currentLanguage = TTSLanguage.current()
        for (language, item) in ttsLanguageItems {
            item.state = language == currentLanguage ? .on : .off
        }
        ttsLanguageItems[.auto]?.toolTip = "Available for Inworld and Grok/xAI"
        updateTTSActionState()
    }

    private func updateTTSActionState() {
        let language = TTSLanguage.current()
        for (provider, item) in ttsActionItems {
            let supportsLanguage = provider.supports(language)
            item.isEnabled = !isTTSProcessing && supportsLanguage
            if !supportsLanguage {
                item.toolTip = "Choose English or German; this runtime does not support Auto"
            } else if isTTSProcessing {
                item.toolTip = "Another speech generation is running"
            } else {
                item.toolTip = nil
            }
        }
    }

    private func updatePermanentSystemAudioState(_ status: PermanentTranscriberStatus) {
        permanentSystemAudioItem.state = status.includesSystemAudio ? .on : .off
        permanentSystemAudioItem.isEnabled = !status.isRunning
        permanentSystemAudioItem.toolTip = status.isRunning
            ? "Stop continuous recording before changing audio sources"
            : nil
    }

    private func updatePermanentTranscriberModeState() {
        let currentMode = PermanentTranscriberMode.current()
        for (mode, item) in permanentModeItems {
            item.state = mode == currentMode ? .on : .off
        }
    }

    private func refreshPermanentTranscriberState() {
        guard !permanentTranscriberRefreshInFlight else { return }
        permanentTranscriberRefreshInFlight = true
        permanentTranscriber.refreshStatus { [weak self] status in
            guard let self else { return }
            self.permanentTranscriberRefreshInFlight = false
            self.permanentTranscriberStatus = status
            self.applyPermanentTranscriberState(status)
            self.requestSystemAudioAccessIfNeeded(status)
        }
    }

    /// macOS lists the app under Screen & System Audio Recording only after it asks once.
    /// Ask as soon as system audio is selected, so access can be granted before recording starts.
    private func requestSystemAudioAccessIfNeeded(_ status: PermanentTranscriberStatus) {
        guard status.includesSystemAudio, !systemAudioAccessRequested, !CGPreflightScreenCaptureAccess() else { return }
        systemAudioAccessRequested = true
        logEvent("system audio access requested")
        _ = CGRequestScreenCaptureAccess()
    }

    private func applyPermanentTranscriberState(_ status: PermanentTranscriberStatus) {
        isPermanentRecording = status.captureRunning && status.captureHealthy
        isPermanentProcessing = !status.captureRunning && (status.quickRunning || status.relaxedRunning)
        permanentTranscriberControlItem.title = status.isRunning ? "Stop Continuous Recording" : "Start Continuous Recording"
        let workerStatus: String
        if status.quickRunning && status.relaxedRunning {
            workerStatus = "quick + canonical"
        } else if status.relaxedRunning {
            workerStatus = "canonical"
        } else if status.quickRunning {
            workerStatus = "quick only"
        } else {
            workerStatus = "no worker"
        }
        if status.captureRunning && status.captureHealthy {
            permanentTranscriberStatusItem.title = "Status: Recording - \(workerStatus)"
            permanentTranscriberStatusItem.toolTip = nil
        } else if status.captureRunning {
            permanentTranscriberStatusItem.title = "Status: Starting"
            permanentTranscriberStatusItem.toolTip = nil
        } else if let error = status.captureError, !error.isEmpty {
            permanentTranscriberStatusItem.title = "Status: Error"
            permanentTranscriberStatusItem.toolTip = error
        } else {
            permanentTranscriberStatusItem.title = "Status: Stopped"
            permanentTranscriberStatusItem.toolTip = nil
        }
        updatePermanentSystemAudioState(status)
        updateStatusIcon()
    }

    private func rebuildRecentMenus() {
        let recoveryDictations = recursiveTranscriptRecords(in: dictationRecoveryDir)
        let legacyDictations = transcriptRecords(in: dictationTranscriptsDir)
        let recentDictations = (recoveryDictations + legacyDictations)
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(5)
        recentDictationsItem.submenu = recentMenu(
            emptyTitle: "No recent dictations",
            records: Array(recentDictations)
        )
        recentPermanentRelaxedItem.submenu = recentMenu(
            emptyTitle: "No recent canonical transcripts",
            records: recursiveTranscriptRecords(
                in: permanentTranscriberTranscriptRoot.appendingPathComponent("relaxed")
            )
        )
        recentPermanentQuickItem.submenu = recentMenu(
            emptyTitle: "No recent quick transcripts",
            records: recursiveTranscriptRecords(
                in: permanentTranscriberTranscriptRoot.appendingPathComponent("quick")
            )
        )
        recentManualItem.submenu = recentMenu(
            emptyTitle: "No recent file transcripts",
            records: transcriptRecords(in: manualTranscriptsDir)
        )
        recentTTSAudioItem.submenu = recentTTSAudioMenu()
    }

    private func recentTTSAudioMenu() -> NSMenu {
        let menu = NSMenu()
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        let runDirectories = (try? FileManager.default.contentsOfDirectory(
            at: ttsAudioDir,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )) ?? []
        let recentRuns = runDirectories.compactMap { directory -> (URL, Date)? in
            guard
                let values = try? directory.resourceValues(forKeys: resourceKeys),
                values.isDirectory == true
            else {
                return nil
            }
            return (directory, values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(5)

        for (directory, _) in recentRuns {
            let playlist = directory.appendingPathComponent("playlist.m3u")
            let audioFiles = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            let supportedAudio = audioFiles.filter {
                ["wav", "mp3", "m4a"].contains($0.pathExtension.lowercased())
            }
            let audio = supportedAudio.first { $0.deletingPathExtension().lastPathComponent == "audio" }
                ?? supportedAudio.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
            let playbackURL = FileManager.default.fileExists(atPath: playlist.path) ? playlist : audio
            guard let playbackURL else { continue }
            let item = NSMenuItem(title: directory.lastPathComponent, action: #selector(openRecentTTSAudio), keyEquivalent: "")
            item.target = self
            item.representedObject = playbackURL.path
            item.toolTip = playbackURL.path
            menu.addItem(item)
        }

        if menu.items.isEmpty {
            let item = NSMenuItem(title: "No generated audio", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        return menu
    }

    private func recentMenu(emptyTitle: String, records: [TranscriptRecord]) -> NSMenu {
        let menu = NSMenu()
        guard !records.isEmpty else {
            let item = NSMenuItem(title: emptyTitle, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        for record in records {
            let title = "\(record.preview)  \(formatter.string(from: record.modifiedAt))"
            let item = NSMenuItem(title: title, action: #selector(copyTranscriptFromMenu), keyEquivalent: "")
            item.target = self
            item.representedObject = record.transcriptURL.path
            item.toolTip = record.sourceURL.path
            menu.addItem(item)
        }
        return menu
    }

    private func rebuildMicrophoneMenu() {
        let menu = NSMenu()
        let currentPreference = AudioInputDeviceSelection.currentPreference()
        let options = AudioInputDeviceSelection.allOptions()
        selectedMicrophoneName = options.first { $0.preferenceValue == currentPreference }?.name
            ?? options.first?.name
            ?? "No microphone"
        for option in options {
            let title: String
            if option.preferenceValue == ":default" {
                title = "Mac Dictation Default (\(option.name))"
            } else if option.preferenceValue == ":system-default" {
                title = "macOS System Default (\(option.name))"
            } else {
                title = option.usesSystemDefault ? "System Default (\(option.name))" : option.name
            }
            let item = NSMenuItem(title: title, action: #selector(selectMicrophone), keyEquivalent: "")
            item.target = self
            item.representedObject = option.preferenceValue
            item.state = option.preferenceValue == currentPreference ? .on : .off
            menu.addItem(item)
        }
        microphoneItem.submenu = menu
        updateHeaderStatus()
    }

    private func refreshPermanentTranscriberDevices() {
        guard !permanentTranscriberDevicesRefreshInFlight else { return }
        permanentTranscriberDevicesRefreshInFlight = true
        permanentTranscriber.refreshDevices { [weak self] devices in
            guard let self else { return }
            self.permanentTranscriberDevicesRefreshInFlight = false
            self.permanentTranscriberDevices = devices
            self.rebuildPermanentTranscriberDeviceMenu(devices: devices)
        }
    }

    private func rebuildPermanentTranscriberDeviceMenu(devices: [PermanentTranscriberDevice]) {
        let menu = NSMenu()
        guard !devices.isEmpty else {
            let item = NSMenuItem(title: permanentTranscriberDevicesRefreshInFlight ? "Loading devices..." : "No devices found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            permanentTranscriberDeviceItem.submenu = menu
            return
        }
        for device in devices {
            var title = "\(device.index): \(device.name)"
            if device.isDefaultInput {
                title += " (default)"
            }
            let item = NSMenuItem(title: title, action: #selector(selectPermanentTranscriberDevice), keyEquivalent: "")
            item.target = self
            item.representedObject = device.index
            item.state = device.isPreferred ? .on : .off
            menu.addItem(item)
        }
        permanentTranscriberDeviceItem.submenu = menu
    }

    private func updateStatusIcon() {
        if isInteractiveRecording || isPermanentRecording {
            setStatusImage(color: NSColor.systemRed)
        } else if isInteractiveProcessing || isPermanentProcessing || isTTSProcessing {
            setStatusImage(color: NSColor.systemBlue)
        } else {
            setStatusImage(color: nil)
        }
        updateHeaderStatus()
    }

    private func updateHeaderStatus() {
        let state: String
        if isInteractiveRecording || isPermanentRecording {
            state = "Recording"
        } else if isInteractiveProcessing || isPermanentProcessing {
            state = "Transcribing"
        } else if isTTSProcessing {
            state = "Generating speech"
        } else {
            state = "Ready"
        }
        appStatusItem.title = "\(state) - \(selectedMicrophoneName)"
    }

    private func setStatusImage(color: NSColor?) {
        guard let button = statusItem.button else { return }
        if var image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Dictation") {
            if let color,
               let configuredImage = image.withSymbolConfiguration(.init(hierarchicalColor: color)) {
                image = configuredImage
                image.isTemplate = false
            } else {
                image.isTemplate = true
            }
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "Dict"
        }
        if !isTTSProcessing {
            button.toolTip = "Mac Dictation Agent"
        }
    }

    private func handlePermanentTranscriberResult(_ result: Result<Void, PermanentTranscriberError>) {
        switch result {
        case .success:
            playStopSound()
        case .failure(let error):
            playErrorSound()
            let alert = NSAlert()
            alert.messageText = "Permanent Transcriber Problem"
            alert.informativeText = error.description
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    private func isStartAtLoginEnabled() -> Bool {
        let output = processOutput("/bin/launchctl", ["print-disabled", "gui/\(getuid())"])
        for line in output.split(separator: "\n") {
            if line.contains(launchAgentLabel) {
                return !line.contains("=> true")
            }
        }
        return true
    }

    private func setStartAtLogin(enabled: Bool) {
        let domainTarget = "gui/\(getuid())/\(launchAgentLabel)"
        if enabled {
            runProcess("/bin/launchctl", ["enable", domainTarget])
        } else {
            runProcess("/bin/launchctl", ["disable", domainTarget])
        }
    }
}

private let recoverySessionMarkerName = ".interactive-dictation-recovery"

private func createRecoverySessionDirectory(
    root: URL,
    sessionID: String,
    startedAt: Date = Date()
) throws -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
    let directory = root.appendingPathComponent(
        "\(formatter.string(from: startedAt))-session-\(sessionID)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data().write(to: directory.appendingPathComponent(recoverySessionMarkerName))
    try Data().write(to: directory.appendingPathComponent("transcript.txt"), options: .atomic)
    return directory
}

private final class InteractiveDictationSession: @unchecked Sendable {
    let id: String
    let recoveryDirectory: URL
    let transcriptURL: URL
    let prepareGroup = DispatchGroup()

    private let lock = NSLock()
    private var chunkIndex = 0
    private var nextRecordingChunkIndex = 1
    private var pendingChunks = 0
    private var finishRequested = false
    private var completionClaimed = false
    private var committedText = ""
    private var chunkTexts: [Int: String] = [:]
    private var nextCommitIndex = 1

    init(recoveryRoot: URL = dictationRecoveryDir) throws {
        id = UUID().uuidString
        recoveryDirectory = try createRecoverySessionDirectory(root: recoveryRoot, sessionID: id)
        transcriptURL = recoveryDirectory.appendingPathComponent("transcript.txt")
        prepareGroup.enter()
    }

    var initialAudioFilename: String {
        "chunk-001.wav"
    }

    func nextAudioFilename() -> String {
        lock.lock()
        defer { lock.unlock() }
        nextRecordingChunkIndex += 1
        return String(format: "chunk-%03d.wav", nextRecordingChunkIndex)
    }

    func markPrepared() {
        prepareGroup.leave()
    }

    func registerChunk() -> Int {
        lock.lock()
        defer { lock.unlock() }
        chunkIndex += 1
        pendingChunks += 1
        return chunkIndex
    }

    func requestFinish() {
        lock.lock()
        finishRequested = true
        lock.unlock()
    }

    func completeChunk(index: Int, text: String) -> String? {
        lock.lock()
        chunkTexts[index] = text
        while let nextText = chunkTexts[nextCommitIndex] {
            if !nextText.isEmpty {
                let separator = committedText.isEmpty ? "" : " "
                committedText = "\(committedText)\(separator)\(nextText)"
            }
            chunkTexts.removeValue(forKey: nextCommitIndex)
            nextCommitIndex += 1
        }
        pendingChunks = max(0, pendingChunks - 1)
        let transcript = committedText
        let completedText = claimCompletedTextIfReadyLocked()
        lock.unlock()

        do {
            try Data(transcript.utf8).write(to: transcriptURL, options: .atomic)
        } catch {
            fputs("recovery transcript write failed session=\(id) path=\(transcriptURL.path) error=\(error)\n", stderr)
        }
        return completedText
    }

    func claimCompletedTextIfReady() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return claimCompletedTextIfReadyLocked()
    }

    private func claimCompletedTextIfReadyLocked() -> String? {
        guard finishRequested, pendingChunks == 0, !completionClaimed else {
            return nil
        }
        completionClaimed = true
        return committedText
    }
}

private enum DictationHotkeyPhase: String, Equatable {
    case idle
    case held
    case lockedWhileHeld
    case lockedAfterRelease
    case endedAwaitingRelease
}

private enum DictationHotkeyAction: String, Equatable {
    case startRecording
    case stopRecording
    case confirmLock
}

private enum RecordingStopReason: String {
    case chordReleased
    case lockedChordPressed
    case chunkRotationFailed
    case testRequest
}

private struct ModifierEventEvidence: Sendable {
    let id: UInt64
    let eventTimestamp: UInt64
    let occurredAt: Date
    let callbackUptimeNanoseconds: UInt64
    let keyCode: Int64
    let rawFlags: UInt64
    let sourcePID: Int64
    let sourceStateID: Int64
    let hidFlags: UInt64
    let combinedFlags: UInt64
    let hidLeftShiftDown: Bool
    let hidRightShiftDown: Bool
    let hidLeftControlDown: Bool
    let hidRightControlDown: Bool
    let hasShift: Bool
    let hasControl: Bool
    let hasOption: Bool
}

private struct DictationHotkeyStateMachine {
    private(set) var phase: DictationHotkeyPhase = .idle

    mutating func chordChanged(isPressed: Bool) -> DictationHotkeyAction? {
        switch (phase, isPressed) {
        case (.idle, true):
            phase = .held
            return .startRecording
        case (.held, false):
            phase = .idle
            return .stopRecording
        case (.lockedWhileHeld, false):
            phase = .lockedAfterRelease
            return nil
        case (.lockedAfterRelease, true):
            phase = .idle
            return .stopRecording
        case (.endedAwaitingRelease, false):
            phase = .idle
            return nil
        default:
            return nil
        }
    }

    mutating func requestLock() -> DictationHotkeyAction? {
        guard phase == .held else { return nil }
        phase = .lockedWhileHeld
        return .confirmLock
    }

    mutating func recordingEnded() {
        switch phase {
        case .held, .lockedWhileHeld:
            phase = .endedAwaitingRelease
        case .lockedAfterRelease:
            phase = .idle
        case .idle, .endedAwaitingRelease:
            break
        }
    }
}

final class DictationAgent {
    private let recorder = AudioRecorder()
    private let dictationASR = FluidDictationClient()
    private lazy var transcriptionAPI = TranscriptionAPIServer(asr: dictationASR)
    private let mlxASR = MLXASRClient()
    private let tts = ClipboardTTSManager()
    private let stateLock = NSLock()
    private let controlQueue = DispatchQueue(label: "com.markschroedr.mac-dictation.control")
    private var isRecording = false
    private var activeSession: InteractiveDictationSession?
    private var processingSessionIDs: Set<String> = []
    private var protectedRecoveryDirectories: Set<String> = []
    private var nextModifierEventID: UInt64 = 0
    private var chunkTimer: DispatchSourceTimer?
    private var eventTapMonitor: DispatchSourceTimer?
    private var accessibilityPermissionMonitor: DispatchSourceTimer?
    private var eventTap: CFMachPort?
    private var hotkeyState = DictationHotkeyStateMachine()
    private var statusMenu: StatusMenuController?
    private let transcriptionQueue = DispatchQueue(label: "com.markschroedr.mac-dictation.transcription", qos: .userInitiated)
    private var suppressPasteForTest = false
    private var testCompletionGroup: DispatchGroup?
    private var previewWindow: NSWindow?

    @MainActor
    func run() {
        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--menu-preview" {
            runMenuPreview()
            return
        }
        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--check-accessibility" {
            print(AXIsProcessTrusted() ? "accessibility=true" : "accessibility=false")
            return
        }
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--transcribe-file" {
            runTranscribeFile(path: CommandLine.arguments[2])
            return
        }
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--dictation-transcribe-file" {
            runDictationTranscribeFile(path: CommandLine.arguments[2])
            return
        }
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--record-test" {
            let seconds = Double(CommandLine.arguments[2]) ?? 3.0
            runRecordTest(seconds: seconds)
            return
        }
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--capture-test" {
            let seconds = Double(CommandLine.arguments[2]) ?? 1.0
            let trials = CommandLine.arguments.count >= 4 ? (Int(CommandLine.arguments[3]) ?? 5) : 5
            runCaptureTest(seconds: seconds, trials: trials)
            return
        }
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--permanent-record-test" {
            let seconds = Double(CommandLine.arguments[2]) ?? 5.0
            runPermanentRecordTest(seconds: seconds)
            return
        }
        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--audio-retention-test" {
            runAudioRetentionTest()
            return
        }
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--flow-test" {
            let seconds = Double(CommandLine.arguments[2]) ?? 3.0
            runFlowTest(seconds: seconds)
            return
        }
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--rapid-flow-test" {
            let seconds = Double(CommandLine.arguments[2]) ?? 1.0
            runRapidFlowTest(seconds: seconds)
            return
        }
        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--hotkey-lock-test" {
            runHotkeyLockTest()
            return
        }
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--tts-benchmark" {
            runTTSBenchmark(arguments: Array(CommandLine.arguments.dropFirst(2)))
            return
        }
        if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--tts-test" {
            let languageOrTextStart = CommandLine.arguments[3].lowercased()
            let language = TTSLanguage(rawValue: languageOrTextStart)
            let textStartIndex = language == nil ? 3 : 4
            runTTSTest(
                providerName: CommandLine.arguments[2],
                language: language ?? .current(),
                text: CommandLine.arguments.dropFirst(textStartIndex).joined(separator: " ")
            )
            return
        }

        DispatchQueue.global(qos: .utility).async {
            pruneRecoverySessions(
                root: dictationRecoveryDir,
                retentionHours: RecoveryRetentionPreference.hours,
                excludingPaths: []
            )
        }
        logEvent("MacDictationAgent running. Hold Control+Shift to dictate.")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        statusMenu = StatusMenuController(asr: mlxASR, tts: tts)
        logEvent("Status menu installed.")
        transcriptionAPI.start()
        configureAccessibilityFeatures()
        DispatchQueue.global(qos: .utility).async {
            self.recorder.preflight()
        }
        app.run()
    }

    @MainActor
    private func runMenuPreview() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let menu = StatusMenuController(asr: mlxASR, tts: tts)
        statusMenu = menu
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(
            contentRect: NSRect(x: screen.midX, y: screen.midY, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        previewWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let view = window.contentView,
                  let event = NSEvent.mouseEvent(
                    with: .rightMouseDown,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                  ) else { return }
            menu.openForPreview(with: event, in: view)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            app.terminate(nil)
        }
        app.run()
    }

    private func runTranscribeFile(path: String) {
        let sessionID = UUID().uuidString
        mlxASR.resetSession(sessionID)
        defer {
            mlxASR.shutdown()
        }
        do {
            let response = try mlxASR.transcribe(
                sessionID: sessionID,
                chunkIndex: 1,
                audioURL: URL(fileURLWithPath: path)
            )
            print(sanitize(response.text ?? ""))
        } catch {
            fputs("transcribe-file failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private func runDictationTranscribeFile(path: String) {
        let sessionID = UUID().uuidString
        defer {
            dictationASR.shutdown()
        }
        dictationASR.resetSession(sessionID)
        dictationASR.warmupSync()
        do {
            let response = try dictationASR.transcribe(
                sessionID: sessionID,
                chunkIndex: 1,
                audioURL: URL(fileURLWithPath: path),
                final: true
            )
            print(sanitize(response.text ?? ""))
        } catch {
            fputs("dictation-transcribe-file failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private func runRecordTest(seconds: Double) {
        let sessionID = UUID().uuidString
        defer {
            dictationASR.shutdown()
        }
        logEvent("record-test recording begin seconds=\(seconds)")
        do {
            _ = try recorder.start()
            Thread.sleep(forTimeInterval: seconds)
            guard let audioURL = try recorder.stop() else {
                fputs("record-test failed: no audio URL\n", stderr)
                exit(1)
            }
            if let stats = wavStats(audioURL) {
                logEvent("record-test captured \(String(format: "%.2f", stats.durationSeconds))s peak=\(stats.peak) rms=\(String(format: "%.1f", stats.rms))")
            }
            keepDebugAudio(audioURL, label: "record-test", maxFiles: 12)
            dictationASR.resetSession(sessionID)
            dictationASR.warmupSync()
            let response = try dictationASR.transcribe(
                sessionID: sessionID,
                chunkIndex: 1,
                audioURL: audioURL,
                final: true
            )
            let transcript = sanitize(response.text ?? "")
            logEvent("record-test transcribed chars=\(transcript.count)")
            print(transcript)
            try? FileManager.default.removeItem(at: audioURL)
        } catch {
            fputs("record-test failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private func runCaptureTest(seconds: Double, trials: Int) {
        recorder.preflight()
        for trial in 1...max(1, trials) {
            logEvent("capture-test trial=\(trial) recording begin seconds=\(seconds)")
            do {
                _ = try recorder.start()
                Thread.sleep(forTimeInterval: seconds)
                guard let audioURL = try recorder.stop() else {
                    fputs("capture-test failed: no audio URL\n", stderr)
                    exit(1)
                }
                if let stats = wavStats(audioURL) {
                    logEvent("capture-test trial=\(trial) captured \(String(format: "%.2f", stats.durationSeconds))s peak=\(stats.peak) rms=\(String(format: "%.1f", stats.rms))")
                } else {
                    logEvent("capture-test trial=\(trial) captured unreadable wav path=\(audioURL.path)")
                }
                keepDebugAudio(audioURL, label: "capture-test", maxFiles: 12)
                try? FileManager.default.removeItem(at: audioURL)
            } catch {
                fputs("capture-test failed trial=\(trial): \(error)\n", stderr)
                exit(1)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func runPermanentRecordTest(seconds: Double) {
        let manager = PermanentTranscriberController()
        if manager.status().isRunning {
            fputs("permanent-record-test refused: permanent-transcriber is already running\n", stderr)
            exit(1)
        }
        let environment = sharedPermanentTranscriberEnvironment()
        let startResult = runProcessCapturingOutput(
            permanentTranscriberExecutable.path,
            ["start"],
            environment: environment,
            currentDirectory: permanentTranscriberCodeRoot
        )
        if startResult.status != 0 {
            fputs("permanent-record-test start failed: \(startResult.output)\n", stderr)
            exit(1)
        }
        Thread.sleep(forTimeInterval: seconds)
        let stopResult = runProcessCapturingOutput(
            permanentTranscriberExecutable.path,
            ["stop"],
            environment: environment,
            currentDirectory: permanentTranscriberCodeRoot
        )
        if stopResult.status != 0 {
            fputs("permanent-record-test stop failed: \(stopResult.output)\n", stderr)
            exit(1)
        }
        print(permanentTranscriberStorageDir.path)
    }

    private func runAudioRetentionTest() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-dictation-retention-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let recoveryRoot = root.appendingPathComponent("recovery")
            let quarantine = root.appendingPathComponent("test-trash")
            try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
            let expired = try createRecoverySessionDirectory(root: recoveryRoot, sessionID: "expired")
            let active = try createRecoverySessionDirectory(root: recoveryRoot, sessionID: "active")
            let fresh = try createRecoverySessionDirectory(root: recoveryRoot, sessionID: "fresh")
            let legacy = recoveryRoot.appendingPathComponent("legacy-diagnostic-artifacts")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            let transcriptSession = try InteractiveDictationSession(recoveryRoot: recoveryRoot)
            let firstIndex = transcriptSession.registerChunk()
            let secondIndex = transcriptSession.registerChunk()
            _ = transcriptSession.completeChunk(index: secondIndex, text: "world")
            guard try String(contentsOf: transcriptSession.transcriptURL, encoding: .utf8).isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            _ = transcriptSession.completeChunk(index: firstIndex, text: "hello")
            guard try String(contentsOf: transcriptSession.transcriptURL, encoding: .utf8) == "hello world" else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let audio = active.appendingPathComponent("chunk-001.wav")
            try Data("recoverable audio".utf8).write(to: audio)
            let oldDate = Date().addingTimeInterval(-48 * 3600)
            for directory in [expired, active, legacy] {
                try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: directory.path)
            }

            pruneRecoverySessions(
                root: recoveryRoot,
                retentionHours: 24,
                excludingPaths: [active.standardizedFileURL.path],
                moveToTrash: { url in
                    try FileManager.default.moveItem(
                        at: url,
                        to: quarantine.appendingPathComponent(url.lastPathComponent)
                    )
                }
            )

            guard !FileManager.default.fileExists(atPath: expired.path) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard FileManager.default.fileExists(atPath: active.path),
                  FileManager.default.fileExists(atPath: audio.path),
                  FileManager.default.fileExists(atPath: fresh.path),
                  FileManager.default.fileExists(atPath: legacy.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            print("audio-retention-test passed")
        } catch {
            fputs("audio-retention-test failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private func runFlowTest(seconds: Double) {
        let group = DispatchGroup()
        group.enter()
        suppressPasteForTest = true
        testCompletionGroup = group
        logEvent("flow-test begin seconds=\(seconds)")
        recorder.preflight()
        controlQueue.sync {
            startRecording()
        }
        Thread.sleep(forTimeInterval: seconds)
        controlQueue.sync {
            stopRecordingAndPaste(reason: .testRequest)
        }
        let result = group.wait(timeout: .now() + 180)
        logEvent("flow-test completion result=\(result == .success ? "success" : "timeout")")
        suppressPasteForTest = false
        testCompletionGroup = nil
        dictationASR.shutdown()
    }

    private func runRapidFlowTest(seconds: Double) {
        let group = DispatchGroup()
        group.enter()
        group.enter()
        suppressPasteForTest = true
        testCompletionGroup = group
        logEvent("rapid-flow-test begin seconds=\(seconds)")
        recorder.preflight()
        for run in 1...2 {
            controlQueue.sync {
                startRecording()
            }
            Thread.sleep(forTimeInterval: seconds)
            controlQueue.sync {
                stopRecordingAndPaste(reason: .testRequest)
            }
            logEvent("rapid-flow-test recording completed run=\(run)")
        }
        let result = group.wait(timeout: .now() + 180)
        logEvent("rapid-flow-test completion result=\(result == .success ? "success" : "timeout")")
        suppressPasteForTest = false
        testCompletionGroup = nil
        dictationASR.shutdown()
        if result != .success {
            exit(1)
        }
    }

    private func runHotkeyLockTest() {
        var ordinary = DictationHotkeyStateMachine()
        precondition(ordinary.chordChanged(isPressed: true) == .startRecording)
        precondition(ordinary.chordChanged(isPressed: true) == nil)
        precondition(ordinary.chordChanged(isPressed: false) == .stopRecording)
        precondition(ordinary.phase == .idle)

        var locked = DictationHotkeyStateMachine()
        precondition(locked.chordChanged(isPressed: true) == .startRecording)
        precondition(locked.requestLock() == .confirmLock)
        precondition(locked.chordChanged(isPressed: false) == nil)
        precondition(locked.phase == .lockedAfterRelease)
        precondition(locked.chordChanged(isPressed: true) == .stopRecording)
        precondition(locked.chordChanged(isPressed: false) == nil)
        precondition(locked.phase == .idle)

        var failed = DictationHotkeyStateMachine()
        precondition(failed.chordChanged(isPressed: true) == .startRecording)
        failed.recordingEnded()
        precondition(failed.chordChanged(isPressed: true) == nil)
        precondition(failed.chordChanged(isPressed: false) == nil)
        precondition(failed.phase == .idle)
        print("hotkey-lock-state=ok")
    }

    private func runTTSTest(providerName: String, language: TTSLanguage, text: String) {
        guard let provider = ttsProvider(named: providerName) else {
            fputs(
                "tts-test failed: provider must be local, supertonic, inworld, or xai\n",
                stderr
            )
            exit(1)
        }

        defer {
            tts.shutdown()
        }
        do {
            let result = try tts.generateSpeech(
                text: text,
                provider: provider,
                language: language,
                play: false
            )
            print(result.openURL.path)
        } catch {
            fputs("tts-test failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private func runTTSBenchmark(arguments: [String]) {
        guard let providerName = arguments.first,
              let provider = ttsProvider(named: providerName) else {
            fputs(
                "usage: --tts-benchmark <provider> [auto|english|german] [--play] --file <path>\n",
                stderr
            )
            exit(1)
        }

        var language = TTSLanguage.current()
        var play = false
        var filePath: String?
        var textParts: [String] = []
        var index = 1
        if arguments.indices.contains(index),
           let positionalLanguage = TTSLanguage(rawValue: arguments[index].lowercased()) {
            language = positionalLanguage
            index += 1
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--play":
                play = true
                index += 1
            case "--file":
                guard arguments.indices.contains(index + 1) else {
                    fputs("tts-benchmark failed: --file requires a path\n", stderr)
                    exit(1)
                }
                filePath = arguments[index + 1]
                index += 2
            default:
                textParts.append(arguments[index])
                index += 1
            }
        }

        let text: String
        do {
            if let filePath {
                guard textParts.isEmpty else {
                    throw ClipboardTTSError.invalidResponse(
                        "Use either --file or inline benchmark text, not both"
                    )
                }
                text = try String(
                    contentsOf: URL(fileURLWithPath: filePath),
                    encoding: .utf8
                )
            } else {
                text = textParts.joined(separator: " ")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ClipboardTTSError.emptyClipboard
            }
        } catch {
            fputs("tts-benchmark failed: \(error)\n", stderr)
            exit(1)
        }

        defer {
            tts.shutdown()
        }
        do {
            let result = try tts.generateSpeech(
                text: text,
                provider: provider,
                language: language,
                play: play
            )
            if play {
                result.metrics.waitForPlayingObservation(timeout: 5)
            }
            let output = TTSBenchmarkOutput(
                provider: provider.rawValue,
                language: language.rawValue,
                play: play,
                characterCount: result.characterCount,
                wordCount: text.split(whereSeparator: \Character.isWhitespace).count,
                chunkCount: result.chunkCount,
                outputPath: result.openURL.path,
                metrics: result.metrics.snapshot()
            )
            let data = try JSONEncoder().encode(output)
            print(String(decoding: data, as: UTF8.self))
            if play, let playbackResult = tts.waitForPlayback() {
                logEvent("tts benchmark playback ended detail=\(playbackResult)")
            }
        } catch {
            fputs("tts-benchmark failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private func ttsProvider(named name: String) -> TTSProvider? {
        switch name.lowercased() {
        case "supertonic", "local":
            return .supertonic
        case "inworld":
            return .inworld
        case "xai", "grok":
            return .xai
        default:
            return nil
        }
    }

    private func startRecording(triggerEventID: UInt64? = nil) {
        guard !isRecording else { return }
        var failedRecoveryDirectory: URL?
        do {
            let session = try InteractiveDictationSession()
            failedRecoveryDirectory = session.recoveryDirectory
            protectRecoveryDirectory(session.recoveryDirectory)
            let trigger = triggerEventID.map(String.init) ?? "none"
            logEvent(
                "recording start requested session=\(session.id) trigger_event=\(trigger) "
                    + "recovery=\(session.recoveryDirectory.path)"
            )
            logEvent("audio recorder start begin session=\(session.id)")
            _ = try recorder.start(
                outputDirectory: session.recoveryDirectory,
                filename: session.initialAudioFilename
            )
            logEvent("audio recorder start end session=\(session.id)")
            activeSession = session
            isRecording = true
            updateInteractiveRecordingIndicator(true)
            playStartSound()
            prepareASRSession(session)
            startChunkTimer()
            logEvent("recording started session=\(session.id)")
        } catch {
            if let failedRecoveryDirectory {
                unprotectRecoveryDirectory(failedRecoveryDirectory)
            }
            activeSession = nil
            isRecording = false
            hotkeyState.recordingEnded()
            updateInteractiveRecordingIndicator(false)
            playErrorSound()
            dictationASR.scheduleShutdown()
            fputs(
                "recording failed; recovery preserved path=\(failedRecoveryDirectory?.path ?? "unavailable") error=\(error)\n",
                stderr
            )
        }
    }

    private func prepareASRSession(_ session: InteractiveDictationSession) {
        DispatchQueue.global(qos: .utility).async {
            logEvent("ASR prepare begin session=\(session.id)")
            // Transcription is serial; each request switches the helper's session atomically.
            self.dictationASR.warmupSync()
            logEvent("ASR prepare end session=\(session.id)")
            session.markPrepared()
        }
    }

    private func stopRecordingAndPaste(
        reason: RecordingStopReason,
        triggerEventID: UInt64? = nil
    ) {
        guard isRecording, let session = activeSession else {
            logEvent("recording stop ignored reason=\(reason.rawValue) session=none")
            return
        }
        isRecording = false
        activeSession = nil
        hotkeyState.recordingEnded()
        updateInteractiveRecordingIndicator(false)
        setSessionProcessing(session, active: true)
        session.requestFinish()
        let trigger = triggerEventID.map(String.init) ?? "none"
        logEvent("recording stop requested session=\(session.id) reason=\(reason.rawValue) trigger_event=\(trigger)")
        chunkTimer?.cancel()
        chunkTimer = nil
        let audioURL: URL
        do {
            guard let stoppedURL = try recorder.stop(
                postrollSeconds: finalChunkPostrollSeconds,
                context: "stop session=\(session.id) reason=\(reason.rawValue)"
            ) else {
                logEvent("recording stop outcome=no-audio session=\(session.id) reason=\(reason.rawValue)")
                finishSessionIfReady(session)
                dictationASR.scheduleShutdown()
                return
            }
            audioURL = stoppedURL
        } catch {
            logEvent(
                "recording stop outcome=failed session=\(session.id) reason=\(reason.rawValue) "
                    + "recovery=\(session.recoveryDirectory.path) error=\(error)"
            )
            playErrorSound()
            finishSessionIfReady(session)
            dictationASR.scheduleShutdown()
            return
        }
        logEvent("recording stopped session=\(session.id) reason=\(reason.rawValue) path=\(audioURL.path)")
        playStopSound()
        processChunk(audioURL, session: session, final: true)
    }

    private func startChunkTimer() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + chunkSeconds, repeating: chunkSeconds)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRecording, let session = self.activeSession else { return }
            do {
                if let url = try self.recorder.rotate(
                    outputDirectory: session.recoveryDirectory,
                    filename: session.nextAudioFilename(),
                    context: "rotation session=\(session.id)"
                ) {
                    self.processChunk(url, session: session, final: false)
                }
            } catch {
                playErrorSound()
                logEvent(
                    "chunk rotation outcome=failed session=\(session.id) "
                        + "recovery=\(session.recoveryDirectory.path) error=\(error)"
                )
                self.stopRecordingAndPaste(reason: .chunkRotationFailed)
            }
        }
        chunkTimer = timer
        timer.resume()
    }

    private func processChunk(
        _ audioURL: URL,
        session: InteractiveDictationSession,
        final: Bool
    ) {
        let index = session.registerChunk()
        let sessionID = session.id
        logEvent("chunk queued session=\(sessionID) chunk=\(index) final=\(final) path=\(audioURL.path)")
        transcriptionQueue.async {
            if let stats = wavStats(audioURL) {
                logEvent(
                    "chunk audio session=\(sessionID) chunk=\(index) duration=\(String(format: "%.2f", stats.durationSeconds))s "
                        + "peak=\(stats.peak) rms=\(String(format: "%.1f", stats.rms)) quiet=\(stats.isSuspiciouslyQuiet) final=\(final)"
                )
            } else {
                logEvent("chunk audio session=\(sessionID) chunk=\(index) stats=unavailable final=\(final)")
            }
            var completedText = ""
            do {
                logEvent("chunk ASR wait begin session=\(sessionID) chunk=\(index)")
                let waitResult = session.prepareGroup.wait(timeout: .now() + fluidSessionPrepareTimeoutSeconds)
                logEvent("chunk ASR wait end session=\(sessionID) chunk=\(index) result=\(waitResult == .success ? "success" : "timeout")")
                let response = try self.dictationASR.transcribe(
                    sessionID: sessionID,
                    chunkIndex: index,
                    audioURL: audioURL,
                    final: final
                )
                completedText = sanitize(response.text ?? "")
                let outcome = completedText.isEmpty ? "empty" : "transcribed"
                logEvent(
                    "chunk outcome=\(outcome) session=\(sessionID) chunk=\(index) chars=\(completedText.count) "
                        + "speedup=\(response.speedup ?? 0) recovery=\(audioURL.path)"
                )
            } catch {
                playErrorSound()
                fputs(
                    "chunk outcome=transcription-failed session=\(sessionID) chunk=\(index) original=\(audioURL.path) error=\(error)\n",
                    stderr
                )
            }
            if let text = session.completeChunk(index: index, text: completedText) {
                self.finishSession(session, text: text)
            }
        }
    }

    private func finishSessionIfReady(_ session: InteractiveDictationSession) {
        if let text = session.claimCompletedTextIfReady() {
            finishSession(session, text: text)
        }
    }

    private func finishSession(_ session: InteractiveDictationSession, text rawText: String) {
        let text = sanitize(rawText)
        setSessionProcessing(session, active: false)
        unprotectRecoveryDirectory(session.recoveryDirectory)
        pruneRecoveryAfterSession()
        defer { dictationASR.scheduleShutdown() }
        defer {
            testCompletionGroup?.leave()
        }
        if text.isEmpty {
            playErrorSound()
            logEvent(
                "session finalized outcome=empty session=\(session.id) transcript=\(session.transcriptURL.path) "
                    + "recovery=\(session.recoveryDirectory.path)"
            )
            return
        }
        if suppressPasteForTest {
            logEvent("session finalized outcome=test-suppressed session=\(session.id) chars=\(text.count) recovery=\(session.recoveryDirectory.path)")
            return
        }
        let targetApplication = NSWorkspace.shared.frontmostApplication
        let targetPID = targetApplication?.processIdentifier ?? -1
        let targetBundle = targetApplication?.bundleIdentifier ?? "unknown"
        let physicalFlags = CGEventSource.flagsState(.combinedSessionState).rawValue
        let clipboardWritten = copyToClipboard(text)
        let pasteEventsPosted = pasteClipboard()
        logEvent(
            "delivery paste requested session=\(session.id) target_pid=\(targetPID) target_bundle=\(targetBundle) "
                + "clipboard_write=\(clipboardWritten ? "success" : "failed") event_posted=\(pasteEventsPosted) "
                + "physical_flags=0x\(String(physicalFlags, radix: 16))"
        )
        logEvent("session finalized outcome=paste-requested session=\(session.id) chars=\(text.count) transcript=\(session.transcriptURL.path)")
    }

    private func setSessionProcessing(_ session: InteractiveDictationSession, active: Bool) {
        stateLock.lock()
        if active {
            processingSessionIDs.insert(session.id)
        } else {
            processingSessionIDs.remove(session.id)
        }
        let hasProcessingSessions = !processingSessionIDs.isEmpty
        stateLock.unlock()
        updateInteractiveProcessingIndicator(hasProcessingSessions)
    }

    private func protectRecoveryDirectory(_ directory: URL) {
        stateLock.lock()
        protectedRecoveryDirectories.insert(directory.standardizedFileURL.path)
        stateLock.unlock()
    }

    private func unprotectRecoveryDirectory(_ directory: URL) {
        stateLock.lock()
        protectedRecoveryDirectories.remove(directory.standardizedFileURL.path)
        stateLock.unlock()
    }

    private func pruneRecoveryAfterSession() {
        stateLock.lock()
        let excluded = protectedRecoveryDirectories
        stateLock.unlock()
        DispatchQueue.global(qos: .utility).async {
            pruneRecoverySessions(
                root: dictationRecoveryDir,
                retentionHours: RecoveryRetentionPreference.hours,
                excludingPaths: excluded
            )
        }
    }

    private func updateInteractiveRecordingIndicator(_ active: Bool) {
        let menu = statusMenu
        DispatchQueue.main.async {
            menu?.setInteractiveRecording(active)
        }
    }

    private func updateInteractiveProcessingIndicator(_ active: Bool) {
        let menu = statusMenu
        DispatchQueue.main.async {
            menu?.setInteractiveProcessing(active)
        }
    }

    private func installEventTap() {
        if let existingTap = eventTap {
            CGEvent.tapEnable(tap: existingTap, enable: false)
            eventTap = nil
        }
        let mask = (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let agent = Unmanaged<DictationAgent>.fromOpaque(refcon!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    agent.eventTapDisabled(type)
                    return Unmanaged.passUnretained(event)
                }
                guard type == .flagsChanged else {
                    return Unmanaged.passUnretained(event)
                }
                agent.handleFlags(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            fputs("failed to create event tap; grant Accessibility permission\n", stderr)
            exit(1)
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func configureAccessibilityFeatures() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            installEventTap()
            startEventTapMonitor()
            logEvent("Accessibility permission confirmed; event tap installed.")
            return
        }
        logEvent("Accessibility permission missing; menu remains available while hotkey setup waits.")
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, AXIsProcessTrusted() else { return }
            self.accessibilityPermissionMonitor?.cancel()
            self.accessibilityPermissionMonitor = nil
            self.installEventTap()
            self.startEventTapMonitor()
            logEvent("Accessibility permission confirmed; event tap installed.")
        }
        accessibilityPermissionMonitor = timer
        timer.resume()
    }

    private func startEventTapMonitor() {
        eventTapMonitor?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.ensureEventTapEnabled(reason: "monitor")
        }
        eventTapMonitor = timer
        timer.resume()
    }

    private func eventTapDisabled(_ type: CGEventType) {
        logEvent("event tap disabled type=\(type.rawValue)")
        ensureEventTapEnabled(reason: "callback-\(type.rawValue)")
    }

    private func ensureEventTapEnabled(reason: String) {
        guard AXIsProcessTrusted() else {
            logEvent("event tap not enabled; Accessibility permission missing reason=\(reason)")
            return
        }
        guard let tap = eventTap, CFMachPortIsValid(tap) else {
            logEvent("event tap missing or invalid; reinstalling reason=\(reason)")
            installEventTap()
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            logEvent("event tap disabled; re-enabling reason=\(reason)")
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleFlags(_ event: CGEvent) {
        nextModifierEventID += 1
        let callbackUptime = DispatchTime.now().uptimeNanoseconds
        let eventTimestamp = event.timestamp
        let eventAge = callbackUptime >= eventTimestamp ? callbackUptime - eventTimestamp : 0
        let flags = event.flags
        let evidence = ModifierEventEvidence(
            id: nextModifierEventID,
            eventTimestamp: eventTimestamp,
            occurredAt: Date().addingTimeInterval(-Double(eventAge) / 1_000_000_000),
            callbackUptimeNanoseconds: callbackUptime,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            rawFlags: flags.rawValue,
            sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
            sourceStateID: event.getIntegerValueField(.eventSourceStateID),
            hidFlags: CGEventSource.flagsState(.hidSystemState).rawValue,
            combinedFlags: CGEventSource.flagsState(.combinedSessionState).rawValue,
            hidLeftShiftDown: CGEventSource.keyState(.hidSystemState, key: 56),
            hidRightShiftDown: CGEventSource.keyState(.hidSystemState, key: 60),
            hidLeftControlDown: CGEventSource.keyState(.hidSystemState, key: 59),
            hidRightControlDown: CGEventSource.keyState(.hidSystemState, key: 62),
            hasShift: flags.contains(.maskShift),
            hasControl: flags.contains(.maskControl),
            hasOption: flags.contains(.maskAlternate)
        )
        logEvent(
            "modifier event received event=\(evidence.id) occurred_at=\(isoTimestamp(evidence.occurredAt)) "
                + "event_uptime_ns=\(evidence.eventTimestamp) callback_delay_ms=\(String(format: "%.3f", Double(eventAge) / 1_000_000)) "
                + "keycode=\(evidence.keyCode) raw_flags=0x\(String(evidence.rawFlags, radix: 16)) "
                + "source_pid=\(evidence.sourcePID) source_state=\(evidence.sourceStateID) "
                + "hid_flags=0x\(String(evidence.hidFlags, radix: 16)) combined_flags=0x\(String(evidence.combinedFlags, radix: 16)) "
                + "hid_keys=shift_l:\(evidence.hidLeftShiftDown),shift_r:\(evidence.hidRightShiftDown),"
                + "control_l:\(evidence.hidLeftControlDown),control_r:\(evidence.hidRightControlDown)"
        )
        controlQueue.async { [weak self] in
            self?.handleHotkeyModifiers(evidence)
        }
    }

    private func handleHotkeyModifiers(_ evidence: ModifierEventEvidence) {
        let handlingUptime = DispatchTime.now().uptimeNanoseconds
        let queueDelay = handlingUptime >= evidence.callbackUptimeNanoseconds
            ? handlingUptime - evidence.callbackUptimeNanoseconds
            : 0
        let isPressed = evidence.hasShift && evidence.hasControl
        let previousPhase = hotkeyState.phase
        let sessionID = activeSession?.id ?? "none"
        let action = hotkeyState.chordChanged(isPressed: isPressed)
        let actionName = action?.rawValue ?? "none"
        let stopReason: RecordingStopReason? = action == .stopRecording
            ? (previousPhase == .lockedAfterRelease ? .lockedChordPressed : .chordReleased)
            : nil
        logEvent(
            "modifier event handled event=\(evidence.id) queue_delay_ms=\(String(format: "%.3f", Double(queueDelay) / 1_000_000)) "
                + "keycode=\(evidence.keyCode) raw_flags=0x\(String(evidence.rawFlags, radix: 16)) "
                + "shift=\(evidence.hasShift) control=\(evidence.hasControl) option=\(evidence.hasOption) "
                + "phase=\(previousPhase.rawValue)->\(hotkeyState.phase.rawValue) action=\(actionName) "
                + "stop_reason=\(stopReason?.rawValue ?? "none") session=\(sessionID)"
        )

        switch action {
        case .startRecording:
            startRecording(triggerEventID: evidence.id)
        case .stopRecording:
            if let stopReason {
                stopRecordingAndPaste(reason: stopReason, triggerEventID: evidence.id)
            } else {
                logEvent("hotkey stop missing reason event=\(evidence.id) session=\(sessionID)")
            }
        case .confirmLock, nil:
            break
        }
        if isPressed && evidence.hasOption {
            lockCurrentRecording(triggerEventID: evidence.id)
        }
    }

    private func lockCurrentRecording(triggerEventID: UInt64) {
        let previousPhase = hotkeyState.phase
        guard isRecording, hotkeyState.requestLock() == .confirmLock else {
            logEvent(
                "hotkey action=lock-ignored event=\(triggerEventID) phase=\(previousPhase.rawValue) "
                    + "session=\(activeSession?.id ?? "none")"
            )
            return
        }
        playLockSound()
        logEvent(
            "hotkey action=confirmLock event=\(triggerEventID) phase=\(previousPhase.rawValue)->\(hotkeyState.phase.rawValue) "
                + "session=\(activeSession?.id ?? "none")"
        )
    }
}

extension DictationAgent: @unchecked Sendable {}

func pruneRecoverySessions(
    root: URL,
    retentionHours: Int,
    excludingPaths: Set<String>,
    now: Date = Date(),
    moveToTrash: ((URL) throws -> Void)? = nil
) {
    guard retentionHours > 0 else {
        logEvent("dictation recovery pruning skipped retention=forever")
        return
    }
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .creationDateKey]
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
    ) else {
        return
    }
    let cutoff = now.addingTimeInterval(-Double(retentionHours) * 3600)
    var trashedCount = 0
    for entry in entries {
        guard !excludingPaths.contains(entry.standardizedFileURL.path) else { continue }
        guard FileManager.default.fileExists(
            atPath: entry.appendingPathComponent(recoverySessionMarkerName).path
        ) else { continue }
        guard let values = try? entry.resourceValues(forKeys: keys), values.isDirectory == true else {
            continue
        }
        let sessionDate = values.contentModificationDate ?? values.creationDate ?? now
        guard sessionDate < cutoff else { continue }
        do {
            if let moveToTrash {
                try moveToTrash(entry)
            } else {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: entry, resultingItemURL: &resultingURL)
            }
            trashedCount += 1
            logEvent("dictation recovery expired action=trashed path=\(entry.path)")
        } catch {
            fputs("dictation recovery expiry failed; original preserved path=\(entry.path) error=\(error)\n", stderr)
        }
    }
    logEvent("dictation recovery pruning complete retention_hours=\(retentionHours) trashed=\(trashedCount)")
}

func keepDebugAudio(_ audioURL: URL, label: String, maxFiles: Int) {
    do {
        try FileManager.default.createDirectory(at: debugAudioDir, withIntermediateDirectories: true)
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let safeLabel = label.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        let ext = audioURL.pathExtension.isEmpty ? "audio" : audioURL.pathExtension
        let destination = debugAudioDir.appendingPathComponent("\(timestamp)-\(safeLabel).\(ext)")
        try FileManager.default.copyItem(at: audioURL, to: destination)
        logEvent("debug audio saved path=\(destination.path)")
        pruneDebugAudio(maxFiles: maxFiles)
    } catch {
        fputs("debug audio save failed: \(error)\n", stderr)
    }
}

func pruneDebugAudio(maxFiles: Int) {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: debugAudioDir,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else {
        return
    }
    let audioFiles = files
        .filter { ["caf", "wav", "m4a", "aiff", "aif"].contains($0.pathExtension.lowercased()) }
        .sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
    for file in audioFiles.dropFirst(maxFiles) {
        try? FileManager.default.removeItem(at: file)
    }
}

func sanitize(_ text: String) -> String {
    text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

struct WavStats {
    let durationSeconds: Double
    let peak: Int
    let rms: Double

    var isSuspiciouslyQuiet: Bool {
        durationSeconds >= 0.5 && rms < 250
    }
}

func wavStats(_ url: URL) -> WavStats? {
    if url.pathExtension.lowercased() != "wav" {
        return audioFileStats(url)
    }
    guard let data = try? Data(contentsOf: url), data.count > 44 else {
        return nil
    }
    let sampleBytes = data.dropFirst(44)
    let sampleCount = sampleBytes.count / MemoryLayout<Int16>.size
    if sampleCount == 0 {
        return WavStats(durationSeconds: 0, peak: 0, rms: 0)
    }
    var peak = 0
    var sumSquares = 0.0
    for index in 0..<sampleCount {
        let byteOffset = 44 + index * 2
        let lo = UInt16(data[byteOffset])
        let hi = UInt16(data[byteOffset + 1]) << 8
        let sample = Int16(bitPattern: hi | lo)
        let absolute = abs(Int(sample))
        peak = max(peak, absolute)
        sumSquares += Double(sample) * Double(sample)
    }
    return WavStats(
        durationSeconds: Double(sampleCount) / 16_000.0,
        peak: peak,
        rms: sqrt(sumSquares / Double(sampleCount))
    )
}

func audioFileStats(_ url: URL) -> WavStats? {
    guard let file = try? AVAudioFile(forReading: url) else {
        return nil
    }
    let format = file.processingFormat
    guard file.length > 0, format.sampleRate > 0 else {
        return nil
    }
    let frameCount = AVAudioFrameCount(min(file.length, AVAudioFramePosition(UInt32.max)))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        return nil
    }
    do {
        try file.read(into: buffer)
    } catch {
        return nil
    }
    let frames = Int(buffer.frameLength)
    guard frames > 0 else {
        return nil
    }
    let channels = Int(format.channelCount)
    var peak = 0
    var sumSquares = 0.0
    var sampleCount = 0
    if let floatChannels = buffer.floatChannelData {
        for channelIndex in 0..<channels {
            let channel = floatChannels[channelIndex]
            for frameIndex in 0..<frames {
                let scaled = Double(channel[frameIndex]) * 32767.0
                let absolute = min(32767, abs(Int(scaled.rounded())))
                peak = max(peak, absolute)
                sumSquares += scaled * scaled
                sampleCount += 1
            }
        }
    } else if let int16Channels = buffer.int16ChannelData {
        for channelIndex in 0..<channels {
            let channel = int16Channels[channelIndex]
            for frameIndex in 0..<frames {
                let sample = Int(channel[frameIndex])
                let absolute = abs(sample)
                peak = max(peak, absolute)
                sumSquares += Double(sample) * Double(sample)
                sampleCount += 1
            }
        }
    } else {
        return WavStats(durationSeconds: Double(file.length) / format.sampleRate, peak: 0, rms: 0)
    }
    guard sampleCount > 0 else {
        return nil
    }
    return WavStats(
        durationSeconds: Double(file.length) / format.sampleRate,
        peak: peak,
        rms: sqrt(sumSquares / Double(sampleCount))
    )
}

@discardableResult
func copyToClipboard(_ text: String) -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.setString(text, forType: .string)
}

@discardableResult
func pasteClipboard() -> Bool {
    let source = CGEventSource(stateID: .hidSystemState)
    guard
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    else {
        return false
    }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    return true
}

func playStartSound() {
    AudioServicesPlaySystemSound(1104)
}

func playStopSound() {
    AudioServicesPlaySystemSound(1105)
}

func playLockSound() {
    DispatchQueue.main.async {
        guard let sound = NSSound(named: NSSound.Name("Pop")) else {
            AudioServicesPlaySystemSound(1104)
            return
        }
        sound.volume = 0.35
        sound.play()
    }
}

func playErrorSound() {
    AudioServicesPlaySystemSound(1053)
}

let agent = DictationAgent()
MainActor.assumeIsolated {
    agent.run()
}
