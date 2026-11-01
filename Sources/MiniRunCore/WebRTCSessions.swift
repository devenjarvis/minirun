import Foundation
import CoreVideo
import IOSurface
import WebRTC
import MiniRunKit
import MiniRunMac
import MiniRunSim

/// What a WebRTC viewer is watching: a simulator, or a Mac app's window.
struct WebRTCTarget: Equatable, Sendable {
    /// The simulator's UDID or the Mac app id. Input from the viewer always goes here.
    let device: String
    let name: String
    /// "mac" for a Mac app, nil for a simulator (as in `screen` messages).
    let kind: String?
}

/// A screen's size, as `screen` messages report it.
struct WebRTCScreen: Equatable, Sendable {
    var pointWidth: Double
    var pointHeight: Double
    var pixelWidth: Int
    var pixelHeight: Int
}

/// What a capture source produces: a new picture (a pixel buffer the source won't change
/// afterwards), its screen size and when it was captured (framebuffer damage, or
/// ScreenCaptureKit delivering it), or a status for the viewers ("error" with a message).
enum WebRTCFrameEvent: @unchecked Sendable {
    case frame(CVPixelBuffer, WebRTCScreen, capturedAt: Date)
    case status(String, message: String?)
}

/// Captures a device's screen until cancelled, emitting a frame each time it changes.
typealias WebRTCFrameSource = @Sendable (_ emit: @escaping @Sendable (WebRTCFrameEvent) -> Void) async -> Void

/// How WebRTC sessions reach the rest of minirun. `live(...)` is the real thing; tests swap in
/// their own capture and input.
struct WebRTCEnvironment: Sendable {
    /// The device a stream key shows ("" is whichever simulator is booted).
    var resolve: @Sendable (_ key: String) async throws -> WebRTCTarget
    var source: @Sendable (_ target: WebRTCTarget) -> WebRTCFrameSource
    /// One step of a live touch; `failed` tells the viewer when it didn't go through.
    var touch: @Sendable (_ device: String, _ phase: String, _ x: Double, _ y: Double, _ failed: @escaping @Sendable (String) -> Void) async -> Void
    /// Runs a viewer's tool call (already checked and made safe).
    var call: @Sendable (_ tool: String, _ arguments: JSONValue) async -> ToolResult
    /// While a peer connection is open, so idle shutdown leaves its device alone.
    var began: @Sendable (_ target: WebRTCTarget) async -> Void
    var ended: @Sendable (_ target: WebRTCTarget) async -> Void
    /// The viewer's device picker, sent to the relay while anyone watches over WebRTC (the
    /// WebSocket streamer only sends it while it's streaming).
    var simulators: @Sendable () async -> JSONValue?
}

