import Foundation

/// Plain helpers for Mac app menus and menu bar icons (status items), kept out of MiniRunMac so
/// they're tested on Linux too.
public enum MacMenus {
    /// Which menu bar press_menu_item looks in.
    public enum Bar: String, Sendable, CaseIterable {
        /// The app's menus at the top left of the screen (File, Edit, …).
        case app
        /// Its menu bar icons (status items: NSStatusItem, SwiftUI's MenuBarExtra) at the top right.
        case status
    }

    // MARK: Shortcuts

    /// AXMenuItemCmdModifiers bits (Carbon's kMenu*Modifier). With none set, the shortcut is ⌘ plus the key.
    public static let shiftBit = 1 << 0
    public static let optionBit = 1 << 1
    public static let controlBit = 1 << 2
    public static let noCommandBit = 1 << 3

    /// AXMenuItemCmdGlyph values (Carbon's kMenu*Glyph) for keys with no character.
    static let glyphs: [Int: String] = [
        0x02: "⇥", 0x09: "Space", 0x0A: "⌦", 0x0B: "↩", 0x17: "⌫", 0x1B: "⎋",
        0x64: "←", 0x65: "→", 0x68: "↑", 0x6A: "↓",
        0x6F: "F1", 0x70: "F2", 0x71: "F3", 0x72: "F4", 0x73: "F5", 0x74: "F6",
        0x75: "F7", 0x76: "F8", 0x77: "F9", 0x78: "F10", 0x79: "F11", 0x7A: "F12",
    ]

    /// A menu item's keyboard shortcut as macOS shows it, like "⌘R" or "⌃⌥⇧⌘K", from its
    /// AXMenuItemCmdChar, AXMenuItemCmdModifiers and AXMenuItemCmdGlyph. Nil when it has none.
    public static func shortcut(character: String?, modifiers: Int?, glyph: Int?) -> String? {
        var key = (character ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // A character that's a control code (some apps report one) says nothing readable.
        if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1, scalar.value < 0x20 { key = "" }
        if key.isEmpty, let glyph, let name = glyphs[glyph] { key = name }
        guard !key.isEmpty else { return nil }
        let bits = modifiers ?? 0
        var text = ""
        if bits & controlBit != 0 { text += "⌃" }
        if bits & optionBit != 0 { text += "⌥" }
        if bits & shiftBit != 0 { text += "⇧" }
        if bits & noCommandBit == 0 { text += "⌘" }
        return text + key.uppercased()
    }

    // MARK: Menu bar icons

    /// What a menu bar icon calls itself through Accessibility.
    public struct StatusItemNames: Equatable, Sendable {
        public var title: String?
        public var description: String?
        public var identifier: String?
        public var help: String?

        public init(title: String? = nil, description: String? = nil, identifier: String? = nil, help: String? = nil) {
            self.title = title
            self.description = description
            self.identifier = identifier
            self.help = help
        }

        var all: [String] { [title, description, identifier, help].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

        /// The name to show: its title, else its accessibility label, id or tooltip.
        public var display: String { all.first ?? "(untitled)" }
    }

    /// The status item `query` names: one whose title, accessibility label, id or tooltip
    /// matches it exactly (case-insensitively), else starts with it, else contains it. With no
    /// query (or "*"), or a query nothing matches, the app's only one: SwiftUI names a
    /// MenuBarExtra's icon after its image ("Favorite" for "star"), not the title in the code.
    /// Nil if none matches and there are several.
    public static func pickStatusItem(_ query: String?, in items: [StatusItemNames]) -> Int? {
        let wanted = normalize(query ?? "")
        if wanted.isEmpty || wanted == "*" { return items.count == 1 ? 0 : nil }
        let names = items.map { $0.all.map(normalize) }
        if let exact = names.firstIndex(where: { $0.contains(wanted) }) { return exact }
        if let prefix = names.firstIndex(where: { $0.contains { $0.hasPrefix(wanted) } }) { return prefix }
        if let partial = names.firstIndex(where: { $0.contains { $0.contains(wanted) } }) { return partial }
        return items.count == 1 ? 0 : nil
    }

    /// The error for a status item that wasn't found.
    public static func statusItemMiss(_ query: String?, appName: String, items: [StatusItemNames]) -> String {
        guard !items.isEmpty else {
            return "\(appName) has no menu bar icon (status item) that Accessibility can see. It may not have created it yet, or macOS may be hiding it."
        }
        let list = items.map { "\"\($0.display)\"" }.joined(separator: ", ")
        if (query ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(appName) has \(items.count) menu bar icons: \(list). Name one as the first element of path."
        }
        return "No menu bar icon \"\(query!)\" in \(appName). Its icons: \(list). (SwiftUI names a MenuBarExtra's icon after its image, not its title.)"
    }

    /// A menu title for matching: lowercased, trimmed, without a trailing "…" or "...".
    public static func normalize(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("…") { text.removeLast() }
        if text.hasSuffix("...") { text.removeLast(3) }
        return text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: Capturing open menus

    /// A window of the app above normal windows: an open menu, a popover or panel, or its menu bar icon.
    public struct Overlay: Equatable, Sendable {
        public var frame: MacRect
        public var layer: Int

        public init(frame: MacRect, layer: Int) {
            self.frame = frame
            self.layer = layer
        }

        /// kCGStatusWindowLevel: menu bar icons live there, and are a menu bar high.
        public var isStatusItem: Bool { layer == 25 && frame.height <= 50 }
    }

    /// The part of the screen to capture to show the app's open menus and popovers: all of them,
    /// with a margin, plus any of its menu bar icons just above them (so a menu is seen hanging off
    /// its icon). With nothing open, just its menu bar icons. Nil when there's nothing at all.
    public static func captureRect(_ overlays: [Overlay], margin: Double = 8) -> MacRect? {
        let open = overlays.filter { !$0.isStatusItem && !$0.frame.isEmpty }.map(\.frame)
        let icons = overlays.filter { $0.isStatusItem && !$0.frame.isEmpty }.map(\.frame)
        var rects = open
        if let area = union(open) {
            // Icons overlapping the menus horizontally, close above them.
            rects += icons.filter { icon in
                icon.x < area.x + area.width && icon.x + icon.width > area.x && icon.y <= area.y && area.y - (icon.y + icon.height) < 60
            }
        } else {
            rects = icons
        }
        guard let area = union(rects) else { return nil }
        return MacRect(x: area.x - margin, y: area.y - margin, width: area.width + margin * 2, height: area.height + margin * 2)
    }

    static func union(_ rects: [MacRect]) -> MacRect? {
        guard let first = rects.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x + first.width, maxY = first.y + first.height
        for rect in rects.dropFirst() {
            minX = min(minX, rect.x)
            minY = min(minY, rect.y)
            maxX = max(maxX, rect.x + rect.width)
            maxY = max(maxY, rect.y + rect.height)
        }
        return MacRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `rect` clipped to `bounds`, or nil if they don't meet.
    public static func clip(_ rect: MacRect, to bounds: MacRect) -> MacRect? {
        let minX = max(rect.x, bounds.x), minY = max(rect.y, bounds.y)
        let maxX = min(rect.x + rect.width, bounds.x + bounds.width), maxY = min(rect.y + rect.height, bounds.y + bounds.height)
        guard maxX > minX, maxY > minY else { return nil }
        return MacRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
