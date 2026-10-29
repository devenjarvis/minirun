import XCTest
@testable import MiniRunKit

final class JSONValueTests: XCTestCase {
    func testRoundTrip() throws {
        let value: JSONValue = ["a": 1, "b": [true, "x", 2.5], "c": nil]
        let decoded = try JSONValue.parse(value.encoded())
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded["a"]?.intValue, 1)
        XCTAssertEqual(value.encodedString(), #"{"a":1,"b":[true,"x",2.5],"c":null}"#)
    }

    func testArguments() {
        let args = ToolArguments(["x": 12.5, "s": "  hi ", "flag": "true", "list": ["a", "b"], "one": "c"])
        XCTAssertEqual(args.double("x"), 12.5)
        XCTAssertEqual(args.string("s"), "hi")
        XCTAssertEqual(args.rawString("s"), "  hi ")
        XCTAssertEqual(args.bool("flag"), true)
        XCTAssertEqual(args.strings("list"), ["a", "b"])
        XCTAssertEqual(args.strings("one"), ["c"])
        XCTAssertThrowsError(try args.requireString("missing"))
    }
}

final class RelayProtocolTests: XCTestCase {
    func testFrameEncoding() throws {
        let payload = Data([0xFF, 0xD8, 0x01, 0x02])
        let frame = RelayProtocol.encodeFrame(kind: .jpeg, sequence: 0x01020304, payload: payload)
        XCTAssertEqual([UInt8](frame.prefix(5)), [1, 1, 2, 3, 4])
        let decoded = try XCTUnwrap(RelayProtocol.decodeFrame(frame))
        XCTAssertEqual(decoded.kind, 1)
        XCTAssertEqual(decoded.sequence, 0x01020304)
        XCTAssertEqual(decoded.key, "")
        XCTAssertEqual(Data(decoded.payload), payload)

        let keyed = RelayProtocol.encodeFrame(key: "SIM-A", sequence: 9, payload: payload)
        XCTAssertEqual([UInt8](keyed.prefix(11)), [2, 0, 0, 0, 9, 5] + Array("SIM-A".utf8))
        let decodedKeyed = try XCTUnwrap(RelayProtocol.decodeFrame(keyed))
        XCTAssertEqual(decodedKeyed.key, "SIM-A")
        XCTAssertEqual(decodedKeyed.sequence, 9)
        XCTAssertEqual(Data(decodedKeyed.payload), payload)
        XCTAssertNil(RelayProtocol.decodeFrame(Data([2, 0, 0, 0, 1, 9, 65])), "key longer than the frame")
    }

