#if canImport(VideoToolbox)
import Foundation
import VideoToolbox

/// The live view's H.264 compression session, shared by the simulator and Mac window encoders.
public enum H264Session {
    public struct StartError: Error, LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? { "Could not start the H.264 encoder (\(status))." }
    }

    /// Creates a realtime session with no frame reordering. It asks for VideoToolbox's low-latency
    /// mode first, which sends each frame out as soon as it's encoded instead of holding frames
    /// back for rate control. That mode only takes the constrained profiles, so High is tried and
    /// then Baseline. If the encoder refuses all of it, the session is made the way it was before
    /// low-latency mode, so the stream still starts. `lowLatency` says which one it got.
    public static func make(width: Int, height: Int, fps: Int, bitrate: Int) throws -> (session: VTCompressionSession, lowLatency: Bool) {
        if let session = makeLowLatency(width: width, height: height, fps: fps, bitrate: bitrate) {
            return (session, true)
        }
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw StartError(status: status) }
        setCommonProperties(created, fps: fps, bitrate: bitrate)
        _ = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTCompressionSessionPrepareToEncodeFrames(created)
        return (created, false)
    }

    private static func makeLowLatency(width: Int, height: Int, fps: Int, bitrate: Int) -> VTCompressionSession? {
        var created: VTCompressionSession?
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        guard VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created
        ) == noErr, let created else { return nil }
        let profiles = [kVTProfileLevel_H264_ConstrainedHigh_AutoLevel, kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel]
        guard profiles.contains(where: { VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: $0) == noErr }) else {
            VTCompressionSessionInvalidate(created)
            return nil
        }
        setCommonProperties(created, fps: fps, bitrate: bitrate)
        // Best effort, like the common properties: low-latency mode already implies most of this.
        _ = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0))
        _ = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        guard VTCompressionSessionPrepareToEncodeFrames(created) == noErr else {
            VTCompressionSessionInvalidate(created)
            return nil
        }
        return created
    }

    private static func setCommonProperties(_ session: VTCompressionSession, fps: Int, bitrate: Int) {
        let properties: [CFString: CFTypeRef] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse,
            kVTCompressionPropertyKey_AverageBitRate: NSNumber(value: bitrate),
            kVTCompressionPropertyKey_ExpectedFrameRate: NSNumber(value: fps),
            // Viewers ask for keyframes when they join or fall behind; this is only a backstop.
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: NSNumber(value: 10),
        ]
        for (key, value) in properties {
            // Best effort: an encoder that lacks a property still produces a stream.
            _ = VTSessionSetProperty(session, key: key, value: value)
        }
    }
}
#endif
