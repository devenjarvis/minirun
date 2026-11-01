#if canImport(VideoToolbox)
import XCTest
import CoreMedia
import CoreVideo
import VideoToolbox
@testable import MiniRunKit

final class H264SessionTests: XCTestCase {
    /// Encodes one frame on this Mac's encoder and checks that the SPS the viewer gets says frames
    /// are never reordered. Machines without a usable H.264 encoder (some CI virtual machines) skip it.
    func testEncodesAFrameWithoutReordering() throws {
        let (width, height) = (602, 1310)
        let made: (session: VTCompressionSession, lowLatency: Bool)
        do {
            made = try H264Session.make(width: width, height: height, fps: 30, bitrate: 1_500_000)
        } catch {
            throw XCTSkip("No H.264 encoder here: \(error.localizedDescription)")
        }
        defer { VTCompressionSessionInvalidate(made.session) }

        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &buffer
        ), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(frame) {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(frame, plane))
            let rows = CVPixelBufferGetHeightOfPlane(frame, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(frame, plane)
            for row in 0..<rows { memset(base + row * stride, Int32(row % 256), stride) }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])

        var sps: Data?
        let time = CMTime(value: 0, timescale: 30)
        let status = VTCompressionSessionEncodeFrame(
            made.session, imageBuffer: frame, presentationTimeStamp: time, duration: .invalid,
            frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary, infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample, let format = CMSampleBufferGetFormatDescription(sample) else { return }
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer {
                sps = Data(bytes: pointer, count: size)
            }
        }
        guard status == noErr else { throw XCTSkip("The encoder here can't encode (\(status)).") }
        VTCompressionSessionCompleteFrames(made.session, untilPresentationTimeStamp: time)

        let encoded = try XCTUnwrap(sps, "a keyframe carries an SPS")
        let rewritten = H264.withoutReordering(sps: encoded)
        print("H264Session: low-latency \(made.lowLatency), profile_idc \(encoded[1]), constraints 0x\(String(encoded[2], radix: 16)), "
            + "SPS \(encoded.map { String(format: "%02x", $0) }.joined())")
        XCTAssertEqual(H264.maxNumReorderFrames(sps: rewritten), 0, "the SPS the viewer gets says frames are never reordered")
        XCTAssertEqual(Array(rewritten.prefix(4)), Array(encoded.prefix(4)), "header, profile and level unchanged")
    }
}
#endif
