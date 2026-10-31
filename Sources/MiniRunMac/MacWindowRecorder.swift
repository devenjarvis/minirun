import Foundation
import CoreMedia
import ScreenCaptureKit
import MiniRunKit

/// Records one Mac app window to an H.264 .mp4 with ScreenCaptureKit's `SCRecordingOutput`. Like
/// screenshots and the live view, it captures just that window, so other windows covering it
/// don't show, and neither do its menus or popovers (they're windows of their own).
///
/// An mp4 can't change size partway through, so the video keeps the window's size from when the
/// recording started: if the window is resized, its frames are scaled to fit, letterboxed.
public final class MacWindowRecorder: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate, @unchecked Sendable {
    public let windowID: UInt32
    public let file: URL
    /// The video's size in pixels.
    public let width: Int
    public let height: Int

    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let queue = DispatchQueue(label: "dev.minirun.mac-recording")
    /// Told why, when the recording stops by itself (the window closed, ScreenCaptureKit gave up).
    private let onStop: @Sendable (String) -> Void

    private let lock = NSLock()
    // Guarded by `lock`.
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var didStart = false
    private var didFinish = false
    private var failure: Error?
    private var stopping = false
    private var reportedStop = false

    private init(window: SCWindow, file: URL, fps: Int, onStop: @escaping @Sendable (String) -> Void) {
        windowID = window.windowID
        self.file = file
        self.onStop = onStop
        filter = SCContentFilter(desktopIndependentWindow: window)
        let rect = filter.contentRect
        let points = rect.width > 0 && rect.height > 0 ? (Double(rect.width), Double(rect.height)) : (Double(window.frame.width), Double(window.frame.height))
        let pixelScale = filter.pointPixelScale > 0 ? Double(filter.pointPixelScale) : 1
        let size = MacGeometry.videoSize(pixels: MacGeometry.capturePixels(points: points, backingScale: pixelScale), scale: 1)
        width = size.width
        height = size.height

        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.capturesAudio = false
        // No shadow, so the video is exactly the window, as in screenshots.
        configuration.ignoreShadowsSingleWindow = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        self.configuration = configuration
        super.init()
    }

    /// Starts recording the window into `file` (which must not exist yet). `onStop` is called,
    /// at most once, if the recording stops before `finish()`.
    public static func start(windowID: UInt32, file: URL, fps: Int = 30, onStop: @escaping @Sendable (String) -> Void) async throws -> MacWindowRecorder {
        try MacPermissions.requireScreenRecording(for: "record Mac app windows")
        let window = try await MacAppDriver.shareableWindow(windowID)
        let recorder = MacWindowRecorder(window: window, file: file, fps: fps, onStop: onStop)
        try await recorder.begin()
        return recorder
    }

    private func begin() async throws {
        let settings = SCRecordingOutputConfiguration()
        settings.outputURL = file
        settings.outputFileType = .mp4
        settings.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: settings, delegate: self)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        // A screen output too, which does nothing: the stream then always has frames to deliver.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addRecordingOutput(output)
        lock.withLock {
            self.stream = stream
            self.output = output
        }
        do {
            try await stream.startCapture()
        } catch {
            throw MacDriverError("ScreenCaptureKit couldn't start recording the window: \(error.localizedDescription)")
        }
        // The recording starts with the first frame, which comes almost at once. Fail only on an
        // error: a window that hasn't drawn yet still records once it does.
        for _ in 0..<50 {
            let (started, failed) = lock.withLock { (didStart, failure) }
            if let failed {
                try? await stream.stopCapture()
                throw MacDriverError("ScreenCaptureKit couldn't record the window: \(failed.localizedDescription)")
            }
            if started { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Stops recording and waits for the file to be finished. Returns what went wrong, if
    /// ScreenCaptureKit reported an error; the file may still hold what was recorded until then.
    public func finish() async -> String? {
        let (stream, output) = lock.withLock { () -> (SCStream?, SCRecordingOutput?) in
            stopping = true
            return (self.stream, self.output)
        }
        // Removing the recording output is what ends the recording and writes the file's index.
        if let stream, let output { try? stream.removeRecordingOutput(output) }
        try? await stream?.stopCapture()
        for _ in 0..<200 {
            let (finished, failed) = lock.withLock { (didFinish, failure) }
            if finished || failed != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return lock.withLock { () -> String? in
            if let failure { return "ScreenCaptureKit reported: \(failure.localizedDescription)" }
            return didFinish ? nil : "ScreenCaptureKit didn't say the recording finished within 10 seconds."
        }
    }

    /// Calls `onStop` once, unless `finish()` is what stopped it.
    private func stoppedByItself(_ reason: String) {
        let report = lock.withLock { () -> Bool in
            guard !stopping, !reportedStop else { return false }
            reportedStop = true
            return true
        }
        if report { onStop(reason) }
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { if failure == nil, !stopping { failure = error } }
        stoppedByItself("ScreenCaptureKit stopped capturing the window (it may have closed): \(error.localizedDescription)")
    }

    // MARK: SCRecordingOutputDelegate

    public func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { didStart = true }
    }

    public func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lock.withLock { failure = error }
        stoppedByItself("ScreenCaptureKit couldn't keep recording: \(error.localizedDescription)")
    }

    public func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { didFinish = true }
    }
}
