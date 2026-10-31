import Foundation

/// A rectangle in points with a top-left origin, the way macOS's global display coordinates
/// (CGWindowList, Accessibility, CGEvent) and window-relative tool coordinates both work.
public struct MacRect: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// Window-point ↔ global-point math for Mac app windows. Tools speak in window points (origin at
/// the window's top-left, title bar included); events and accessibility use global points.
public enum MacGeometry {
    /// A point in the window to global display coordinates.
    public static func toGlobal(windowPoint: (x: Double, y: Double), window: MacRect) -> (x: Double, y: Double) {
        (window.x + windowPoint.x, window.y + windowPoint.y)
    }

    /// A global point to window coordinates.
    public static func toWindow(globalPoint: (x: Double, y: Double), window: MacRect) -> (x: Double, y: Double) {
        (globalPoint.x - window.x, globalPoint.y - window.y)
    }

    /// A global rectangle (e.g. an accessibility element's frame) to window coordinates.
    public static func toWindow(globalRect: MacRect, window: MacRect) -> MacRect {
        MacRect(x: globalRect.x - window.x, y: globalRect.y - window.y, width: globalRect.width, height: globalRect.height)
    }

    /// Whether a window point lies inside the window.
    public static func contains(_ window: MacRect, windowPoint: (x: Double, y: Double)) -> Bool {
        windowPoint.x >= 0 && windowPoint.y >= 0 && windowPoint.x < window.width && windowPoint.y < window.height
    }

    /// The pixel size to capture a window at: its points times the display's backing scale.
    public static func capturePixels(points: (width: Double, height: Double), backingScale: Double) -> (width: Int, height: Int) {
        let factor = backingScale > 0 ? backingScale : 1
        return (max(1, Int((points.width * factor).rounded())), max(1, Int((points.height * factor).rounded())))
    }

    /// The size of a screenshot: `scale` image pixels per window point (default 1, so one pixel
    /// is one point and coordinates read straight off the image).
    public static func imageSize(points: (width: Double, height: Double), scale: Double?) -> (width: Int, height: Int) {
        let factor = (scale ?? 1) > 0 ? (scale ?? 1) : 1
        return (max(1, Int((points.width * factor).rounded())), max(1, Int((points.height * factor).rounded())))
    }

    /// An H.264-friendly size (even, at least 16) for `pixels` scaled by `scale`.
    public static func videoSize(pixels: (width: Int, height: Int), scale: Double) -> (width: Int, height: Int) {
        let factor = scale > 0 ? min(scale, 1) : 1
        return (max(16, Int(Double(pixels.width) * factor) & ~1), max(16, Int(Double(pixels.height) * factor) & ~1))
    }

    /// Evenly spaced points from `start` to `end` (both included), for a drag of `steps` moves.
    public static func path(from start: (x: Double, y: Double), to end: (x: Double, y: Double), steps: Int) -> [(x: Double, y: Double)] {
        let count = max(1, steps)
        return (0...count).map { step in
            let t = Double(step) / Double(count)
            return (start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t)
        }
    }
}
