import AppKit
import CryptoKit
import MiniRunKit

/// Installs a release from GitHub over /Applications/minirun.app: download the zip, check its
/// SHA-256, unzip it, check it's the minirun app at the right version and that its helper runs,
/// swap the bundles (keeping the old one to roll back to), restart `minirun serve` from the new
/// helper, and relaunch. Releases are ad-hoc signed, so the checksum and the checks on the bundle
/// are what stands between GitHub and this Mac.
enum AppUpdater {
    static var workDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/minirun/update")
    }

    /// Everything up to the swap. Returns the unzipped, checked app.
    static func prepare(_ release: UpdateCheck.Release, transport: HTTPTransport = URLSessionTransport()) async throws -> URL {
        guard let asset = release.asset, let url = URL(string: asset.downloadURL) else {
            throw ToolError("minirun \(release.version) has no app download.")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: workDirectory)
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let expected = try await expectedChecksum(asset, transport: transport)
        let zip = workDirectory.appendingPathComponent(asset.name)
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        let (status, data) = try await transport.send(request)
        guard status == 200 else { throw ToolError("Downloading \(asset.name) failed (HTTP \(status)).") }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw ToolError("\(asset.name) doesn't match its checksum (expected \(expected.prefix(12))…, got \(actual.prefix(12))…). Not installing it.")
        }
        try data.write(to: zip)

        let unzipped = workDirectory.appendingPathComponent("unzipped")
        try await Shell.check("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path], timeout: 300, what: "Unzipping the update")
        let app = unzipped.appendingPathComponent("minirun.app")
        // A download through URLSession isn't quarantined, but make sure: a quarantined helper
        // would be stopped by Gatekeeper when launchd starts it.
        _ = try? await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path], timeout: 60)

        let info = (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]) ?? [:]
        let helper = app.appendingPathComponent("Contents/Helpers/minirun").path
        if let problem = Updater.problem(infoPlist: info, expectedVersion: release.version, hasHelper: fm.isExecutableFile(atPath: helper)) {
            throw ToolError(problem)
        }
        try await Shell.check("/usr/bin/codesign", ["--verify", "--deep", app.path], timeout: 120, what: "Checking the update's signature")
        try await checkHelper(helper, version: release.version)
        return app
    }

    /// The new bundle's helper must start (it loads the bundled frameworks) and report the version.
    static func checkHelper(_ helper: String, version: String) async throws {
        let result = try await Shell.run(helper, ["version"], timeout: 60)
        let reported = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, reported == version else {
            throw ToolError("The new minirun didn't start (\(reported.isEmpty ? result.tail(300) : "it says it's \(reported)")).")
        }
    }

    static func expectedChecksum(_ asset: UpdateCheck.Asset, transport: HTTPTransport) async throws -> String {
        if let digest = asset.sha256 { return digest }
        guard let link = asset.checksumURL, let url = URL(string: link) else {
            throw ToolError("\(asset.name) has no checksum to check it against. Not installing it.")
        }
        let (status, body) = try await transport.send(URLRequest(url: url))
        guard status == 200, let hex = Updater.checksum(fromShasum: String(decoding: body, as: UTF8.self)) else {
            throw ToolError("Couldn't read \(asset.name).sha256 (HTTP \(status)).")
        }
        return hex
    }

    /// Puts `newApp` where this app is, restarts the daemon from it, and relaunches. On failure
    /// the old app goes back and the daemon keeps running from it.
    @MainActor
    static func install(_ newApp: URL, version: String) async throws {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let backup = workDirectory.appendingPathComponent("previous.app")
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: current, to: backup)
        do {
            try fm.moveItem(at: newApp, to: current)
            try await checkHelper(current.appendingPathComponent("Contents/Helpers/minirun").path, version: version)
        } catch {
            try? fm.removeItem(at: current)
            try? fm.moveItem(at: backup, to: current)
            throw ToolError("The update didn't install, so minirun stays as it was: \(error.localizedDescription)")
        }
        // The plist already points at /Applications/minirun.app/Contents/Helpers/minirun.
        try? await LaunchAgent.kickstart(restart: true)
        relaunch(current)
    }

    /// Opens the new app once this one has quit.
    @MainActor
    static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.5; done; open \(CommandLineTool.shellQuoted(app.path))"]
        try? process.run()
        NSApp.terminate(nil)
    }
}
