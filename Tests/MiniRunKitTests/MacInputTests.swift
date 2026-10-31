import Foundation
import XCTest
@testable import MiniRunKit

final class MacGeometryTests: XCTestCase {
    let window = MacRect(x: 100, y: 50, width: 800, height: 600)

    func testWindowAndGlobalPoints() {
        let global = MacGeometry.toGlobal(windowPoint: (10, 20), window: window)
        XCTAssertEqual(global.x, 110)
        XCTAssertEqual(global.y, 70)
        let back = MacGeometry.toWindow(globalPoint: global, window: window)
        XCTAssertEqual(back.x, 10)
        XCTAssertEqual(back.y, 20)
        XCTAssertEqual(MacGeometry.toWindow(globalRect: MacRect(x: 150, y: 80, width: 40, height: 20), window: window),
                       MacRect(x: 50, y: 30, width: 40, height: 20))
        // A window on a display left of or above the main one has negative global coordinates.
        let left = MacRect(x: -1440, y: -200, width: 500, height: 400)
        let point = MacGeometry.toGlobal(windowPoint: (250, 200), window: left)
        XCTAssertEqual(point.x, -1190)
        XCTAssertEqual(point.y, 0)
    }

    func testContains() {
        XCTAssertTrue(MacGeometry.contains(window, windowPoint: (0, 0)))
        XCTAssertTrue(MacGeometry.contains(window, windowPoint: (799.5, 599)))
        XCTAssertFalse(MacGeometry.contains(window, windowPoint: (800, 10)))
        XCTAssertFalse(MacGeometry.contains(window, windowPoint: (-1, 10)))
        XCTAssertFalse(MacGeometry.contains(window, windowPoint: (10, 600)))
    }

    func testSizes() {
        XCTAssertTrue(MacGeometry.capturePixels(points: (800, 600), backingScale: 2) == (1600, 1200))
        XCTAssertTrue(MacGeometry.capturePixels(points: (800.5, 600), backingScale: 0) == (801, 600), "unknown scale means 1")
        XCTAssertTrue(MacGeometry.imageSize(points: (800, 600), scale: nil) == (800, 600), "one pixel per point by default")
        XCTAssertTrue(MacGeometry.imageSize(points: (800, 600), scale: 0.5) == (400, 300))
        XCTAssertTrue(MacGeometry.imageSize(points: (0.2, 0.2), scale: 1) == (1, 1))
        XCTAssertTrue(MacGeometry.videoSize(pixels: (1601, 1201), scale: 1) == (1600, 1200), "even sizes for H.264")
        XCTAssertTrue(MacGeometry.videoSize(pixels: (1600, 1200), scale: 0.5) == (800, 600))
        XCTAssertTrue(MacGeometry.videoSize(pixels: (10, 10), scale: 1) == (16, 16))
        XCTAssertTrue(MacGeometry.videoSize(pixels: (100, 100), scale: 3) == (100, 100), "never upscaled")
    }

    func testPath() {
        let path = MacGeometry.path(from: (0, 0), to: (100, 50), steps: 4)
        XCTAssertEqual(path.count, 5)
        XCTAssertEqual(path.first?.x, 0)
        XCTAssertEqual(path[2].x, 50)
        XCTAssertEqual(path[2].y, 25)
        XCTAssertEqual(path.last?.x, 100)
        XCTAssertEqual(path.last?.y, 50)
        XCTAssertEqual(MacGeometry.path(from: (0, 0), to: (1, 1), steps: 0).count, 2)
    }
}

final class MacKeysTests: XCTestCase {
    func testModifiers() throws {
        XCTAssertEqual(try MacKeys.parseModifiers(["cmd", "Shift", "⌥", "ctrl", "fn"]), [.command, .shift, .option, .control, .function])
        XCTAssertEqual(try MacKeys.parseModifiers(["command", "alt", "opt", "control", "⌘", "⇧", "⌃", "function", ""]),
                       [.command, .option, .control, .shift, .function])
        XCTAssertEqual(try MacKeys.parseModifiers([]), [])
        XCTAssertThrowsError(try MacKeys.parseModifiers(["hyper"]))
        XCTAssertEqual(MacKeys.Modifiers([.shift, .command, .control]).names, ["control", "shift", "command"])
    }

    func testFlags() {
        XCTAssertEqual(MacKeys.flags([]), 0)
        XCTAssertEqual(MacKeys.flags(.command), 0x100000)
        XCTAssertEqual(MacKeys.flags(.shift), 0x20000)
        XCTAssertEqual(MacKeys.flags(.option), 0x80000)
        XCTAssertEqual(MacKeys.flags(.control), 0x40000)
        XCTAssertEqual(MacKeys.flags(.function), 0x800000)
        XCTAssertEqual(MacKeys.flags([.command, .shift]), 0x120000)
        XCTAssertEqual(MacKeys.modifierKeyCodes([.command, .shift]), [0x38, 0x37])
    }

