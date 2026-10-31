import XCTest
@testable import MiniRunKit

final class MacToolsTests: XCTestCase {
    func testPlatform() throws {
        XCTAssertNil(try MacToolSupport.platform(argument: nil, device: nil))
        XCTAssertNil(try MacToolSupport.platform(argument: "", device: nil))
        XCTAssertEqual(try MacToolSupport.platform(argument: nil, device: "mac-3f9a2c"), .macos)
        XCTAssertEqual(try MacToolSupport.platform(argument: nil, device: "8A1B2C3D-0000-1111-2222-333344445555"), .ios)
        XCTAssertEqual(try MacToolSupport.platform(argument: "macOS", device: nil), .macos)
        XCTAssertEqual(try MacToolSupport.platform(argument: "mac-catalyst", device: nil), .macCatalyst)
        XCTAssertEqual(try MacToolSupport.platform(argument: "catalyst", device: "mac-3f9a2c"), .macCatalyst)
        XCTAssertEqual(try MacToolSupport.platform(argument: "ios", device: "iPhone 17 Pro"), .ios)
        XCTAssertThrowsError(try MacToolSupport.platform(argument: "tvos", device: nil))
        XCTAssertThrowsError(try MacToolSupport.platform(argument: "ios", device: "mac-3f9a2c"))
        XCTAssertThrowsError(try MacToolSupport.platform(argument: "macos", device: "8A1B2C3D-0000-1111-2222-333344445555"))
    }

    func testInputPath() throws {
        XCTAssertNil(try MacToolSupport.inputPath(nil))
        XCTAssertEqual(try MacToolSupport.inputPath("HID"), "hid")
        XCTAssertEqual(try MacToolSupport.inputPath("pid"), "pid")
        XCTAssertThrowsError(try MacToolSupport.inputPath("mouse"))
    }

    func testKeyAndModifiers() throws {
        var parsed = try MacToolSupport.keyAndModifiers(key: "s", modifiers: ["cmd"])
        XCTAssertEqual(parsed.key, "s")
        XCTAssertEqual(parsed.modifiers, .command)
        parsed = try MacToolSupport.keyAndModifiers(key: "cmd+shift+n", modifiers: [])
        XCTAssertEqual(parsed.key, "n")
        XCTAssertEqual(parsed.modifiers, [.command, .shift])
        // Punctuation the viewer sends as keys.
        for key in [",", "=", "[", "]", "-", ";", "'", ".", "/", "\\", "`"] {
            parsed = try MacToolSupport.keyAndModifiers(key: key, modifiers: ["command"])
            XCTAssertEqual(parsed.key, key)
            XCTAssertNotNil(MacKeys.keyCode(key), key)
        }
        XCTAssertEqual(MacKeys.keyCode("="), 0x18)
        XCTAssertEqual(MacKeys.keyCode("["), 0x21)
        XCTAssertEqual(MacKeys.keyCode("]"), 0x1E)
        XCTAssertEqual(MacKeys.keyCode("\\"), 0x2A)
        XCTAssertThrowsError(try MacToolSupport.keyAndModifiers(key: "s", modifiers: ["hyper"]))
        XCTAssertThrowsError(try MacToolSupport.keyAndModifiers(key: "nope", modifiers: []))
    }

    func testScrollDelta() throws {
        XCTAssertTrue(try MacToolSupport.scrollDelta(direction: "down", amount: nil, dx: nil, dy: nil) == (0, 300))
        XCTAssertTrue(try MacToolSupport.scrollDelta(direction: "up", amount: 50, dx: nil, dy: nil) == (0, -50))
        XCTAssertTrue(try MacToolSupport.scrollDelta(direction: "left", amount: 10, dx: nil, dy: nil) == (-10, 0))
        XCTAssertTrue(try MacToolSupport.scrollDelta(direction: nil, amount: nil, dx: nil, dy: 120) == (0, 120))
        XCTAssertThrowsError(try MacToolSupport.scrollDelta(direction: nil, amount: nil, dx: nil, dy: nil))
        XCTAssertThrowsError(try MacToolSupport.scrollDelta(direction: "sideways", amount: nil, dx: nil, dy: nil))
    }

