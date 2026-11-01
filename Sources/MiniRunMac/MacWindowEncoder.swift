import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import VideoToolbox
import MiniRunKit

/// Encodes one Mac app window as H.264 with VideoToolbox, fed by a ScreenCaptureKit stream of
/// just that window (so other windows covering it don't show). ScreenCaptureKit only delivers
/// a frame when the window changes, and an unchanged window produces no frames at all.
///
/// The window can be resized: the stream is reconfigured to the new size, the next frame is a
/// keyframe, and frames report the new `sourceWidth`/`pointWidth`, so the caller can re-announce
/// the screen.
public final class MacWindowEncoder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public struct Frame: Sendable {
        /// NAL units, each prefixed with its length as a `lengthSize`-byte big-endian number.
        public let nalUnits: Data
        public let lengthSize: Int
        /// SPS and PPS, on keyframes.
        public let parameterSets: [Data]
        public let isKeyframe: Bool
        /// The window in pixels on its display, before scaling.
        public let sourceWidth: Int
        public let sourceHeight: Int
        /// The window in points.
        public let pointWidth: Double
        public let pointHeight: Double
    }

    /// One stream configuration: the window's size and the frames the stream makes for it.
    struct Geometry: Equatable {
        var points: (width: Double, height: Double)
        var pixels: (width: Int, height: Int)
        var output: (width: Int, height: Int)

        static func == (a: Geometry, b: Geometry) -> Bool {
            a.points == b.points && a.pixels == b.pixels && a.output == b.output
        }
    }

    public let windowID: UInt32
    private let filter: SCContentFilter
    private let pixelScale: Double
    private let scale: Double
    private let fps: Int
    /// Target bits per second for an encoded size.
    private let bitrate: @Sendable (_ width: Int, _ height: Int) -> Int
    private let queue = DispatchQueue(label: "dev.minirun.mac-window")
    private let lock = NSLock()
    private var stream: SCStream?

    // Guarded by `lock`.
    private var current: Geometry
    private var pending: Geometry?
    private var latest: (buffer: CVPixelBuffer, geometry: Geometry, number: Int)?
    private var frameCount = 0
    private var stopError: Error?
    private var changePending = false
    private var changeWaiter: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    private var waiterCount = 0

    // Only touched by encode(), jpeg() and close(), which the caller doesn't overlap.
    private var session: VTCompressionSession?
    private var sessionSize = (width: 0, height: 0)
    private var lastEncoded = 0
    private var nextSizeCheck = Date()

    init(window: SCWindow, scale: Double, fps: Int, bitrate: @escaping @Sendable (_ width: Int, _ height: Int) -> Int) {
        windowID = window.windowID
        filter = SCContentFilter(desktopIndependentWindow: window)
        pixelScale = Double(filter.pointPixelScale > 0 ? filter.pointPixelScale : 1)
        self.scale = scale
        self.fps = max(1, fps)
        self.bitrate = bitrate
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
        latest = (buffer, current, frameCount)
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

    /// Returns when the window has a new frame (or already had one since the last call), or after `timeout`.
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

    // MARK: Resizing

    /// The window's size in points from the window server, or nil once it's gone.
    static func windowSize(_ windowID: UInt32) -> (width: Double, height: Double)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              let bounds = info[kCGWindowBounds as String],
              let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary) else { return nil }
        return (Double(rect.width), Double(rect.height))
    }

    /// Follows the window's size (checked at most twice a second): a new size reconfigures the stream.
    private func followResize() async throws {
        guard Date() >= nextSizeCheck else { return }
        nextSizeCheck = Date().addingTimeInterval(0.5)
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

    // MARK: Encoding

    /// Encodes the latest frame. Returns nil when there's nothing new since the last frame
    /// (unless `forceKeyframe`), or before the first frame arrives.
    public func encode(forceKeyframe: Bool) async throws -> Frame? {
        try await followResize()
        let (snapshot, error) = lock.withLock { (self.latest, stopError) }
        if let error { throw MacDriverError("The window stream stopped: \(error.localizedDescription)") }
        guard let latest = snapshot else { return nil }
        if !forceKeyframe && latest.number == lastEncoded { return nil }

        let buffer = latest.buffer, geometry = latest.geometry
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var keyframe = forceKeyframe
        if session == nil || width != sessionSize.width || height != sessionSize.height {
            try makeSession(width: width, height: height)
            keyframe = true
        }
        guard let session else { return nil }
        lastEncoded = latest.number

        let time = CMClockGetTime(CMClockGetHostTimeClock())
        let options = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Frame?, Error>) in
            let once = ResumeOnce(continuation)
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: buffer, presentationTimeStamp: time, duration: .invalid,
                frameProperties: options, infoFlagsOut: nil
            ) { status, flags, sample in
                if status != noErr {
                    once.resume(.failure(MacDriverError("H.264 encoding failed (\(status)).")))
                } else if flags.contains(.frameDropped) || sample == nil {
                    once.resume(.success(nil))
                } else {
                    once.resume(.success(Self.frame(from: sample!, geometry: geometry)))
                }
            }
            if status != noErr {
                once.resume(.failure(MacDriverError("H.264 encoding failed (\(status)).")))
                return
            }
            // Realtime with no reordering: this returns as soon as the frame is out.
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: time)
        }
    }

    /// The latest frame as JPEG, `scale` image pixels per window pixel (as for simulator screens).
    public func jpeg(scale: Double, quality: Int) async throws -> (data: Data, width: Int, height: Int) {
        try await followResize()
        var snapshot: (buffer: CVPixelBuffer, geometry: Geometry, number: Int)?
        let deadline = Date().addingTimeInterval(2)
        while true {
            let state = lock.withLock { (self.latest, stopError) }
            snapshot = state.0
            let error = state.1
            if let error { throw MacDriverError("The window stream stopped: \(error.localizedDescription)") }
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

    public func close() {
        let stream = self.stream
        self.stream = nil
        stream?.stopCapture { _ in }
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    private func makeSession(width: Int, height: Int) throws {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        session = try H264Session.make(width: width, height: height, fps: fps, bitrate: bitrate(width, height)).session
        sessionSize = (width, height)
    }

    private static func frame(from sample: CMSampleBuffer, geometry: Geometry) -> Frame? {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        let isKeyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool) ?? false)

        var lengthSize: Int32 = 4
        var parameterSets: [Data] = []
        if let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize
            )
            if isKeyframe {
                for index in 0..<count {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                    ) == noErr, let pointer {
                        parameterSets.append(Data(bytes: pointer, count: size))
                    }
                }
            }
        }

        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        return Frame(
            nalUnits: data, lengthSize: Int(lengthSize), parameterSets: parameterSets, isKeyframe: isKeyframe,
            sourceWidth: geometry.pixels.width, sourceHeight: geometry.pixels.height,
            pointWidth: geometry.points.width, pointHeight: geometry.points.height
        )
    }
}

/// Resizing and JPEG encoding for window images.
enum MacImage {
    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        if image.width == width && image.height == height { return image }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func jpeg(_ image: CGImage, quality: Int) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MacDriverError("Could not create a JPEG encoder.")
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: Double(min(100, max(1, quality))) / 100.0,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MacDriverError("JPEG encoding failed.") }
        return output as Data
    }
}

/// Resumes a continuation once, whichever of VideoToolbox's paths reports first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
