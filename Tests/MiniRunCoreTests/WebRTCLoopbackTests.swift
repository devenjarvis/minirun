import XCTest
import CoreVideo
import WebRTC
@testable import MiniRunCore
@testable import MiniRunKit
import MiniRunSim

/// Runs `WebRTCSessions` against a viewer peer connection in the same process, standing in for
/// the browser, with signaling passed directly between them as the relay would.
///
/// `testSyntheticScreen` needs nothing but libwebrtc. `testSimulatorScreen` streams a real
/// simulator and touches it: set MINIRUN_WEBRTC_E2E_UDID to a booted simulator of your own.
final class WebRTCLoopbackTests: XCTestCase {
    func testSyntheticScreen() async throws {
        let source = SyntheticScreen()
        let recorder = InputRecorder()
        let environment = WebRTCEnvironment(
            resolve: { key in WebRTCTarget(device: key.isEmpty ? "SIM-TEST" : key, name: "Test Phone", kind: nil) },
            source: { _ in { emit in await source.run(emit) } },
            touch: { device, phase, x, y, _ in await recorder.touch(device, phase, x, y) },
            call: { tool, arguments in
                await recorder.call(tool, arguments, fromViewer: ToolRegistry.fromViewer)
                return .text("ok")
            },
            began: { target in await recorder.activity("begin \(target.device)") },
            ended: { target in await recorder.activity("end \(target.device)") },
            simulators: { nil }
        )
        let loop = Loopback(environment: environment)
        try await loop.start(key: "", fps: 30, scale: 1)

        try await loop.waitFor("10 frames", timeout: 15) { loop.viewer.framesReceived >= 10 }
        try await loop.waitFor("input channel", timeout: 5) { loop.viewer.channel("input")?.readyState == .open && loop.viewer.channel("touch")?.readyState == .open }
        // `screen` and `stream_status` arrive on the input channel, as on the relay socket.
        try await loop.waitFor("screen message", timeout: 5) { loop.viewer.messages.contains { $0["type"] == "screen" } }
        let screen = try XCTUnwrap(loop.viewer.messages.first { $0["type"] == "screen" })
        XCTAssertEqual(screen["udid"], "SIM-TEST")
        XCTAssertEqual(screen["key"], "")
        XCTAssertEqual(screen["pixelWidth"]?.intValue, SyntheticScreen.width)
        XCTAssertTrue(loop.viewer.messages.contains { $0["type"] == "stream_status" && $0["status"] == "live" })

        // Touches: down and up on the reliable channel, moves on the unreliable one.
        loop.viewer.send(["type": "touch", "phase": "down", "x": 10, "y": 20], on: "input")
        // The channels don't keep order between them; a move before its down is dropped.
        try await Task.sleep(nanoseconds: 100_000_000)
        loop.viewer.send(["phase": "move", "x": 30, "y": 40], on: "touch")
        try await Task.sleep(nanoseconds: 100_000_000)
        loop.viewer.send(["type": "touch", "phase": "up", "x": 30, "y": 40], on: "input")
        // Input: an allowed tool, made safe; a forbidden one, dropped.
        loop.viewer.send(["type": "input", "tool": "type_text", "arguments": ["text": "hi", "input": "hid", "window": 3, "device": "OTHER"]], on: "input")
        loop.viewer.send(["type": "input", "tool": "run_command", "arguments": ["command": "true"]], on: "input")
        // Probe: echoed back on the same channel.
        loop.viewer.send(["type": "probe", "t": 42], on: "input")
        try await loop.waitFor("touches and input", timeout: 5) {
            let touched = await recorder.touches.count
            let called = await recorder.calls.count
            return touched >= 3 && called >= 1
        }
        try await loop.waitFor("probe echo", timeout: 5) { loop.viewer.messages.contains { $0["type"] == "probe" } }
        XCTAssertEqual(loop.viewer.messages.first { $0["type"] == "probe" }, ["type": "probe", "t": 42])
        let touches = await recorder.touches
        XCTAssertEqual(touches.first, "SIM-TEST down 10 20")
        XCTAssertEqual(touches.last, "SIM-TEST up 30 40")
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.tool, "type_text")
        XCTAssertEqual(calls.first?.arguments, ["text": "hi", "device": "SIM-TEST"])
        XCTAssertEqual(calls.first?.fromViewer, true)

