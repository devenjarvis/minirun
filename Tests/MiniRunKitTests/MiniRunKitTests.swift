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

        let video = RelayProtocol.encodeVideoFrame(key: "SIM-A", sequence: 3, keyframe: true, payload: Data([0, 0, 0, 1, 0x65]))
        XCTAssertEqual([UInt8](video), [3, 0, 0, 0, 3, 5] + Array("SIM-A".utf8) + [1, 0, 0, 0, 1, 0x65])
        let decodedVideo = try XCTUnwrap(RelayProtocol.decodeFrame(video))
        XCTAssertEqual(decodedVideo.key, "SIM-A")
        XCTAssertEqual([UInt8](decodedVideo.payload), [1, 0, 0, 0, 1, 0x65], "flags byte, then Annex B")
        XCTAssertEqual(RelayProtocol.encodeVideoFrame(key: "", sequence: 4, keyframe: false, payload: Data([9]))[6], 0)
    }

    func testAnnexB() throws {
        let sps = Data([0x67, 0x4D, 0x40, 0x1F])
        let pps = Data([0x68, 0xEE])
        let avcc = Data([0, 0, 0, 2, 0x65, 0xAA, 0, 0, 0, 1, 0x06])
        let annexB = try XCTUnwrap(H264.annexB(lengthPrefixed: avcc, parameterSets: [sps, pps]))
        XCTAssertEqual([UInt8](annexB), [0, 0, 0, 1, 0x67, 0x4D, 0x40, 0x1F, 0, 0, 0, 1, 0x68, 0xEE, 0, 0, 0, 1, 0x65, 0xAA, 0, 0, 0, 1, 0x06])
        XCTAssertEqual([UInt8](try XCTUnwrap(H264.annexB(lengthPrefixed: Data([0, 1, 0x41]), lengthSize: 2))), [0, 0, 0, 1, 0x41])
        XCTAssertNil(H264.annexB(lengthPrefixed: Data([0, 0, 0, 5, 0x65])), "length past the end")
        XCTAssertNil(H264.annexB(lengthPrefixed: Data([0, 0])), "truncated length")
        XCTAssertEqual(H264.annexB(lengthPrefixed: Data()), Data())
    }

    func testSPSWithoutReordering() throws {
        // A VideoToolbox Constrained Baseline SPS (698x1016, one reference frame, no VUI).
        let sps = Data([0x27, 0x42, 0xc0, 0x1f, 0xab, 0x40, 0x58, 0x04, 0x0f, 0x24, 0xa8])
        let rewritten = [UInt8](H264.withoutReordering(sps: sps))
        XCTAssertEqual(Array(rewritten.prefix(4)), [0x27, 0x42, 0xc0, 0x1f], "header, profile and level unchanged")

        var r = H264.BitReader(H264.unescape(Array(rewritten.dropFirst(4))))
        // sps id, log2_max_frame_num, poc type, log2_max_poc_lsb, refs, gaps, width, height
        XCTAssertEqual([r.ue(), r.ue(), r.ue(), r.ue(), r.ue(), r.bit(), r.ue(), r.ue()], [0, 1, 0, 2, 1, 0, 43, 63])
        XCTAssertEqual([r.bit(), r.bit(), r.bit()], [1, 1, 1], "frame_mbs_only, direct_8x8, cropping")
        XCTAssertEqual([r.ue(), r.ue(), r.ue(), r.ue()], [0, 3, 0, 4], "crop offsets kept")
        XCTAssertEqual(r.bit(), 1, "now has a VUI")
        XCTAssertEqual(r.bits(8), 0)
        XCTAssertEqual([r.bit(), r.bit()], [1, 1], "bitstream_restriction, mv over boundaries")
        XCTAssertEqual([r.ue(), r.ue(), r.ue(), r.ue(), r.ue(), r.ue()], [0, 0, 15, 15, 0, 1], "no reordering, one frame buffered")
        XCTAssertEqual(r.bit(), 1, "stop bit")

        XCTAssertEqual(H264.withoutReordering(sps: Data(rewritten)), Data(rewritten), "already has a VUI")
        XCTAssertEqual(H264.withoutReordering(sps: Data([0x28, 0xce, 0x3c, 0x80])), Data([0x28, 0xce, 0x3c, 0x80]), "not an SPS")
        XCTAssertEqual(H264.escape([0, 0, 1, 0, 0, 0]), [0, 0, 3, 1, 0, 0, 3, 0])
        XCTAssertEqual(H264.unescape([0, 0, 3, 1, 0, 0, 3, 0]), [0, 0, 1, 0, 0, 0])
    }

    func testBitrate() {
        let smooth = H264.bitrate(width: 602, height: 1310, fps: 30, quality: 55)
        XCTAssertGreaterThan(smooth, 1_000_000)
        XCTAssertLessThan(smooth, 2_000_000)
        XCTAssertEqual(H264.bitrate(width: 100, height: 100, fps: 1, quality: 10), 150_000)
        XCTAssertEqual(H264.bitrate(width: 4000, height: 4000, fps: 30, quality: 95), 8_000_000)
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
        XCTAssertEqual(
            RelayProtocol.decode(#"{"type":"stream","action":"set","streams":[{"udid":"SIM-A","fps":30,"quality":55,"scale":0.5,"codec":"h264"},{"udid":"SIM-B","codec":"vp9"}]}"#),
            .streams([.init(key: "SIM-A", fps: 30, quality: 55, scale: 0.5, codec: .h264), .init(key: "SIM-B", fps: 12, quality: 60, scale: 0.5)]),
            "unknown codecs fall back to JPEG"
        )
        XCTAssertEqual(RelayProtocol.decode(#"{"type":"keyframe","key":"SIM-A"}"#), .keyframe(key: "SIM-A"))
        XCTAssertEqual(
            RelayProtocol.decode(#"{"type":"touch","device":"SIM-A","phase":"move","x":12.5,"y":40}"#),
            .touch(udid: "SIM-A", phase: "move", x: 12.5, y: 40)
        )
        XCTAssertEqual(RelayProtocol.decode(#"{"type":"touch","phase":"down","x":1,"y":2}"#), .unknown(#"{"type":"touch","phase":"down","x":1,"y":2}"#), "no device")
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

    func testDefaultiPhoneSkipsDuoAndPrefersNewestPro() throws {
        // The Duo alone on the newest runtime sorts first, but it's a foldable: never the default.
        let json = """
        {"devices":{
          "com.apple.CoreSimulator.SimRuntime.iOS-27-1":[{"udid":"DUO","name":"iPhone Duo","state":"Shutdown","isAvailable":true}],
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
            {"udid":"17","name":"iPhone 17","state":"Shutdown","isAvailable":true},
            {"udid":"17e","name":"iPhone 17e","state":"Shutdown","isAvailable":true},
            {"udid":"AIR","name":"iPhone Air","state":"Shutdown","isAvailable":true},
            {"udid":"18PM","name":"iPhone 18 Pro Max","state":"Shutdown","isAvailable":true},
            {"udid":"18P","name":"iPhone 18 Pro","state":"Shutdown","isAvailable":true}]
        }}
        """
        let devices = try XcodeParsing.parseDevices(Data(json.utf8))
        XCTAssertEqual(devices.first?.udid, "DUO")
        XCTAssertEqual(XcodeParsing.defaultiPhones(devices).map(\.udid), ["18P", "18PM", "17", "17e", "AIR"])
        XCTAssertEqual(XcodeParsing.pickDevice(devices, query: nil)?.udid, "18P")
        XCTAssertEqual(XcodeParsing.defaultiPhones(devices.filter { $0.udid == "DUO" }), [], "asking for the Duo by name still works; it's only never the default")
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
        XCTAssertEqual(config.idleShutdownMinutes, 30)
        XCTAssertEqual(config.maxBootedSimulators, 4)
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

    func testFreshSkipsTheDuo() {
        let duo = Device(udid: "DUO", name: "iPhone Duo", state: "Shutdown", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1", isAvailable: true)
        let devices = [duo, device("17", "iPhone 17"), device("18P", "iPhone 18 Pro")]
        XCTAssertEqual(udid(SimulatorPicker.fresh(query: nil, label: "you/app@x", devices: devices, claims: [:], preferredName: nil)), "18P")
        XCTAssertEqual(udid(SimulatorPicker.fresh(query: "iPhone Duo", label: "you/app@x", devices: devices, claims: [:], preferredName: nil)), "DUO", "still there by name")
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

    func testBootRespectsTheLimit() {
        let devices = [device("A", "iPhone 17 Pro", booted: true), device("B", "iPhone 17 Pro", booted: true), device("C", "iPhone 17 Pro")]
        let claims = ["A": claim("you/app@a"), "B": claim("you/app@b")]
        let full = SimulatorPicker.fresh(query: nil, label: "you/app@c", devices: devices, claims: claims, preferredName: nil, maxBooted: 2, now: now)
        XCTAssertTrue(message(full).contains("2 simulators are already running"))
        XCTAssertTrue(message(full).contains("shutdown_simulator"))
        XCTAssertEqual(udid(SimulatorPicker.fresh(query: nil, label: "you/app@a", devices: devices, claims: claims, preferredName: nil, maxBooted: 2)), "A", "your own is still yours")
        XCTAssertEqual(udid(SimulatorPicker.fresh(query: nil, label: "you/app@c", devices: devices, claims: claims, preferredName: nil, maxBooted: 3)), "C")
    }

    func testIdleSimulatorsShutDownButOneStaysWarm() {
        let a = device("A", "iPhone 17 Pro", booted: true), b = device("B", "iPhone 17", booted: true), c = device("C", "iPhone 17 Pro Max", booted: true)
        let hour: TimeInterval = 3600

        // Both idle: the more recent one stays up, freed for other work.
        var claims = ["A": claim("you/app@a", minutesAgo: 90), "B": claim("you/app@b", minutesAgo: 70)]
        XCTAssertEqual(IdleSimulators.plan(booted: [a, b], claims: claims, busy: [], idleAfter: hour, now: now), [.unreserve("B"), .shutdown("A")])

        // A spare that's already free is left as it is.
        claims["B"] = claim(nil, minutesAgo: 70)
        XCTAssertEqual(IdleSimulators.plan(booted: [b], claims: claims, busy: [], idleAfter: hour, now: now), [])

        // Something else is still running, so every idle one goes.
        claims["C"] = claim("you/app@c", minutesAgo: 5)
        XCTAssertEqual(IdleSimulators.plan(booted: [a, b, c], claims: claims, busy: [], idleAfter: hour, now: now), [.shutdown("B"), .shutdown("A")])

        // A job or a viewer keeps a simulator up however long ago a tool touched it.
        XCTAssertEqual(IdleSimulators.plan(booted: [a, b], claims: claims, busy: ["A"], idleAfter: hour, now: now), [.shutdown("B")])

        // Simulators minirun never used are left alone, and so is everything when turned off.
        XCTAssertEqual(IdleSimulators.plan(booted: [a, c], claims: ["C": claim(nil, minutesAgo: 5)], busy: [], idleAfter: hour, now: now), [])
        XCTAssertEqual(IdleSimulators.plan(booted: [a, b], claims: claims, busy: [], idleAfter: 0, now: now), [])
    }

    func testBootsRunOnceAndReportFailures() async throws {
        let boots = SimulatorBoots()
        let log = EventLog()
        let first = await boots.start("A") {
            await log.add("boot A")
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let second = await boots.start("A") { await log.add("boot A again") }
        let booting = await boots.booting
        XCTAssertEqual(booting, ["A"])
        let joined = await boots.task("A")
        XCTAssertNotNil(joined)
        try await first.value
        try await second.value
        let events = await log.events
        XCTAssertEqual(events, ["boot A"], "a second start joins the running boot")
        var stillBooting = true
        for _ in 0..<50 {
            stillBooting = await boots.isBooting("A")
            if !stillBooting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(stillBooting, "a finished boot is no longer listed")

        let failing = await boots.start("B") { throw ToolError("no runtime") }
        do {
            try await failing.value
            XCTFail("expected the boot to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no runtime"))
        }
    }

    func testActivityCountsOverlappingWork() async {
        let activity = SimulatorActivity()
        await activity.begin("A")
        await activity.begin("A")
        await activity.end("A")
        var busy = await activity.busy
        XCTAssertEqual(busy, ["A"], "a viewer and a job overlap")
        await activity.end("A")
        await activity.end("A")
        busy = await activity.busy
        XCTAssertEqual(busy, [])
    }

    func testClaimStoreSavesUseTimesAndUnreserves() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minirun-claims-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SimulatorClaimStore(url: url)
        await store.reserve("A", for: "you/app@a", now: now)
        await store.touch("A", now: now.addingTimeInterval(30))
        var reloaded = await SimulatorClaimStore(url: url).snapshot(booted: ["A"])
        XCTAssertEqual(reloaded["A"]?.updatedAt, now, "touches within a minute aren't written")
        await store.touch("A", now: now.addingTimeInterval(120))
        reloaded = await SimulatorClaimStore(url: url).snapshot(booted: ["A"])
        XCTAssertEqual(reloaded["A"]?.updatedAt, now.addingTimeInterval(120))

        await store.unreserve("A")
        reloaded = await SimulatorClaimStore(url: url).snapshot(booted: ["A"])
        XCTAssertNil(reloaded["A"]?.label)
        XCTAssertEqual(reloaded["A"]?.updatedAt, now.addingTimeInterval(120), "freeing it doesn't count as using it")
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

    /// Waits up to `seconds` for `event` to be logged; false if it never was.
    func waitFor(_ event: String, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !events.contains(event) {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }
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
        // "a" stays held until "other" has run, so if other keys waited this would time out
        // instead of depending on how quickly a busy CI runner schedules tasks.
        async let first: Void = lock.withLock("a") {
            await log.add("first start")
            _ = await log.waitFor("other")
            await log.add("first end")
        }
        let firstHoldsTheLock = await log.waitFor("first start")
        XCTAssertTrue(firstHoldsTheLock)
        async let second: Void = lock.withLock("a") { await log.add("second") }
        async let other: Void = lock.withLock("b") { await log.add("other") }
        _ = try await (first, second, other)
        let events = await log.events
        XCTAssertEqual(events.filter { $0 != "other" }, ["first start", "first end", "second"])
        XCTAssertLessThan(events.firstIndex(of: "other")!, events.firstIndex(of: "first end")!, "other keys don't wait")
    }
}

final class ControlSocketTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var directory: String!

    override func setUp() {
        // Short: socket paths are limited to ~104 bytes, and macOS temp folders are long.
        directory = "/tmp/mr-" + UUID().uuidString.prefix(8)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    func sample() -> ServeStatus {
        ServeStatus(
            version: "0.1.0", pid: 42, startedAt: now.addingTimeInterval(-7200),
            relay: .init(state: .connected, host: "minirun.you.workers.dev", since: now.addingTimeInterval(-600), viewerURL: "https://minirun.you.workers.dev/"),
            simulators: [
                .init(udid: "SIM-A", name: "iPhone 17 Pro", runtime: "iOS 26.0", reservedFor: "you/app@main", bundleID: "com.you.app",
                      lastUsed: now.addingTimeInterval(-120), busy: true, viewerURL: "https://minirun.you.workers.dev/?device=SIM-A"),
                .init(udid: "SIM-B", name: "iPhone 17 Pro (minirun 2)", runtime: "iOS 26.0", booting: true, reservedFor: "you/app@feature"),
            ],
            jobs: [
                .init(id: "job_2", title: "build_and_run you/app@feature", status: "running", startedAt: now.addingTimeInterval(-30)),
                .init(id: "job_1", title: "run_tests you/app@main", status: "failed", startedAt: now.addingTimeInterval(-400), finishedAt: now.addingTimeInterval(-300)),
            ]
        )
    }

    func testStatusRoundTripsOverTheSocket() async throws {
        let path = directory + "/control.sock"
        let status = sample()
        let server = ControlServer(path: path) { line in
            await ControlProtocol.respond(to: line) { status }
        }
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "only this user may ask")

        let line = try await Task.detached {
            try ControlSocket.request(path, ControlProtocol.encode(ControlProtocol.Request(command: "status")))
        }.value
        let response = try ControlProtocol.decode(ControlProtocol.Response.self, from: line)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.status, status)

        let unknown = try await Task.detached { try ControlSocket.request(path, #"{"command":"dance"}"#) }.value
        XCTAssertEqual(try ControlProtocol.decode(ControlProtocol.Response.self, from: unknown).error, "Unknown command dance.")
        let garbage = try await Task.detached { try ControlSocket.request(path, "hello") }.value
        XCTAssertFalse(try ControlProtocol.decode(ControlProtocol.Response.self, from: garbage).ok)
    }

    func testOneServerPerPathAndLeftoverSocketsAreReplaced() async throws {
        let path = directory + "/control.sock"
        // A regular file where the socket goes, as if a crashed daemon left something behind.
        FileManager.default.createFile(atPath: path, contents: Data())
        let first = ControlServer(path: path) { _ in "first" }
        try first.start()

        let second = ControlServer(path: path) { _ in "second" }
        XCTAssertThrowsError(try second.start(), "a running server keeps its socket")
        let answer = try await Task.detached { try ControlSocket.request(path, "hi") }.value
        XCTAssertEqual(answer, "first")

        first.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "stop removes the socket")
        XCTAssertThrowsError(try ControlSocket.request(path, "hi"))
        try second.start()
        defer { second.stop() }
        let after = try await Task.detached { try ControlSocket.request(path, "hi") }.value
        XCTAssertEqual(after, "second")
    }

    func testConcurrentRequests() async throws {
        let path = directory + "/control.sock"
        let server = ControlServer(path: path) { line in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return "echo " + line
        }
        try server.start()
        defer { server.stop() }
        let answers = try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<8 { group.addTask { try ControlSocket.request(path, "\(i)") } }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        XCTAssertEqual(Set(answers), Set((0..<8).map { "echo \($0)" }))
    }

    func testSocketPathLimit() {
        XCTAssertThrowsError(try ControlServer(path: "/tmp/" + String(repeating: "x", count: 200)) { _ in "" }.start())
    }

    func testSummary() {
        XCTAssertEqual(sample().summary(now: now), """
        minirun 0.1.0 serving (pid 42, up 2h 0m)
        Relay: connected to minirun.you.workers.dev for 10m
        Live view: https://minirun.you.workers.dev/

        Simulators:
          iPhone 17 Pro (iOS 26.0) SIM-A — reserved for you/app@main, busy, last app com.you.app, used 2 min ago
          iPhone 17 Pro (minirun 2) (iOS 26.0) SIM-B — booting, reserved for you/app@feature

        Jobs (1 running):
          job_2 build_and_run you/app@feature: running for 30s
          job_1 run_tests you/app@main: failed in 1m
        """)

        var down = sample()
        down.relay = .init(state: .disconnected, host: "minirun.you.workers.dev", since: now.addingTimeInterval(-45), problem: "The relay rejected the agent token.")
        down.simulators = []
        down.jobs = []
        XCTAssertEqual(down.summary(now: now), """
        minirun 0.1.0 serving (pid 42, up 2h 0m)
        Relay: disconnected from minirun.you.workers.dev for 45s
          The relay rejected the agent token.

        Simulators: none booted

        Jobs: none yet
        """)
    }
}
