import Foundation

/// One stream's latency on the Mac, for the viewer's latency readout (`?stats=1`):
///
/// - pipeline: from a frame's capture (framebuffer damage, ScreenCaptureKit delivering it, or the
///   screenshot) to the frame being handed to the socket, over the last `frameSamples` frames;
/// - touch: from a live touch reaching the Mac to the next frame sent that was captured after it
///   and shows a change, over the last `touchSamples` touches that changed the screen.
///
/// `message` turns them into a `stats` message about once a second.
public struct LatencyStats: Sendable {
    public static let frameSamples = 60
    public static let touchSamples = 20
    /// A touch with no changed frame this long after it didn't change the screen: it's dropped
    /// rather than matched with some later, unrelated change.
    public static let touchTimeout: TimeInterval = 2

    private var pipeline: [Double] = []
    private var touches: [Double] = []
    /// The earliest touch that no frame has shown yet.
    private var touchAt: Date?
    /// Frames sent since the last message, and when that message went (or the first frame came).
    private var framesSinceMessage = 0
    private var windowStart: Date?

    public init() {}

    /// A live touch reached the Mac.
    public mutating func touched(at time: Date) {
        if let touchAt, time.timeIntervalSince(touchAt) < Self.touchTimeout { return }
        touchAt = time
    }

    /// A frame captured at `capturedAt` was handed to the socket at `sentAt`. `changed` is false
    /// for a frame that shows the same picture as the one before (JPEG streams send those).
    public mutating func frameSent(capturedAt: Date, sentAt: Date, changed: Bool = true) {
        Self.append(max(0, sentAt.timeIntervalSince(capturedAt)) * 1000, to: &pipeline, keeping: Self.frameSamples)
        framesSinceMessage += 1
        if windowStart == nil { windowStart = sentAt }
        guard let touchAt else { return }
        if sentAt.timeIntervalSince(touchAt) > Self.touchTimeout {
            self.touchAt = nil
        } else if changed && capturedAt >= touchAt {
            Self.append(sentAt.timeIntervalSince(touchAt) * 1000, to: &touches, keeping: Self.touchSamples)
            self.touchAt = nil
        }
    }

    /// The `stats` message for stream `key`, once at least a second has passed since the last one
    /// (or since the first frame), or nil if it's not time yet. Only frames make it time, so a
    /// still screen sends nothing and the viewer keeps showing the last figures.
    public mutating func message(key: String, codec: RelayProtocol.Codec, now: Date) -> JSONValue? {
        guard let windowStart, !pipeline.isEmpty else { return nil }
        let elapsed = now.timeIntervalSince(windowStart)
        guard elapsed >= 1 else { return nil }
        let fps = Double(framesSinceMessage) / elapsed
        framesSinceMessage = 0
        self.windowStart = now
        return RelayProtocol.stats(
            key: key, codec: codec, fps: fps,
            pipelineMs: Self.average(pipeline), pipelineP95Ms: Self.percentile(pipeline, 0.95),
            touchMs: touches.isEmpty ? nil : Self.average(touches), touchP95Ms: touches.isEmpty ? nil : Self.percentile(touches, 0.95)
        )
    }

    private static func append(_ value: Double, to samples: inout [Double], keeping limit: Int) {
        samples.append(value)
        if samples.count > limit { samples.removeFirst(samples.count - limit) }
    }

    static func average(_ samples: [Double]) -> Double {
        samples.reduce(0, +) / Double(samples.count)
    }

    /// The nearest-rank percentile: the smallest sample with at least `fraction` of them at or below it.
    static func percentile(_ samples: [Double], _ fraction: Double) -> Double {
        let sorted = samples.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }
}

extension RelayProtocol {
    /// A stream's latency on the Mac (see `LatencyStats`), in milliseconds rounded to 0.1. The
    /// relay passes it to the stream's viewers. The touch figures are left out until a touch has
    /// changed the screen.
    public static func stats(
        key: String, codec: Codec, fps: Double, pipelineMs: Double, pipelineP95Ms: Double, touchMs: Double? = nil, touchP95Ms: Double? = nil
    ) -> JSONValue {
        func ms(_ value: Double) -> JSONValue { .number((value * 10).rounded() / 10) }
        var message: [String: JSONValue] = [
            "type": "stats",
            "key": .string(key),
            "codec": .string(codec.rawValue),
            "fps": ms(fps),
            "pipelineMs": ms(pipelineMs),
            "pipelineP95Ms": ms(pipelineP95Ms),
        ]
        if let touchMs { message["touchMs"] = ms(touchMs) }
        if let touchP95Ms { message["touchP95Ms"] = ms(touchP95Ms) }
        return .object(message)
    }
}
