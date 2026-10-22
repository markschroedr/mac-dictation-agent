import Foundation

/// xAI streaming contract: POST /tts, codec pcm, mono s16le at 24 kHz.
/// URLSession's data delegate delivers audio before the response completes.
final class XAISpeechStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let receivePCM: (Data) throws -> Void
    private let done = DispatchSemaphore(value: 0)
    private let failure = SynchronizedBox<Error?>(nil)
    // Delegate queue only. A network chunk may split a 16-bit sample.
    private var remainder = Data()
    private var receivedBytes = 0

    private init(receive: @escaping (Data) throws -> Void) { receivePCM = receive }

    static func synthesize(text: String, voice: String, language: String, apiKey: String,
                           receive: @escaping (Data) throws -> Void) throws {
        let delegate = XAISpeechStream(receive: receive)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/tts")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text, "voice_id": voice, "language": language,
            "output_format": ["codec": "pcm", "sample_rate": 24_000]
        ])
        session.dataTask(with: request).resume()
        guard delegate.done.wait(timeout: .now() + 3600) == .success else {
            throw ClipboardTTSError.requestFailed("xAI speech stream timed out")
        }
        if let error = delegate.failure.value() { throw error }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            failure.set(ClipboardTTSError.requestFailed("xAI stream failed HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        remainder.append(data)
        let count = remainder.count - remainder.count % 2
        guard count > 0 else { return }
        let pcm = Data(remainder.prefix(count))
        remainder.removeFirst(count)
        do {
            try receivePCM(pcm)
            receivedBytes += pcm.count
        } catch {
            failure.set(error)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if failure.value() == nil {
            if let error { failure.set(error) }
            else if !remainder.isEmpty || receivedBytes == 0 {
                failure.set(ClipboardTTSError.invalidResponse("xAI returned empty or incomplete PCM"))
            }
        }
        done.signal()
    }
}
