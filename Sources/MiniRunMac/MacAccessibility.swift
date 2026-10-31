import Foundation
import ApplicationServices
import CoreGraphics
import MiniRunKit

/// The window's CGWindowID. Private, but stable for years and what every window manager uses;
/// without it, AX windows can only be matched to CGWindowList entries by frame.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Reads and acts on Mac apps through the Accessibility API (AXUIElement). Everything here is
/// synchronous IPC to the app, so the driver calls it off the main actor. Each call gives up
/// on an app that stops answering (see `timeout`) instead of hanging the daemon.
enum MacAccessibility {
    /// Seconds one AX message may take before the app counts as not responding.
    static let messageTimeout: Float = 1.5
    /// Seconds a whole tree read may take.
    static let walkBudget: TimeInterval = 8

    private static let configure: Void = {
        // On the system-wide element this sets the timeout for every element in this process.
        _ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messageTimeout)
    }()

    static func application(_ pid: Int32) -> AXUIElement {
        _ = configure
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, messageTimeout)
        return app
    }

    static func notResponding(_ pid: Int32) -> MacDriverError {
        MacDriverError("The app (pid \(pid)) isn't responding to accessibility requests. It may be busy, hung or showing a modal dialog; try again, or take a screenshot to see.")
    }

    // MARK: Attributes

    static func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as AnyObject
    }

    /// Several attributes in one round trip. Missing ones are left out. Nil if the app didn't answer.
    static func values(_ element: AXUIElement, _ names: [String]) -> (values: [String: AnyObject], error: AXError) {
        var out: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
        guard error == .success, let out else { return ([:], error) }
        let array = (out as NSArray) as [AnyObject]
        var result: [String: AnyObject] = [:]
        for (index, value) in array.enumerated() where index < names.count {
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
            if value is NSNull { continue }
            result[names[index]] = value
        }
        return (result, .success)
    }

    static func string(_ value: AnyObject?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return (value as? Bool) == true ? "1" : "0" }
        if let number = value as? NSNumber { return number.stringValue }
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    static func bool(_ value: AnyObject?) -> Bool? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    static func elements(_ value: AnyObject?) -> [AXUIElement] {
        guard let array = value as? [AnyObject] else { return [] }
        return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    static func element(_ value: AnyObject?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func point(_ value: AnyObject?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: AnyObject?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func frame(_ values: [String: AnyObject]) -> MacRect? {
        guard let origin = point(values["AXPosition"]), let size = size(values["AXSize"]) else { return nil }
        return MacRect(x: Double(origin.x), y: Double(origin.y), width: Double(size.width), height: Double(size.height))
    }

    static func frame(of element: AXUIElement) -> MacRect? {
        frame(values(element, ["AXPosition", "AXSize"]).values)
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let names else { return [] }
        return ((names as NSArray) as? [String]) ?? []
    }

    static func windowID(_ window: AXUIElement) -> UInt32? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
    }

    // MARK: Windows

    struct WindowState {
        let element: AXUIElement
        let windowID: UInt32?
        let title: String
        let frame: MacRect?
        let isMain: Bool
        let isFocused: Bool
        let isMinimized: Bool
    }

    /// The app's windows as Accessibility sees them, or nil without the permission.
    static func windows(pid: Int32) -> [WindowState]? {
        guard AXIsProcessTrusted() else { return nil }
        let app = application(pid)
        let windows = elements(value(app, "AXWindows"))
        return windows.compactMap { window in
            let read = values(window, ["AXRole", "AXSubrole", "AXTitle", "AXMain", "AXFocused", "AXMinimized", "AXPosition", "AXSize"])
            if let role = string(read.values["AXRole"]), role != "AXWindow" { return nil }
            return WindowState(
                element: window, windowID: windowID(window), title: string(read.values["AXTitle"]) ?? "",
                frame: frame(read.values), isMain: bool(read.values["AXMain"]) ?? false,
                isFocused: bool(read.values["AXFocused"]) ?? false, isMinimized: bool(read.values["AXMinimized"]) ?? false
            )
        }
    }

    /// The AX element of the window with `windowID`, matched by id, else by frame.
    static func windowElement(pid: Int32, windowID: UInt32, frame: MacRect) throws -> AXUIElement {
        try MacPermissions.requireAccessibility()
        let all = windows(pid: pid) ?? []
        if let match = all.first(where: { $0.windowID == windowID }) { return match.element }
        if let match = all.first(where: { state in
            guard let other = state.frame else { return false }
            return abs(other.x - frame.x) < 1 && abs(other.y - frame.y) < 1 && abs(other.width - frame.width) < 1 && abs(other.height - frame.height) < 1
        }) { return match.element }
        if all.isEmpty, AXIsProcessTrusted() {
            // Either no windows, or the app isn't answering.
            var probe: CFTypeRef?
            if AXUIElementCopyAttributeValue(application(pid), "AXRole" as CFString, &probe) == .cannotComplete { throw notResponding(pid) }
        }
        throw MacDriverError("Couldn't find that window through Accessibility (window \(windowID)). It may have just closed; call list_windows.")
    }

    // MARK: Tree

    static let nodeAttributes = [
        "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXIdentifier", "AXHelp",
        "AXPlaceholderValue", "AXPosition", "AXSize", "AXEnabled", "AXFocused", "AXSelected", "AXChildren",
    ]

    /// One element found while walking, for searches.
    struct Found {
        let element: AXUIElement
        let role: String
        let subrole: String?
        let label: String?
        let value: String?
        let identifier: String?
        let frame: MacRect?
        let enabled: Bool
    }

    /// Walks an element's subtree into AXe-shaped JSON: `type`, `role`, `subrole`, `AXLabel`,
    /// `AXValue`, `AXIdentifier`, `help`, `placeholder`, `frame` (relative to `origin`),
    /// `enabled`, `focused`, `selected`, `children`.
    final class Walker {
        let pid: Int32
        let origin: MacRect?
        let maxDepth: Int
        let maxNodes: Int
        let deadline: Date
        var count = 0
        var truncated = false
        var timedOut = false
        var found: [Found]?

        init(pid: Int32, origin: MacRect?, maxDepth: Int = 60, maxNodes: Int = 2500, collect: Bool = false) {
            self.pid = pid
            self.origin = origin
            self.maxDepth = maxDepth
            self.maxNodes = maxNodes
            self.deadline = Date().addingTimeInterval(MacAccessibility.walkBudget)
            self.found = collect ? [] : nil
        }

        func walk(_ element: AXUIElement, depth: Int = 0) -> JSONValue? {
            guard !timedOut else { return nil }
            if count >= maxNodes || Date() > deadline {
                truncated = true
                return nil
            }
            count += 1
            let read = MacAccessibility.values(element, MacAccessibility.nodeAttributes)
            if read.error == .cannotComplete {
                timedOut = true
                return nil
            }
            let values = read.values
            let role = MacAccessibility.string(values["AXRole"]) ?? "AXUnknown"
            let subrole = MacAccessibility.string(values["AXSubrole"])
            let title = MacAccessibility.string(values["AXTitle"])
            let description = MacAccessibility.string(values["AXDescription"])
            let value = MacAccessibility.string(values["AXValue"])
            var label = [title, description].compactMap { $0 }.first { !$0.isEmpty }
            // Static text keeps its text in AXValue; iOS calls that the label.
            if label == nil, role == "AXStaticText" { label = value }
            let identifier = MacAccessibility.string(values["AXIdentifier"])
            let global = MacAccessibility.frame(values)
            let enabled = MacAccessibility.bool(values["AXEnabled"]) ?? true

            var node: [String: JSONValue] = [
                "type": .string(role.hasPrefix("AX") ? String(role.dropFirst(2)) : role),
                "role": .string(role),
                "enabled": .bool(enabled),
            ]
            if let subrole, !subrole.isEmpty { node["subrole"] = .string(subrole) }
            if let label { node["AXLabel"] = .string(label) }
            if let value, !(role == "AXStaticText" && value == label) { node["AXValue"] = .string(value) }
            if let identifier, !identifier.isEmpty { node["AXIdentifier"] = .string(identifier) }
            if let help = MacAccessibility.string(values["AXHelp"]), !help.isEmpty { node["help"] = .string(help) }
            if let placeholder = MacAccessibility.string(values["AXPlaceholderValue"]), !placeholder.isEmpty { node["placeholder"] = .string(placeholder) }
            if MacAccessibility.bool(values["AXFocused"]) == true { node["focused"] = .bool(true) }
            if MacAccessibility.bool(values["AXSelected"]) == true { node["selected"] = .bool(true) }
            if let global, let origin {
                let frame = MacGeometry.toWindow(globalRect: global, window: origin)
                node["frame"] = .object([
                    "x": .number(frame.x.rounded()), "y": .number(frame.y.rounded()),
                    "width": .number(frame.width.rounded()), "height": .number(frame.height.rounded()),
                ])
            }
            found?.append(Found(element: element, role: role, subrole: subrole, label: label, value: value, identifier: identifier, frame: global, enabled: enabled))

            let children = MacAccessibility.elements(values["AXChildren"])
            if !children.isEmpty {
                if depth >= maxDepth {
                    truncated = true
                } else {
                    let nodes = children.compactMap { walk($0, depth: depth + 1) }
                    if !nodes.isEmpty { node["children"] = .array(nodes) }
                }
            }
            return .object(node)
        }
    }

    /// The window's tree (and the menu bar's), as JSON data.
    static func describe(pid: Int32, windowID: UInt32, frame: MacRect, includeMenus: Bool, at point: (x: Double, y: Double)?) throws -> Data {
        let window = try windowElement(pid: pid, windowID: windowID, frame: frame)
        var roots: [JSONValue] = []
        if let point {
            let global = MacGeometry.toGlobal(windowPoint: point, window: frame)
            var hit: AXUIElement?
            let error = AXUIElementCopyElementAtPosition(application(pid), Float(global.x), Float(global.y), &hit)
            if error == .cannotComplete { throw notResponding(pid) }
            guard error == .success, let hit else {
                throw MacDriverError("No accessibility element at (\(Int(point.x)), \(Int(point.y))) in the window.")
            }
            let walker = Walker(pid: pid, origin: frame, maxDepth: 8, maxNodes: 300)
            if let node = walker.walk(hit) { roots.append(node) }
            if walker.timedOut { throw notResponding(pid) }
        } else {
            let walker = Walker(pid: pid, origin: frame)
            if var node = walker.walk(window) {
                if walker.truncated, case .object(var object) = node {
                    object["truncated"] = .bool(true)
                    node = .object(object)
                }
                roots.append(node)
            }
            if walker.timedOut { throw notResponding(pid) }
        }
        if includeMenus, let menuBar = element(value(application(pid), "AXMenuBar")) {
            // Menus live outside the window, so their frames would only confuse: none are given.
            let walker = Walker(pid: pid, origin: nil, maxDepth: 8, maxNodes: 1500)
            if let node = walker.walk(menuBar) { roots.append(node) }
        }
        return try JSONEncoder().encode(JSONValue.array(roots))
    }

    // MARK: Finding and pressing

    enum PressOutcome: Sendable {
        /// Pressed or focused through Accessibility; the point is the element's center, in window points.
        case pressed(x: Double, y: Double)
        /// No AX action to use: click this window point instead.
        case click(x: Double, y: Double)
    }

    static func matches(_ query: MacElementQuery, in found: [Found]) -> Found? {
        func pick(_ candidates: [Found]) -> Found? {
            candidates.first { $0.enabled && !($0.frame?.isEmpty ?? true) } ?? candidates.first { !($0.frame?.isEmpty ?? true) } ?? candidates.first
        }
        switch query {
        case .id(let id):
            return pick(found.filter { $0.identifier == id }) ?? pick(found.filter { $0.identifier?.caseInsensitiveCompare(id) == .orderedSame })
        case .label(let label), .value(let label):
            let key: (Found) -> String? = { if case .label = query { return $0.label } else { return $0.value } }
            let exact = found.filter { key($0)?.caseInsensitiveCompare(label) == .orderedSame }
            if let match = pick(exact) { return match }
            return pick(found.filter { key($0)?.range(of: label, options: [.caseInsensitive, .diacriticInsensitive]) != nil })
        }
    }

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]

    /// Finds the element and presses it (or focuses it, for text fields). Nil if there's no match yet.
    static func press(pid: Int32, windowID: UInt32, frame: MacRect, query: MacElementQuery) throws -> PressOutcome? {
        let window = try windowElement(pid: pid, windowID: windowID, frame: frame)
        let walker = Walker(pid: pid, origin: frame, collect: true)
        _ = walker.walk(window)
        if walker.timedOut { throw notResponding(pid) }
        guard let match = matches(query, in: walker.found ?? []) else { return nil }
        let center: (x: Double, y: Double)
        if let global = match.frame {
            let local = MacGeometry.toWindow(globalRect: global, window: frame)
            center = (local.midX, local.midY)
        } else {
            center = (frame.width / 2, frame.height / 2)
        }
        if !match.enabled {
            throw MacDriverError("Found \(describe(match)), but it's disabled.")
        }
        if textRoles.contains(match.role) || textRoles.contains(match.subrole ?? "") {
            if AXUIElementSetAttributeValue(match.element, "AXFocused" as CFString, kCFBooleanTrue) == .success {
                return .pressed(x: center.x, y: center.y)
            }
            return .click(x: center.x, y: center.y)
        }
        if actions(match.element).contains("AXPress") {
            let error = AXUIElementPerformAction(match.element, "AXPress" as CFString)
            // An action that opens a modal dialog doesn't return until the dialog closes, so a
            // timeout here usually means it worked.
            if error == .success || error == .cannotComplete { return .pressed(x: center.x, y: center.y) }
        }
        guard match.frame != nil else {
            throw MacDriverError("Found \(describe(match)), but it can't be pressed and has no frame to click.")
        }
        return .click(x: center.x, y: center.y)
    }

    /// Roles a click means "press" for.
    static let pressableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink", "AXDisclosureTriangle", "AXIncrementor",
    ]

    /// Presses the button-like element at a window point (or one of its first ancestors) through
    /// Accessibility, or focuses the text field there. Returns what it pressed, like
    /// `Button "Increment" id=incrementButton`, or nil when there's nothing there to press this way.
    static func pressElement(pid: Int32, frame: MacRect, at point: (x: Double, y: Double)) throws -> String? {
        let global = MacGeometry.toGlobal(windowPoint: point, window: frame)
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(application(pid), Float(global.x), Float(global.y), &hit)
        if error == .cannotComplete { throw notResponding(pid) }
        guard error == .success, var current = hit else { return nil }
        for _ in 0..<3 {
            let read = values(current, ["AXRole", "AXEnabled", "AXTitle", "AXDescription", "AXIdentifier"]).values
            let role = string(read["AXRole"]) ?? ""
            var name = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
            if let label = string(read["AXTitle"]) ?? string(read["AXDescription"]), !label.isEmpty { name += " \"\(label)\"" }
            if let id = string(read["AXIdentifier"]), !id.isEmpty { name += " id=\(id)" }
            if textRoles.contains(role) {
                return AXUIElementSetAttributeValue(current, "AXFocused" as CFString, kCFBooleanTrue) == .success ? name : nil
            }
            if pressableRoles.contains(role) {
                guard bool(read["AXEnabled"]) ?? true, actions(current).contains("AXPress") else { return nil }
                let result = AXUIElementPerformAction(current, "AXPress" as CFString)
                return result == .success || result == .cannotComplete ? name : nil
            }
            guard let parent = element(value(current, "AXParent")) else { return nil }
            current = parent
        }
        return nil
    }

    static func describe(_ found: Found) -> String {
        var text = found.role.hasPrefix("AX") ? String(found.role.dropFirst(2)) : found.role
        if let label = found.label, !label.isEmpty { text += " \"\(label)\"" }
        if let id = found.identifier, !id.isEmpty { text += " id=\(id)" }
        return text
    }

    /// Raises the window and makes the app frontmost (for input that has to go through the HID tap).
    static func raise(pid: Int32, windowID: UInt32, frame: MacRect) {
        guard AXIsProcessTrusted() else { return }
        let app = application(pid)
        _ = AXUIElementSetAttributeValue(app, "AXFrontmost" as CFString, kCFBooleanTrue)
        if let window = try? windowElement(pid: pid, windowID: windowID, frame: frame) {
            _ = AXUIElementPerformAction(window, "AXRaise" as CFString)
            _ = AXUIElementSetAttributeValue(window, "AXMain" as CFString, kCFBooleanTrue)
        }
    }

    // MARK: Menus

    /// A menu title for matching: lowercased, trimmed, without a trailing "…" or "...".
    static func normalize(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("…") { text.removeLast() }
        if text.hasSuffix("...") { text.removeLast(3) }
        return text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Presses the menu item at `path` (["File", "New Window"]). Returns the titles it matched.
    static func pressMenuItem(pid: Int32, path: [String]) throws -> [String] {
        try MacPermissions.requireAccessibility(for: "use Mac app menus")
        guard !path.isEmpty else { throw MacDriverError("Give the menu path, e.g. [\"File\", \"New Window\"].") }
        let app = application(pid)
        var probe: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, "AXMenuBar" as CFString, &probe)
        if error == .cannotComplete { throw notResponding(pid) }
        guard let menuBar = element(probe) else {
            throw MacDriverError("The app (pid \(pid)) has no menu bar through Accessibility. It may not have finished launching.")
        }
        var items = elements(value(menuBar, "AXChildren"))
        var matched: [String] = []
        for (level, name) in path.enumerated() {
            let titled: [(element: AXUIElement, title: String)] = items.compactMap { item in
                guard let title = string(value(item, "AXTitle")), !title.isEmpty else { return nil }
                return (item, title)
            }
            let wanted = normalize(name)
            guard let hit = titled.first(where: { normalize($0.title) == wanted }) ?? titled.first(where: { normalize($0.title).hasPrefix(wanted) }) else {
                let place = matched.isEmpty ? "the menu bar" : "the \(matched.joined(separator: " > ")) menu"
                throw MacDriverError("No \"\(name)\" in \(place). Available: \(titled.map(\.title).joined(separator: ", ")).")
            }
            matched.append(hit.title)
            if level == path.count - 1 {
                if bool(value(hit.element, "AXEnabled")) == false {
                    throw MacDriverError("\(matched.joined(separator: " > ")) is disabled right now.")
                }
                let result = AXUIElementPerformAction(hit.element, "AXPress" as CFString)
                guard result == .success || result == .cannotComplete else {
                    throw MacDriverError("Couldn't press \(matched.joined(separator: " > ")) (AX error \(result.rawValue)).")
                }
                return matched
            }
            let children = elements(value(hit.element, "AXChildren"))
            let menu = children.first { string(value($0, "AXRole")) == "AXMenu" } ?? children.first
            guard let menu else { throw MacDriverError("\(matched.joined(separator: " > ")) has no submenu.") }
            items = elements(value(menu, "AXChildren"))
        }
        return matched
    }
}
