import AppKit
import Foundation

struct TranscriptRecord: Sendable {
    let transcriptURL: URL
    let sourceURL: URL
    let modifiedAt: Date
    let preview: String
}

enum TranscriptCollection: Sendable {
    case dictations, continuous, manual

    var locations: [(URL, TranscriptLayout)] {
        switch self {
        case .dictations: return [(dictationRecoveryDir, .sessions), (dictationTranscriptsDir, .flat)]
        case .continuous: return [
            (permanentTranscriberTranscriptRoot.appendingPathComponent("relaxed"), .dated),
            (permanentTranscriberTranscriptRoot.appendingPathComponent("quick"), .dated),
            (permanentTranscriberTranscriptRoot.appendingPathComponent("participants"), .sessionsByID),
        ]
        case .manual: return [(manualTranscriptsDir, .flat)]
        }
    }
}

enum TranscriptLayout { case sessions, flat, dated, sessionsByID }

@MainActor
final class TranscriptPageMenu: NSMenu {
    let collection: TranscriptCollection
    let before: String?
    var refreshInFlight = false
    var refreshedAt: Date?

    init(collection: TranscriptCollection, before: String? = nil) {
        self.collection = collection
        self.before = before
        super.init(title: "")
        let placeholder = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        addItem(placeholder)
    }

    required init(coder: NSCoder) { fatalError("Transcript menus are created in code") }
}

struct TranscriptPage: Sendable {
    let records: [TranscriptRecord]
    let nextBefore: String?
}

private struct TranscriptFile {
    let url: URL
    let source: URL
    let key: String
}

private struct TranscriptFiles: IteratorProtocol {
    let root: URL
    let layout: TranscriptLayout
    var stack: [URL]

    init(root: URL, layout: TranscriptLayout) {
        self.root = root
        self.layout = layout
        self.stack = Self.entries(root)
    }

    static func entries(_ directory: URL) -> [URL] {
        // Filenames and date folders are generated in chronological order.
        // Read only shallow names; never walk recovery audio/chunk folders.
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []).map { ($0.lastPathComponent, $0) }
            .sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    mutating func next() -> TranscriptFile? {
        while let entry = stack.popLast() {
            if layout == .sessions {
                let transcript = entry.appendingPathComponent("transcript.txt")
                guard FileManager.default.fileExists(atPath: transcript.path) else { continue }
                return TranscriptFile(url: transcript, source: entry, key: entry.lastPathComponent)
            }
            if layout == .dated,
               (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                stack.append(contentsOf: Self.entries(entry))
                continue
            }
            guard ["md", "txt"].contains(entry.pathExtension.lowercased()) else { continue }
            let relative = String(entry.path.dropFirst(root.path.count + 1))
            let key: String
            switch layout {
            case .dated:
                // Persisted hourly format: YYYY/MM/DD/HH.md. Canonical and quick share one key.
                let parts = (relative as NSString).deletingPathExtension.split(separator: "/")
                guard parts.count == 4 else { continue }
                key = parts.joined() + "0000"
            case .sessionsByID:
                // Persisted recording format: YYYYMMDDTHHMMSSZ-<id>.txt. Keep each session distinct.
                let name = entry.deletingPathExtension().lastPathComponent
                key = String(name.prefix(8)) + String(name.dropFirst(9).prefix(6)) + "-" + name
            case .flat, .sessions:
                key = relative
            }
            return TranscriptFile(url: entry, source: entry, key: key)
        }
        return nil
    }
}

func transcriptPage(collection: TranscriptCollection, before: String?) -> TranscriptPage {
    var iterators = collection.locations.map { TranscriptFiles(root: $0.0, layout: $0.1) }
    var heads = iterators.indices.map { iterators[$0].next() }
    var records: [(String, TranscriptRecord)] = []
    while records.count < 6 {
        guard let key = heads.compactMap({ $0?.key }).max() else { break }
        // Prefer canonical, then quick, for the same legacy hour. Never hide a nonempty quick fallback.
        let candidates = heads.indices.filter { heads[$0]?.key == key }.map { index -> TranscriptFile in
            let file = heads[index]!
            heads[index] = iterators[index].next()
            return file
        }
        if let before, key >= before { continue }
        for file in candidates {
            let preview = transcriptPreview(file.url)
            guard !preview.isEmpty else { continue }
            let modifiedAt = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            records.append((key, TranscriptRecord(transcriptURL: file.url, sourceURL: file.source,
                                                  modifiedAt: modifiedAt, preview: preview)))
            break
        }
    }
    return TranscriptPage(records: records.prefix(5).map { $0.1 }, nextBefore: records.count > 5 ? records[4].0 : nil)
}

func transcriptPreview(_ url: URL, maxBytes: Int = 4096, maxWords: Int = 14) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
    try? handle.close()
    let text = sanitize(String(data: data, encoding: .utf8) ?? "")
    guard !text.isEmpty else { return "" }
    let words = text.split(separator: " ").prefix(maxWords).joined(separator: " ")
    return words.count < text.count ? "\(words)..." : words
}

struct RecentAudioRecord: Sendable {
    let name: String
    let url: URL
}

func recentAudioRecords(in directory: URL) -> [RecentAudioRecord] {
    let directories = TranscriptFiles.entries(directory).reversed().lazy.filter {
        (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }.prefix(5)
    return directories.compactMap { directory in
        let playlist = directory.appendingPathComponent("playlist.m3u")
        let audioFiles = TranscriptFiles.entries(directory).filter {
            ["wav", "mp3", "m4a"].contains($0.pathExtension.lowercased())
        }
        let audio = audioFiles.first { $0.deletingPathExtension().lastPathComponent == "audio" }
            ?? audioFiles.first
        let url = FileManager.default.fileExists(atPath: playlist.path) ? playlist : audio
        return url.map { RecentAudioRecord(name: directory.lastPathComponent, url: $0) }
    }
}