        // A held finger is lifted when the viewer goes away.
        loop.viewer.send(["type": "touch", "phase": "down", "x": 5, "y": 5], on: "input")
        try await loop.waitFor("second touch", timeout: 5) { (await recorder.touches.last) == "SIM-TEST down 5 5" }

        // The Mac's latency figures, on the input channel like the relay's `stats`.
        try await loop.waitFor("stats", timeout: 5) { loop.viewer.messages.contains { $0["type"] == "stats" && $0["touchMs"] != nil } }
        let stats = try XCTUnwrap(loop.viewer.messages.last { $0["type"] == "stats" })
        XCTAssertEqual(stats["key"], "")
        XCTAssertNotNil(stats["pipelineMs"]?.doubleValue)
        XCTAssertNotNil(stats["pipelineP95Ms"]?.doubleValue)
        XCTAssertGreaterThan(stats["fps"]?.doubleValue ?? 0, 0)

        let latency = loop.viewer.latencies(sentAt: source.sentAt)
        let pair = await loop.viewer.candidatePair()
        print("WebRTC loopback (synthetic): Mac stats \(stats.encodedString()), \(loop.viewer.framesReceived) frames, \(loop.viewer.width)x\(loop.viewer.height), path \(pair), capture to decoded frame \(latency)")
        XCTAssertTrue(pair.contains("host"), pair)

