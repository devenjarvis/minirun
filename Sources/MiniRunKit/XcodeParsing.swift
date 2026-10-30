import Foundation

/// Pure parsing helpers for `simctl` and `xcodebuild` output. Kept platform-neutral so they can
/// be unit tested on Linux CI.
public enum XcodeParsing {
    // MARK: simctl

    public struct SimDevice: Equatable, Sendable {
        public let udid: String
        public let name: String
        public let state: String
        public let runtime: String
        public let isAvailable: Bool
        /// e.g. "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"; needed to create a copy.
        public let deviceType: String?
        /// When it last booted, if it ever has.
        public let lastBootedAt: Date?

        public init(udid: String, name: String, state: String, runtime: String, isAvailable: Bool, deviceType: String? = nil, lastBootedAt: Date? = nil) {
            self.udid = udid
            self.name = name
            self.state = state
            self.runtime = runtime
            self.isAvailable = isAvailable
            self.deviceType = deviceType
            self.lastBootedAt = lastBootedAt
        }

        public var isBooted: Bool { state == "Booted" }

        /// The same simulator, marked booted (after booting it).
        public var booted: SimDevice {
            SimDevice(udid: udid, name: name, state: "Booted", runtime: runtime, isAvailable: isAvailable, deviceType: deviceType, lastBootedAt: lastBootedAt)
        }

        /// "com.apple.CoreSimulator.SimRuntime.iOS-26-0" -> "iOS 26.0"
        public var runtimeName: String {
            let last = runtime.split(separator: ".").last.map(String.init) ?? runtime
            let parts = last.split(separator: "-")
            guard let platform = parts.first else { return last }
            return parts.count > 1 ? "\(platform) \(parts.dropFirst().joined(separator: "."))" : String(platform)
        }

        public var json: JSONValue {
            ["udid": .string(udid), "name": .string(name), "state": .string(state), "runtime": .string(runtimeName)]
        }
    }