    func testKeyCodes() {
        XCTAssertEqual(MacKeys.keyCode("a"), 0x00)
        XCTAssertEqual(MacKeys.keyCode("A"), 0x00)
        XCTAssertEqual(MacKeys.keyCode("n"), 0x2D)
        XCTAssertEqual(MacKeys.keyCode("z"), 0x06)
        XCTAssertEqual(MacKeys.keyCode("0"), 0x1D)
        XCTAssertEqual(MacKeys.keyCode("5"), 0x17)
        XCTAssertEqual(MacKeys.keyCode(","), 0x2B)
        XCTAssertEqual(MacKeys.keyCode("/"), 0x2C)
        XCTAssertEqual(MacKeys.keyCode("`"), 0x32)
        XCTAssertEqual(MacKeys.keyCode("return"), 0x24)
        XCTAssertEqual(MacKeys.keyCode("Enter"), 0x24)
        XCTAssertEqual(MacKeys.keyCode("tab"), 0x30)
        XCTAssertEqual(MacKeys.keyCode("space"), 0x31)
        XCTAssertEqual(MacKeys.keyCode(" "), 0x31)
        XCTAssertEqual(MacKeys.keyCode("delete"), 0x33)
        XCTAssertEqual(MacKeys.keyCode("escape"), 0x35)
        XCTAssertEqual(MacKeys.keyCode("forwarddelete"), 0x75)
        XCTAssertEqual(MacKeys.keyCode("left"), 0x7B)
        XCTAssertEqual(MacKeys.keyCode("up"), 0x7E)
        XCTAssertEqual(MacKeys.keyCode("home"), 0x73)
        XCTAssertEqual(MacKeys.keyCode("end"), 0x77)
        XCTAssertEqual(MacKeys.keyCode("pageup"), 0x74)
        XCTAssertEqual(MacKeys.keyCode("pagedown"), 0x79)
        XCTAssertEqual(MacKeys.keyCode("f1"), 0x7A)
        XCTAssertEqual(MacKeys.keyCode("F12"), 0x6F)
        XCTAssertNil(MacKeys.keyCode("f13"))
        XCTAssertNil(MacKeys.keyCode("hyper"))
        XCTAssertNil(MacKeys.keyCode("é"))

        // Every letter and digit has a distinct code.
        let all = "abcdefghijklmnopqrstuvwxyz0123456789".map { MacKeys.keyCode(String($0)) }
        XCTAssertFalse(all.contains(nil))
        XCTAssertEqual(Set(all.compactMap { $0 }).count, 36)
    }

    func testStrokes() {
        XCTAssertTrue(MacKeys.stroke("A")! == (0x00, .shift))
        XCTAssertTrue(MacKeys.stroke("?")! == (0x2C, .shift))
        XCTAssertTrue(MacKeys.stroke("!")! == (0x12, .shift))
        XCTAssertTrue(MacKeys.stroke("+")! == (0x18, .shift))
        XCTAssertTrue(MacKeys.stroke("a")! == (0x00, []))
    }

    func testCombos() throws {
        var combo = try MacKeys.parseCombo("cmd+shift+n")
        XCTAssertEqual(combo.key, "n")
        XCTAssertEqual(combo.modifiers, [.command, .shift])
        combo = try MacKeys.parseCombo("Ctrl-A")
        XCTAssertEqual(combo.key, "A")
        XCTAssertEqual(combo.modifiers, .control)
        combo = try MacKeys.parseCombo("⌘⇧N")
        XCTAssertEqual(combo.key, "N")
        XCTAssertEqual(combo.modifiers, [.command, .shift])
        combo = try MacKeys.parseCombo("cmd++")
        XCTAssertEqual(combo.key, "+")
        XCTAssertEqual(combo.modifiers, .command)
        combo = try MacKeys.parseCombo("cmd+-")
        XCTAssertEqual(combo.key, "-")
        combo = try MacKeys.parseCombo("return")
        XCTAssertEqual(combo.key, "return")
        XCTAssertEqual(combo.modifiers, [])
        combo = try MacKeys.parseCombo("page-down")
        XCTAssertEqual(combo.key, "page-down")
        combo = try MacKeys.parseCombo("option + f5")
        XCTAssertEqual(combo.key, "f5")
        XCTAssertEqual(combo.modifiers, .option)
        XCTAssertThrowsError(try MacKeys.parseCombo("hyper+a"))
        XCTAssertThrowsError(try MacKeys.parseCombo("cmd+nope"))
        XCTAssertThrowsError(try MacKeys.parseCombo(""))
    }

    func testTextChunks() {
        XCTAssertEqual(MacKeys.textChunks("hello"), ["hello"])
        XCTAssertEqual(MacKeys.textChunks(""), [])
        XCTAssertEqual(MacKeys.textChunks(String(repeating: "a", count: 45)).map(\.count), [20, 20, 5])
        XCTAssertEqual(MacKeys.textChunks("one\ntwo\tthree"), ["one", "\n", "two", "\t", "three"])
        XCTAssertEqual(MacKeys.textChunks("a\r\nb"), ["a", "\n", "b"])
        // Emoji are two UTF-16 units (or more) and never split.
        let emoji = String(repeating: "😀", count: 15)
        let chunks = MacKeys.textChunks(emoji)
        XCTAssertEqual(chunks.joined(), emoji)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 20 })
        XCTAssertEqual(chunks.first?.count, 10)
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(MacKeys.textChunks(family, limit: 4), [family], "a character longer than the limit goes alone")
    }
}
