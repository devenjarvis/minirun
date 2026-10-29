import Foundation
import MiniRunKit

/// Thin wrapper over `xcrun simctl` for lifecycle and app management (stable, documented commands).
enum Simctl {
    typealias Device = XcodeParsing.SimDevice

    static func run(_ args: [String], timeout: TimeInterval = 120, what: String? = nil) async throws -> ShellResult {
        try await Shell.check("/usr/bin/xcrun", ["simctl"] + args, timeout: timeout, what: what ?? "simctl \(args.first ?? "")")
    }

    static func devices() async throws -> [Device] {
        let result = try await run(["list", "devices", "--json"], timeout: 60)
        return try XcodeParsing.parseDevices(Data(result.stdout.utf8))
    }

    /// Creates a new simulator of the same model and runtime as `like`. Returns its UDID.
    static func create(name: String, like: Device) async throws -> String {
        guard let type = like.deviceType else { throw ToolError("Can't tell what kind of device \(like.name) is, so a copy can't be created. Pass device with a simulator that isn't in use.") }
        let result = try await run(["create", name, type, like.runtime], timeout: 120, what: "Creating \(name)")
        let udid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else { throw ToolError("simctl create didn't return a UDID.") }
        return udid
    }

    static func boot(_ udid: String) async throws {
        let result = try await Shell.run("/usr/bin/xcrun", ["simctl", "boot", udid], timeout: 120)
        // "Unable to boot device in current state: Booted" is fine.
        if !result.succeeded && !result.stderr.contains("current state: Booted") {
            throw ToolError("Booting \(udid) failed:\n\(result.tail(2000))")
        }
        // A new simulator's first boot runs a data migration that can take several minutes.
        _ = try await run(["bootstatus", udid, "-b"], timeout: 900, what: "Waiting for the simulator to finish booting")
        // Simulator.app isn't required for automation, but opening it makes demos visible on the Mac.
        _ = try? await Shell.run("/usr/bin/open", ["-g", "-a", "Simulator", "--args", "-CurrentDeviceUDID", udid], timeout: 20)
    }

    static func shutdown(_ udid: String) async throws {
        let result = try await Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", udid], timeout: 120)
        if !result.succeeded && !result.stderr.contains("current state: Shutdown") {
            throw ToolError("Shutting down \(udid) failed:\n\(result.tail(2000))")
        }
    }

    static func install(_ udid: String, appPath: String) async throws {
        _ = try await run(["install", udid, appPath], timeout: 300, what: "Installing \(URL(fileURLWithPath: appPath).lastPathComponent)")
    }

    static func uninstall(_ udid: String, bundleID: String) async throws {
        _ = try await run(["uninstall", udid, bundleID], timeout: 120)
    }

    /// Launches an app and returns its pid.
    static func launch(_ udid: String, bundleID: String, arguments: [String] = [], environment: [String: String] = [:], terminateExisting: Bool = true) async throws -> String {
        var args = ["launch"]
        if terminateExisting { args.append("--terminate-running-process") }
        args += [udid, bundleID] + arguments
        // simctl forwards SIMCTL_CHILD_* variables into the launched app's environment.
        let env = Dictionary(uniqueKeysWithValues: environment.map { ("SIMCTL_CHILD_" + $0.key, $0.value) })
        let result = try await Shell.run("/usr/bin/xcrun", ["simctl"] + args, environment: env, timeout: 120)
        guard result.succeeded else { throw ToolError("Launching \(bundleID) failed:\n\(result.tail(2000))") }
        // Output: "com.example.app: 12345"
        return result.stdout.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    static func terminate(_ udid: String, bundleID: String) async throws {
        let result = try await Shell.run("/usr/bin/xcrun", ["simctl", "terminate", udid, bundleID], timeout: 60)
        if !result.succeeded && !result.stderr.contains("found nothing to terminate") {
            throw ToolError("Terminating \(bundleID) failed:\n\(result.tail(2000))")
        }
    }

    static func openURL(_ udid: String, url: String) async throws {
        _ = try await run(["openurl", udid, url], timeout: 60)
    }

    static func setPasteboard(_ udid: String, text: String) async throws {
        let result = try await Shell.run("/usr/bin/xcrun", ["simctl", "pbcopy", udid], timeout: 30, stdin: Data(text.utf8))
        guard result.succeeded else { throw ToolError("Setting the pasteboard failed:\n\(result.tail(1000))") }
    }

    static func setAppearance(_ udid: String, dark: Bool) async throws {
        _ = try await run(["ui", udid, "appearance", dark ? "dark" : "light"], timeout: 30)
    }

    static func setLocation(_ udid: String, latitude: Double, longitude: Double) async throws {
        _ = try await run(["location", udid, "set", "\(latitude),\(longitude)"], timeout: 30)
    }

    static func privacy(_ udid: String, action: String, service: String, bundleID: String) async throws {
        _ = try await run(["privacy", udid, action, service, bundleID], timeout: 30)
    }

    static func addMedia(_ udid: String, paths: [String]) async throws {
        _ = try await run(["addmedia", udid] + paths, timeout: 120)
    }

    /// Clean status bar (9:41, full battery) for demos and screenshots.
    static func overrideStatusBar(_ udid: String, clear: Bool) async throws {
        if clear {
            _ = try await run(["status_bar", udid, "clear"], timeout: 30)
        } else {
            _ = try await run([
                "status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active",
                "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "charged", "--batteryLevel", "100",
            ], timeout: 30)
        }
    }

    /// Recent unified log lines from the simulator, optionally filtered to one process.
    static func logs(_ udid: String, process: String?, seconds: Int, filter: String?) async throws -> String {
        var predicate: [String] = []
        if let process, !process.isEmpty { predicate.append("process == \"\(process.replacingOccurrences(of: "\"", with: ""))\"") }
        if let filter, !filter.isEmpty { predicate.append("eventMessage CONTAINS[c] \"\(filter.replacingOccurrences(of: "\"", with: ""))\"") }
        var args = ["spawn", udid, "log", "show", "--style", "compact", "--last", "\(max(1, seconds))s"]
        if !predicate.isEmpty { args += ["--predicate", predicate.joined(separator: " AND ")] }
        let result = try await run(args, timeout: 90, what: "Reading simulator logs")
        let lines = result.stdout.split(separator: "\n").filter { !$0.hasPrefix("Timestamp") && !$0.hasPrefix("Filtering the log data") }
        return lines.suffix(300).joined(separator: "\n")
    }

    /// The executable name of an installed app (used to filter logs).
    static func executableName(_ udid: String, bundleID: String) async -> String? {
        guard let result = try? await Shell.run("/usr/bin/xcrun", ["simctl", "get_app_container", udid, bundleID, "app"], timeout: 30),
              result.succeeded else { return nil }
        let appPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = NSDictionary(contentsOfFile: appPath + "/Info.plist")
        return info?["CFBundleExecutable"] as? String
    }
}