/// Streams to viewers over WebRTC (protocol 6): one peer connection per viewer id, set up through
/// `rtc` messages on the relay socket. Video and input then go directly between the Mac and the
/// viewer. See docs/live-view-latency-plan.md.
///
/// The relay no longer sees a WebRTC viewer's input, so input from the data channels is checked
/// here as `relay.ts` checks socket input: only `RelayProtocol.viewerTools`, never `input` or
/// `window`, and always to the device this peer connection shows, as a `fromViewer` call.
actor WebRTCSessions {
    private let environment: WebRTCEnvironment
    private let sendText: @Sendable (JSONValue) async -> Void
    private let log: @Sendable (String) -> Void
    private var peers: [String: WebRTCPeer] = [:]
    /// One capture per device, shared by its viewers.
    private var hubs: [String: WebRTCCaptureHub] = [:]
    private var watcher: Task<Void, Never>?

    /// A peer connection that hasn't connected by then is given up (the viewer falls back after 8s).
    static let connectTimeout: TimeInterval = 30

    init(environment: WebRTCEnvironment, log: @escaping @Sendable (String) -> Void, sendText: @escaping @Sendable (JSONValue) async -> Void) {
        self.environment = environment
        self.log = log
        self.sendText = sendText
    }

    var viewerCount: Int { peers.count }

    func handle(_ signal: RelayProtocol.RTCSignal) async {
        switch signal {
        case .start(let start):
            await self.start(start)
        case .answer(let viewer, let sdp):
            guard let peer = peers[viewer] else { return }
            do {
                try await peer.setAnswer(sdp)
            } catch {
                log("WebRTC answer from viewer \(viewer) failed: \(error.localizedDescription)")
                await fail(viewer, message: "The Mac couldn't use the viewer's answer: \(error.localizedDescription)")
            }
        case .candidate(let viewer, let candidate):
            peers[viewer]?.addCandidate(candidate)
        case .stop(let viewer):
            await close(viewer, notify: false)
        }
    }

    /// Closes every peer connection (e.g. when minirun stops).
    func closeAll() async {
        for viewer in Array(peers.keys) { await close(viewer, notify: false) }
    }

    private func start(_ start: RelayProtocol.RTCStart) async {
        let viewer = start.viewer
        // A viewer that starts again (it reconnected, or picked another device) gets a new connection.
        if peers[viewer] != nil { await close(viewer, notify: false) }
        let target: WebRTCTarget
        do {
            target = try await environment.resolve(start.key)
        } catch {
            await sendText(RelayProtocol.rtcError(viewer: viewer, message: error.localizedDescription))
            return
        }
        // The viewer may have stopped or started again while the device was resolved.
        guard peers[viewer] == nil else { return }
        let peer: WebRTCPeer
        do {
            peer = try WebRTCPeer(start: start, target: target, environment: environment, log: log) { [weak self] event in
                Task { await self?.peerEvent(viewer: viewer, event) }
            }
        } catch {
            await sendText(RelayProtocol.rtcError(viewer: viewer, message: error.localizedDescription))
            return
        }
        peers[viewer] = peer
        await environment.began(target)

        let hub = hubs[target.device] ?? {
            let hub = WebRTCCaptureHub(source: environment.source(target))
            hubs[target.device] = hub
            return hub
        }()
        hub.subscribe(viewer, peer: peer)
        if watcher == nil { watcher = Task { await self.watchSimulators() } }

        do {
            let offer = try await peer.makeOffer()
            await sendText(RelayProtocol.rtcOffer(viewer: viewer, sdp: offer))
            log("WebRTC offer sent to viewer \(viewer) for \(target.name)")
        } catch {
            log("WebRTC offer for viewer \(viewer) failed: \(error.localizedDescription)")
            await fail(viewer, message: "The Mac couldn't start WebRTC: \(error.localizedDescription)")
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.connectTimeout * 1_000_000_000))
            await self?.giveUpIfUnconnected(viewer, peer: peer)
        }
    }

    private func giveUpIfUnconnected(_ viewer: String, peer: WebRTCPeer) async {
        guard peers[viewer] === peer, !peer.hasConnected else { return }
        log("WebRTC viewer \(viewer) didn't connect in \(Int(Self.connectTimeout))s")
        await close(viewer, notify: true)
    }

    private func peerEvent(viewer: String, _ event: WebRTCPeer.Event) async {
        guard peers[viewer] != nil else { return }
        switch event {
        case .candidate(let candidate):
            await sendText(RelayProtocol.rtcCandidate(viewer: viewer, candidate))
        case .connected(let path):
            log("WebRTC viewer \(viewer) connected (\(path))")
        case .failed:
            log("WebRTC viewer \(viewer) connection failed")
            await close(viewer, notify: true)
        }
    }

    /// Tells the viewer to fall back to the WebSocket stream, and closes its peer connection.
    private func fail(_ viewer: String, message: String) async {
        await sendText(RelayProtocol.rtcError(viewer: viewer, message: message))
        await close(viewer, notify: false)
    }

    /// `notify` tells the viewer (through the relay) that the Mac gave up on the connection.
    private func close(_ viewer: String, notify: Bool) async {
        guard let peer = peers.removeValue(forKey: viewer) else { return }
        peer.close()
        if let hub = hubs[peer.target.device], hub.unsubscribe(viewer) {
            hub.stop()
            hubs[peer.target.device] = nil
        }
        if peers.isEmpty {
            watcher?.cancel()
            watcher = nil
        }
        await environment.ended(peer.target)
        if notify { await sendText(RelayProtocol.rtcStop(viewer: viewer)) }
        log("WebRTC viewer \(viewer) closed after \(peer.framesSent) frames")
    }

    private func watchSimulators() async {
        var last: JSONValue?
        while !Task.isCancelled {
            if let message = await environment.simulators(), message != last {
                await sendText(message)
                last = message
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}

// MARK: - Capture shared by a device's viewers

/// Runs one capture source and hands each frame to every subscribed peer. Repeats the last frame
/// about once a second while the screen is still, so the encoder can sharpen the picture (a
/// screen that stops changing would otherwise stay at whatever quality its last frame had).
final class WebRTCCaptureHub: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [String: WebRTCPeer] = [:]
    private var last: (buffer: CVPixelBuffer, screen: WebRTCScreen, at: Date)?
    private var lastStatus: (status: String, message: String?)?
    private var task: Task<Void, Never>?
    private var repeater: Task<Void, Never>?

    static let repeatInterval: TimeInterval = 1

    init(source: @escaping WebRTCFrameSource) {
        let emit: @Sendable (WebRTCFrameEvent) -> Void = { [weak self] event in self?.deliver(event) }
        task = Task.detached { await source(emit) }
        repeater = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.repeatInterval * 1_000_000_000 / 2))
                self?.repeatIfStill()
            }
        }
    }

    func subscribe(_ viewer: String, peer: WebRTCPeer) {
        let (last, status) = lock.withLock {
            peers[viewer] = peer
            return (self.last, lastStatus)
        }
        // A new viewer gets the picture at once rather than at the next change.
        if let last { peer.send(frame: last.buffer, screen: last.screen, capturedAt: Date(), changed: false) }
        if let status, last == nil { peer.send(status: status.status, message: status.message) }
    }

    /// Returns true when no one is left.
    func unsubscribe(_ viewer: String) -> Bool {
        lock.withLock {
            peers[viewer] = nil
            return peers.isEmpty
        }
    }

    func stop() {
        task?.cancel()
        repeater?.cancel()
        lock.withLock { last = nil }
    }

    private func deliver(_ event: WebRTCFrameEvent) {
        switch event {
        case .frame(let buffer, let screen, let capturedAt):
            let targets = lock.withLock {
                last = (buffer, screen, Date())
                lastStatus = nil
                return Array(peers.values)
            }
            for peer in targets { peer.send(frame: buffer, screen: screen, capturedAt: capturedAt, changed: true) }
        case .status(let status, let message):
            let targets = lock.withLock {
                lastStatus = (status, message)
                return Array(peers.values)
            }
            for peer in targets { peer.send(status: status, message: message) }
        }
    }

    private func repeatIfStill() {
        let (frame, targets): ((buffer: CVPixelBuffer, screen: WebRTCScreen)?, [WebRTCPeer]) = lock.withLock {
            guard let last, Date().timeIntervalSince(last.at) >= Self.repeatInterval else { return (nil, []) }
            self.last = (last.buffer, last.screen, Date())
            return ((last.buffer, last.screen), Array(peers.values))
        }
        guard let frame else { return }
        for peer in targets { peer.send(frame: frame.buffer, screen: frame.screen, capturedAt: Date(), changed: false) }
    }
}