    /// Parses `xcrun simctl list devices --json`.
    public static func parseDevices(_ json: Data) throws -> [SimDevice] {
        guard let root = try JSONValue.parse(json)["devices"]?.objectValue else { return [] }
        var devices: [SimDevice] = []
        for (runtime, list) in root {
            for entry in list.arrayValue ?? [] {
                guard let udid = entry["udid"]?.stringValue, let name = entry["name"]?.stringValue else { continue }
                devices.append(SimDevice(
                    udid: udid,
                    name: name,
                    state: entry["state"]?.stringValue ?? "Unknown",
                    runtime: runtime,
                    isAvailable: entry["isAvailable"]?.boolValue ?? true,
                    deviceType: entry["deviceTypeIdentifier"]?.stringValue,
                    lastBootedAt: entry["lastBootedAt"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) }
                ))
            }
        }
        // Booted first, then newest runtime, then name.
        return devices.sorted { a, b in
            if a.isBooted != b.isBooted { return a.isBooted }
            if a.runtime != b.runtime { return a.runtime.compare(b.runtime, options: .numeric) == .orderedDescending }
            return a.name < b.name
        }
    }

    /// Picks a device for a query: a UDID, an exact name, "booted", or nil (booted, else newest iPhone).
    public static func pickDevice(_ devices: [SimDevice], query: String?, preferredName: String? = nil) -> SimDevice? {
        let available = devices.filter(\.isAvailable)
        if let query, !query.isEmpty, query.lowercased() != "booted" {
            if let match = available.first(where: { $0.udid.caseInsensitiveCompare(query) == .orderedSame }) { return match }
            let named = available.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
            return named.first(where: \.isBooted) ?? named.first
        }
        if let booted = available.first(where: \.isBooted) { return booted }
        if query?.lowercased() == "booted" { return nil }
        if let preferredName, let preferred = available.first(where: { $0.name == preferredName && $0.runtime.contains("iOS") }) {
            return preferred
        }
        return defaultiPhones(available).first ?? available.first(where: { $0.runtime.contains("iOS") })
    }

    /// The iPhones to use when nobody named one, best first: the newest generation, its Pro first.
    /// Leaves out the SE, and the Duo, a foldable whose app can be on either of its two screens.
    public static func defaultiPhones(_ devices: [SimDevice]) -> [SimDevice] {
        let phones = devices.enumerated().filter { _, device in
            device.runtime.contains("iOS") && device.name.hasPrefix("iPhone")
                && !device.name.contains("SE") && !device.name.contains("Duo")
        }
        // Ties keep the given order (booted, then newest runtime).
        return phones.sorted { a, b in
            let rankA = modelRank(a.element.name), rankB = modelRank(b.element.name)
            return rankA != rankB ? rankA > rankB : a.offset < b.offset
        }.map(\.element)
    }

    /// Generation number, then Pro > plain > Pro Max > anything else ("iPhone 18 Pro" ranks highest
    /// of the 18s). Names without a number, like "iPhone Air", rank below every numbered model.
    static func modelRank(_ name: String) -> (generation: Int, variant: Int) {
        let base = SimulatorPicker.baseName(name)
        let words = base.split(separator: " ").dropFirst() // drop "iPhone"
        guard let first = words.first, let generation = Int(first.prefix(while: \.isNumber)) else { return (0, 0) }
        let variant = (String(first.drop(while: \.isNumber)) + " " + words.dropFirst().joined(separator: " "))
            .trimmingCharacters(in: .whitespaces)
        let order = ["Pro", "", "Pro Max"]
        return (generation, order.firstIndex(of: variant).map { order.count - $0 } ?? 0)
    }

    // MARK: xcodebuild

    public struct BuildIssue: Equatable, Sendable {
        public let severity: String // "error" or "warning"
        public let location: String? // file:line:col
        public let message: String

        public var line: String { [location, "\(severity): \(message)"].compactMap { $0 }.joined(separator: " ") }
    }

    /// Extracts compiler/linker diagnostics from xcodebuild output, de-duplicated, errors first.
    public static func parseIssues(_ output: String, includeWarnings: Bool = false, limit: Int = 40) -> [BuildIssue] {
        var seen = Set<String>()
        var errors: [BuildIssue] = []
        var warnings: [BuildIssue] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            var issue: BuildIssue?
            for severity in ["error", "warning"] {
                if let range = line.range(of: ": \(severity): ") {
                    let location = String(line[..<range.lowerBound])
                    let message = String(line[range.upperBound...])
                    // Only keep things that look like file locations, not arbitrary log prefixes.
                    let looksLikeFile = location.hasPrefix("/") || location.contains(".swift") || location.contains(".m") || location.contains(".h")
                    issue = BuildIssue(severity: severity, location: looksLikeFile ? location : nil, message: looksLikeFile ? message : line)
                    break
                } else if line.hasPrefix("\(severity): ") {
                    issue = BuildIssue(severity: severity, location: nil, message: String(line.dropFirst(severity.count + 2)))
                    break
                }
            }
            if line.hasPrefix("xcodebuild: error:") {
                issue = BuildIssue(severity: "error", location: nil, message: String(line.dropFirst("xcodebuild: error: ".count)))
            }
            guard let issue, seen.insert(issue.line).inserted else { continue }
            if issue.severity == "error" { errors.append(issue) } else if includeWarnings { warnings.append(issue) }
        }
        return Array((errors + warnings).prefix(limit))
    }

    /// Parses `xcodebuild -list -json` into (schemes, kind) where kind is "project" or "workspace".
    public static func parseSchemes(_ json: Data) -> [String] {
        guard let root = try? JSONValue.parse(json) else { return [] }
        let container = root["workspace"] ?? root["project"]
        return container?["schemes"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    public struct AppProduct: Equatable, Sendable {
        public let appPath: String
        public let bundleIdentifier: String?
        public let targetName: String?
    }

    /// Finds the built .app from `xcodebuild -showBuildSettings -json`.
    public static func parseAppProduct(_ json: Data) -> AppProduct? {
        guard let entries = try? JSONValue.parse(json).arrayValue else { return nil }
        for entry in entries {
            guard let settings = entry["buildSettings"] else { continue }
            guard settings["WRAPPER_EXTENSION"]?.stringValue == "app",
                  let dir = settings["TARGET_BUILD_DIR"]?.stringValue,
                  let wrapper = settings["WRAPPER_NAME"]?.stringValue else { continue }
            return AppProduct(
                appPath: dir + "/" + wrapper,
                bundleIdentifier: settings["PRODUCT_BUNDLE_IDENTIFIER"]?.stringValue,
                targetName: entry["target"]?.stringValue
            )
        }
        return nil
    }

    // MARK: Accessibility

    /// Compacts AXe's accessibility JSON into short lines Claude can read cheaply:
    /// `Button "Sign In" id=signInButton (120,640 150x44)`.
    public static func summarizeAccessibility(_ json: Data, maxLines: Int = 400) -> String {
        guard let root = try? JSONValue.parse(json) else { return String(decoding: json, as: UTF8.self) }
        var lines: [String] = []
        func visit(_ node: JSONValue, depth: Int) {
            guard lines.count < maxLines else { return }
            let type = node["type"]?.stringValue ?? node["role"]?.stringValue ?? "Element"
            var parts = [String(repeating: "  ", count: depth) + type]
            if let label = node["AXLabel"]?.stringValue, !label.isEmpty { parts.append("\"\(label)\"") }
            if let value = node["AXValue"]?.stringValue, !value.isEmpty { parts.append("value=\"\(value)\"") }
            if let id = node["AXUniqueId"]?.stringValue ?? node["AXIdentifier"]?.stringValue, !id.isEmpty { parts.append("id=\(id)") }
            if let frame = node["frame"],
               let x = frame["x"]?.doubleValue, let y = frame["y"]?.doubleValue,
               let w = frame["width"]?.doubleValue, let h = frame["height"]?.doubleValue {
                parts.append("(\(Int(x)),\(Int(y)) \(Int(w))x\(Int(h)))")
            }
            if node["enabled"]?.boolValue == false { parts.append("disabled") }
            lines.append(parts.joined(separator: " "))
            for child in node["children"]?.arrayValue ?? [] { visit(child, depth: depth + 1) }
        }
        if let array = root.arrayValue { array.forEach { visit($0, depth: 0) } } else { visit(root, depth: 0) }
        if lines.count >= maxLines { lines.append("… (truncated; pass format=json for the full tree)") }
        return lines.joined(separator: "\n")
    }

    /// The root application frame size in points, from AXe's accessibility JSON.
    public static func screenPointSize(fromAccessibility json: Data) -> (width: Double, height: Double)? {
        guard let root = try? JSONValue.parse(json) else { return nil }
        let first = root.arrayValue?.first ?? root
        guard let frame = first["frame"], let w = frame["width"]?.doubleValue, let h = frame["height"]?.doubleValue, w > 0, h > 0 else { return nil }
        return (w, h)
    }
}