    func testMenuPath() throws {
        XCTAssertEqual(try MacToolSupport.menuPath(["Counter", " Reset Counter "], text: nil), ["Counter", "Reset Counter"])
        XCTAssertEqual(try MacToolSupport.menuPath([], text: "File > New Window"), ["File", "New Window"])
        XCTAssertThrowsError(try MacToolSupport.menuPath([], text: nil))
    }

    func testPaths() {
        XCTAssertEqual(MacToolSupport.isolatedHome(appPath: "/x/Fetch.app", checkout: "/w/you/fetch@main", id: "mac-1", fallbackRoot: "/h"), "/w/you/fetch@main/.minirun/home")
        XCTAssertEqual(MacToolSupport.isolatedHome(appPath: "/w/fetch/.minirun/DerivedData/Build/Products/Debug/Fetch.app", id: "mac-1", fallbackRoot: "/h"), "/w/fetch/.minirun/home")
        XCTAssertEqual(MacToolSupport.isolatedHome(appPath: "/Applications/TextEdit.app", id: "mac-1", fallbackRoot: "/h"), "/h/mac-1")
        XCTAssertEqual(MacToolSupport.logPath(id: "mac-1", home: "/Users/me"), "/Users/me/Library/Logs/minirun/apps/mac-1.log")
        let log = "old run\n\n=== minirun launch 2026-01-01T00:00:00Z /a ===\nfirst\n\n=== minirun launch 2026-01-02T00:00:00Z /a ===\nHelloMacApp: launched\nboom\n"
        XCTAssertEqual(MacToolSupport.outputSinceLaunch(log), "HelloMacApp: launched\nboom")
        XCTAssertEqual(MacToolSupport.outputSinceLaunch("no marker"), "no marker")
        XCTAssertEqual(MacToolSupport.outputSinceLaunch("abcdef", limit: 2), "…ef")
        XCTAssertEqual(MacToolSupport.appName(appPath: "/x/Fetch.app"), "Fetch")
        XCTAssertEqual(MacToolSupport.appName(appPath: "/x/Fetch.app", productName: "Fetch Beta"), "Fetch Beta")
    }

    func testText() {
        let footer = MacToolSupport.footer(name: "Fetch", id: "mac-3f9a2c", viewerURL: "https://r.example/?device=mac-3f9a2c")
        XCTAssertTrue(footer.contains("Pass device: \"mac-3f9a2c\" on later calls"))
        XCTAssertTrue(footer.contains("https://r.example/?device=mac-3f9a2c"))

        let running = MacAppSession(id: "mac-aaaaaa", label: "you/fetch@main", name: "Fetch", appPath: "/a/Fetch.app", executablePath: "/a/Fetch.app/Contents/MacOS/Fetch", pid: 42)
        let unknown = MacToolSupport.unknownApp("mac-bbbbbb", known: [running])
        XCTAssertTrue(unknown.contains("No Mac app with id mac-bbbbbb"))
        XCTAssertTrue(unknown.contains("mac-aaaaaa: Fetch for you/fetch@main (running, pid 42)"))
        XCTAssertTrue(MacToolSupport.unknownApp("mac", known: []).contains("Mac app id"))

        let note = MacToolSupport.screenshotNote(width: 480, height: 300, windowIndex: 0, title: "Fetch", pointWidth: 480, pointHeight: 300)
        XCTAssertTrue(note.contains("window points from the window's top-left, title bar included"))
        XCTAssertTrue(note.contains("use them directly"))

        XCTAssertEqual(MacToolSupport.inputNote("pid"), "")
        XCTAssertTrue(MacToolSupport.inputNote("hid").contains("moved the real cursor"))

        XCTAssertTrue(MacToolSupport.earlyExit(name: "Fetch", exit: "killed by signal 9 (SIGKILL)", adHoc: true).contains("entitlements"))
        XCTAssertFalse(MacToolSupport.earlyExit(name: "Fetch", exit: "exited with status 1", adHoc: false).contains("entitlements"))

        for tool in ["press_button", "configure_simulator", "add_media", "install_app", "uninstall_app"] {
            XCTAssertFalse(MacToolSupport.unsupported(tool).contains("doesn't work"), tool)
        }
    }

