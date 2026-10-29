import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FBControlCore
import FBSimulatorControl

/// In-process simulator control built on FBSimulatorControl, using AXe's vendored helpers for
/// HID input, accessibility and orientation handling (see AXe/LICENSE-AXe).
@MainActor
public final class SimulatorDriver {
    public static let shared = SimulatorDriver()

    public enum Button: String, CaseIterable, Sendable {
        case home, lock, siri
        case sideButton = "side-button"
        case applePay = "apple-pay"

        var hid: FBSimulatorHIDButton {
            switch self {
            case .applePay: return FBSimulatorHIDButton(rawValue: 1)!
            case .home: return FBSimulatorHIDButton(rawValue: 2)!
            case .lock: return FBSimulatorHIDButton(rawValue: 3)!
            case .sideButton: return FBSimulatorHIDButton(rawValue: 4)!
            case .siri: return FBSimulatorHIDButton(rawValue: 5)!
            }
        }
    }

    public enum ElementQuery: Sendable {
        case id(String)
        case label(String)
        case value(String)

        var axe: AccessibilityQuery {
            switch self {
            case .id(let value): return .id(value)
            case .label(let value): return .label(value)
            case .value(let value): return .value(value)
            }
        }
    }

    public struct DriverError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private let logger = AxeLogger()
    private var didSetup = false
    private var simulatorSet: FBSimulatorSet?

    private init() {}

    // MARK: Setup

    /// Loads CoreSimulator / SimulatorKit from the selected Xcode. Safe to call repeatedly.
    public func prepare() async throws {
        guard !didSetup else { return }
        try await performGlobalSetup(logger: logger)
        didSetup = true
    }

    private func simulator(_ udid: String) async throws -> FBSimulator {
        try await prepare()
        if simulatorSet == nil {
            simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        }
        var found = simulatorSet?.allSimulators.first(where: { $0.udid == udid })
        if found == nil {
            // A simulator created after we started: refresh the set once.
            simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
            found = simulatorSet?.allSimulators.first(where: { $0.udid == udid })
        }
        guard let simulator = found else {
            throw DriverError(message: "No simulator with UDID \(udid).")
        }
        guard simulator.state == .booted else {
            throw DriverError(message: "Simulator \(simulator.name) (\(udid)) is not booted. Call boot_simulator first.")
        }
        return simulator
    }

    // MARK: Screen

    /// Captures the screen as JPEG. The image is resized to `targetWidth` pixels if given,
    /// otherwise by `scale` relative to native pixels.
    public func screenshotJPEG(udid: String, targetWidth: Int? = nil, scale: Double = 1.0, quality: Int = 75) async throws -> (data: Data, width: Int, height: Int) {
        let target = try await simulator(udid)
        let png = try await target.takeScreenshot(format: .png)
        return try Self.encodeJPEG(png, targetWidth: targetWidth, scale: scale, quality: quality)
    }

    /// An H.264 encoder fed straight from the simulator's display. `bitrate` gets the encoded size.
    public func screenEncoder(udid: String, scale: Double, fps: Int, bitrate: @escaping @Sendable (_ width: Int, _ height: Int) -> Int) async throws -> ScreenEncoder {
        let target = try await simulator(udid)
        let framebuffer = try FBFramebuffer.mainScreenSurface(for: target, logger: logger)
        return ScreenEncoder(framebuffer: framebuffer, scale: scale, fps: fps, bitrate: bitrate)
    }

    public func screenshotPNG(udid: String) async throws -> Data {
        try await simulator(udid).takeScreenshot(format: .png)
    }

