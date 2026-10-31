import Foundation

/// Key names and modifiers for Mac apps, as virtual key codes (Carbon's kVK_*, US layout) and
/// CGEventFlags bits. Plain numbers so this builds and tests on Linux.
public enum MacKeys {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
        public static let function = Modifiers(rawValue: 1 << 4)

        /// Lowercase names, in the order macOS shows them (⌃⌥⇧⌘), with fn first.
        public var names: [String] {
            var names: [String] = []
            if contains(.function) { names.append("fn") }
            if contains(.control) { names.append("control") }
            if contains(.option) { names.append("option") }
            if contains(.shift) { names.append("shift") }
            if contains(.command) { names.append("command") }
            return names
        }
    }

    public struct KeyError: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    static let modifierAliases: [String: Modifiers] = [
        "cmd": .command, "command": .command, "⌘": .command, "meta": .command, "super": .command,
        "shift": .shift, "⇧": .shift,
        "option": .option, "opt": .option, "alt": .option, "⌥": .option,
        "control": .control, "ctrl": .control, "ctl": .control, "⌃": .control,
        "fn": .function, "function": .function,
    ]

    /// The modifier a name stands for, or nil.
    public static func modifier(_ name: String) -> Modifiers? {
        modifierAliases[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// Parses modifier names like `["cmd", "shift"]`. Throws on an unknown name.
    public static func parseModifiers(_ names: [String]) throws -> Modifiers {
        var result: Modifiers = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let modifier = modifier(trimmed) else {
                throw KeyError(message: "Unknown modifier \(name). Use command, shift, option, control or fn.")
            }
            result.insert(modifier)
        }
        return result
    }

    /// CGEventFlags raw bits for `modifiers`.
    public static func flags(_ modifiers: Modifiers) -> UInt64 {
        var flags: UInt64 = 0
        if modifiers.contains(.command) { flags |= 0x100000 }      // maskCommand
        if modifiers.contains(.shift) { flags |= 0x20000 }         // maskShift
        if modifiers.contains(.option) { flags |= 0x80000 }        // maskAlternate
        if modifiers.contains(.control) { flags |= 0x40000 }       // maskControl
        if modifiers.contains(.function) { flags |= 0x800000 }     // maskSecondaryFn
        return flags
    }

    /// Virtual key codes of the modifier keys themselves (left-hand ones), in press order.
    public static func modifierKeyCodes(_ modifiers: Modifiers) -> [UInt16] {
        var codes: [UInt16] = []
        if modifiers.contains(.function) { codes.append(0x3F) }
        if modifiers.contains(.control) { codes.append(0x3B) }
        if modifiers.contains(.option) { codes.append(0x3A) }
        if modifiers.contains(.shift) { codes.append(0x38) }
        if modifiers.contains(.command) { codes.append(0x37) }
        return codes
    }

    static let letters: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,
    ]

    static let digits: [Character: UInt16] = [
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19, "7": 0x1A,
        "8": 0x1C, "0": 0x1D,
    ]

    static let punctuation: [Character: UInt16] = [
        "=": 0x18, "-": 0x1B, "]": 0x1E, "[": 0x21, "'": 0x27, ";": 0x29, "\\": 0x2A, ",": 0x2B,
        "/": 0x2C, ".": 0x2F, "`": 0x32,
    ]

    /// Characters typed with shift on a US keyboard, and the unshifted key they're on.
    static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static let named: [String: UInt16] = [
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
        "escape": 0x35, "esc": 0x35, "forwarddelete": 0x75, "forward-delete": 0x75, "del": 0x75,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "arrowleft": 0x7B, "arrowright": 0x7C, "arrowdown": 0x7D, "arrowup": 0x7E,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79, "page-up": 0x74, "page-down": 0x79,
        "help": 0x72, "keypadenter": 0x4C,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "minus": 0x1B, "equal": 0x18, "equals": 0x18, "leftbracket": 0x21, "rightbracket": 0x1E,
        "quote": 0x27, "semicolon": 0x29, "backslash": 0x2A, "comma": 0x2B, "slash": 0x2C,
        "period": 0x2F, "grave": 0x32, "backtick": 0x32,
    ]

    /// Key names for error messages and tool descriptions.
    public static let namedKeys: [String] = [
        "return", "tab", "space", "delete", "escape", "forwarddelete", "left", "right", "up", "down",
        "home", "end", "pageup", "pagedown", "f1–f12", "a–z", "0–9", "punctuation",
    ]

    /// The virtual key code for a key name (`return`, `f5`, `pageup`), a letter, a digit or a
    /// punctuation character on a US keyboard. Case-insensitive. Shifted characters (`?`, `A`)
    /// return their key's code; use `stroke` to get the shift too.
    public static func keyCode(_ name: String) -> UInt16? {
        stroke(name)?.code
    }

    /// The key code plus any modifiers the character needs: `A` is shift+a, `?` is shift+/.
    public static func stroke(_ name: String) -> (code: UInt16, modifiers: Modifiers)? {
        if name.count == 1, let character = name.first {
            if character == " " { return (0x31, []) }
            if let code = letters[character] ?? digits[character] ?? punctuation[character] { return (code, []) }
            let lower = Character(character.lowercased())
            if character.isUppercase, let code = letters[lower] { return (code, .shift) }
            if let base = shifted[character], let code = punctuation[base] ?? digits[base] { return (code, .shift) }
        }
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let code = named[key] { return (code, []) }
        if key.count == 1, let character = key.first, let code = letters[character] { return (code, []) }
        return nil
    }

    /// Parses a shortcut like `cmd+shift+n`, `ctrl-a`, `⌘⇧N` or `return` into a key and modifiers.
    /// Throws when a part isn't a known modifier or key.
    public static func parseCombo(_ combo: String) throws -> (key: String, modifiers: Modifiers) {
        var text = combo.trimmingCharacters(in: .whitespaces)
        var modifiers: Modifiers = []
        // Leading symbols: ⌘⇧N.
        while let first = text.first, text.count > 1, let modifier = modifierAliases[String(first)], "⌘⇧⌥⌃".contains(first) {
            modifiers.insert(modifier)
            text.removeFirst()
        }
        var parts: [String]
        if stroke(text) != nil {
            parts = [text]
        } else {
            // A trailing separator is the key itself: "cmd++" is command and "+".
            let separator: Character = text.contains("+") ? "+" : "-"
            parts = text.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" {
                parts.removeLast(2)
                parts.append(String(separator))
            }
        }
        guard let key = parts.last?.trimmingCharacters(in: .whitespaces), !key.isEmpty else {
            throw KeyError(message: "No key in \(combo). Write shortcuts like cmd+shift+n.")
        }
        modifiers.formUnion(try parseModifiers(parts.dropLast().map { $0 }))
        guard stroke(key) != nil else {
            throw KeyError(message: "Unknown key \(key) in \(combo). Use a letter, digit, punctuation, or one of: \(namedKeys.joined(separator: ", ")).")
        }
        return (key, modifiers)
    }

    /// Splits text into chunks of at most `limit` UTF-16 units for keyboard events, never inside a
    /// character (so emoji and accented letters arrive whole). Newlines and tabs become their own
    /// chunks so they can be sent as Return and Tab key presses.
    public static func textChunks(_ text: String, limit: Int = 20) -> [String] {
        var chunks: [String] = []
        var current = ""
        var units = 0
        for character in text {
            if character == "\n" || character == "\r\n" || character == "\r" || character == "\t" {
                if !current.isEmpty { chunks.append(current) }
                chunks.append(character == "\t" ? "\t" : "\n")
                current = ""
                units = 0
                continue
            }
            let size = character.utf16.count
            if units + size > max(limit, size), !current.isEmpty {
                chunks.append(current)
                current = ""
                units = 0
            }
            current.append(character)
            units += size
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
