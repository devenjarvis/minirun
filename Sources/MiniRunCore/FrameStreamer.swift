import Foundation
import MiniRunKit
import MiniRunMac
import MiniRunSim

/// Streams each simulator someone is watching to the relay, as H.264 when its viewers can decode
/// it and as JPEG frames otherwise (or when H.264 can't start).
///
/// Each stream is keyed by the UDID its viewers asked for, or "" for "whichever simulator is
/// booted". A Mac app id as the key streams that app's main window instead. While anything is
/// streaming, the booted simulators and running Mac apps are also sent to the relay so the viewer
/// can offer a picker.
///
/// Flow control: at most `window` frames of a stream may be unacknowledged, so a slow phone
/// connection gets fewer, fresher frames instead of a growing backlog. H.264 frames can't be
/// dropped, so the encoder waits instead, and a viewer that misses frames asks for a keyframe.
actor FrameStreamer {
    private final class Stream {
        let request: RelayProtocol.StreamRequest
        var task: Task<Void, Never>?
        var sequence: UInt32 = 0
        var lastAcked: UInt32 = 0
        var lastAckTime = Date()
        var wantsKeyframe = true
        /// The simulator UDID or Mac app id on screen, which live touches name.
        var device: String?
        var stats = LatencyStats()

        init(_ request: RelayProtocol.StreamRequest) {
            self.request = request
        }
    }

    private let registry: ToolRegistry
    private let sendFrame: @Sendable (Data) async -> Void
    private let sendText: @Sendable (JSONValue) async -> Void
    private var streams: [String: Stream] = [:]
    private var watcher: Task<Void, Never>?
    private let window: UInt32 = 2
    /// H.264 frames are small, so more can be in flight.
    private let videoWindow: UInt32 = 6

    init(registry: ToolRegistry, sendFrame: @escaping @Sendable (Data) async -> Void, sendText: @escaping @Sendable (JSONValue) async -> Void) {
        self.registry = registry
        self.sendFrame = sendFrame
        self.sendText = sendText
    }

    /// Makes the running streams match `requests`: starts new ones, restarts changed ones, stops the rest.
    func set(_ requests: [RelayProtocol.StreamRequest]) {
        var wanted: [String: RelayProtocol.StreamRequest] = [:]
        for request in requests { wanted[request.key] = request }
        for (key, stream) in streams where wanted[key] != stream.request {
            stream.task?.cancel()
            streams[key] = nil
        }
        for (key, request) in wanted where streams[key] == nil {
            let stream = Stream(request)
            streams[key] = stream
            stream.task = Task { await self.run(stream) }
        }
        if streams.isEmpty {
            watcher?.cancel()
            watcher = nil
        } else if watcher == nil {
            watcher = Task { await self.watchSimulators() }
        }
    }

    func stop() {
        set([])
    }

    /// When each stream last told its viewers about failed input, to send that at most every 10s.
    private var inputErrorsSent: [String: Date] = [:]

    /// Tells the viewers of stream `key` that their click or input didn't go through (say,
    /// minirun lacks Accessibility), at most every 10 seconds per stream. The message shows over
    /// the view for a few seconds, then the stream is marked live again (frames keep coming).
    func inputFailed(key: String, message: String) {
        guard let stream = streams[key] else { return }
        let now = Date()
        if let last = inputErrorsSent[key], now.timeIntervalSince(last) < 10 { return }
        inputErrorsSent[key] = now
        let sendText = self.sendText
        Task {
            await sendText(RelayProtocol.streamStatus("error", key: key, message: message))
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            // Still the same stream: it's live, the overlay can go.
            if await self.isStreaming(stream, key: key) { await sendText(RelayProtocol.streamStatus("live", key: key)) }
        }
    }

    private func isStreaming(_ stream: Stream, key: String) -> Bool { streams[key] === stream }

    /// A live touch for `device` reached the Mac, for its streams' touch → screen time.
    func touched(device: String, at time: Date) {
        for stream in streams.values where stream.device == device { stream.stats.touched(at: time) }
    }

    /// Records a frame that just went to the socket, and about once a second tells the stream's
    /// viewers the latency figures (`stats`).
    private func frameSent(_ stream: Stream, codec: RelayProtocol.Codec, capturedAt: Date, changed: Bool = true) async {
        let now = Date()
        stream.stats.frameSent(capturedAt: capturedAt, sentAt: now, changed: changed)
        if let message = stream.stats.message(key: stream.request.key, codec: codec, now: now) { await sendText(message) }
    }

    func ack(_ sequence: UInt32, key: String) {
        // An ack past the last frame sent is for an earlier stream (this one restarted, or the Mac
        // reconnected while the viewer stayed open). Counting it would make every later frame
        // look unacknowledged and stall the stream.
        guard let stream = streams[key], sequence <= stream.sequence else { return }
        if sequence > stream.lastAcked { stream.lastAcked = sequence }
        stream.lastAckTime = Date()
    }

    func requestKeyframe(key: String) {
        streams[key]?.wantsKeyframe = true
    }

    private func run(_ stream: Stream) async {
        let settings = stream.request
        let key = settings.key
        if MacAppID.isMacDevice(key) {
            await runMac(stream)
            return
        }
        let device: XcodeParsing.SimDevice
        do {
            device = try await registry.streamDevice(key.isEmpty ? nil : key)
        } catch {
            await sendText(RelayProtocol.streamStatus("error", key: key, message: error.localizedDescription))
            return
        }
        // Someone is watching, so idle shutdown leaves this simulator alone until they stop.
        await registry.activity.begin(device.udid)
        stream.device = device.udid
        var streamedVideo = false
        if settings.codec == .h264 { streamedVideo = await runVideo(stream, device: device) }
        if !streamedVideo { await runJPEG(stream, device: device) }
        await registry.activity.end(device.udid)
        await registry.claims.touch(device.udid)
    }

    private func runJPEG(_ stream: Stream, device: XcodeParsing.SimDevice) async {
        let settings = stream.request
        let key = settings.key
        var announced = false
        var failures = 0
        var lastJPEG: Data?
        let interval = 1.0 / Double(settings.fps)
        while !Task.isCancelled {
            let started = Date()
            // Wait for the viewer to catch up, but don't stall forever if acks are lost.
            if stream.sequence &- stream.lastAcked >= window && Date().timeIntervalSince(stream.lastAckTime) < 2 {
                try? await Task.sleep(nanoseconds: 15_000_000)
                continue
            }
            do {
                let capturedAt = Date()
                let shot = try await SimulatorDriver.shared.screenshotJPEG(udid: device.udid, scale: settings.scale, quality: settings.quality)
                if !announced {
                    let size = await registry.geometry.pointSize(udid: device.udid)
                    let pixelWidth = Int((Double(shot.width) / settings.scale).rounded())
                    let pixelHeight = Int((Double(shot.height) / settings.scale).rounded())
                    await sendText(RelayProtocol.screen(
                        key: key, udid: device.udid, name: device.name,
                        pointWidth: size?.width ?? Double(pixelWidth) / 3,
                        pointHeight: size?.height ?? Double(pixelHeight) / 3,
                        pixelWidth: pixelWidth, pixelHeight: pixelHeight
                    ))
                    await sendText(RelayProtocol.streamStatus("live", key: key))
                    announced = true
                }
                if Task.isCancelled { break }
                stream.sequence &+= 1
                await sendFrame(RelayProtocol.encodeFrame(key: key, sequence: stream.sequence, payload: shot.data))
                // The same picture encodes to the same bytes, so this tells which frames show a change.
                await frameSent(stream, codec: .jpeg, capturedAt: capturedAt, changed: shot.data != lastJPEG)
                lastJPEG = shot.data
                failures = 0
            } catch {
                failures += 1
                if failures == 3 { await sendText(RelayProtocol.streamStatus("error", key: key, message: error.localizedDescription)) }
                try? await Task.sleep(nanoseconds: UInt64(min(5.0, 0.5 * Double(failures)) * 1_000_000_000))
                continue
            }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < interval { try? await Task.sleep(nanoseconds: UInt64((interval - elapsed) * 1_000_000_000)) }
        }
    }

    /// Streams H.264. Returns false if the encoder couldn't start or never produced a frame, so
    /// the caller can fall back to JPEG (which every viewer can show).
    private func runVideo(_ stream: Stream, device: XcodeParsing.SimDevice) async -> Bool {
        let settings = stream.request
        let key = settings.key
        let fps = settings.fps, quality = settings.quality
        let encoder: ScreenEncoder
        do {
            encoder = try await SimulatorDriver.shared.screenEncoder(udid: device.udid, scale: settings.scale, fps: fps) { width, height in
                H264.bitrate(width: width, height: height, fps: fps, quality: quality)
            }
        } catch {
            return false
        }
        defer { encoder.close() }

        let began = Date()
        var announced = false
        var failures = 0
        let interval = 1.0 / Double(fps)
        while !Task.isCancelled {
            let started = Date()
            if !announced && started.timeIntervalSince(began) > 5 { return false }
            if stream.sequence &- stream.lastAcked >= videoWindow && started.timeIntervalSince(stream.lastAckTime) < 2 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            var sent = false
            do {
                if let frame = try await encoder.encode(forceKeyframe: stream.wantsKeyframe),
                   // Without the SPS saying frames aren't reordered, browsers hold several back.
                   let payload = H264.annexB(
                       lengthPrefixed: frame.nalUnits, lengthSize: frame.lengthSize,
                       parameterSets: frame.parameterSets.map { $0.first.map { $0 & 0x1f } == 7 ? H264.withoutReordering(sps: $0) : $0 }
                   ) {
                    if !announced {
                        let size = await registry.geometry.pointSize(udid: device.udid)
                        await sendText(RelayProtocol.screen(
                            key: key, udid: device.udid, name: device.name,
                            pointWidth: size?.width ?? Double(frame.sourceWidth) / 3,
                            pointHeight: size?.height ?? Double(frame.sourceHeight) / 3,
                            pixelWidth: frame.sourceWidth, pixelHeight: frame.sourceHeight
                        ))
                        await sendText(RelayProtocol.streamStatus("live", key: key))
                        announced = true
                    }
                    if Task.isCancelled { break }
                    if frame.isKeyframe { stream.wantsKeyframe = false }
                    stream.sequence &+= 1
                    await sendFrame(RelayProtocol.encodeVideoFrame(key: key, sequence: stream.sequence, keyframe: frame.isKeyframe, payload: payload))
                    await frameSent(stream, codec: .h264, capturedAt: frame.capturedAt)
                    sent = true
                }
                failures = 0
            } catch {
                failures += 1
                if !announced && failures >= 3 { return false }
                if failures == 3 { await sendText(RelayProtocol.streamStatus("error", key: key, message: error.localizedDescription)) }
                try? await Task.sleep(nanoseconds: UInt64(min(5.0, 0.5 * Double(failures)) * 1_000_000_000))
                continue
            }
            // At most `fps` frames a second, but otherwise encode as soon as the simulator reports a
            // change rather than on the next tick, which saves up to a frame interval of latency.
            let elapsed = Date().timeIntervalSince(started)
            if sent && elapsed < interval { try? await Task.sleep(nanoseconds: UInt64((interval - elapsed) * 1_000_000_000)) }
            if !sent { await encoder.waitForChange(timeout: interval) }
        }
        return true
    }

    // MARK: Mac apps

    /// A Mac app window's size as last announced to viewers.
    private struct MacScreen: Equatable {
        let pointWidth: Double
        let pointHeight: Double
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// Streams a Mac app's main window until the stream stops. When the app quits or its window
    /// closes, it waits for the app to come back (a new build_and_run relaunches it under the same
    /// id) and picks it up again.
    private func runMac(_ stream: Stream) async {
        let key = stream.request.key
        // Someone is watching, so idle quitting leaves this app alone until they stop.
        await registry.activity.begin(key)
        stream.device = key
        var lastError: String?
        while !Task.isCancelled {
            let session: MacAppSession
            do {
                session = try await registry.macApp(ToolArguments(["device": .string(key)]))
            } catch {
                if error.localizedDescription != lastError {
                    lastError = error.localizedDescription
                    await sendText(RelayProtocol.streamStatus("error", key: key, message: error.localizedDescription))
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            lastError = nil
            var streamedVideo = false
            if stream.request.codec == .h264 { streamedVideo = await runMacVideo(stream, session: session) }
            if !streamedVideo { await runMacJPEG(stream, session: session) }
            registry.streamedMacWindows[key] = nil
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        registry.streamedMacWindows[key] = nil
        await registry.activity.end(key)
        await registry.macApps.touch(key)
    }

    private func announce(_ screen: MacScreen, session: MacAppSession, key: String) async {
        await sendText(RelayProtocol.screen(
            key: key, udid: session.id, name: session.name, kind: "mac",
            pointWidth: screen.pointWidth, pointHeight: screen.pointHeight, pixelWidth: screen.pixelWidth, pixelHeight: screen.pixelHeight
        ))
    }

    /// Streams the window as H.264 until the app quits or the window goes away (returns true), or
    /// returns false if the encoder couldn't start or never produced a frame, so the caller can
    /// fall back to JPEG. A resized window is announced again, followed by a keyframe.
    private func runMacVideo(_ stream: Stream, session: MacAppSession) async -> Bool {
        guard let pid = session.pid else { return true }
        let settings = stream.request
        let key = settings.key
        let fps = settings.fps, quality = settings.quality
        let encoder: MacWindowEncoder
        do {
            let started = try await MacAppDriver.shared.windowEncoder(pid: pid, window: .main, scale: settings.scale, fps: fps) { width, height in
                H264.bitrate(width: width, height: height, fps: fps, quality: quality)
            }
            encoder = started.encoder
            // The stream stays on this window: the viewer's clicks and input go to it too.
            registry.streamedMacWindows[key] = started.window.windowID
        } catch {
            return false
        }
        defer { encoder.close() }
        stream.wantsKeyframe = true

        let began = Date()
        var announced: MacScreen?
        var failures = 0
        let interval = 1.0 / Double(fps)
        while !Task.isCancelled {
            let started = Date()
            if announced == nil && started.timeIntervalSince(began) > 5 { return false }
            if stream.sequence &- stream.lastAcked >= videoWindow && started.timeIntervalSince(stream.lastAckTime) < 2 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            var sent = false
            do {
                if let frame = try await encoder.encode(forceKeyframe: stream.wantsKeyframe),
                   let payload = H264.annexB(
                       lengthPrefixed: frame.nalUnits, lengthSize: frame.lengthSize,
                       parameterSets: frame.parameterSets.map { $0.first.map { $0 & 0x1f } == 7 ? H264.withoutReordering(sps: $0) : $0 }
                   ) {
                    let screen = MacScreen(pointWidth: frame.pointWidth, pointHeight: frame.pointHeight, pixelWidth: frame.sourceWidth, pixelHeight: frame.sourceHeight)
                    if screen != announced {
                        await announce(screen, session: session, key: key)
                        if announced == nil { await sendText(RelayProtocol.streamStatus("live", key: key)) }
                        announced = screen
                        // Viewers start decoding afresh at a new size, so the next frame must be a keyframe.
                        if !frame.isKeyframe {
                            stream.wantsKeyframe = true
                            continue
                        }
                    }
                    if Task.isCancelled { break }
                    if frame.isKeyframe { stream.wantsKeyframe = false }
                    stream.sequence &+= 1
                    await sendFrame(RelayProtocol.encodeVideoFrame(key: key, sequence: stream.sequence, keyframe: frame.isKeyframe, payload: payload))
                    await frameSent(stream, codec: .h264, capturedAt: frame.capturedAt)
                    sent = true
                }
                failures = 0
            } catch {
                failures += 1
                if announced == nil && failures >= 3 { return false }
                // The app quit or its window closed: start over with whatever window it has now.
                if failures >= 3 || !MacAppDriver.isRunning(session) { return true }
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            // A window only produces frames when it changes, so wait for one rather than polling.
            let elapsed = Date().timeIntervalSince(started)
            if sent && elapsed < interval { try? await Task.sleep(nanoseconds: UInt64((interval - elapsed) * 1_000_000_000)) }
            if !sent { await encoder.waitForChange(timeout: interval) }
        }
        return true
    }

    /// Streams the window as JPEG screenshots until the app quits or captures keep failing.
    private func runMacJPEG(_ stream: Stream, session: MacAppSession) async {
        guard let pid = session.pid else { return }
        let settings = stream.request
        let key = settings.key
        var announced: MacScreen?
        var failures = 0
        var lastJPEG: Data?
        let interval = 1.0 / Double(settings.fps)
        while !Task.isCancelled {
            let started = Date()
            if stream.sequence &- stream.lastAcked >= window && Date().timeIntervalSince(stream.lastAckTime) < 2 {
                try? await Task.sleep(nanoseconds: 15_000_000)
                continue
            }
            do {
                let capturedAt = Date()
                // `scale` is relative to the window's pixels, two per point on a Retina display.
                let shot = try await MacAppDriver.shared.screenshotJPEG(pid: pid, window: .main, scale: settings.scale * 2, quality: settings.quality)
                // Each frame shows the main window as of now; the viewer's input follows it.
                registry.streamedMacWindows[key] = shot.window.windowID
                let screen = MacScreen(
                    pointWidth: shot.window.frame.width, pointHeight: shot.window.frame.height,
                    pixelWidth: Int((Double(shot.width) / settings.scale).rounded()), pixelHeight: Int((Double(shot.height) / settings.scale).rounded())
                )
                if screen != announced {
                    await announce(screen, session: session, key: key)
                    if announced == nil { await sendText(RelayProtocol.streamStatus("live", key: key)) }
                    announced = screen
                }
                if Task.isCancelled { break }
                stream.sequence &+= 1
                await sendFrame(RelayProtocol.encodeFrame(key: key, sequence: stream.sequence, payload: shot.data))
                await frameSent(stream, codec: .jpeg, capturedAt: capturedAt, changed: shot.data != lastJPEG)
                lastJPEG = shot.data
                failures = 0
            } catch {
                failures += 1
                if failures == 3 { await sendText(RelayProtocol.streamStatus("error", key: key, message: error.localizedDescription)) }
                if failures >= 5 || !MacAppDriver.isRunning(session) { return }
                try? await Task.sleep(nanoseconds: UInt64(min(5.0, 0.5 * Double(failures)) * 1_000_000_000))
                continue
            }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < interval { try? await Task.sleep(nanoseconds: UInt64((interval - elapsed) * 1_000_000_000)) }
        }
    }

    /// Sends the booted simulators whenever they change, so the viewer's picker stays current.
    private func watchSimulators() async {
        var last: JSONValue?
        while !Task.isCancelled {
            if let message = await registry.simulatorsMessage(), message != last {
                await sendText(message)
                last = message
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}

extension ToolRegistry {
    /// The simulator a viewer stream shows: `udid`, or else the most recently used booted
    /// simulator (booting the default one if none is running).
    func streamDevice(_ udid: String?) async throws -> XcodeParsing.SimDevice {
        let (devices, claims) = try await simulators()
        if let udid {
            guard let device = devices.first(where: { $0.udid == udid }) else { throw ToolError("No simulator with UDID \(udid).") }
            guard device.isBooted else { throw ToolError("\(device.name) isn't running. Pick a booted simulator.") }
            // It may still be booting.
            return try await realize(.use(device), boot: false).ready()
        }
        let booted = devices.filter(\.isBooted).sorted {
            (claims[$0.udid]?.updatedAt ?? .distantPast) > (claims[$1.udid]?.updatedAt ?? .distantPast)
        }
        if let device = booted.first { return try await realize(.use(device), boot: false).ready() }
        let choice = SimulatorPicker.target(query: nil, workspace: nil, devices: devices, claims: claims, preferredName: config.defaultDevice)
        return try await realize(choice, boot: true).ready()
    }

    /// The booted simulators and what each is reserved for, then the running Mac apps (with
    /// `kind: "mac"` and their Mac app id as `udid`).
    func simulatorsMessage() async -> JSONValue? {
        guard let snapshot = try? await simulators() else { return nil }
        let (all, claims) = snapshot
        let simulators = all.filter(\.isBooted).map { device -> JSONValue in
            var json = device.json.objectValue ?? [:]
            if let label = claims[device.udid]?.label { json["reserved_for"] = .string(label) }
            if let bundle = claims[device.udid]?.bundleID { json["last_app"] = .string(bundle) }
            return .object(json)
        }
        return RelayProtocol.simulators(simulators + (await macPickerEntries()))
    }
}
