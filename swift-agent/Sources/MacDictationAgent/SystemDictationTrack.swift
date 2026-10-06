import Foundation

/// A session-owned system track. Closed WAV files use the same FluidAudio queue as the microphone.
final class SystemDictationTrack: @unchecked Sendable {
    struct Chunk: Sendable {
        let url: URL
        let offset: Double
        let final: Bool
    }

    private let helper = Process()
    private let pipe = Pipe()
    private let readerFinished = DispatchGroup()
    private let lock = NSLock()
    private var completed: [Chunk] = []
    private var readerError: Error?
    private var stopping = false
    private let directory: URL
    private let startedAt: UInt64
    private let chunkBytes = 640_000 // 20 seconds, mono 16 kHz signed 16-bit PCM.

    init(executable: URL, directory: URL, startedAt: UInt64) throws {
        self.directory = directory
        self.startedAt = startedAt
        helper.executableURL = executable
        helper.arguments = ["--continuous-pcm"]
        helper.standardOutput = pipe
        let log = directory.appendingPathComponent("system-capture.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        helper.standardError = try FileHandle(forWritingTo: log)
        try helper.run()
        readerFinished.enter()
        DispatchQueue.global(qos: .userInitiated).async { self.readAudio() }
    }

    func takeCompleted() throws -> [Chunk] {
        lock.lock()
        defer { lock.unlock() }
        let result = completed
        completed.removeAll()
        return result
    }

    func stop() throws -> [Chunk] {
        lock.lock()
        stopping = true
        lock.unlock()
        if helper.isRunning { helper.terminate() }
        guard readerFinished.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "SystemDictation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "System audio did not finish; recovery audio is preserved."])
        }
        return try takeCompleted()
    }

    var captureError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return readerError
    }

    private func readAudio() {
        defer { readerFinished.leave() }
        var pcm = Data()
        var firstOffset: Double?
        var bytesWritten = 0
        var index = 0
        do {
            while let data = try pipe.fileHandleForReading.read(upToCount: 32_000), !data.isEmpty {
                if firstOffset == nil {
                    firstOffset = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
                }
                pcm.append(data)
                while pcm.count >= chunkBytes {
                    let block = Data(pcm.prefix(chunkBytes))
                    pcm.removeFirst(chunkBytes)
                    try save(block, index: &index, offset: firstOffset! + Double(bytesWritten) / 32_000, final: false)
                    bytesWritten += block.count
                }
            }
            if !pcm.isEmpty {
                try save(pcm, index: &index, offset: (firstOffset ?? 0) + Double(bytesWritten) / 32_000, final: true)
            }
            lock.lock()
            if !stopping {
                readerError = NSError(domain: "SystemDictation", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "System audio capture ended unexpectedly; recovery audio is preserved."])
            }
            lock.unlock()
        } catch {
            // Keep an interrupted tail in recovery even if normal finalization failed.
            if !pcm.isEmpty { try? pcm.write(to: directory.appendingPathComponent("system-unfinished.pcm"), options: .atomic) }
            lock.lock()
            readerError = error
            lock.unlock()
        }
    }

    private func save(_ pcm: Data, index: inout Int, offset: Double, final: Bool) throws {
        index += 1
        let url = directory.appendingPathComponent(String(format: "system-%03d.wav", index))
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        wav.append(Data("RIFF".utf8)); append(UInt32(pcm.count + 36))
        wav.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        wav.append(Data("data".utf8)); append(UInt32(pcm.count)); wav.append(pcm)
        try wav.write(to: url, options: .atomic)
        lock.lock()
        completed.append(Chunk(url: url, offset: offset, final: final))
        lock.unlock()
    }
}
