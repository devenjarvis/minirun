import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MiniRunKit
import UniformTypeIdentifiers

/// Turns a recording into what a PR can show inline: an animated GIF small enough for GitHub's
/// image proxy (GitHub won't play an externally hosted video), and a few still frames for the
/// agent to check its work. No ffmpeg: AVFoundation reads the frames and ImageIO writes the GIF.
enum GIFMaker {
    struct GIF {
        let data: Data
        let fps: Int
        let width: Int
        let height: Int
        let frames: Int
        /// False when even the smallest attempt is over the inline limit.
        let fits: Bool
    }

    /// Tried in order until the GIF fits the inline limit.
    static let attempts: [(fps: Int, width: Int)] = [(10, 320), (8, 280), (6, 240)]

    static func make(video: URL, limitBytes: Int) async throws -> GIF {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ToolError("The recording is empty.") }
        let shown = try await displaySize(asset)
        var last: GIF?
        for attempt in attempts {
            try Task.checkCancellation()
            let gif = try await encode(asset, duration: duration, shown: shown, fps: attempt.fps, width: attempt.width)
            if gif.data.count <= limitBytes { return gif }
            last = GIF(data: gif.data, fps: gif.fps, width: gif.width, height: gif.height, frames: gif.frames, fits: false)
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

    private static func encode(_ asset: AVURLAsset, duration: Double, shown: CGSize, fps: Int, width: Int) async throws -> GIF {
        let generator = makeGenerator(asset, shown: shown, width: width, tolerance: 0.5 / Double(fps))
        let count = max(1, Int(duration * Double(fps)))
        // The destination needs the frame count up front, so a frame that can't be read repeats
        // the one before; the first must work.
        var previous = try await generator.image(at: .zero).image

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, count, nil) else {
            throw ToolError("Couldn't create a GIF encoder.")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let delay = 1.0 / Double(fps)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay],
        ] as CFDictionary

        for index in 0..<count {
            try Task.checkCancellation()
            if index > 0, let image = try? await generator.image(at: CMTime(seconds: Double(index) * delay, preferredTimescale: 600)).image {
                previous = image
            }
            CGImageDestinationAddImage(destination, previous, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw ToolError("GIF encoding failed.") }
        return GIF(data: output as Data, fps: fps, width: previous.width, height: previous.height, frames: count, fits: true)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
