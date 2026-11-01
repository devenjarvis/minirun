import Foundation
import CoreMedia
import CoreVideo
import IOSurface
import VideoToolbox
import FBControlCore
import FBSimulatorControl

/// Encodes a simulator's screen as H.264 with VideoToolbox (the hardware encoder when there is
/// one). Frames come straight from the simulator's framebuffer, an IOSurface, so there's no PNG
/// screenshot to take and decode. An unchanged screen produces no frames at all.
public final class ScreenEncoder: NSObject, FBFramebufferConsumer, @unchecked Sendable {
    /// Where frames come from: FBFramebuffer's main screen, or, on devices with several main
    /// screens (foldables), whichever of them is lit.
    enum Source {
        case framebuffer(FBFramebuffer)
        case displays(MainDisplays)
    }

    public struct Frame: Sendable {
        /// NAL units, each prefixed with its length as a `lengthSize`-byte big-endian number.
        public let nalUnits: Data
        public let lengthSize: Int
        /// SPS and PPS, on keyframes.
        public let parameterSets: [Data]
        public let isKeyframe: Bool
        /// The simulator's screen in pixels, before scaling.
        public let sourceWidth: Int
        public let sourceHeight: Int
        /// When the change this frame shows was first reported (the earliest framebuffer damage
        /// since the last frame), or when the screen was read if none was. For the latency readout.
        public let capturedAt: Date
    }

    private let source: Source
    private let scale: Double
    private let fps: Int
    /// Target bits per second for an encoded size.
    private let bitrate: @Sendable (_ width: Int, _ height: Int) -> Int
    private let queue = DispatchQueue(label: "dev.minirun.framebuffer")
    private let lock = NSLock()
    private var surface: IOSurface?
    /// The simulator reported damage that no `waitForChange` has picked up yet.
    private var changePending = false
    /// The first damage since `encode` last read the screen.
    private var damagedAt: Date?
    private var changeWaiter: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    private var waiterCount = 0

    // Only touched by encode() and close(), which the caller doesn't overlap.
    private var session: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var sourceSize = (width: 0, height: 0)
    private var lastSeed: UInt32?
    private var lastSurface: IOSurface?

    init(source: Source, scale: Double, fps: Int, bitrate: @escaping @Sendable (_ width: Int, _ height: Int) -> Int) {
        self.source = source
        self.scale = scale
        self.fps = fps
        self.bitrate = bitrate
        super.init()
        if case .framebuffer(let framebuffer) = source {
            let immediate = framebuffer.attach(self, on: queue)
            lock.lock()
            if surface == nil { surface = immediate }
            lock.unlock()
        }
    }

    // MARK: FBFramebufferConsumer

    public func didChange(_ surface: IOSurface?) {
        lock.lock()
        self.surface = surface
        lock.unlock()
        signalChange()
    }

    public func didReceiveDamageRect() {
        signalChange()
    }

    private func signalChange() {
        let now = Date()
        lock.lock()
        if damagedAt == nil { damagedAt = now }
        let waiter = changeWaiter
        changeWaiter = nil
        if waiter == nil { changePending = true }
        lock.unlock()
        waiter?.continuation.resume()
    }

    /// Returns when the simulator reports that the screen changed (or already has since the last
    /// call), or after `timeout`. Only the main screen's framebuffer reports changes; for the other
    /// sources this always waits for the timeout, which makes it a plain polling interval.
    public func waitForChange(timeout: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if changePending {
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

    // MARK: Encoding

    /// Encodes the current screen. Returns nil when the screen hasn't changed since the last
    /// frame (unless `forceKeyframe`), or before the simulator has delivered its first surface.
    public func encode(forceKeyframe: Bool) async throws -> Frame? {
        let current: IOSurface?
        var damaged: Date?
        switch source {
        case .framebuffer:
            lock.lock()
            current = surface
            damaged = damagedAt
            damagedAt = nil
            lock.unlock()
        case .displays(let displays):
            current = displays.currentSurface()
        }
        let capturedAt = damaged ?? Date()
        guard let current else { return nil }
        let seed = current.seed
        var keyframe = forceKeyframe
        if !keyframe && seed == lastSeed && current === lastSurface { return nil }

        let width = current.width, height = current.height
        if session == nil || width != sourceSize.width || height != sourceSize.height {
            try makeSession(width: width, height: height)
            keyframe = true
        }
        guard let session, let transfer, let pool else { return nil }

        var unmanaged: Unmanaged<CVPixelBuffer>?
        let surfaceRef = unsafeBitCast(current, to: IOSurfaceRef.self)
        guard CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surfaceRef, nil, &unmanaged) == kCVReturnSuccess,
              let source = unmanaged?.takeRetainedValue() else {
            throw SimulatorDriver.DriverError(message: "Could not read the simulator's screen.")
        }
        var scaled: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &scaled) == kCVReturnSuccess, let scaled else {
            throw SimulatorDriver.DriverError(message: "Could not allocate a video frame.")
        }
        // Copying out of the surface also means the simulator can't redraw it mid-encode.
        try check(VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled), "scale the screen")
        lastSeed = seed
        lastSurface = current