        await loop.sessions.handle(.stop(viewer: "v1"))
        try await loop.waitFor("release", timeout: 5) { (await recorder.touches.last) == "SIM-TEST up 5 5" }
        let activity = await recorder.activityLog
        XCTAssertEqual(activity, ["begin SIM-TEST", "end SIM-TEST"])
        let remaining = await loop.sessions.viewerCount
        XCTAssertEqual(remaining, 0)
        loop.viewer.close()
    }

    /// A still screen keeps getting a frame about once a second.
    func testRepeatsStillScreen() async throws {
        let environment = WebRTCEnvironment(
            resolve: { _ in WebRTCTarget(device: "SIM-STILL", name: "Still", kind: nil) },
            source: { _ in { emit in
                // One frame, then nothing.
                emit(.frame(SyntheticScreen.buffer(luma: 128), WebRTCScreen(pointWidth: 195, pointHeight: 422, pixelWidth: SyntheticScreen.width, pixelHeight: SyntheticScreen.height), capturedAt: Date()))
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
            } },
            touch: { _, _, _, _, _ in }, call: { _, _ in .text("ok") }, began: { _ in }, ended: { _ in }, simulators: { nil }
        )
        let loop = Loopback(environment: environment)
        try await loop.start(key: "SIM-STILL", fps: 30, scale: 1)
        try await loop.waitFor("first frame", timeout: 15) { loop.viewer.framesReceived >= 1 }
        let first = loop.viewer.framesReceived
        try await Task.sleep(nanoseconds: 3_500_000_000)
        XCTAssertGreaterThanOrEqual(loop.viewer.framesReceived - first, 2, "repeated frames")
        await loop.sessions.closeAll()
        loop.viewer.close()
    }

    /// The Mac reports an error (so the viewer falls back) when the device can't be streamed.
    /// Safari and WKWebView give only mDNS names for their host candidates. The Mac still connects
    /// directly: the viewer's checks reach the Mac's own host candidates, and the Mac learns the
    /// viewer's address from them (a peer-reflexive candidate).
    func testConnectsWithMDNSCandidates() async throws {
        let environment = WebRTCEnvironment(
            resolve: { _ in WebRTCTarget(device: "SIM-MDNS", name: "mDNS", kind: nil) },
            source: { _ in { emit in await SyntheticScreen().run(emit) } },
            touch: { _, _, _, _, _ in }, call: { _, _ in .text("ok") }, began: { _ in }, ended: { _ in }, simulators: { nil }
        )
        let loop = Loopback(environment: environment, mdnsCandidates: true)
        try await loop.start(key: "SIM-MDNS", fps: 30, scale: 1)
        try await loop.waitFor("frames", timeout: 15) { loop.viewer.framesReceived >= 5 }
        let pair = await loop.viewer.candidatePair()
        print("WebRTC loopback (mDNS viewer candidates): \(loop.viewer.framesReceived) frames, path \(pair)")
        XCTAssertTrue(pair.hasPrefix("host") || pair.hasPrefix("prflx"), pair)
        await loop.sessions.closeAll()
        loop.viewer.close()
    }

    func testErrorWhenDeviceUnknown() async throws {
        let sent = SentMessages()
        let environment = WebRTCEnvironment(
            resolve: { _ in throw ToolError("No simulator with UDID NOPE.") },
            source: { _ in { _ in } }, touch: { _, _, _, _, _ in }, call: { _, _ in .text("ok") },
            began: { _ in }, ended: { _ in }, simulators: { nil }
        )
        let sessions = WebRTCSessions(environment: environment, log: { _ in }, sendText: { await sent.add($0) })
        await sessions.handle(.start(.init(viewer: "v9", key: "NOPE", fps: 30, quality: 60, scale: 1, iceServers: [])))
        let messages = await sent.messages
        XCTAssertEqual(messages, [RelayProtocol.rtcError(viewer: "v9", message: "No simulator with UDID NOPE.")])
    }

    func testSimulatorScreen() async throws {
        guard let udid = ProcessInfo.processInfo.environment["MINIRUN_WEBRTC_E2E_UDID"] else {
            throw XCTSkip("Set MINIRUN_WEBRTC_E2E_UDID to a booted simulator to stream it.")
        }
        let recorder = InputRecorder()
        let environment = WebRTCEnvironment(
            resolve: { _ in WebRTCTarget(device: udid, name: "Simulator", kind: nil) },
            source: { target in WebRTCEnvironment.simulatorSource(udid: target.device) { nil } },
            touch: { device, phase, x, y, _ in
                await recorder.touch(device, phase, x, y)
                guard let phase = SimulatorDriver.TouchPhase(rawValue: phase) else { return }
                do { try await SimulatorDriver.shared.touch(udid: device, phase: phase, x: x, y: y) } catch { print("touch failed: \(error)") }
            },
            call: { _, _ in .text("ok") }, began: { _ in }, ended: { _ in }, simulators: { nil }
        )
        let loop = Loopback(environment: environment)
        let started = Date()
        try await loop.start(key: udid, fps: 30, scale: 0.5)
        try await loop.waitFor("first frame", timeout: 20) { loop.viewer.framesReceived >= 1 }
        let firstFrame = Date().timeIntervalSince(started)
        try await loop.waitFor("input channel", timeout: 5) { loop.viewer.channel("input")?.readyState == .open }

        // A tap with a little drag, as a viewer's finger sends it, at MINIRUN_WEBRTC_E2E_TAP ("x,y" in
        // points; by default where an iPhone's home screen has Settings), so the screen changes.
        let tap = (ProcessInfo.processInfo.environment["MINIRUN_WEBRTC_E2E_TAP"] ?? "338,437").split(separator: ",").compactMap { Double($0) }
        let x = tap.first ?? 338, y = tap.last ?? 437
        // A first touch in a new process sets up the HID connection and the orientation, which
        // takes seconds: warm that up with a tap on the status bar, so the tap below is timed warm.
        loop.viewer.send(["type": "touch", "phase": "down", "x": 200, "y": 12], on: "input")
        loop.viewer.send(["type": "touch", "phase": "up", "x": 200, "y": 12], on: "input")
        try await loop.waitFor("warm-up touch", timeout: 15) { (await recorder.touches.count) >= 2 }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let before = loop.viewer.framesReceived
        loop.viewer.send(["type": "touch", "phase": "down", "x": .number(x), "y": .number(y)], on: "input")
        for step in 1...3 {
            try await Task.sleep(nanoseconds: 16_000_000)
            loop.viewer.send(["phase": "move", "x": .number(x), "y": .number(y + Double(step))], on: "touch")
        }
        loop.viewer.send(["type": "touch", "phase": "up", "x": .number(x), "y": .number(y + 3)], on: "input")
        let touchSent = Date()
        try await loop.waitFor("frames after the touch", timeout: 10) { loop.viewer.framesReceived > before + 3 }
        let touchToFrames = Date().timeIntervalSince(touchSent)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Probe round trips over the data channel.
        var probes: [Double] = []
        for i in 0..<5 {
            let sent = Date()
            loop.viewer.send(["type": "probe", "t": .number(Double(i))], on: "input")
            try await loop.waitFor("probe \(i)", timeout: 5) { loop.viewer.messages.contains { $0["type"] == "probe" && $0["t"]?.intValue == i } }
            probes.append((loop.viewer.probeAnswered[i] ?? Date()).timeIntervalSince(sent) * 1000)
        }
        let pair = await loop.viewer.candidatePair()
        let touches = await recorder.touches
        print("""
            WebRTC loopback (simulator \(udid)): \(loop.viewer.framesReceived) frames, \(loop.viewer.width)x\(loop.viewer.height), \
            first frame after \(Int(firstFrame * 1000))ms, path \(pair), \(touches.count) touch steps delivered, \
            3 more frames \(Int(touchToFrames * 1000))ms after touch up, \
            Mac stats \(loop.viewer.messages.last { $0["type"] == "stats" }?.encodedString() ?? "none"), probe RTT \(probes.map { String(format: "%.1f", $0) }.joined(separator: "/"))ms
            """)
        XCTAssertEqual(touches.first?.hasPrefix("\(udid) down"), true)
        XCTAssertEqual(touches.last?.hasPrefix("\(udid) up"), true)
        await loop.sessions.closeAll()
        loop.viewer.close()
    }
}