    func testLiveMouse() {
        var mouse = MacLiveMouse()
        // A click: nothing until the button comes up, then one click where it went down.
        XCTAssertEqual(mouse.step(id: "mac-a", phase: "down", x: 10, y: 10), .none)
        XCTAssertEqual(mouse.step(id: "mac-a", phase: "move", x: 11, y: 11), .none)
        XCTAssertEqual(mouse.step(id: "mac-a", phase: "up", x: 11, y: 11), .click(x: 10, y: 10))
        // A drag: down where it started once it moves, then moves, then up.
        XCTAssertEqual(mouse.step(id: "mac-a", phase: "down", x: 10, y: 10), .none)
        XCTAssertEqual(mouse.step(id: "mac-a", phase: "move", x: 30, y: 10), .post([.init("down", 10, 10), .init("move", 30, 10)]))
        XCTAssertEqual(mouse.step(id: "mac-a", phase: "move", x: 40, y: 10), .post([.init("move", 40, 10)]))
        XCTAssertEqual(mouse.step(id: "mac-a", phase: "up", x: 40, y: 12), .post([.init("up", 40, 12)]))
        // Stray events, and apps kept apart.
        XCTAssertEqual(mouse.step(id: "mac-a", phase: "up", x: 0, y: 0), .none)
        XCTAssertEqual(mouse.step(id: "mac-a", phase: "move", x: 0, y: 0), .none)
        XCTAssertEqual(mouse.step(id: "mac-a", phase: "down", x: 1, y: 1), .none)
        XCTAssertEqual(mouse.step(id: "mac-b", phase: "up", x: 1, y: 1), .none)
        XCTAssertEqual(mouse.step(id: "mac-a", phase: "up", x: 1, y: 1), .click(x: 1, y: 1))
    }

    func testPermissionMessage() {
        let granted = MacPermissionReport(screenRecording: true, accessibility: true, hasDisplay: true, binaryPath: "/bin/minirun")
        XCTAssertTrue(MacToolSupport.permissionRequestMessage(granted).contains("are granted"))
        let missing = MacPermissionReport(screenRecording: false, accessibility: true, hasDisplay: false, binaryPath: "/bin/minirun")
        let text = MacToolSupport.permissionRequestMessage(missing)
        XCTAssertTrue(text.contains("Screen Recording"))
        XCTAssertFalse(text.contains("for /bin/minirun. Turn it on in System Settings → Privacy & Security → Screen Recording and Accessibility"))
        XCTAssertTrue(text.contains("restart minirun serve"))
        XCTAssertTrue(text.contains("no active display"))
    }

    func testPickerAndScreen() {
        let session = MacAppSession(id: "mac-aaaaaa", label: "you/fetch@main", name: "Fetch", bundleID: "dev.you.Fetch", appPath: "/a/Fetch.app", executablePath: "/a/Fetch.app/Contents/MacOS/Fetch", pid: 42)
        let entry = MacToolSupport.pickerEntry(session)
        XCTAssertEqual(entry["udid"]?.stringValue, "mac-aaaaaa")
        XCTAssertEqual(entry["kind"]?.stringValue, "mac")
        XCTAssertEqual(entry["reserved_for"]?.stringValue, "you/fetch@main")
        XCTAssertEqual(entry["state"]?.stringValue, "Booted")

        let screen = RelayProtocol.screen(key: "mac-aaaaaa", udid: "mac-aaaaaa", name: "Fetch", kind: "mac", pointWidth: 480, pointHeight: 300, pixelWidth: 960, pixelHeight: 600)
        XCTAssertEqual(screen["kind"]?.stringValue, "mac")
        XCTAssertNil(RelayProtocol.screen(udid: "X", name: "iPhone", pointWidth: 1, pointHeight: 1, pixelWidth: 1, pixelHeight: 1)["kind"])
        XCTAssertEqual(RelayProtocol.version, 5)
    }
}
