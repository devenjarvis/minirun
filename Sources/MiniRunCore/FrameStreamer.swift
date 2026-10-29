import Foundation
import MiniRunKit
import MiniRunSim

/// Streams each simulator someone is watching to the relay, as H.264 when its viewers can decode
/// it and as JPEG frames otherwise (or when H.264 can't start).
///
/// Each stream is keyed by the UDID its viewers asked for, or "" for "whichever simulator is
/// booted". While anything is streaming, the booted simulators are also sent to the relay so
/// the viewer can offer a picker.
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

    func ack(_ sequence: UInt32, key: String) {
        guard let stream = streams[key] else { return }
        if sequence > stream.lastAcked { stream.lastAcked = sequence }
        stream.lastAckTime = Date()
    }

    func requestKeyframe(key: String) {
        streams[key]?.wantsKeyframe = true
    }

    private func run(_ stream: Stream) async {
        let settings = stream.request
        let key = settings.key
        let device: XcodeParsing.SimDevice
        do {
            device = try await registry.streamDevice(key.isEmpty ? nil : key)
        } catch {
            await sendText(RelayProtocol.streamStatus("error", key: key, message: error.localizedDescription))
            return
        }
        // Someone is watching, so idle shutdown leaves this simulator alone until they stop.
        await registry.activity.begin(device.udid)
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
        let interval = 1.0 / Double(settings.fps)
        while !Task.isCancelled {
            let started = Date()
            // Wait for the viewer to catch up, but don't stall forever if acks are lost.
            if stream.sequence &- stream.lastAcked >= window && Date().timeIntervalSince(stream.lastAckTime) < 2 {
                try? await Task.sleep(nanoseconds: 15_000_000)
                continue
            }
            do {
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
            do {
                if let frame = try await encoder.encode(forceKeyframe: stream.wantsKeyframe),
                   let payload = H264.annexB(lengthPrefixed: frame.nalUnits, lengthSize: frame.lengthSize, parameterSets: frame.parameterSets) {
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
                }
                failures = 0
            } catch {
                failures += 1
                if !announced && failures >= 3 { return false }
                if failures == 3 { await sendText(RelayProtocol.streamStatus("error", key: key, message: error.localizedDescription)) }
                try? await Task.sleep(nanoseconds: UInt64(min(5.0, 0.5 * Double(failures)) * 1_000_000_000))
                continue
            }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < interval { try? await Task.sleep(nanoseconds: UInt64((interval - elapsed) * 1_000_000_000)) }
        }
        return true
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

    /// The booted simulators and what each is reserved for.
    func simulatorsMessage() async -> JSONValue? {
        guard let snapshot = try? await simulators() else { return nil }
        let (all, claims) = snapshot
        return RelayProtocol.simulators(all.filter(\.isBooted).map { device -> JSONValue in
            var json = device.json.objectValue ?? [:]
            if let label = claims[device.udid]?.label { json["reserved_for"] = .string(label) }
            if let bundle = claims[device.udid]?.bundleID { json["last_app"] = .string(bundle) }
            return .object(json)
        })
    }
}
