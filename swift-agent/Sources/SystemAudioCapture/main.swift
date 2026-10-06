import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let output = FileHandle.standardOutput
    private let errorOutput = FileHandle.standardError
    private let continuousPCM = CommandLine.arguments.contains("--continuous-pcm")
    private var firstTimestamp: Double?
    private var emittedFrames = 0

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return }

        let bufferCount = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            ? Int(description.mChannelsPerFrame)
            : 1
        let listSize = MemoryLayout<AudioBufferList>.size
            + max(0, bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        let audioList = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioList,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(audioList)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let channels = max(1, Int(description.mChannelsPerFrame))
        var pcm = Data(capacity: frameCount * 2)
        for frame in 0..<frameCount {
            var sample: Float = 0
            for channel in 0..<channels {
                let bufferIndex = buffers.count == 1 ? 0 : channel
                guard bufferIndex < buffers.count, let data = buffers[bufferIndex].mData else { continue }
                let sampleIndex = buffers.count == 1 ? frame * channels + channel : frame
                if description.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                    sample += data.assumingMemoryBound(to: Float.self)[sampleIndex]
                } else {
                    let value = data.assumingMemoryBound(to: Int16.self)[sampleIndex]
                    sample += Float(value) / Float(Int16.max)
                }
            }
            sample /= Float(channels)
            var value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        do {
            if continuousPCM {
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                guard timestamp.isNumeric else { throw NSError(domain: "SystemAudioCapture", code: 2) }
                let seconds = CMTimeGetSeconds(timestamp)
                if firstTimestamp == nil { firstTimestamp = seconds }
                let expectedFrame = max(0, Int(((seconds - firstTimestamp!) * 16_000).rounded()))
                var missingFrames = max(0, expectedFrame - emittedFrames)
                while missingFrames > 0 {
                    let count = min(missingFrames, 16_000)
                    try output.write(contentsOf: Data(count: count * 2))
                    emittedFrames += count
                    missingFrames -= count
                }
                emittedFrames += frameCount
            }
            try output.write(contentsOf: pcm)
        } catch {
            exit(1)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        try? errorOutput.write(contentsOf: Data("system audio capture stopped: \(error)\n".utf8))
        exit(1)
    }
}

@main
struct SystemAudioCapture {
    static func main() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                throw NSError(domain: "SystemAudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display available"])
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 1
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 16_000
            configuration.channelCount = 1

            let receiver = SystemAudioOutput()
            let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
            try stream.addStreamOutput(
                receiver,
                type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "com.markschroedr.mac-dictation.system-audio")
            )
            try await stream.startCapture()
            try? FileHandle.standardError.write(contentsOf: Data("system audio capture ready\n".utf8))
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        } catch {
            fputs("system audio capture failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