    nonisolated static func encodeJPEG(_ imageData: Data, targetWidth: Int? = nil, scale: Double, quality: Int) throws -> (data: Data, width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            throw DriverError(message: "Could not decode the simulator screenshot.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int
        let height = properties?[kCGImagePropertyPixelHeight] as? Int
        var factor = scale
        if let targetWidth, let width, width > 0 { factor = Double(targetWidth) / Double(width) }
        let image: CGImage?
        if factor < 0.999, let width, let height {
            let maxSide = max(16, Int((Double(max(width, height)) * factor).rounded()))
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { throw DriverError(message: "Could not decode the simulator screenshot.") }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw DriverError(message: "Could not create a JPEG encoder.")
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: Double(min(100, max(1, quality))) / 100.0,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw DriverError(message: "JPEG encoding failed.") }
        return (output as Data, image.width, image.height)
    }

    // MARK: Accessibility

    /// The accessibility tree of the frontmost app as AXe-format JSON, or the element at a point.
    public func describeUI(udid: String, x: Double? = nil, y: Double? = nil) async throws -> Data {
        _ = try await simulator(udid)
        let point = (x != nil && y != nil) ? AccessibilityPoint(x: x!, y: y!) : nil
        return try await AccessibilityFetcher.fetchAccessibilityInfoJSONData(for: udid, point: point, logger: logger)
    }

    // MARK: Input (coordinates are in points, in the current UI orientation)

    /// Taps a point, or an element found by accessibility id/label/value. Returns the point tapped.
    @discardableResult
    public func tap(udid: String, x: Double? = nil, y: Double? = nil, query: ElementQuery? = nil, wait: TimeInterval = 0) async throws -> (x: Double, y: Double) {
        _ = try await simulator(udid)
        let resolution: TapResolution
        if let query {
            resolution = try await AccessibilityPoller.resolveWithPolling(
                query: query.axe,
                simulatorUDID: udid,
                waitTimeout: wait,
                pollInterval: 0.25,
                logger: logger
            )
        } else if let x, let y {
            resolution = TapResolution(point: (x: x, y: y), isSwitchLikeControl: false)
        } else {
            throw DriverError(message: "Give either x and y, or an element id/label/value to tap.")
        }

        let physical = try await OrientationAwareCoordinates.translate(point: resolution.point, for: udid, logger: logger)
        if resolution.isSwitchLikeControl {
            try await HIDInteractor.performPhysicalTap(at: physical, preDelay: nil, postDelay: nil, for: udid, logger: logger)
        } else {
            try await HIDInteractor.performHIDEvent(.tapAt(x: physical.x, y: physical.y), for: udid, logger: logger)
        }
        return resolution.point
    }

    public func swipe(udid: String, from start: (x: Double, y: Double), to end: (x: Double, y: Double), duration: TimeInterval = 0.4) async throws {
        _ = try await simulator(udid)
        let points = try await OrientationAwareCoordinates.translateBatch(points: [start, end], for: udid, logger: logger)
        let delta = max(5.0, hypot(points[1].x - points[0].x, points[1].y - points[0].y) / 20.0)
        let event = FBSimulatorHIDEvent.swipe(
            points[0].x,
            yStart: points[0].y,
            xEnd: points[1].x,
            yEnd: points[1].y,
            delta: delta,
            duration: max(0.05, duration)
        )
        try await HIDInteractor.performHIDEvent(event, for: udid, logger: logger)
    }

    /// Long press / drag primitive: touch down at `start`, move to `end` over `duration`, release.
    public func drag(udid: String, from start: (x: Double, y: Double), to end: (x: Double, y: Double), duration: TimeInterval, hold: TimeInterval) async throws {
        _ = try await simulator(udid)
        let points = try await OrientationAwareCoordinates.translateBatch(points: [start, end], for: udid, logger: logger)
        let event = try HIDInteractor.makeCompositeDragEvent(
            from: points[0],
            to: points[1],
            duration: duration,
            steps: max(1, Int(duration * 30)),
            initialHold: hold,
            finalHold: 0.05
        )
        try await HIDInteractor.performHIDEvent(event, for: udid, logger: logger)
    }

    public func typeText(udid: String, text: String) async throws {
        _ = try await simulator(udid)
        guard TextToHIDEvents.validateText(text) else {
            throw DriverError(message: "type_text only supports characters on a US keyboard. For other text, paste it with set_pasteboard and long-press to paste.")
        }
        let events = try TextToHIDEvents.convertTextToHIDEvents(text)
        guard !events.isEmpty else { return }
        try await HIDInteractor.performHIDEvent(.composite(events), for: udid, logger: logger)
    }

    /// Presses a named key: return, delete, tab, escape, space, arrows.
    public func pressKey(udid: String, name: String) async throws {
        _ = try await simulator(udid)
        let codes: [String: UInt32] = [
            "return": 40, "enter": 40, "escape": 41, "delete": 42, "backspace": 42, "tab": 43, "space": 44,
            "right": 79, "left": 80, "down": 81, "up": 82,
        ]
        guard let code = codes[name.lowercased()] else {
            throw DriverError(message: "Unknown key \(name). Use one of: \(codes.keys.sorted().joined(separator: ", ")).")
        }
        try await HIDInteractor.performHIDEvent(.shortKeyPress(code), for: udid, logger: logger)
    }

    public func pressButton(udid: String, button: Button, duration: TimeInterval? = nil) async throws {
        _ = try await simulator(udid)
        let event: FBSimulatorHIDEvent
        if let duration, duration > 0 {
            event = .composite([
                .button(direction: .down, button: button.hid),
                .delay(duration),
                .button(direction: .up, button: button.hid),
            ])
        } else {
            event = .shortButtonPress(button.hid)
        }
        try await HIDInteractor.performHIDEvent(event, for: udid, logger: logger)
    }

    /// Drops cached HID connections, e.g. after a simulator reboots. Pass `udid` to leave other
    /// simulators' connections alone.
    public func reset(udid: String? = nil) {
        HIDInteractor.clearHIDConnections(for: udid)
        simulatorSet = nil
    }
}
