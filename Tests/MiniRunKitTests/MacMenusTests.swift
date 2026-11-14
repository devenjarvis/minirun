import XCTest
@testable import MiniRunKit

final class MacMenusTests: XCTestCase {
    func testShortcut() {
        XCTAssertEqual(MacMenus.shortcut(character: "R", modifiers: 0, glyph: nil), "⌘R")
        XCTAssertEqual(MacMenus.shortcut(character: "r", modifiers: nil, glyph: nil), "⌘R")
        XCTAssertEqual(MacMenus.shortcut(character: "N", modifiers: MacMenus.shiftBit, glyph: nil), "⇧⌘N")
        XCTAssertEqual(MacMenus.shortcut(character: "K", modifiers: MacMenus.shiftBit | MacMenus.optionBit | MacMenus.controlBit, glyph: nil), "⌃⌥⇧⌘K")
        XCTAssertEqual(MacMenus.shortcut(character: "F", modifiers: MacMenus.controlBit | MacMenus.noCommandBit, glyph: nil), "⌃F")
        XCTAssertEqual(MacMenus.shortcut(character: nil, modifiers: 0, glyph: 0x17), "⌘⌫")
        XCTAssertEqual(MacMenus.shortcut(character: "", modifiers: MacMenus.noCommandBit, glyph: 0x6F), "F1")
        XCTAssertEqual(MacMenus.shortcut(character: "\u{8}", modifiers: 0, glyph: 0x17), "⌘⌫")
        XCTAssertNil(MacMenus.shortcut(character: nil, modifiers: 0, glyph: nil))
        XCTAssertNil(MacMenus.shortcut(character: " ", modifiers: 0, glyph: 0x999))
    }

    func testPickStatusItem() {
        let items = [
            MacMenus.StatusItemNames(title: nil, description: "Hello", identifier: "helloExtra"),
            MacMenus.StatusItemNames(title: "Timer 5:00", description: nil),
            MacMenus.StatusItemNames(description: "Hello World"),
        ]
        XCTAssertEqual(MacMenus.pickStatusItem("hello", in: items), 0)
        XCTAssertEqual(MacMenus.pickStatusItem("Hello World", in: items), 2)
        XCTAssertEqual(MacMenus.pickStatusItem("helloextra", in: items), 0)
        XCTAssertEqual(MacMenus.pickStatusItem("timer", in: items), 1)
        XCTAssertEqual(MacMenus.pickStatusItem("5:00", in: items), 1)
        XCTAssertNil(MacMenus.pickStatusItem("Weather", in: items))
        XCTAssertNil(MacMenus.pickStatusItem(nil, in: items))
        XCTAssertEqual(MacMenus.pickStatusItem(nil, in: [items[1]]), 0)
        XCTAssertEqual(MacMenus.pickStatusItem("*", in: [items[1]]), 0)
        XCTAssertNil(MacMenus.pickStatusItem(nil, in: []))
        XCTAssertEqual(items[0].display, "Hello")
        XCTAssertEqual(MacMenus.StatusItemNames().display, "(untitled)")
    }

    func testStatusItemMiss() {
        XCTAssertTrue(MacMenus.statusItemMiss("x", appName: "App", items: []).contains("no menu bar icon"))
        let items = [MacMenus.StatusItemNames(title: "A"), MacMenus.StatusItemNames(title: "B")]
        XCTAssertTrue(MacMenus.statusItemMiss(nil, appName: "App", items: items).contains("2 menu bar icons: \"A\", \"B\""))
        XCTAssertTrue(MacMenus.statusItemMiss("C", appName: "App", items: items).contains("No menu bar icon \"C\""))
    }

    func testNormalize() {
        XCTAssertEqual(MacMenus.normalize("  Settings… "), "settings")
        XCTAssertEqual(MacMenus.normalize("Open..."), "open")
    }

    func testCaptureRect() {
        let icon = MacMenus.Overlay(frame: MacRect(x: 1200, y: 0, width: 30, height: 24), layer: 25)
        let otherIcon = MacMenus.Overlay(frame: MacRect(x: 100, y: 0, width: 30, height: 24), layer: 25)
        let menu = MacMenus.Overlay(frame: MacRect(x: 1190, y: 24, width: 200, height: 300), layer: 101)
        XCTAssertTrue(icon.isStatusItem)
        XCTAssertFalse(menu.isStatusItem)
        XCTAssertNil(MacMenus.captureRect([]))
        // Only icons: just them.
        XCTAssertEqual(MacMenus.captureRect([icon], margin: 0), icon.frame)
        // A menu hanging off its icon takes the icon along, but not a far-away one.
        XCTAssertEqual(MacMenus.captureRect([icon, otherIcon, menu], margin: 0), MacRect(x: 1190, y: 0, width: 200, height: 324))
        XCTAssertEqual(MacMenus.captureRect([menu], margin: 8), MacRect(x: 1182, y: 16, width: 216, height: 316))
        // A popover panel at the status level is not an icon.
        let panel = MacMenus.Overlay(frame: MacRect(x: 1100, y: 30, width: 300, height: 400), layer: 25)
        XCTAssertFalse(panel.isStatusItem)
        XCTAssertEqual(MacMenus.captureRect([icon, panel], margin: 0), MacRect(x: 1100, y: 0, width: 300, height: 430))
    }

    func testClip() {
        let screen = MacRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(MacMenus.clip(MacRect(x: -8, y: -8, width: 100, height: 100), to: screen), MacRect(x: 0, y: 0, width: 92, height: 92))
        XCTAssertNil(MacMenus.clip(MacRect(x: 2000, y: 0, width: 10, height: 10), to: screen))
    }

    func testSummaryShowsMenuState() throws {
        let json = Data(#"[{"type":"MenuItem","AXLabel":"Pinned","enabled":true,"checked":true,"shortcut":"⌘P"}]"#.utf8)
        XCTAssertEqual(XcodeParsing.summarizeAccessibility(json), "MenuItem \"Pinned\" checked shortcut=⌘P")
    }
}
