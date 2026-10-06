import AppKit
import CryptoKit

// This public key is the update trust root. Never replace it during a normal release.
private let updatePublicKey = "GDT+YFo+JuJ/AZwB3LbH7PAnXoiXm8REEegh76yXZFg="

struct AppUpdate: Sendable {
    let version: String
    let archive: URL
    let signature: URL
}

enum UpdateError: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let text) = self { return text }; return nil }
}

enum UpdateInstaller {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    static func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.failed("Download failed: \(url.lastPathComponent)")
        }
        return data
    }
    static func latest() async throws -> AppUpdate? {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        let feed = ProcessInfo.processInfo.environment["MAC_DICTATION_UPDATE_FEED_URL"] ?? "https://api.github.com/repos/markschroedr/mac-dictation-agent/releases/latest"
        guard let url = URL(string: feed) else { throw UpdateError.failed("Invalid update feed URL") }
        let release = try JSONDecoder().decode(Release.self, from: await fetch(url))
        let candidate = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard candidate.range(of: #"^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil,
              !release.draft, !release.prerelease else { throw UpdateError.failed("Invalid latest release") }
        guard candidate.compare(version, options: .numeric) == .orderedDescending else { return nil }
        let name = "Mac-Dictation-Agent-\(candidate)-macOS-arm64.zip"
        guard let archive = release.assets.first(where: { $0.name == name }),
              let signature = release.assets.first(where: { $0.name == name + ".sig" }) else {
            throw UpdateError.failed("This release has no signed update archive. Use the release page for manual installation.")
        }
        return AppUpdate(version: candidate, archive: archive.browser_download_url, signature: signature.browser_download_url)
    }
    static func command(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, log: URL) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            try output.seekToEnd()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw UpdateError.failed("Update command failed (\(process.terminationStatus)). Details: \(log.path)")
            }
        }.value
    }
    static func prepare(_ update: AppUpdate) async throws -> (runtime: URL, workspace: URL, log: URL) {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("mac-dictation-update-\(UUID().uuidString)")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let log = workspace.appendingPathComponent("update.log")
        let archive = workspace.appendingPathComponent("release.zip")
        let bytes = try await fetch(update.archive)
        let signature = try await fetch(update.signature)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: updatePublicKey)!)
        guard key.isValidSignature(signature, for: bytes) else { throw UpdateError.failed("Update signature is invalid. Nothing was installed.") }
        // URLSession + Data.write do not add com.apple.quarantine. No browser downloader is used.
        try bytes.write(to: archive)
        try await command("/usr/bin/ditto", ["-x", "-k", archive.path, workspace.appendingPathComponent("package").path], log: log)
        let package = workspace.appendingPathComponent("package/Mac-Dictation-Agent-\(update.version)-macOS-arm64")
        let app = package.appendingPathComponent("MacDictationAgent.app")
        let info = try NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"), error: ())
        guard info["CFBundleShortVersionString"] as? String == update.version else { throw UpdateError.failed("Archive version does not match the release") }
        try await command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], log: log)
        let plan = try NSDictionary(contentsOf: agentRoot.appendingPathComponent("installation.plist"), error: ())
        guard let target = plan["TargetApp"] as? String, let plist = plan["TargetPlist"] as? String,
              let data = plan["DataRoot"] as? String else { throw UpdateError.failed("No managed installation. Run the release installer first.") }
        var env = ProcessInfo.processInfo.environment
        env["MAC_DICTATION_APP_DIR"] = target
        env["MAC_DICTATION_PLIST"] = plist
        env["MAC_DICTATION_DATA_ROOT"] = data
        let runtime = URL(fileURLWithPath: data).appendingPathComponent("runtimes/\(UUID().uuidString)")
        env["MAC_DICTATION_INSTALL_ROOT"] = runtime.path
        env["MAC_DICTATION_PREBUILT_APP"] = app.path
        env["MAC_DICTATION_ACTIVATE"] = "0"
        env["MAC_DICTATION_WARM_MODELS"] = "0"
        env["MAC_DICTATION_INSTALL_EXTRAS"] = fm.isExecutableFile(atPath: permanentTranscriberExecutable.path) ? "1" : "0"
        try await command("/bin/bash", [package.appendingPathComponent("runtime/scripts/install_launch_agent.sh").path], environment: env, log: log)
        return (runtime, workspace, log)
    }
    @discardableResult
    static func activate(runtime: URL, workspace: URL, log: URL) async throws -> String {
        // A separate launchd job survives bootout of the app's LaunchAgent and process coalition.
        let helper = workspace.appendingPathComponent("activate_update.sh")
        try FileManager.default.copyItem(at: agentRoot.appendingPathComponent("scripts/activate_update.sh"), to: helper)
        let label = "com.markschroedr.mac-dictation.update-\(UUID().uuidString)"
        try await command("/bin/launchctl", ["submit", "-l", label, "-o", log.path, "-e", log.path,
                                            "--", "/bin/bash", helper.path, runtime.path, log.path, label], log: log)
        return label
    }
}

