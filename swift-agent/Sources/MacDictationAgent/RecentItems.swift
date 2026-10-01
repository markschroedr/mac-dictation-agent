import AppKit
import Foundation

struct TranscriptRecord: Sendable {
    let transcriptURL: URL
    let sourceURL: URL
    let modifiedAt: Date
    let preview: String
}

enum TranscriptCollection: Sendable {
    case dictations, canonical, quick, sources, manual

    var locations: [(URL, TranscriptLayout)] {
        switch self {
        case .dictations: return [(dictationRecoveryDir, .sessions), (dictationTranscriptsDir, .flat)]
        case .canonical: return [(permanentTranscriberTranscriptRoot.appendingPathComponent("relaxed"), .dated)]
        case .quick: return [(permanentTranscriberTranscriptRoot.appendingPathComponent("quick"), .dated)]
        case .sources: return [(permanentTranscriberTranscriptRoot.appendingPathComponent("participants"), .flat)]
        case .manual: return [(manualTranscriptsDir, .flat)]
        }
    }
}

enum TranscriptLayout { case sessions, flat, dated }

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
            return TranscriptFile(url: entry, source: entry,
                                  key: String(entry.path.dropFirst(root.path.count + 1)))
        }
        return nil
    }
}

func transcriptPage(collection: TranscriptCollection, before: String?) -> TranscriptPage {
    var iterators = collection.locations.map { TranscriptFiles(root: $0.0, layout: $0.1) }
    var heads = iterators.indices.map { iterators[$0].next() }
    var files: [TranscriptFile] = []
    while files.count < 6 {
        guard let index = heads.indices.filter({ heads[$0] != nil })
            .max(by: { heads[$0]!.key < heads[$1]!.key }) else { break }
        let file = heads[index]!
        heads[index] = iterators[index].next()
        if let before, file.key >= before { continue }
        files.append(file)
    }
    let records = files.prefix(5).compactMap { file -> TranscriptRecord? in
        let preview = transcriptPreview(file.url)
        guard !preview.isEmpty else { return nil }
        let modifiedAt = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return TranscriptRecord(transcriptURL: file.url, sourceURL: file.source,
                                modifiedAt: modifiedAt, preview: preview)
    }
    return TranscriptPage(records: records, nextBefore: files.count > 5 ? files[4].key : nil)
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
