import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox
import MiniRunKit

/// A ScreenCaptureKit stream of one Mac app window (so other windows covering it don't show).
/// ScreenCaptureKit only delivers a frame when the window changes. `MacWindowEncoder` (H.264
/// over the relay) and the WebRTC sessions both read the window through this.
///
/// The window can be resized: `followResize` reconfigures the stream to the new size, and frames
/// carry the geometry they were captured at.
public final class MacWindowCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// One stream configuration: the window's size and the frames the stream makes for it.
    public struct Geometry: Equatable, Sendable {
        public var points: (width: Double, height: Double)
        public var pixels: (width: Int, height: Int)
        public var output: (width: Int, height: Int)

        public static func == (a: Geometry, b: Geometry) -> Bool {
            a.points == b.points && a.pixels == b.pixels && a.output == b.output
        }
    }

    /// A captured frame. `number` goes up by one for each new frame.
    public struct Frame: @unchecked Sendable {
        public let buffer: CVPixelBuffer
        public let geometry: Geometry
        public let number: Int
        /// When ScreenCaptureKit delivered it.
        public let arrivedAt: Date
    }

    public let windowID: UInt32
    private let filter: SCContentFilter
    private let pixelScale: Double
    private let scale: Double
    private let fps: Int
    private let queue = DispatchQueue(label: "dev.minirun.mac-window")
    private let lock = NSLock()
    private var stream: SCStream?

    // Guarded by `lock`.
    private var current: Geometry
    private var pending: Geometry?
    private var latest: Frame?
    private var frameCount = 0
    private var stopError: Error?
    private var changePending = false
    private var changeWaiter: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    private var waiterCount = 0
    private var nextSizeCheck = Date()

    /// `scale` is video pixels per window pixel.
    init(window: SCWindow, scale: Double, fps: Int) {
        windowID = window.windowID
        filter = SCContentFilter(desktopIndependentWindow: window)
        pixelScale = Double(filter.pointPixelScale > 0 ? filter.pointPixelScale : 1)
        self.scale = scale
        self.fps = max(1, fps)
        let size = filter.contentRect.size.width > 0 ? filter.contentRect.size : window.frame.size
        current = Self.geometry(points: (Double(size.width), Double(size.height)), pixelScale: pixelScale, scale: scale)
        super.init()
    }

    static func geometry(points: (width: Double, height: Double), pixelScale: Double, scale: Double) -> Geometry {
        let pixels = MacGeometry.capturePixels(points: points, backingScale: pixelScale)
        return Geometry(points: points, pixels: pixels, output: MacGeometry.videoSize(pixels: pixels, scale: scale))
    }

    func configuration(_ geometry: Geometry) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = geometry.output.width
        configuration.height = geometry.output.height
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.queueDepth = 4
        configuration.showsCursor = false
        configuration.capturesAudio = false
        // No shadow, so pixels map exactly onto the window's frame.
        configuration.ignoreShadowsSingleWindow = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        return configuration
    }

    func start() async throws {
        let stream = SCStream(filter: filter, configuration: configuration(current), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func close() {
        let stream = self.stream
        self.stream = nil
        stream?.stopCapture { _ in }
    }

    // MARK: SCStreamOutput, SCStreamDelegate

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = (width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        lock.lock()
        if let pending, pending.output == size {
            current = pending
            self.pending = nil
        }
        // A frame from before a resize took effect would be letterboxed; skip those.
        guard current.output == size else {
            lock.unlock()
            return
        }
        frameCount += 1
        latest = Frame(buffer: buffer, geometry: current, number: frameCount, arrivedAt: Date())
        let waiter = changeWaiter
        changeWaiter = nil
        if waiter == nil { changePending = true }
        lock.unlock()
        waiter?.continuation.resume()
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        stopError = error
        let waiter = changeWaiter
        changeWaiter = nil
        lock.unlock()
        waiter?.continuation.resume()
    }

    /// Returns when the window has a new frame (or already had one since the last call), or after
    /// `timeout`. One waiter at a time.
    public func waitForChange(timeout: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if changePending || stopError != nil {
                changePending = false
                lock.unlock()
                continuation.resume()
                return
            }
            waiterCount += 1
            let id = waiterCount
            changeWaiter = (id, continuation)
            lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                lock.lock()
                let waiter = changeWaiter?.id == id ? changeWaiter : nil
                if waiter != nil { changeWaiter = nil }
                lock.unlock()
                waiter?.continuation.resume()
            }
        }
    }

    /// The newest frame, or nil before the first one arrives. Throws once the stream has stopped.
    public func latestFrame() throws -> Frame? {
        let (latest, error) = lock.withLock { (self.latest, stopError) }
        if let error { throw MacDriverError("The window stream stopped: \(error.localizedDescription)") }
        return latest
    }

    // MARK: Resizing

    /// The window's size in points from the window server, or nil once it's gone.
    static func windowSize(_ windowID: UInt32) -> (width: Double, height: Double)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              let bounds = info[kCGWindowBounds as String],
              let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary) else { return nil }
        return (Double(rect.width), Double(rect.height))
    }

    /// Follows the window's size (checked at most twice a second): a new size reconfigures the
    /// stream. Throws once the window has closed.
    public func followResize() async throws {
        let due = lock.withLock {
            guard Date() >= nextSizeCheck else { return false }
            nextSizeCheck = Date().addingTimeInterval(0.5)
            return true
        }
        guard due else { return }
        guard let size = Self.windowSize(windowID) else {
            throw MacDriverError("The window (\(windowID)) closed. Call list_windows to find the app's windows.")
        }
        let target = lock.withLock { pending ?? current }
        guard abs(size.width - target.points.width) >= 1 || abs(size.height - target.points.height) >= 1 else { return }
        let geometry = Self.geometry(points: size, pixelScale: pixelScale, scale: scale)
        let reconfigure = lock.withLock {
            if geometry.output == current.output {
                // Same video size (a sub-pixel change): just take the new point size.
                current = geometry
                pending = nil
            } else {
                pending = geometry
            }
            return pending != nil
        }
        if reconfigure, let stream {
            try? await stream.updateConfiguration(configuration(geometry))
        }
    }

    // MARK: JPEG

    /// The latest frame as JPEG, `scale` image pixels per window pixel (as for simulator screens).
    public func jpeg(scale: Double, quality: Int) async throws -> (data: Data, width: Int, height: Int) {
        try await followResize()
        var snapshot: Frame?
        let deadline = Date().addingTimeInterval(2)
        while true {
            snapshot = try latestFrame()
            if snapshot != nil || Date() > deadline { break }
            await waitForChange(timeout: 0.1)
        }
        guard let latest = snapshot else { throw MacDriverError("The window hasn't produced a frame yet. Is it minimized or on another Space?") }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(latest.buffer, options: nil, imageOut: &image) == noErr, let image else {
            throw MacDriverError("Could not read the window's frame.")
        }
        let width = max(1, Int((Double(latest.geometry.pixels.width) * scale).rounded()))
        let height = max(1, Int((Double(latest.geometry.pixels.height) * scale).rounded()))
        let output = MacImage.resized(image, width: width, height: height) ?? image
        return (try MacImage.jpeg(output, quality: quality), output.width, output.height)
    }
}
