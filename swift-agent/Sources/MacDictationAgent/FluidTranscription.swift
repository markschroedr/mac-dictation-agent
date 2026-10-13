import AVFoundation
import Darwin
import DictationServiceProtocol
import Foundation

final class FluidDictationClient: @unchecked Sendable {
    // Only one pipe exchange/model invocation runs at a time. Background work
    // yields between bounded audio windows; waiting dictation always goes next.
    private let admission = NSCondition()
    private var busy = false
    private var foregroundWaiters = 0
    private var generation = 0
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var launchedModel: DictationModel?
    private var lastSessionID: String?

    /// Decode outside the model's admission gate. Files may be hours long;
    /// only a 20-second recognition window can delay an arriving dictation.
    func transcribeFiles(_ paths: [URL], background: Bool) throws -> TranscriptionResponse {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluid-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID().uuidString
        var index = 0
        var offset = 0.0
        var recognition = 0.0
        var segments: [DictationTextSegment] = []
        var texts: [String] = []
        for (fileIndex, path) in paths.enumerated() {
            var source = path
            // Opus/Ogg source archives need ffmpeg. CoreAudio-readable uploads
            // keep working without optional Python or ffmpeg installations.
            if ["opus", "ogg", "webm"].contains(path.pathExtension.lowercased()) {
                source = directory.appendingPathComponent("decoded-\(fileIndex).wav")
                let status = runProcess(ffmpegExecutablePath(), [
                    "-hide_banner", "-loglevel", "error", "-nostdin", "-i", path.path,
                    "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", source.path,
                ])
                guard status == 0 else { throw ManualTranscriptionError.conversionFailed(status) }
            }
            try forEachAudioWindow(source, directory: directory) { chunk in
                index += 1
                let result = try self.transcribe(sessionID: sessionID, chunkIndex: index, audioURL: chunk,
                    final: true, background: background)
                let duration = result.duration_seconds ?? 0
                if let text = result.text, !text.isEmpty { texts.append(text) }
                segments += (result.segments ?? []).map {
                    DictationTextSegment(start: offset + min($0.start, duration),
                        end: offset + min($0.end, duration), text: $0.text)
                }
                offset += duration
                recognition += result.recognize_seconds ?? 0
            }
        }
        let text = texts.joined(separator: " ")
        return TranscriptionResponse(segments: segments, text: text, raw_text: text,
            duration_seconds: offset, recognize_seconds: recognition,
            speedup: recognition > 0 ? offset / recognition : nil, error: nil)
    }

