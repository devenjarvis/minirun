import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import VideoToolbox
import MiniRunKit

/// Encodes one Mac app window as H.264 with VideoToolbox, fed by a `MacWindowCapture` of just
/// that window. ScreenCaptureKit only delivers a frame when the window changes, and an unchanged
/// window produces no frames at all.
///
/// The window can be resized: the stream is reconfigured to the new size, the next frame is a
/// keyframe, and frames report the new `sourceWidth`/`pointWidth`, so the caller can re-announce
/// the screen.
public final class MacWindowEncoder: NSObject, @unchecked Sendable {
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
        /// When ScreenCaptureKit delivered the frame (or when it was encoded again, for a keyframe
        /// of an unchanged window). For the latency readout.
        public let capturedAt: Date
    }

    typealias Geometry = MacWindowCapture.Geometry

    public var windowID: UInt32 { capture.windowID }
    private let capture: MacWindowCapture
    private let fps: Int
    /// Target bits per second for an encoded size.
    private let bitrate: @Sendable (_ width: Int, _ height: Int) -> Int

    // Only touched by encode(), jpeg() and close(), which the caller doesn't overlap.
    private var session: VTCompressionSession?
    private var sessionSize = (width: 0, height: 0)
    private var lastEncoded = 0

    init(capture: MacWindowCapture, fps: Int, bitrate: @escaping @Sendable (_ width: Int, _ height: Int) -> Int) {
        self.capture = capture
        self.fps = max(1, fps)
        self.bitrate = bitrate
        super.init()
    }

    func start() async throws {
        try await capture.start()
    }

    /// Returns when the window has a new frame (or already had one since the last call), or after `timeout`.
    public func waitForChange(timeout: TimeInterval) async {
        await capture.waitForChange(timeout: timeout)
    }

    // MARK: Encoding

    /// Encodes the latest frame. Returns nil when there's nothing new since the last frame
    /// (unless `forceKeyframe`), or before the first frame arrives.
    public func encode(forceKeyframe: Bool) async throws -> Frame? {
        try await capture.followResize()
        guard let latest = try capture.latestFrame() else { return nil }
        if !forceKeyframe && latest.number == lastEncoded { return nil }
        let capturedAt = latest.number == lastEncoded ? Date() : latest.arrivedAt

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
                    once.resume(.success(Self.frame(from: sample!, geometry: geometry, capturedAt: capturedAt)))
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
        try await capture.jpeg(scale: scale, quality: quality)
    }

    public func close() {
        capture.close()
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    private func makeSession(width: Int, height: Int) throws {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        session = try H264Session.make(width: width, height: height, fps: fps, bitrate: bitrate(width, height)).session
        sessionSize = (width, height)
    }

    private static func frame(from sample: CMSampleBuffer, geometry: Geometry, capturedAt: Date) -> Frame? {
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
            pointWidth: geometry.points.width, pointHeight: geometry.points.height, capturedAt: capturedAt
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
