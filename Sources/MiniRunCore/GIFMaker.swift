import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MiniRunKit
import UniformTypeIdentifiers

/// Turns a recording into what a PR can show inline: an animated GIF (GitHub won't play an
/// externally hosted video), and a few still frames for the agent to check its work. No ffmpeg:
/// AVFoundation reads the frames and `GIFEncoder` writes the GIF, storing only what changed
/// from frame to frame, so a sharp, smooth GIF of an app stays small.
enum GIFMaker {
    struct GIF {
        let data: Data
        let fps: Int
        let width: Int
        let height: Int
        /// Frames stored; frames where nothing moved are folded into the one before.
        let frames: Int
        /// False when even the smallest attempt is over the limit.
        let fits: Bool
    }

    /// Tried in order until the GIF fits: frames a second, and width as a multiple of the
    /// screen's width in points (2 is as sharp as a Retina screenshot).
    static let attempts: [(fps: Int, scale: Double)] = [(15, 2), (15, 1.5), (12, 1), (10, 0.8)]
    /// The last resort, as before: small enough for nearly any clip.
    static let fallback = (fps: 6, width: 240)
    /// Wider than this is more than a PR description can show anyway.
    static let maxWidth = 1280

    /// The widths and frame rates to try for a video `shown` pixels wide, best first.
    static func plan(shownWidth: Double, pointWidth: Double?) -> [(fps: Int, width: Int)] {
        // Without the point size, assume a 3x screen.
        let points = pointWidth ?? shownWidth / 3
        var plan: [(fps: Int, width: Int)] = []
        for attempt in attempts {
            let width = Int(min(Double(maxWidth), shownWidth, (points * attempt.scale).rounded()))
            if width > fallback.width, !plan.contains(where: { $0.fps == attempt.fps && $0.width == width }) {
                plan.append((attempt.fps, width))
            }
        }
        plan.append(fallback)
        return plan
    }

    static func make(video: URL, pointWidth: Double?, limitBytes: Int) async throws -> GIF {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ToolError("The recording is empty.") }
        let shown = try await displaySize(asset)
        let plan = plan(shownWidth: shown.width, pointWidth: pointWidth)
        var last: GIF?
        var overshoot: (bytesPerSecond: Double, fps: Int, width: Int)?
        for (index, attempt) in plan.enumerated() {
            try Task.checkCancellation()
            let isLast = index == plan.count - 1
            // Skip a step that the last try shows can't fit: size grows with area and, for
            // motion, with frame rate.
            if !isLast, let overshoot {
                let area = pow(Double(attempt.width) / Double(overshoot.width), 2)
                let rate = Double(attempt.fps) / Double(overshoot.fps)
                if overshoot.bytesPerSecond * duration * area * rate > Double(limitBytes) * 1.15 { continue }
            }
            let result = try await encode(asset, duration: duration, shown: shown, fps: attempt.fps, width: attempt.width,
                                          stopAbove: isLast ? nil : limitBytes)
            switch result {
            case .done(let gif):
                if gif.data.count <= limitBytes { return gif }
                last = GIF(data: gif.data, fps: gif.fps, width: gif.width, height: gif.height, frames: gif.frames, fits: false)
            case .tooBig(let seconds, let bytes):
                overshoot = (Double(bytes) / max(seconds, 0.5), attempt.fps, attempt.width)
            }
        }
        return last!
    }

    /// JPEG stills of the first, middle and last moments, one image pixel per screen point.
    static func stills(video: URL, pointWidth: Double?) async throws -> [Data] {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return [] }
        let shown = try await displaySize(asset)
        // Without the point size, assume a 3x screen.
        let width = Int((pointWidth ?? shown.width / 3).rounded())
        let generator = makeGenerator(asset, shown: shown, width: width, tolerance: 0.1)
        var stills: [Data] = []
        for time in [0, duration / 2, max(0, duration - 0.2)] {
            guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image,
                  let jpeg = jpeg(image) else { continue }
            stills.append(jpeg)
        }
        return stills
    }

    /// The video's size as shown, after its track's rotation.
    private static func displaySize(_ asset: AVURLAsset) async throws -> CGSize {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ToolError("The recording has no video track.")
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let shown = natural.applying(transform)
        return CGSize(width: abs(shown.width), height: abs(shown.height))
    }

    private static func makeGenerator(_ asset: AVURLAsset, shown: CGSize, width: Int, tolerance: Double) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let target = min(Double(width), Double(shown.width))
        if shown.width > 0 {
            // maximumSize is a box the frame is fitted into; a little extra height keeps width the limit.
            generator.maximumSize = CGSize(width: target, height: (target * shown.height / shown.width).rounded(.up) + 2)
        }
        let slack = CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack
        return generator
    }

    private enum Outcome {
        case done(GIF)
        /// Went over `stopAbove` `seconds` into the video, at `bytes`.
        case tooBig(seconds: Double, bytes: Int)
    }

    private static func encode(_ asset: AVURLAsset, duration: Double, shown: CGSize, fps: Int, width: Int, stopAbove: Int?) async throws -> Outcome {
        let generator = makeGenerator(asset, shown: shown, width: width, tolerance: 0.5 / Double(fps))
        let count = max(1, Int((duration * Double(fps)).rounded(.up)))
        let delay = 1.0 / Double(fps)
        // A frame that can't be read repeats the one before; the first must work.
        let first = try await generator.image(at: .zero).image
        var canvas = try RGBACanvas(width: first.width, height: first.height)
        var encoder = GIFEncoder(width: canvas.width, height: canvas.height)
        canvas.draw(first)

        for index in 0..<count {
            try Task.checkCancellation()
            if index > 0, let image = try? await generator.image(at: CMTime(seconds: Double(index) * delay, preferredTimescale: 600)).image {
                canvas.draw(image)
            }
            let start = Double(index) * delay
            canvas.withPixels { encoder.add(rgba: $0, bytesPerRow: canvas.bytesPerRow, duration: min(delay, max(0.01, duration - start))) }
            if let stopAbove, encoder.byteCount > stopAbove {
                return .tooBig(seconds: start + delay, bytes: encoder.byteCount)
            }
        }
        let data = encoder.finish()
        return .done(GIF(data: data, fps: fps, width: canvas.width, height: canvas.height, frames: encoder.storedFrames, fits: true))
    }

    /// One frame's pixels as RGBA bytes, for `GIFEncoder`.
    private struct RGBACanvas {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        private let context: CGContext

        init(width: Int, height: Int) throws {
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { throw ToolError("Couldn't make a \(width)x\(height) bitmap for the GIF.") }
            context.interpolationQuality = .high
            self.width = width
            self.height = height
            self.bytesPerRow = context.bytesPerRow
            self.context = context
        }

        /// Draws `image` to fill the canvas (frames can differ by a pixel after scaling).
        mutating func draw(_ image: CGImage) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        func withPixels<T>(_ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
            let base = context.data!.assumingMemoryBound(to: UInt8.self)
            return body(UnsafeBufferPointer(start: base, count: bytesPerRow * height))
        }
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