    private func forEachAudioWindow(_ source: URL, directory: URL,
                                    consume: (URL) throws -> Void) throws {
        let asset = AVURLAsset(url: source)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw ASRClientError.requestFailed("Audio has no readable track: \(source.path)")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? ASRClientError.requestFailed("Audio decoding failed")
        }
        defer { reader.cancelReading() }
        let windowBytes = 20 * 16_000 * 2
        var pending = Data()
        let chunk = directory.appendingPathComponent("window.wav")
        func emit(_ pcm: Data) throws {
            var wav = Data("RIFF".utf8)
            func append32(_ value: UInt32) {
                var value = value.littleEndian
                withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) }
            }
            func append16(_ value: UInt16) {
                var value = value.littleEndian
                withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) }
            }
            append32(UInt32(pcm.count + 36))
            wav.append(Data("WAVEfmt ".utf8)); append32(16)
            append16(1); append16(1); append32(16_000); append32(32_000)
            append16(2); append16(16); wav.append(Data("data".utf8)); append32(UInt32(pcm.count))
            wav.append(pcm)
            try wav.write(to: chunk)
            try consume(chunk)
        }
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetDataBuffer(sample) else {
                throw ASRClientError.requestFailed("Audio decoder returned no samples")
            }
            var data = Data(count: CMBlockBufferGetDataLength(buffer))
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else {
                throw ASRClientError.requestFailed("Audio sample copy failed")
            }
            pending.append(data)
            while pending.count >= windowBytes {
                try emit(Data(pending.prefix(windowBytes)))
                pending.removeFirst(windowBytes)
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? ASRClientError.requestFailed("Incomplete audio decoding")
        }
        if !pending.isEmpty { try emit(pending) }
    }

    private func enter(background: Bool) {
        admission.lock()
        if !background { foregroundWaiters += 1 }
        while busy || (background && foregroundWaiters > 0) { admission.wait() }
        if !background { foregroundWaiters -= 1 }
        busy = true
        generation += 1
        admission.unlock()
    }

    private func leave() {
        admission.lock()
        busy = false
        admission.broadcast()
        admission.unlock()
    }

    func cancelScheduledShutdownForActivity() {
        admission.lock()
        generation += 1
        admission.unlock()
    }

    func scheduleShutdown() {
        admission.lock()
        generation += 1
        let expected = generation
        admission.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + fluidIdleShutdownSeconds) { [weak self] in
            guard let self else { return }
            self.admission.lock()
            guard !self.busy, self.foregroundWaiters == 0, self.generation == expected else {
                self.admission.unlock()
                return
            }
            self.busy = true
            self.admission.unlock()
            self.terminateProcess()
            self.leave()
        }
    }

    func shutdown() {
        enter(background: false)
        defer { leave() }
        terminateProcess()
    }

    func warmupSync(background: Bool = false) {
        do {
            _ = try request(DictationServiceRequest(action: .warmup), timeout: fluidWarmupTimeoutSeconds,
                background: background)
        } catch { logEvent("Fluid ASR warmup failed error=\(error)") }
    }

    func resetSession(_ sessionID: String) {
        do {
            _ = try request(DictationServiceRequest(action: .resetSession, sessionID: sessionID), timeout: 8)
        } catch { logEvent("Fluid ASR reset failed session=\(sessionID) error=\(error)") }
    }

    func transcribe(sessionID: String, chunkIndex: Int, audioURL: URL, final: Bool = false,
                    background: Bool = false) throws -> TranscriptionResponse {
        let response = try request(DictationServiceRequest(action: .transcribe, sessionID: sessionID,
            chunkIndex: chunkIndex, path: audioURL.path, final: final),
            timeout: fluidTranscribeTimeoutSeconds, background: background)
        return TranscriptionResponse(segments: response.segments, text: response.text, raw_text: response.rawText,
            duration_seconds: response.durationSeconds, recognize_seconds: response.recognizeSeconds,
            speedup: response.speedup, error: response.error)
    }

    private func request(_ request: DictationServiceRequest, timeout: Double,
                         background: Bool = false) throws -> DictationServiceResponse {
        enter(background: background)
        defer { leave() }
        if request.sessionID == nil || request.sessionID != lastSessionID,
           let launchedModel, launchedModel != DictationModel.current {
            terminateProcess()
        }
        if let session = request.sessionID { lastSessionID = session }
        let cold = process?.isRunning != true
        try ensureProcess()
        guard let inputHandle, let outputHandle else {
            throw ASRClientError.requestFailed("Fluid ASR pipes unavailable")
        }
        let response: DictationServiceResponse
        do {
            var data = try JSONEncoder().encode(request)
            data.append(0x0A)
            try inputHandle.write(contentsOf: data)
            response = try JSONDecoder().decode(DictationServiceResponse.self,
                from: readLine(from: outputHandle.fileDescriptor, timeout: cold ? max(timeout, fluidWarmupTimeoutSeconds) : timeout))
            guard response.id == request.id else {
                throw ASRClientError.requestFailed("Fluid ASR response mismatch")
            }
        } catch {
            // Do not leave a late response in the pipe or load a second model
            // while a timed-out helper is still alive.
            terminateProcess()
            throw error
        }
        if let error = response.error { throw ASRClientError.workerError(error) }
        return response
    }

    private func ensureProcess() throws {
        if process?.isRunning == true { return }
        terminateProcess()
        guard FileManager.default.isExecutableFile(atPath: fluidServiceExecutable.path) else {
            throw ASRClientError.requestFailed("Fluid ASR helper missing: \(fluidServiceExecutable.path)")
        }
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("fluid-dictation-service.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let error = try FileHandle(forWritingTo: logURL)
        try error.seekToEnd()
        let input = Pipe(), output = Pipe()
        let child = Process()
        child.executableURL = fluidServiceExecutable
        child.standardInput = input
        child.standardOutput = output
        child.standardError = error
        var env = ProcessInfo.processInfo.environment
        env["MAC_DICTATION_FLUID_MODEL_ROOT"] = fluidModelRoot.path
        let model = DictationModel.current
        env[DictationModel.environmentKey] = model.rawValue
        child.environment = env
        do { try child.run() } catch let launchError { try? error.close(); throw launchError }
        process = child
        inputHandle = input.fileHandleForWriting
        outputHandle = output.fileHandleForReading
        errorHandle = error
        launchedModel = model
        logEvent("Fluid ASR service launched pid=\(child.processIdentifier) model=\(model.rawValue)")
    }

    private func readLine(from fd: Int32, timeout: Double) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count <= 1_048_576 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ASRClientError.requestFailed("Fluid ASR timed out") }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(min(Double(Int32.max), ceil(remaining * 1000))))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw ASRClientError.requestFailed("Fluid ASR timed out or pipe failed") }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { throw ASRClientError.requestFailed("Fluid ASR closed pipe") }
            data.append(buffer, count: count)
            if let newline = data.firstIndex(of: 0x0A) { return Data(data[..<newline]) }
        }
        throw ASRClientError.requestFailed("Fluid ASR response exceeded 1 MB")
    }

    private func terminateProcess() {
        if let process, process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()
        inputHandle = nil; outputHandle = nil; errorHandle = nil
        process = nil; launchedModel = nil
    }
}