// MARK: - One viewer's peer connection

/// One viewer's peer connection: a sendonly video track fed from the device's capture, and the
/// "touch" and "input" data channels. libwebrtc calls the delegate methods on its own threads.
final class WebRTCPeer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case candidate(RelayProtocol.RTCCandidate)
        /// The connection is up; `path` describes the candidate pair (host, srflx, relay).
        case connected(path: String)
        case failed
    }

    struct WebRTCError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let viewer: String
    let target: WebRTCTarget
    let settings: RelayProtocol.RTCStart
    private let environment: WebRTCEnvironment
    private let log: @Sendable (String) -> Void
    private let events: @Sendable (Event) -> Void
    private let connection: RTCPeerConnection
    private let videoSource: RTCVideoSource
    private let capturer: RTCVideoCapturer
    private let sender: RTCRtpSender
    private let touchChannel: RTCDataChannel
    private let inputChannel: RTCDataChannel
    private let touches: TouchFeeder

    // Guarded by `lock`.
    private let lock = NSLock()
    private var screen: WebRTCScreen?
    private var announcedLive = false
    /// Messages for the viewer from before the "input" channel opened.
    private var outbox: [JSONValue] = []
    private var remoteDescriptionSet = false
    private var pendingCandidates: [RTCIceCandidate] = []
    private var closed = false
    private(set) var hasConnected = false
    private var lastInputError: Date?
    /// Frames handed to libwebrtc, for the log and tests.
    private(set) var framesSent = 0
    /// For the viewer's latency readout: sent as `stats` on the "input" channel about once a
    /// second while frames flow, with the same fields as the relay's.
    private var stats = LatencyStats()

    /// One factory for every peer connection: it owns libwebrtc's threads. Its encoders are
    /// VideoToolbox H.264 (hardware) plus VP8/VP9/AV1 in software for browsers without H.264.
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    init(start: RelayProtocol.RTCStart, target: WebRTCTarget, environment: WebRTCEnvironment,
         log: @escaping @Sendable (String) -> Void, events: @escaping @Sendable (Event) -> Void) throws {
        viewer = start.viewer
        self.target = target
        settings = start
        self.environment = environment
        self.log = log
        self.events = events
        let factory = Self.factory

        let configuration = RTCConfiguration()
        configuration.iceServers = start.iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        // Keep gathering, so a network change (Wi-Fi to Ethernet) can still connect.
        configuration.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else {
            throw WebRTCError(message: "Could not create a peer connection.")
        }
        self.connection = connection

        // A screencast source: libwebrtc tunes the encoder for sharp text rather than motion.
        videoSource = factory.videoSource(forScreenCast: true)
        capturer = RTCVideoCapturer(delegate: videoSource)
        let track = factory.videoTrack(with: videoSource, trackId: "screen")
        let initial = RTCRtpTransceiverInit()
        initial.direction = .sendOnly
        initial.streamIds = ["minirun"]
        let encoding = RTCRtpEncodingParameters()
        encoding.maxFramerate = NSNumber(value: start.fps)
        encoding.scaleResolutionDownBy = NSNumber(value: 1 / start.scale)
        initial.sendEncodings = [encoding]
        guard let transceiver = connection.addTransceiver(with: track, init: initial) else {
            connection.close()
            throw WebRTCError(message: "Could not add the video track.")
        }
        // H.264 first, so Safari and Chrome decode in hardware; the rest stay as fallbacks.
        let codecs = factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
        let preferred = codecs.filter { $0.name.uppercased() == "H264" } + codecs.filter { $0.name.uppercased() != "H264" }
        do {
            // `error: ()` picks the throwing form over the deprecated one of the same name.
            try transceiver.setCodecPreferences(preferred, error: ())
        } catch {
            log("WebRTC: couldn't prefer H.264: \(error.localizedDescription)")
        }
        sender = transceiver.sender

        let touchConfiguration = RTCDataChannelConfiguration()
        touchConfiguration.isOrdered = false
        touchConfiguration.maxRetransmits = 0
        guard let touchChannel = connection.dataChannel(forLabel: RelayProtocol.RTCChannel.touch.rawValue, configuration: touchConfiguration),
              let inputChannel = connection.dataChannel(forLabel: RelayProtocol.RTCChannel.input.rawValue, configuration: RTCDataChannelConfiguration()) else {
            connection.close()
            throw WebRTCError(message: "Could not create the data channels.")
        }
        self.touchChannel = touchChannel
        self.inputChannel = inputChannel
        touches = TouchFeeder(device: target.device, environment: environment)
        super.init()
        touches.failed = { [weak self] message in self?.inputFailed(message) }
        connection.delegate = self
        touchChannel.delegate = self
        inputChannel.delegate = self
        applyEncoding(for: nil)
    }

    /// Screen text must stay sharp: when bandwidth drops, lower the frame rate, never the
    /// resolution. The bitrate is capped from the viewer's quality, as for the WebSocket stream,
    /// and the viewer's scale becomes libwebrtc's downscale.
    private func applyEncoding(for screen: WebRTCScreen?) {
        let parameters = sender.parameters
        parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
        for encoding in parameters.encodings {
            encoding.maxFramerate = NSNumber(value: settings.fps)
            encoding.scaleResolutionDownBy = NSNumber(value: 1 / settings.scale)
            if let screen {
                let width = Int(Double(screen.pixelWidth) * settings.scale), height = Int(Double(screen.pixelHeight) * settings.scale)
                encoding.maxBitrateBps = NSNumber(value: H264.bitrate(width: width, height: height, fps: settings.fps, quality: settings.quality))
            }
        }
        sender.parameters = parameters
    }

    // MARK: Signaling

    func makeOffer() async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: constraints) { description, error in
                if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: error ?? WebRTCError(message: "No offer."))
                }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(offer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return offer.sdp
    }

    func setAnswer(_ sdp: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let pending = lock.withLock {
            remoteDescriptionSet = true
            defer { pendingCandidates = [] }
            return pendingCandidates
        }
        for candidate in pending { add(candidate) }
    }

    /// Candidates that arrive before the answer is applied wait for it.
    func addCandidate(_ candidate: RelayProtocol.RTCCandidate) {
        // A nil candidate only says the viewer has no more; libwebrtc doesn't need to be told.
        guard let sdp = candidate.candidate, !sdp.isEmpty else { return }
        let ice = RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(candidate.sdpMLineIndex ?? 0), sdpMid: candidate.sdpMid)
        let ready = lock.withLock {
            if !remoteDescriptionSet { pendingCandidates.append(ice) }
            return remoteDescriptionSet
        }
        if ready { add(ice) }
    }

    private func add(_ candidate: RTCIceCandidate) {
        connection.add(candidate) { [log, viewer] error in
            if let error { log("WebRTC viewer \(viewer): candidate rejected: \(error.localizedDescription)") }
        }
    }

    func close() {
        let wasClosed = lock.withLock {
            defer { closed = true }
            return closed
        }
        guard !wasClosed else { return }
        // A finger left down would block everything else on the device.
        touches.release()
        touchChannel.delegate = nil
        inputChannel.delegate = nil
        connection.delegate = nil
        connection.close()
    }

    // MARK: Video

    /// `changed` is false for a repeat of the last picture, which doesn't count as the screen
    /// answering a touch.
    func send(frame buffer: CVPixelBuffer, screen: WebRTCScreen, capturedAt: Date, changed: Bool) {
        let (isClosed, resized, first) = lock.withLock {
            let resized = self.screen != screen
            self.screen = screen
            let first = !announcedLive
            announcedLive = true
            return (closed, resized, first)
        }
        guard !isClosed else { return }
        if resized {
            // A resized Mac window (or rotated simulator): tell the viewer the new size, as the
            // WebSocket stream does, and cap the bitrate for it.
            applyEncoding(for: screen)
            sendToViewer(RelayProtocol.screen(
                key: settings.key, udid: target.device, name: target.name, kind: target.kind,
                pointWidth: screen.pointWidth, pointHeight: screen.pointHeight,
                pixelWidth: screen.pixelWidth, pixelHeight: screen.pixelHeight
            ))
        }
        if first { sendToViewer(RelayProtocol.streamStatus("live", key: settings.key)) }
        let time = Int64(DispatchTime.now().uptimeNanoseconds)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: time)
        videoSource.capturer(capturer, didCapture: frame)
        // The pipeline is capture to handing the frame to libwebrtc, which encodes and sends it.
        let now = Date()
        let message: JSONValue? = lock.withLock {
            framesSent += 1
            stats.frameSent(capturedAt: capturedAt, sentAt: now, changed: changed)
            return stats.message(key: settings.key, codec: .h264, now: now)
        }
        if let message { sendToViewer(message) }
    }

    func send(status: String, message: String?) {
        if status != "live" { lock.withLock { announcedLive = false } }
        sendToViewer(RelayProtocol.streamStatus(status, key: settings.key, message: message))
    }

    /// Like `FrameStreamer.inputFailed`: at most every 10 seconds, the viewer shows the message
    /// for a few seconds, then the stream is live again.
    private func inputFailed(_ message: String) {
        let now = Date()
        let send = lock.withLock {
            if let last = lastInputError, now.timeIntervalSince(last) < 10 { return false }
            lastInputError = now
            return true
        }
        guard send else { return }
        sendToViewer(RelayProtocol.streamStatus("error", key: settings.key, message: message))
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.lock.withLock({ self.closed }) else { return }
            self.sendToViewer(RelayProtocol.streamStatus("live", key: self.settings.key))
        }
    }

    // MARK: Data channels

    /// Sends a message on the "input" channel, or keeps it until the channel opens.
    func sendToViewer(_ message: JSONValue) {
        let open = lock.withLock {
            let open = inputChannel.readyState == .open
            if !open { outbox.append(message) }
            return open
        }
        if open { send(message, on: inputChannel) }
    }

    private func send(_ message: JSONValue, on channel: RTCDataChannel) {
        channel.sendData(RTCDataBuffer(data: message.encoded(), isBinary: false))
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open where dataChannel === inputChannel:
            let pending = lock.withLock {
                defer { outbox = [] }
                return outbox
            }
            for message in pending { send(message, on: inputChannel) }
        case .closing, .closed:
            // Released as when a viewer's socket closes, so a finger isn't left down.
            touches.release()
        default:
            break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, let text = String(data: buffer.data, encoding: .utf8) else { return }
        let channel: RelayProtocol.RTCChannel = dataChannel === touchChannel ? .touch : .input
        switch RelayProtocol.viewerMessage(text, channel: channel) {
        case .touch(let phase, let x, let y):
            let arrived = Date()
            lock.withLock { stats.touched(at: arrived) }
            touches.add(phase: phase, x: x, y: y)
        case .input(let tool, let arguments):
            guard let safe = RelayProtocol.viewerArguments(tool: tool, arguments: arguments, device: target.device) else { return }
            let environment = self.environment, log = self.log
            Task { [weak self] in
                let result = await ToolRegistry.$fromViewer.withValue(true) {
                    await environment.call(tool, safe)
                }
                guard result.isError else { return }
                var message = ""
                if case .text(let text)? = result.content.first { message = text }
                log("Viewer action \(tool) failed: \(message)")
                if self?.target.kind == "mac" { self?.inputFailed("\(tool) failed: \(message)") }
            }
        case .probe(let t):
            // Straight back on the same channel, so the viewer measures the round trip to the Mac.
            send(RelayProtocol.probeEcho(t: t), on: dataChannel)
        case .unknown:
            break
        }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        events(.candidate(RelayProtocol.RTCCandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: Int(candidate.sdpMLineIndex))))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .connected:
            let first = lock.withLock {
                defer { hasConnected = true }
                return !hasConnected
            }
            guard first else { return }
            candidatePair { [events] path in events(.connected(path: path)) }
        case .failed:
            events(.failed)
        default:
            break
        }
    }

    /// The selected candidate pair, as "host -> srflx (udp)": whether the connection is direct.
    func candidatePair(_ completion: @escaping @Sendable (String) -> Void) {
        connection.statistics { report in
            completion(Self.describePair(report.statistics.mapValues { ($0.type, $0.values) }))
        }
    }

    /// From stats (type and values by id): the selected pair's local and remote candidate types.
    static func describePair(_ stats: [String: (type: String, values: [String: NSObject])]) -> String {
        let transport = stats.values.first { $0.type == "transport" }
        let pairID = transport?.values["selectedCandidatePairId"] as? String
        let pair = pairID.flatMap { stats[$0] } ?? stats.values.first {
            $0.type == "candidate-pair" && ($0.values["nominated"] as? NSNumber)?.boolValue == true && ($0.values["state"] as? String) == "succeeded"
        }
        guard let pair else { return "unknown path" }
        func candidate(_ key: String) -> (type: String, proto: String) {
            let values = (pair.values[key] as? String).flatMap { stats[$0] }?.values
            return ((values?["candidateType"] as? String) ?? "?", (values?["protocol"] as? String) ?? "?")
        }
        let local = candidate("localCandidateId"), remote = candidate("remoteCandidateId")
        return "\(local.type) -> \(remote.type) (\(local.proto))"
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// Hands one viewer's touches to the device in order. Down and up come on the reliable channel
/// and moves on the unreliable one, so they're queued here as they arrive (synchronously, so
/// their order holds), and a run of moves the device hasn't caught up with collapses to the
/// latest, as in `TouchQueue`. Remembers a finger that's down, to lift it when the viewer goes.
final class TouchFeeder: @unchecked Sendable {
    private struct Step {
        let phase: String
        let x: Double
        let y: Double
    }

    private let device: String
    private let environment: WebRTCEnvironment
    private let lock = NSLock()
    private var pending: [Step] = []
    private var draining = false
    private var held: (x: Double, y: Double)?
    var failed: @Sendable (String) -> Void = { _ in }

    init(device: String, environment: WebRTCEnvironment) {
        self.device = device
        self.environment = environment
    }

    func add(phase: String, x: Double, y: Double) {
        let start = lock.withLock {
            switch phase {
            case "down": held = (x, y)
            case "move":
                // Late moves (the unordered channel) after the finger lifted are dropped.
                guard held != nil else { return false }
                held = (x, y)
            default: held = nil
            }
            if phase == "move", let last = pending.last, last.phase == "move" { pending.removeLast() }
            pending.append(Step(phase: phase, x: x, y: y))
            defer { draining = true }
            return !draining
        }
        guard start else { return }
        Task { await drain() }
    }

    /// Lifts the finger if it's down.
    func release() {
        let point: (x: Double, y: Double)? = lock.withLock { held }
        if let point { add(phase: "up", x: point.x, y: point.y) }
    }

    private func drain() async {
        while true {
            let next: Step? = lock.withLock {
                guard !pending.isEmpty else {
                    draining = false
                    return nil
                }
                return pending.removeFirst()
            }
            guard let next else { return }
            await environment.touch(device, next.phase, next.x, next.y, failed)
        }
    }
}

// MARK: - The real environment

extension WebRTCEnvironment {
    /// Captures through the simulator and Mac app drivers, and sends input the way the relay's
    /// viewer input goes (`TouchQueue` and `registry.call`).
    static func live(registry: ToolRegistry, touches: TouchQueue, log: @escaping @Sendable (String) -> Void) -> WebRTCEnvironment {
        WebRTCEnvironment(
            resolve: { key in
                if MacAppID.isMacDevice(key) {
                    let session = try await registry.macApp(ToolArguments(["device": .string(key)]), running: false)
                    return WebRTCTarget(device: session.id, name: session.name, kind: "mac")
                }
                let device = try await registry.streamDevice(key.isEmpty ? nil : key)
                return WebRTCTarget(device: device.udid, name: device.name, kind: nil)
            },
            source: { target in
                if target.kind == "mac" { return macWindowSource(registry: registry, id: target.device) }
                return simulatorSource(udid: target.device) { await registry.geometry.pointSize(udid: target.device) }
            },
            touch: { device, phase, x, y, failed in
                await touches.add(TouchQueue.Event(udid: device, phase: phase, x: x, y: y), log: log) { _, message in failed(message) }
            },
            call: { tool, arguments in await registry.call(tool, arguments: arguments) },
            began: { target in await registry.activity.begin(target.device) },
            ended: { target in
                await registry.activity.end(target.device)
                if target.kind == "mac" { await registry.macApps.touch(target.device) } else { await registry.claims.touch(target.device) }
            },
            simulators: { await registry.simulatorsMessage() }
        )
    }

    /// A simulator's framebuffer: each change is copied out (the simulator keeps drawing into its
    /// surface) at up to 30 frames a second.
    static func simulatorSource(udid: String, pointSize: @escaping @Sendable () async -> (width: Double, height: Double)?) -> WebRTCFrameSource {
        { emit in
            let capture: SimulatorScreenCapture
            do {
                capture = try await SimulatorDriver.shared.screenCapture(udid: udid)
            } catch {
                emit(.status("error", message: error.localizedDescription))
                return
            }
            defer { capture.close() }
            let copier = SurfaceCopier()
            var lastSeed: UInt32?
            var lastSurface: IOSurface?
            var screen: WebRTCScreen?
            let interval = 1.0 / 30
            while !Task.isCancelled {
                let (current, damagedAt) = capture.takeSurface()
                if let surface = current, surface.seed != lastSeed || surface !== lastSurface {
                    let started = Date()
                    // Read before copying: a change during the copy changes the seed, so it's copied again.
                    lastSeed = surface.seed
                    lastSurface = surface
                    if screen?.pixelWidth != surface.width || screen?.pixelHeight != surface.height {
                        var points = await pointSize() ?? (Double(surface.width) / 3, Double(surface.height) / 3)
                        // The cached point size may be from the other orientation.
                        if (points.width > points.height) != (surface.width > surface.height) { points = (points.height, points.width) }
                        screen = WebRTCScreen(pointWidth: points.width, pointHeight: points.height, pixelWidth: surface.width, pixelHeight: surface.height)
                    }
                    if let buffer = copier.copy(surface), let screen { emit(.frame(buffer, screen, capturedAt: damagedAt ?? started)) }
                    let elapsed = Date().timeIntervalSince(started)
                    if elapsed < interval { try? await Task.sleep(nanoseconds: UInt64((interval - elapsed) * 1_000_000_000)) }
                }
                await capture.waitForChange(timeout: 0.5)
            }
        }
    }

    /// A Mac app's main window at full resolution. When the app quits or the window closes, it
    /// waits for the app to come back (a new build_and_run relaunches it under the same id).
    static func macWindowSource(registry: ToolRegistry, id: String) -> WebRTCFrameSource {
        { emit in
            var lastError: String?
            func report(_ error: Error) async {
                if error.localizedDescription != lastError {
                    lastError = error.localizedDescription
                    emit(.status("error", message: error.localizedDescription))
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            while !Task.isCancelled {
                let capture: MacWindowCapture
                let session: MacAppSession
                do {
                    session = try await registry.macApp(ToolArguments(["device": .string(id)]))
                    guard let pid = session.pid else { throw ToolError(MacToolSupport.notRunning(session)) }
                    capture = try await MacAppDriver.shared.windowCapture(pid: pid, window: .main, scale: 1, fps: 30).capture
                } catch {
                    await report(error)
                    continue
                }
                lastError = nil
                // The viewer's clicks and input go to the window it sees.
                registry.streamedMacWindows[id] = capture.windowID
                var lastNumber = 0
                while !Task.isCancelled {
                    do {
                        try await capture.followResize()
                        if let frame = try capture.latestFrame(), frame.number != lastNumber {
                            lastNumber = frame.number
                            let geometry = frame.geometry
                            emit(.frame(frame.buffer, WebRTCScreen(
                                pointWidth: geometry.points.width, pointHeight: geometry.points.height,
                                pixelWidth: geometry.pixels.width, pixelHeight: geometry.pixels.height
                            ), capturedAt: frame.arrivedAt))
                        }
                    } catch {
                        // The window closed or the app quit: start over with whatever window it has now.
                        break
                    }
                    await capture.waitForChange(timeout: 0.5)
                }
                capture.close()
                if registry.streamedMacWindows[id] == capture.windowID { registry.streamedMacWindows[id] = nil }
                if !Task.isCancelled, !MacAppDriver.isRunning(session) { emit(.status("error", message: MacToolSupport.notRunning(session))) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
