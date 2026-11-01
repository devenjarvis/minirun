import XCTest
@testable import MiniRunKit

final class RTCSignalingTests: XCTestCase {
    func testHelloSaysWebRTC() {
        let hello = RelayProtocol.hello(host: [:], tools: [], instance: "i", webrtc: true)
        XCTAssertEqual(hello["webrtc"], .bool(true))
        XCTAssertEqual(hello["version"]?.intValue, 6)
        XCTAssertEqual(RelayProtocol.hello(host: [:], tools: [], instance: "i")["webrtc"], .bool(false))
    }

    func testDecodesStart() {
        let text = #"{"type":"rtc","action":"start","viewer":"v1","key":"SIM-A","fps":60,"quality":5,"scale":0.5,"iceServers":[{"urls":"stun:stun.cloudflare.com:3478"},{"urls":["turn:turn.cloudflare.com:3478?transport=udp","turns:turn.cloudflare.com:5349"],"username":"u","credential":"c"},{"urls":[]}]}"#
        let expected = RelayProtocol.RTCStart(
            viewer: "v1", key: "SIM-A", fps: 30, quality: 10, scale: 0.5,
            iceServers: [
                .init(urls: ["stun:stun.cloudflare.com:3478"]),
                .init(urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:5349"], username: "u", credential: "c"),
            ]
        )
        XCTAssertEqual(RelayProtocol.decode(text), .rtc(.start(expected)))
        // "Whichever simulator is booted", with the default settings.
        guard case .rtc(.start(let start)) = RelayProtocol.decode(#"{"type":"rtc","action":"start","viewer":"v2","key":""}"#) else {
            return XCTFail("not a start")
        }
        XCTAssertEqual(start.key, "")
        XCTAssertEqual(start.iceServers, [])
        XCTAssertEqual(start.fps, 30)
    }

    func testDecodesAnswerCandidateStop() {
        XCTAssertEqual(
            RelayProtocol.decode(#"{"type":"rtc","action":"answer","viewer":"v1","sdp":"v=0"}"#),
            .rtc(.answer(viewer: "v1", sdp: "v=0"))
        )
        XCTAssertEqual(
            RelayProtocol.decode(#"{"type":"rtc","action":"candidate","viewer":"v1","candidate":"candidate:1 1 udp 1 192.168.1.2 5000 typ host","sdpMid":"0","sdpMLineIndex":0}"#),
            .rtc(.candidate(viewer: "v1", .init(candidate: "candidate:1 1 udp 1 192.168.1.2 5000 typ host", sdpMid: "0", sdpMLineIndex: 0)))
        )
        // End of candidates.
        XCTAssertEqual(
            RelayProtocol.decode(#"{"type":"rtc","action":"candidate","viewer":"v1","candidate":null}"#),
            .rtc(.candidate(viewer: "v1", .init(candidate: nil, sdpMid: nil, sdpMLineIndex: nil)))
        )
        XCTAssertEqual(RelayProtocol.decode(#"{"type":"rtc","action":"stop","viewer":"v1"}"#), .rtc(.stop(viewer: "v1")))
        XCTAssertEqual(RelayProtocol.RTCSignal.stop(viewer: "v9").viewer, "v9")
    }

    func testRejectsMalformedRTC() {
        for text in [
            #"{"type":"rtc","action":"stop"}"#, // no viewer id
            #"{"type":"rtc","action":"stop","viewer":""}"#,
            #"{"type":"rtc","action":"answer","viewer":"v1"}"#, // no sdp
            #"{"type":"rtc","action":"dance","viewer":"v1"}"#,
        ] {
            XCTAssertEqual(RelayProtocol.decode(text), .unknown(text), text)
        }
    }

    func testEncodesMacMessages() throws {
        XCTAssertEqual(
            RelayProtocol.rtcOffer(viewer: "v1", sdp: "v=0"),
            ["type": "rtc", "action": "offer", "viewer": "v1", "sdp": "v=0"]
        )
        let candidate = RelayProtocol.rtcCandidate(viewer: "v1", .init(candidate: "candidate:1", sdpMid: "0", sdpMLineIndex: 0))
        XCTAssertEqual(candidate, ["type": "rtc", "action": "candidate", "viewer": "v1", "candidate": "candidate:1", "sdpMid": "0", "sdpMLineIndex": 0])
        let end = try JSONValue.parse(RelayProtocol.rtcCandidate(viewer: "v1", .init(candidate: nil, sdpMid: nil, sdpMLineIndex: nil)).encodedString())
        XCTAssertEqual(end["candidate"], .null)
        XCTAssertEqual(RelayProtocol.rtcStop(viewer: "v1"), ["type": "rtc", "action": "stop", "viewer": "v1"])
        XCTAssertEqual(
            RelayProtocol.rtcError(viewer: "v1", message: "No simulator"),
            ["type": "rtc", "action": "error", "viewer": "v1", "message": "No simulator"]
        )
    }

    func testViewerMessages() {
        XCTAssertEqual(RelayProtocol.viewerMessage(#"{"phase":"move","x":10.5,"y":20}"#, channel: .touch), .touch(phase: "move", x: 10.5, y: 20))
        XCTAssertEqual(RelayProtocol.viewerMessage(#"{"type":"touch","phase":"down","x":1,"y":2}"#, channel: .input), .touch(phase: "down", x: 1, y: 2))
        XCTAssertEqual(RelayProtocol.viewerMessage(#"{"type":"touch","phase":"hover","x":1,"y":2}"#, channel: .input), .unknown)
        XCTAssertEqual(RelayProtocol.viewerMessage(#"{"type":"touch","phase":"up","x":"1","y":2}"#, channel: .input), .unknown)
        XCTAssertEqual(RelayProtocol.viewerMessage(#"{"phase":"up"}"#, channel: .touch), .unknown)
        XCTAssertEqual(
            RelayProtocol.viewerMessage(#"{"type":"input","tool":"type_text","arguments":{"text":"hi"}}"#, channel: .input),
            .input(tool: "type_text", arguments: ["text": "hi"])
        )
        XCTAssertEqual(RelayProtocol.viewerMessage(#"{"type":"probe","t":123.5}"#, channel: .input), .probe(t: 123.5))
        XCTAssertEqual(RelayProtocol.probeEcho(t: 123.5), ["type": "probe", "t": 123.5])
        XCTAssertEqual(RelayProtocol.viewerMessage("not json", channel: .input), .unknown)
        XCTAssertEqual(RelayProtocol.viewerMessage(#"{"type":"stream"}"#, channel: .input), .unknown)
    }

    /// The Mac enforces for data channel input what the relay enforces for socket input.
    func testViewerArgumentsAreMadeSafe() {
        XCTAssertNil(RelayProtocol.viewerArguments(tool: "run_command", arguments: ["command": "rm -rf /"], device: "SIM-A"))
        XCTAssertNil(RelayProtocol.viewerArguments(tool: "build_and_run", arguments: [:], device: "SIM-A"))
        XCTAssertEqual(
            RelayProtocol.viewerArguments(tool: "press_key", arguments: ["key": "a", "input": "hid", "window": 42, "device": "SIM-OTHER"], device: "mac-abc123"),
            ["key": "a", "device": "mac-abc123"]
        )
        XCTAssertEqual(RelayProtocol.viewerArguments(tool: "tap", arguments: "junk", device: "SIM-A"), ["device": "SIM-A"])
        XCTAssertEqual(RelayProtocol.viewerTools.count, 9)
    }
}
