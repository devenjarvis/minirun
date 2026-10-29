import Foundation
import MiniRunKit
import MiniRunSim

/// Captures JPEG frames while a viewer is watching and hands them to the relay.
///
/// Flow control: at most `window` frames may be unacknowledged, so a slow phone connection gets
/// fewer, fresher frames instead of a growing backlog.
actor FrameStreamer {
    struct Settings: Equatable {
        var udid: String?
        var fps: Int
        var quality: Int
        var scale: Double
    }

    private let registry: ToolRegistry
    private let sendFrame: @Sendable (Data) async -> Void
    private let sendText: @Sendable (JSONValue) async -> Void
    private var task: Task<Void, Never>?
    private var settings: Settings?
    private var sequence: UInt32 = 0
    private var lastAcked: UInt32 = 0
    private var lastAckTime = Date()
    private let window: UInt32 = 2

    init(registry: ToolRegistry, sendFrame: @escaping @Sendable (Data) async -> Void, sendText: @escaping @Sendable (JSONValue) async -> Void) {
        self.registry = registry
        self.sendFrame = sendFrame
        self.sendText = sendText
    }

    func start(_ new: Settings) {
        if settings == new, task != nil { return }
        stop()
        settings = new
        lastAcked = sequence
        lastAckTime = Date()
        task = Task { await self.run(new) }
    }

    func stop() {
        task?.cancel()
        task = nil
        settings = nil
    }

    func ack(_ seq: UInt32) {
        if seq > lastAcked { lastAcked = seq }
        lastAckTime = Date()
    }

    private func run(_ settings: Settings) async {
        let device: XcodeParsing.SimDevice
        do {
            device = try await Simctl.resolve(settings.udid, config: registry.config, boot: true)
        } catch {
            await sendText(RelayProtocol.streamStatus("error", message: error.localizedDescription))
            return
        }

        var announced = false
        var failures = 0
        let interval = 1.0 / Double(settings.fps)
        while !Task.isCancelled {
            let started = Date()
            // Wait for the viewer to catch up, but don't stall forever if acks are lost.
            if sequence &- lastAcked >= window && Date().timeIntervalSince(lastAckTime) < 2 {
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
                        udid: device.udid, name: device.name,
                        pointWidth: size?.width ?? Double(pixelWidth) / 3,
                        pointHeight: size?.height ?? Double(pixelHeight) / 3,
                        pixelWidth: pixelWidth, pixelHeight: pixelHeight
                    ))
                    await sendText(RelayProtocol.streamStatus("live"))
                    announced = true
                }
                sequence &+= 1
                await sendFrame(RelayProtocol.encodeFrame(kind: .jpeg, sequence: sequence, payload: shot.data))
                failures = 0
            } catch {
                failures += 1
                if failures == 3 { await sendText(RelayProtocol.streamStatus("error", message: error.localizedDescription)) }
                try? await Task.sleep(nanoseconds: UInt64(min(5.0, 0.5 * Double(failures)) * 1_000_000_000))
                continue
            }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < interval { try? await Task.sleep(nanoseconds: UInt64((interval - elapsed) * 1_000_000_000)) }
        }
    }
}