        let time = CMClockGetTime(CMClockGetHostTimeClock())
        let options = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Frame?, Error>) in
            let once = ResumeOnce(continuation)
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: scaled, presentationTimeStamp: time, duration: .invalid,
                frameProperties: options, infoFlagsOut: nil
            ) { status, flags, sample in
                if status != noErr {
                    once.resume(.failure(SimulatorDriver.DriverError(message: "H.264 encoding failed (\(status)).")))
                } else if flags.contains(.frameDropped) || sample == nil {
                    once.resume(.success(nil))
                } else {
                    once.resume(.success(Self.frame(from: sample!, sourceWidth: width, sourceHeight: height, capturedAt: capturedAt)))
                }
            }
            if status != noErr {
                once.resume(.failure(SimulatorDriver.DriverError(message: "H.264 encoding failed (\(status)).")))
                return
            }
            // Realtime with no reordering: this returns as soon as the frame is out.
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: time)
        }
    }

    public func close() {
        if case .framebuffer(let framebuffer) = source { framebuffer.detach(self) }
        invalidate()
    }

    private func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        session = nil
        transfer = nil
        pool = nil
    }

    private func makeSession(width: Int, height: Int) throws {
        invalidate()
        // H.264 wants even dimensions.
        let encodedWidth = max(16, Int(Double(width) * scale) & ~1)
        let encodedHeight = max(16, Int(Double(height) * scale) & ~1)

        var created: VTCompressionSession?
        try check(VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(encodedWidth), height: Int32(encodedHeight),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created
        ), "start the H.264 encoder")
        guard let created else { throw SimulatorDriver.DriverError(message: "Could not start the H.264 encoder.") }
        let properties: [CFString: CFTypeRef] = [
            kVTCompressionPropertyKey_RealTime: NSNumber(value: true),
            kVTCompressionPropertyKey_AllowFrameReordering: NSNumber(value: false),
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: NSNumber(value: bitrate(encodedWidth, encodedHeight)),
            kVTCompressionPropertyKey_ExpectedFrameRate: NSNumber(value: fps),
            // Viewers ask for keyframes when they join or fall behind; this is only a backstop.
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: NSNumber(value: 10),
        ]
        for (key, value) in properties {
            // Best effort: an encoder that lacks a property still produces a stream.
            _ = VTSessionSetProperty(created, key: key, value: value)
        }
        VTCompressionSessionPrepareToEncodeFrames(created)

        var createdTransfer: VTPixelTransferSession?
        try check(VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &createdTransfer), "start the video scaler")

        var createdPool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: encodedWidth,
            kCVPixelBufferHeightKey: encodedHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &createdPool) == kCVReturnSuccess else {
            throw SimulatorDriver.DriverError(message: "Could not allocate video frames.")
        }
        session = created
        transfer = createdTransfer
        pool = createdPool
        sourceSize = (width, height)
    }

    private static func frame(from sample: CMSampleBuffer, sourceWidth: Int, sourceHeight: Int, capturedAt: Date) -> Frame? {
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
            sourceWidth: sourceWidth, sourceHeight: sourceHeight, capturedAt: capturedAt
        )
    }

    private func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw SimulatorDriver.DriverError(message: "Could not \(action) (\(status)).") }
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