// The E2E entry point uses the production download/prepare/handoff path without TCC prompts.
// It cannot run against a normal installation or launch label.
@MainActor
func runUpdateE2EIfRequested() -> Bool {
    let env = ProcessInfo.processInfo.environment
    guard env["MAC_DICTATION_UPDATE_E2E"] == "1" else { return false }
    guard env["MAC_DICTATION_LAUNCH_AGENT_LABEL"]?.hasSuffix(".update-test") == true,
          dataRoot.path.hasPrefix(FileManager.default.temporaryDirectory.path + "/") else {
        fputs("Update E2E requires an isolated temporary root and test label\n", stderr)
        exit(2)
    }
    if CommandLine.arguments.contains("--update-e2e") {
        Task {
            do {
                guard let update = try await UpdateInstaller.latest() else { throw UpdateError.failed("No newer release") }
                print("Detected \(update.version)")
                let prepared = try await UpdateInstaller.prepare(update)
                print("Verified and prepared: \(prepared.runtime.path)")
                let job = try await UpdateInstaller.activate(runtime: prepared.runtime, workspace: prepared.workspace, log: prepared.log)
                print("Detached activation submitted: \(prepared.log.path)")
                print("Detached activation job: \(job)")
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
    } else {
        print("Isolated update app running: \(UpdateInstaller.version)")
    }
    NSApplication.shared.run()
    return true
}

@MainActor
final class AppUpdater: NSObject {
    let checkItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkManually), keyEquivalent: "")
    let installItem = NSMenuItem(title: "", action: #selector(install), keyEquivalent: "")
    var reserveRecording: () -> Bool = { false }
    var releaseRecording: () -> Void = {}
    var continuousBusy: () -> Bool = { true }
    private(set) var installing = false
    private var checking = false
    private var available: AppUpdate?
    private var timer: Timer?
    override init() {
        super.init()
        checkItem.target = self
        installItem.target = self
        installItem.isHidden = true
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDaily() }
        }
        Task { checkDaily() }
    }
    private func checkDaily() {
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        if Date().timeIntervalSince1970 - last >= 86400 { check(manual: false) }
    }
    @objc private func checkManually() { check(manual: true) }
    private func check(manual: Bool) {
        guard !checking, !installing else { return }
        checking = true
        checkItem.title = "Checking for Updates…"
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        Task {
            defer { checking = false; checkItem.title = "Check for Updates…" }
            do {
                available = try await UpdateInstaller.latest()
                installItem.isHidden = available == nil
                installItem.title = available.map { "Update to \($0.version)…" } ?? ""
                if manual { message(available == nil ? "You're up to date" : "Update available", available.map { "Select Update to \($0.version)… to install and restart." } ?? "Version \(UpdateInstaller.version)") }
            } catch { if manual { message("Update check failed", error.localizedDescription) } }
        }
    }
    @objc private func install() {
        guard !installing, let update = available else { return }
        guard !continuousBusy(), reserveRecording() else {
            message("Update postponed", "Finish dictation and stop continuous recording before installing an update.")
            return
        }
        installing = true
        installItem.title = "Preparing Update…"
        Task {
            do {
                let prepared = try await UpdateInstaller.prepare(update)
                guard !continuousBusy() else { throw UpdateError.failed("Continuous recording is active. Stop it and try again.") }
                try await UpdateInstaller.activate(runtime: prepared.runtime, workspace: prepared.workspace, log: prepared.log)
                installItem.title = "Restarting for Update…"
                // Do not time out and enable recording while activation could still stop us.
                let result = URL(fileURLWithPath: prepared.log.path + ".result")
                while !FileManager.default.fileExists(atPath: result.path) {
                    try await Task.sleep(for: .seconds(1))
                }
                throw UpdateError.failed("Update finished without replacing this process. Details: \(prepared.log.path)")
            } catch {
                installing = false
                releaseRecording()
                installItem.title = "Update to \(update.version)…"
                message("Update failed", error.localizedDescription)
            }
        }
    }
    private func message(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
