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
        XCTAssertEqual(Data(decoded.payload), payload)
    }

    func testDecodeMessages() {
        XCTAssertEqual(
            RelayProtocol.decode(#"{"type":"call","id":"7","tool":"tap","arguments":{"x":1}}"#),
            .call(id: "7", tool: "tap", arguments: ["x": 1])
        )
        XCTAssertEqual(RelayProtocol.decode(#"{"type":"call","tool":"tap"}"#), .call(id: nil, tool: "tap", arguments: [:]))
        XCTAssertEqual(RelayProtocol.decode(#"{"type":"stream","action":"stop"}"#), .streamStop)
        XCTAssertEqual(
            RelayProtocol.decode(#"{"type":"stream","action":"start","fps":100,"quality":5,"scale":0.5}"#),
            .streamStart(udid: nil, fps: 30, quality: 10, scale: 0.5)
        )
        XCTAssertEqual(RelayProtocol.decode(#"{"type":"ack","seq":42}"#), .ack(sequence: 42))
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
        let result = try await Shell.run("/bin/sh", ["-c", "sleep 10"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(result.duration, 5)
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