// MARK: - Helpers

actor InputRecorder {
    var touches: [String] = []
    var calls: [(tool: String, arguments: JSONValue, fromViewer: Bool)] = []
    var activityLog: [String] = []

    func touch(_ device: String, _ phase: String, _ x: Double, _ y: Double) {
        touches.append("\(device) \(phase) \(Int(x)) \(Int(y))")
    }

    func call(_ tool: String, _ arguments: JSONValue, fromViewer: Bool) {
        calls.append((tool, arguments, fromViewer))
    }

    func activity(_ entry: String) {
        activityLog.append(entry)
    }
}

actor SentMessages {
    var messages: [JSONValue] = []
    func add(_ message: JSONValue) { messages.append(message) }
}

/// A screen whose brightness changes ten times a second, remembering when each level was sent,
/// so the viewer can time capture to decoded frame.
final class SyntheticScreen: @unchecked Sendable {
    static let width = 390, height = 844
    private let lock = NSLock()
    private var sent: [(level: Int, at: Date)] = []

    var sentAt: [(level: Int, at: Date)] { lock.withLock { sent } }

    static func buffer(luma: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(pixels, plane)!
            memset(base, plane == 0 ? Int32(luma) : 128, CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) * CVPixelBufferGetHeightOfPlane(pixels, plane))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    func run(_ emit: @escaping @Sendable (WebRTCFrameEvent) -> Void) async {
        let levels = [40, 80, 120, 160, 200]
        var index = 0
        while !Task.isCancelled {
            let luma = levels[index % levels.count]
            index += 1
            lock.withLock { sent.append((luma, Date())) }
            emit(.frame(Self.buffer(luma: luma), WebRTCScreen(pointWidth: 195, pointHeight: 422, pixelWidth: Self.width, pixelHeight: Self.height), capturedAt: Date()))
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

/// Signaling between the sessions and the viewer, as the relay passes it.
final class Loopback: @unchecked Sendable {
    let viewer = LoopbackViewer()
    private(set) var sessions: WebRTCSessions!

    /// `mdnsCandidates` hides the viewer's addresses behind made-up `.local` names, as Safari
    /// and Chrome do, which nothing can resolve.
    init(environment: WebRTCEnvironment, mdnsCandidates: Bool = false) {
        sessions = WebRTCSessions(environment: environment, log: { print("[webrtc] \($0)") }) { [weak self] message in
            await self?.fromMac(message)
        }
        viewer.onCandidate = { [weak self] candidate in
            guard let self else { return }
            var candidate = candidate
            if mdnsCandidates, let sdp = candidate.candidate {
                // candidate:<foundation> <component> <protocol> <priority> <address> <port> typ ...
                var fields = sdp.split(separator: " ").map(String.init)
                if fields.count > 4 { fields[4] = UUID().uuidString.lowercased() + ".local" }
                candidate = RelayProtocol.RTCCandidate(candidate: fields.joined(separator: " "), sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)
            }
            Task { await self.sessions.handle(.candidate(viewer: "v1", candidate)) }
        }
    }

    func start(key: String, fps: Int, scale: Double) async throws {
        await sessions.handle(.start(.init(viewer: "v1", key: key, fps: fps, quality: 60, scale: scale, iceServers: [])))
    }

    private func fromMac(_ message: JSONValue) async {
        guard message["type"] == "rtc" else { return }
        XCTAssertEqual(message["viewer"], "v1")
        switch message["action"]?.stringValue {
        case "offer":
            do {
                let answer = try await viewer.answer(offer: message["sdp"]?.stringValue ?? "")
                await sessions.handle(.answer(viewer: "v1", sdp: answer))
            } catch {
                XCTFail("answer: \(error)")
            }
        case "candidate":
            viewer.add(RelayProtocol.RTCCandidate(candidate: message["candidate"]?.stringValue, sdpMid: message["sdpMid"]?.stringValue, sdpMLineIndex: message["sdpMLineIndex"]?.intValue))
        case "error":
            XCTFail("rtc error: \(message)")
        default:
            break
        }
    }

    func waitFor(_ what: String, timeout: TimeInterval, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline {
                let received = viewer.messages.suffix(8).map { $0.encodedString() }.joined(separator: "\n")
                print("Timed out waiting for \(what). Last messages:\n\(received)\nViewer stats: \(await viewer.statsSummary())")
                throw XCTSkipFailure(what: what)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

struct XCTSkipFailure: LocalizedError {
    let what: String
    var errorDescription: String? { "Timed out waiting for \(what)" }
}

/// The browser's side: answers the offer, receives the video and the data channels.
final class LoopbackViewer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, RTCVideoRenderer, @unchecked Sendable {
    private let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    private var connection: RTCPeerConnection!
    private let lock = NSLock()
    private var channels: [String: RTCDataChannel] = [:]
    private var received: [JSONValue] = []
    private var probes: [Int: Date] = [:]
    /// When each probe's echo arrived, by its `t`.
    var probeAnswered: [Int: Date] { lock.withLock { probes } }
    private var frames = 0
    private var size = (width: 0, height: 0)
    /// When each brightness level was first seen.
    private var seen: [(level: Int, at: Date)] = []
    var onCandidate: (@Sendable (RelayProtocol.RTCCandidate) -> Void)?
    private var videoTrack: RTCVideoTrack?

    override init() {
        super.init()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        connection = factory.peerConnection(with: configuration, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
    }

    var framesReceived: Int { lock.withLock { frames } }
    var width: Int { lock.withLock { size.width } }
    var height: Int { lock.withLock { size.height } }
    var messages: [JSONValue] { lock.withLock { received } }
    func channel(_ label: String) -> RTCDataChannel? { lock.withLock { channels[label] } }

    func answer(offer: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offer)) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        // The track to render, from the offer's video transceiver.
        // Kept: the track object takes its renderers away when it's released.
        if let track = connection.transceivers.first(where: { $0.mediaType == .video })?.receiver.track as? RTCVideoTrack {
            track.add(self)
            videoTrack = track
        }
        let answer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { description, error in
                if let description { continuation.resume(returning: description) } else { continuation.resume(throwing: error!) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(answer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return answer.sdp
    }

    func add(_ candidate: RelayProtocol.RTCCandidate) {
        guard let sdp = candidate.candidate else { return }
        connection.add(RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(candidate.sdpMLineIndex ?? 0), sdpMid: candidate.sdpMid)) { _ in }
    }

    func send(_ message: JSONValue, on label: String) {
        channel(label)?.sendData(RTCDataBuffer(data: message.encoded(), isBinary: false))
    }

    func close() {
        connection.close()
    }

    /// The receiving side's RTP and transport stats, for a test that times out.
    func statsSummary() async -> String {
        await withCheckedContinuation { continuation in
            connection.statistics { report in
                let interesting = report.statistics.values.filter { ["inbound-rtp", "transport", "codec"].contains($0.type) }
                continuation.resume(returning: interesting.map { "\($0.type): \($0.values)" }.joined(separator: "\n"))
            }
        }
    }

    func candidatePair() async -> String {
        await withCheckedContinuation { continuation in
            connection.statistics { report in
                continuation.resume(returning: WebRTCPeer.describePair(report.statistics.mapValues { ($0.type, $0.values) }))
            }
        }
    }

    /// Capture to decoded frame, from when each brightness level was sent to when it was first seen.
    func latencies(sentAt sent: [(level: Int, at: Date)]) -> String {
        let seen = lock.withLock { self.seen }
        // Each change of level seen, against the last time that level was sent before it.
        let delays = seen.compactMap { shown in
            sent.last { $0.level == shown.level && $0.at <= shown.at }.map { shown.at.timeIntervalSince($0.at) * 1000 }
        }.filter { $0 < 1000 }.sorted()
        guard !delays.isEmpty else { return "not measured" }
        return String(format: "median %.0fms (%.0f–%.0fms) over %d changes", delays[delays.count / 2], delays.first!, delays.last!, delays.count)
    }

    // MARK: RTCVideoRenderer

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        var level: Int?
        if let buffer = frame.buffer as? RTCCVPixelBuffer {
            let pixels = buffer.pixelBuffer
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            if let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) {
                let row = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
                let y = CVPixelBufferGetHeightOfPlane(pixels, 0) / 2, x = CVPixelBufferGetWidthOfPlane(pixels, 0) / 2
                level = Int(base.load(fromByteOffset: y * row + x, as: UInt8.self))
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        } else {
            let i420 = frame.buffer.toI420()
            level = Int(i420.dataY[(Int(i420.height) / 2) * Int(i420.strideY) + Int(i420.width) / 2])
        }
        let now = Date()
        lock.withLock {
            frames += 1
            size = (Int(frame.width), Int(frame.height))
            // Snap to the synthetic levels (40, 80, ...), which survive compression to within a few steps.
            if let level {
                let snapped = Int((Double(level) / 40).rounded()) * 40
                if abs(snapped - level) <= 8, seen.last?.level != snapped { seen.append((snapped, now)) }
            }
        }
    }

    // MARK: Delegates

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onCandidate?(RelayProtocol.RTCCandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: Int(candidate.sdpMLineIndex)))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
        lock.withLock { channels[dataChannel.label] = dataChannel }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let message = try? JSONValue.parse(buffer.data) else { return }
        let now = Date()
        lock.withLock {
            received.append(message)
            if message["type"] == "probe", let t = message["t"]?.intValue { probes[t] = now }
        }
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}