    func testDecodeMessages() {
        XCTAssertEqual(
            RelayProtocol.decode(#"{"type":"call","id":"7","tool":"tap","arguments":{"x":1}}"#),
            .call(id: "7", tool: "tap", arguments: ["x": 1])
        )
        XCTAssertEqual(RelayProtocol.decode(#"{"type":"call","tool":"tap"}"#), .call(id: nil, tool: "tap", arguments: [:]))
        XCTAssertEqual(RelayProtocol.decode(#"{"type":"stream","action":"stop"}"#), .streams([]))
        XCTAssertEqual(
            RelayProtocol.decode(#"{"type":"stream","action":"start","fps":100,"quality":5,"scale":0.5}"#),
            .streams([.init(key: "", fps: 30, quality: 10, scale: 0.5)]),
            "version 1 relays"
        )
        XCTAssertEqual(
            RelayProtocol.decode(#"{"type":"stream","action":"set","streams":[{"udid":null,"fps":12,"quality":60,"scale":0.5},{"udid":"SIM-B","fps":6,"quality":45,"scale":0.33}]}"#),
            .streams([.init(key: "", fps: 12, quality: 60, scale: 0.5), .init(key: "SIM-B", fps: 6, quality: 45, scale: 0.33)])
        )
        XCTAssertEqual(RelayProtocol.decode(#"{"type":"ack","seq":42}"#), .ack(sequence: 42, key: ""))
        XCTAssertEqual(RelayProtocol.decode(#"{"type":"ack","seq":42,"key":"SIM-B"}"#), .ack(sequence: 42, key: "SIM-B"))
        if case .unknown = RelayProtocol.decode("garbage") {} else { XCTFail("expected unknown") }
    }

    func testResultShape() {
        let result = ToolResult([.text("hi"), .image(data: Data([1, 2]), mimeType: "image/jpeg")])
        let message = RelayProtocol.result(id: "1", result: result)
        XCTAssertEqual(message["result"]?["content"]?.arrayValue?.count, 2)
        XCTAssertEqual(message["result"]?["content"]?.arrayValue?[1]["data"]?.stringValue, "AQI=")
        XCTAssertEqual(message["result"]?["isError"], false)
    }
}

final class XcodeParsingTests: XCTestCase {
    let devicesJSON = """
    {"devices":{
      "com.apple.CoreSimulator.SimRuntime.iOS-18-6":[{"udid":"A","name":"iPhone 16","state":"Shutdown","isAvailable":true}],
      "com.apple.CoreSimulator.SimRuntime.iOS-26-0":[
        {"udid":"B","name":"iPhone 17 Pro","state":"Shutdown","isAvailable":true},
        {"udid":"C","name":"iPhone SE (3rd generation)","state":"Shutdown","isAvailable":true},
        {"udid":"D","name":"iPad Air","state":"Booted","isAvailable":true},
        {"udid":"E","name":"Broken","state":"Shutdown","isAvailable":false}],
      "com.apple.CoreSimulator.SimRuntime.watchOS-26-0":[{"udid":"W","name":"Apple Watch","state":"Shutdown","isAvailable":true}]
    }}
    """

    func testParseAndPickDevices() throws {
        let devices = try XcodeParsing.parseDevices(Data(devicesJSON.utf8))
        XCTAssertEqual(devices.first?.udid, "D", "booted first")
        XCTAssertEqual(devices.first?.runtimeName, "iOS 26.0")
        XCTAssertEqual(XcodeParsing.pickDevice(devices, query: nil)?.udid, "D")
        XCTAssertEqual(XcodeParsing.pickDevice(devices, query: "b")?.udid, "B")
        XCTAssertEqual(XcodeParsing.pickDevice(devices, query: "iphone 16")?.udid, "A")
        XCTAssertNil(XcodeParsing.pickDevice(devices, query: "Broken"))

        let none = devices.map { XcodeParsing.SimDevice(udid: $0.udid, name: $0.name, state: "Shutdown", runtime: $0.runtime, isAvailable: $0.isAvailable) }
        XCTAssertEqual(XcodeParsing.pickDevice(none, query: nil)?.udid, "B", "newest non-SE iPhone")
        XCTAssertEqual(XcodeParsing.pickDevice(none, query: nil, preferredName: "iPhone 16")?.udid, "A")
        XCTAssertNil(XcodeParsing.pickDevice(none, query: "booted"))
    }

    func testParseIssues() {
        let log = """
        CompileSwift normal arm64 /src/App/ContentView.swift
        /src/App/ContentView.swift:12:9: error: cannot find 'foo' in scope
        /src/App/ContentView.swift:12:9: error: cannot find 'foo' in scope
        /src/App/Model.swift:3:5: warning: variable 'x' was never used
        ld: error: undefined symbol: _bar
        xcodebuild: error: Unable to find a destination matching the provided destination specifier
        ** BUILD FAILED **
        """
        let errors = XcodeParsing.parseIssues(log)
        XCTAssertEqual(errors.count, 3)
        XCTAssertEqual(errors[0].location, "/src/App/ContentView.swift:12:9")
        XCTAssertEqual(errors[0].message, "cannot find 'foo' in scope")
        XCTAssertEqual(errors[2].message, "Unable to find a destination matching the provided destination specifier")
        XCTAssertEqual(XcodeParsing.parseIssues(log, includeWarnings: true).filter { $0.severity == "warning" }.count, 1)
    }

    func testSchemesAndProduct() {
        XCTAssertEqual(XcodeParsing.parseSchemes(Data(#"{"project":{"name":"App","schemes":["App","AppTests"]}}"#.utf8)), ["App", "AppTests"])
        XCTAssertEqual(XcodeParsing.parseSchemes(Data(#"{"workspace":{"name":"W","schemes":["W"]}}"#.utf8)), ["W"])

        let settings = """
        [{"target":"AppKitLib","buildSettings":{"WRAPPER_EXTENSION":"framework","TARGET_BUILD_DIR":"/d","WRAPPER_NAME":"Lib.framework"}},
         {"target":"App","buildSettings":{"WRAPPER_EXTENSION":"app","TARGET_BUILD_DIR":"/dd/Debug-iphonesimulator","WRAPPER_NAME":"App.app","PRODUCT_BUNDLE_IDENTIFIER":"com.x.app"}}]
        """
        let product = XcodeParsing.parseAppProduct(Data(settings.utf8))
        XCTAssertEqual(product?.appPath, "/dd/Debug-iphonesimulator/App.app")
        XCTAssertEqual(product?.bundleIdentifier, "com.x.app")
    }

    func testAccessibilitySummary() {
        let json = """
        [{"type":"Application","AXLabel":"Settings","frame":{"x":0,"y":0,"width":402,"height":874},
          "children":[{"type":"Button","AXLabel":"General","AXUniqueId":"com.apple.settings.general","frame":{"x":16,"y":300.5,"width":370,"height":52}},
                      {"type":"Switch","AXLabel":"Airplane Mode","AXValue":"0","enabled":false,"frame":{"x":16,"y":200,"width":370,"height":52}}]}]
        """
        let text = XcodeParsing.summarizeAccessibility(Data(json.utf8))
        XCTAssertEqual(text, """
        Application "Settings" (0,0 402x874)
          Button "General" id=com.apple.settings.general (16,300 370x52)
          Switch "Airplane Mode" value="0" (16,200 370x52) disabled
        """)
        let size = XcodeParsing.screenPointSize(fromAccessibility: Data(json.utf8))
        XCTAssertEqual(size?.width, 402)
        XCTAssertEqual(size?.height, 874)
    }
}

final class ConfigTests: XCTestCase {
    func testResolveRepo() throws {
        let config = MiniRunConfig()
        XCTAssertEqual(try config.resolveRepo("me/app").url, "https://github.com/me/app.git")
        XCTAssertEqual(try config.resolveRepo("me/app").slug, "me/app")
        XCTAssertEqual(try config.resolveRepo("https://github.com/me/app.git").slug, "me/app")
        XCTAssertEqual(try config.resolveRepo("git@github.com:me/app.git").slug, "me/app")
        XCTAssertThrowsError(try config.resolveRepo("../etc"))
        XCTAssertThrowsError(try config.resolveRepo("a/../b"))
    }

    func testDecodesPartialConfig() throws {
        let config = try JSONDecoder().decode(MiniRunConfig.self, from: Data(#"{"relayURL":"wss://x/agent"}"#.utf8))
        XCTAssertEqual(config.relayURL, "wss://x/agent")
        XCTAssertFalse(config.allowShell)
        XCTAssertTrue(config.preventSleep)
    }
}

final class ShellAndJobTests: XCTestCase {
    func testShellCapturesOutput() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertFalse(result.succeeded)
    }

    func testShellTimeout() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "exec sleep 10"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        // SIGTERM, then SIGKILL 5s later if needed (corelibs Foundation on Linux can need the latter).
        XCTAssertLessThan(result.duration, 8)
    }

    func testShellStdin() async throws {
        let result = try await Shell.run("/bin/cat", [], stdin: Data("hello".utf8))
        XCTAssertEqual(result.stdout, "hello")
    }

    func testJobWaitsAndTimesOut() async throws {
        let jobs = JobStore()
        let quick = await jobs.start(title: "quick", logPath: nil) { .text("done") }
        let quickReport = await jobs.report(quick, waited: 5)
        XCTAssertTrue(quickReport.content.description.contains("done"))
        XCTAssertFalse(quickReport.isError)

        let slow = await jobs.start(title: "slow", logPath: nil) {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return .error("boom")
        }
        let started = Date()
        let pending = await jobs.report(slow, waited: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertTrue(pending.content.description.contains("still running"))
        let final = await jobs.report(slow, waited: 5)
        XCTAssertTrue(final.isError)
        XCTAssertTrue(final.content.description.contains("boom"))
    }
}

final class SimulatorPickerTests: XCTestCase {
    typealias Device = XcodeParsing.SimDevice
    let now = Date(timeIntervalSince1970: 1_000_000)
    let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
    let proType = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"

    func device(_ udid: String, _ name: String, booted: Bool = false) -> Device {
        Device(udid: udid, name: name, state: booted ? "Booted" : "Shutdown", runtime: runtime, isAvailable: true, deviceType: proType)
    }

    func claim(_ label: String?, minutesAgo: Double = 1) -> SimulatorClaim {
        SimulatorClaim(label: label, updatedAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    func udid(_ choice: SimulatorPicker.Choice) -> String? {
        if case .use(let device, _) = choice { return device.udid }
        return nil
    }

    func message(_ choice: SimulatorPicker.Choice) -> String {
        if case .failure(let text) = choice { return text }
        return ""
    }

    func testPlainToolsNeverGuessBetweenBootedSimulators() {
        let devices = [device("A", "iPhone 17 Pro", booted: true), device("B", "iPhone 17", booted: true), device("C", "iPhone 17 Pro Max")]
        let claims = ["A": claim("you/app@feature-a"), "B": claim("you/other")]

        let ambiguous = SimulatorPicker.target(query: nil, workspace: nil, devices: devices, claims: claims, preferredName: nil, now: now)
        XCTAssertTrue(message(ambiguous).contains("2 simulators are booted"))
        XCTAssertTrue(message(ambiguous).contains("- A  iPhone 17 Pro (iOS 26.0) — reserved for you/app@feature-a, used 1 min ago"))
        XCTAssertTrue(message(ambiguous).contains("boot_simulator"))

        XCTAssertEqual(udid(SimulatorPicker.target(query: "B", workspace: nil, devices: devices, claims: claims, preferredName: nil)), "B", "UDID wins")
        XCTAssertEqual(udid(SimulatorPicker.target(query: "iphone 17", workspace: nil, devices: devices, claims: claims, preferredName: nil)), "B", "unique name")
        XCTAssertEqual(udid(SimulatorPicker.target(query: "iPhone 17 Pro Max", workspace: nil, devices: devices, claims: claims, preferredName: nil)), "C", "boots by name")
        XCTAssertTrue(message(SimulatorPicker.target(query: "Pixel", workspace: nil, devices: devices, claims: claims, preferredName: nil)).contains("No available simulator matches"))

        let one = [device("A", "iPhone 17 Pro", booted: true), device("C", "iPhone 17 Pro Max")]
        XCTAssertEqual(udid(SimulatorPicker.target(query: nil, workspace: nil, devices: one, claims: [:], preferredName: nil)), "A", "the only booted one")
        let none = [device("A", "iPhone 17 Pro"), device("C", "iPhone 17 Pro Max")]
        XCTAssertEqual(udid(SimulatorPicker.target(query: nil, workspace: nil, devices: none, claims: [:], preferredName: "iPhone 17 Pro Max")), "C", "boots the default")
    }

    func testBuildsFindTheirOwnSimulator() {
        let devices = [device("A", "iPhone 17 Pro", booted: true), device("B", "iPhone 17 Pro"), device("C", "iPhone 17", booted: true)]
        let claims = ["A": claim("you/app@feature-a"), "C": claim("you/app@feature-c")]

        XCTAssertEqual(udid(SimulatorPicker.target(query: nil, workspace: "you/app@feature-c", devices: devices, claims: claims, preferredName: nil)), "C")

        // Another branch of the same app gets a separate simulator instead of taking one.
        let other = SimulatorPicker.target(query: nil, workspace: "you/app@feature-b", devices: devices, claims: claims, preferredName: "iPhone 17 Pro")
        guard case .use(let fresh, let note) = other else { return XCTFail("expected a fresh simulator, got \(other)") }
        XCTAssertEqual(fresh.udid, "B")
        XCTAssertNotNil(note)

        // An unreserved booted simulator is adopted.
        let adopted = SimulatorPicker.target(query: nil, workspace: "you/app@x", devices: devices, claims: ["A": claim("you/app@feature-a")], preferredName: nil)
        XCTAssertEqual(udid(adopted), "C")

        // Naming a simulator reserved for other work is refused unless it's by UDID.
        let named = SimulatorPicker.target(query: "iPhone 17", workspace: "you/app@x", devices: devices, claims: claims, preferredName: nil)
        XCTAssertTrue(message(named).contains("reserved for you/app@feature-c"))
        XCTAssertEqual(udid(SimulatorPicker.target(query: "C", workspace: "you/app@x", devices: devices, claims: claims, preferredName: nil)), "C")

        // Too many running: stop and ask.
        let busy = SimulatorPicker.target(query: nil, workspace: "you/app@x", devices: devices, claims: claims, preferredName: nil, maxBooted: 2)
        XCTAssertTrue(message(busy).contains("already running"))
    }

    func testBootGivesEachSessionItsOwnSimulator() {
        var devices = [device("A", "iPhone 17 Pro", booted: true), device("B", "iPhone 17")]
        let claims = ["A": claim("you/app@a")]

        XCTAssertEqual(udid(SimulatorPicker.fresh(query: nil, label: "you/app@a", devices: devices, claims: claims, preferredName: nil)), "A", "same label, same simulator")
        XCTAssertEqual(udid(SimulatorPicker.fresh(query: nil, label: "you/app@b", devices: devices, claims: claims, preferredName: "iPhone 17 Pro")), "B", "an idle iPhone")

        // Every iPhone 17 Pro is busy: make another.
        let copy = SimulatorPicker.fresh(query: "iPhone 17 Pro", label: "you/app@b", devices: devices, claims: claims, preferredName: nil)
        XCTAssertEqual(copy, .create(name: "iPhone 17 Pro (minirun 2)", like: devices[0]))

        // A copy that's idle is reused for that model, and numbering skips taken names.
        devices.append(device("P2", "iPhone 17 Pro (minirun 2)", booted: true))
        devices.append(device("P3", "iPhone 17 Pro (minirun 3)"))
        XCTAssertEqual(udid(SimulatorPicker.fresh(query: "iPhone 17 Pro", label: nil, devices: devices, claims: claims, preferredName: nil)), "P3")
        devices[3] = device("P3", "iPhone 17 Pro (minirun 3)", booted: true)
        XCTAssertEqual(
            SimulatorPicker.fresh(query: "iPhone 17 Pro", label: nil, devices: devices, claims: claims, preferredName: nil),
            .create(name: "iPhone 17 Pro (minirun 4)", like: devices[0])
        )
        XCTAssertEqual(udid(SimulatorPicker.fresh(query: "A", label: nil, devices: devices, claims: claims, preferredName: nil)), "A", "UDID wins")
    }

    func testClaimStorePersistsAndPrunes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minirun-claims-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SimulatorClaimStore(url: url)
        let none = await store.reserve("A", for: "you/app@a")
        XCTAssertNil(none)
        await store.noteApp("A", bundleID: "com.you.app")
        let previous = await store.reserve("A", for: "you/app@b")
        XCTAssertEqual(previous, "you/app@a")
        await store.reserve("B", for: "you/other")

        let reloaded = SimulatorClaimStore(url: url)
        let claims = await reloaded.snapshot(booted: ["A"])
        XCTAssertEqual(claims["A"]?.label, "you/app@b")
        XCTAssertNil(claims["A"]?.bundleID, "a new reservation starts clean")
        XCTAssertNil(claims["B"], "simulators that aren't booted lose their reservation")
    }
}

private actor EventLog {
    var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

final class WorkspaceTests: XCTestCase {
    func testDirectoriesPerRef() {
        XCTAssertEqual(WorkspaceNaming.directory(slug: "you/app", ref: nil), "you/app")
        XCTAssertEqual(WorkspaceNaming.directory(slug: "you/app", ref: " "), "you/app")
        XCTAssertEqual(WorkspaceNaming.directory(slug: "you/app", ref: "feature-x_1.2"), "you/app@feature-x_1.2")
        let slashed = WorkspaceNaming.directory(slug: "you/app", ref: "feature/x")
        XCTAssertTrue(slashed.hasPrefix("you/app@feature-x-"))
        XCTAssertEqual(slashed.count, "you/app@feature-x-".count + 8)
        XCTAssertNotEqual(slashed, WorkspaceNaming.directory(slug: "you/app", ref: "feature-x"), "no collisions")
        XCTAssertFalse(WorkspaceNaming.directory(slug: "you/app", ref: "../../etc").contains("/.."))
        XCTAssertEqual(WorkspaceNaming.label(slug: "you/app", ref: "feature/x"), "you/app@feature/x")
        XCTAssertEqual(WorkspaceNaming.label(slug: "you/app", ref: nil), "you/app")
    }

    func testViewerURL() {
        var config = MiniRunConfig(relayURL: "wss://minirun.you.workers.dev/agent")
        XCTAssertEqual(config.viewerURL(device: "ABC-1"), "https://minirun.you.workers.dev/?device=ABC-1")
        XCTAssertEqual(config.viewerURL(device: nil), "https://minirun.you.workers.dev/")
        config.relayURL = "ws://127.0.0.1:8787/agent"
        XCTAssertEqual(config.viewerURL(device: nil), "http://127.0.0.1:8787/")
        config.relayURL = nil
        XCTAssertNil(config.viewerURL(device: "x"))
    }

    func testKeyedLockSerializesPerKey() async throws {
        let lock = KeyedLock()
        let log = EventLog()
        async let first: Void = lock.withLock("a") {
            await log.add("first start")
            try await Task.sleep(nanoseconds: 100_000_000)
            await log.add("first end")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        async let second: Void = lock.withLock("a") { await log.add("second") }
        async let other: Void = lock.withLock("b") { await log.add("other") }
        _ = try await (first, second, other)
        let events = await log.events
        XCTAssertEqual(events.filter { $0 != "other" }, ["first start", "first end", "second"])
        XCTAssertLessThan(events.firstIndex(of: "other")!, events.firstIndex(of: "first end")!, "other keys don't wait")
    }
}
