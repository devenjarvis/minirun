import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The programs minirun has running (xcodebuild, swift test, commands…), written to a file as
/// they start and stop. If minirun dies, they keep running as orphans: a hung `xcodebuild test`
/// goes on holding its simulator and checkout with nothing left to stop it. On the next start,
/// `reapOrphans` stops whatever the file still lists.
///
/// Mac apps minirun launches are spawned directly (MiniRunMac), not through `Shell` or
/// `BackgroundProcess`, so they're never listed here: they're meant to outlive a restart, and
/// `MacAppStore` reconciles them by pid and executable.
public final class ChildProcessLedger: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var pid: Int32
        /// Names the program may show in `ps` (e.g. "xcrun" and "xcodebuild"), so a pid that's
        /// been reused by something else is left alone.
        public var names: [String]
        public var startedAt: Date
    }

    public static let shared = ChildProcessLedger()

    public static var defaultURL: URL {
        MiniRunConfig.configURL.deletingLastPathComponent().appendingPathComponent("processes.json")
    }

    private let lock = NSLock()
    private var url: URL?
    private var entries: [Int32: Entry] = [:]

    init() {}

    /// Starts writing the ledger to `url`. Until this is called (e.g. in one-off CLI commands)
    /// nothing is recorded.
    public func record(to url: URL) {
        lock.lock()
        self.url = url
        lock.unlock()
        save()
    }

    func add(_ pid: Int32, names: [String]) {
        lock.lock()
        guard url != nil else { lock.unlock(); return }
        entries[pid] = Entry(pid: pid, names: names, startedAt: Date())
        lock.unlock()
        save()
    }

    func remove(_ pid: Int32) {
        lock.lock()
        guard url != nil, entries.removeValue(forKey: pid) != nil else { lock.unlock(); return }
        lock.unlock()
        save()
    }

    private func save() {
        lock.lock()
        defer { lock.unlock() }
        guard let url else { return }
        let list = entries.values.sorted { $0.pid < $1.pid }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The names a program started as `executable arguments…` can show in `ps`: its own, and for
    /// launchers that hand over to another program (env, xcrun), that program's.
    static func names(executable: String, arguments: [String]) -> [String] {
        var names = [(executable as NSString).lastPathComponent]
        var rest = arguments[...]
        if ["env", "xcrun"].contains(names[0]), let index = rest.firstIndex(where: { !$0.hasPrefix("-") }) {
            names.append((rest[index] as NSString).lastPathComponent)
            rest = rest[(index + 1)...]
        }
        // `swift test` hands over to swift-test (likewise build, run, package).
        if names.last == "swift", let sub = rest.first(where: { !$0.hasPrefix("-") }) { names.append("swift-" + sub) }
        return names
    }

    /// Stops the programs a previous run of minirun left behind, and their children. Only ones
    /// that were orphaned (their parent is now launchd) and still go by the recorded name are
    /// touched. Returns a line per program stopped.
    public static func reapOrphans(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        try? FileManager.default.removeItem(at: url)
        var stopped: [String] = []
        for entry in entries {
            guard let info = processInfo(entry.pid), info.ppid == 1,
                  entry.names.contains((info.command as NSString).lastPathComponent) else { continue }
            let tree = [entry.pid] + descendants(of: entry.pid)
            for pid in tree.reversed() { kill(pid, SIGTERM) }
            stopped.append("\(info.command) (pid \(entry.pid), started \(entry.startedAt.formatted(date: .abbreviated, time: .standard)))")
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                for pid in tree where processInfo(pid) != nil { kill(pid, SIGKILL) }
            }
        }
        return stopped
    }

    private static func processInfo(_ pid: Int32) -> (ppid: Int32, command: String)? {
        guard let out = runSync("/bin/ps", ["-o", "ppid=", "-o", "comm=", "-p", String(pid)]) else { return nil }
        let line = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = line.firstIndex(of: " "), let ppid = Int32(line[..<space]) else { return nil }
        return (ppid, line[space...].trimmingCharacters(in: .whitespaces))
    }

    private static func descendants(of pid: Int32) -> [Int32] {
        guard let out = runSync("/usr/bin/pgrep", ["-P", String(pid)]) else { return [] }
        let children = out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        return children.flatMap { [$0] + descendants(of: $0) }
    }

    private static func runSync(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
