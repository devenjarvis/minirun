import Foundation
import CoreGraphics
import CoreImage
import IOSurface
import CoreSimulator
import CoreSimDeviceIO
import FBSimulatorControl

/// A simulator's main screens, for devices with more than one. A foldable like the iPhone Duo has
/// an inner screen and a cover screen, and only the one in use is lit; the other stays black.
/// `FBFramebuffer.mainScreenSurface` and `takeScreenshot` always take the first main screen, so
/// they show black whenever the app is on the other one. This follows whichever screen is lit.
final class MainDisplays: @unchecked Sendable {
    private let renderables: [SimDisplayIOSurfaceRenderable]
    private let lock = NSLock()
    private var active: Int?
    private var checkedAt = Date.distantPast
    private var surfaces: [IOSurface?] = []

    /// How often to look again for the lit screen, so folding or unfolding is picked up.
    private static let recheckInterval: TimeInterval = 1

    /// The main screens of a simulator, or nil when it has just one (use FBFramebuffer then).
    static func load(_ simulator: FBSimulator) -> MainDisplays? {
        guard let io = simulator.device.io else { return nil }
        let renderables = io.ioPorts().compactMap { port -> SimDisplayIOSurfaceRenderable? in
            // The descriptors are XPC proxies: check selectors rather than protocol conformance.
            let descriptor = port.descriptor as AnyObject
            guard descriptor.responds(to: #selector(getter: SimDisplayDescriptorState.displayClass)),
                  descriptor.responds(to: #selector(getter: SimDisplayIOSurfaceRenderable.ioSurface)) else { return nil }
            guard unsafeBitCast(descriptor, to: SimDisplayDescriptorState.self).displayClass == 0 else { return nil }
            return unsafeBitCast(descriptor, to: SimDisplayIOSurfaceRenderable.self)
        }
        return renderables.count > 1 ? MainDisplays(renderables) : nil
    }

    private init(_ renderables: [SimDisplayIOSurfaceRenderable]) {
        self.renderables = renderables
    }

    /// The lit screen's surface. Checks which screen is lit at most once a second.
    func currentSurface() -> IOSurface? {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(checkedAt) >= Self.recheckInterval || surfaces.isEmpty {
            // Surfaces are replaced on rotation, so fetch them again too.
            surfaces = renderables.map(Self.surface)
            active = Self.pick(surfaces, previous: active)
            checkedAt = Date()
        }
        guard let active, active < surfaces.count else { return nil }
        return surfaces[active]
    }

    /// The lit screen as an image.
    func image() -> CGImage? {
        guard let surface = currentSurface() else { return nil }
        let image = CIImage(ioSurface: unsafeBitCast(surface, to: IOSurfaceRef.self))
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(image, from: image.extent)
    }

    private static func surface(_ renderable: SimDisplayIOSurfaceRenderable) -> IOSurface? {
        // Since Xcode 13.2 `framebufferSurface` is the primary one; older proxies only have `ioSurface`.
        (renderable.framebufferSurface ?? renderable.ioSurface) as? IOSurface
    }

    /// Prefers the one lit screen. With several lit, keeps the previous choice; with none (still
    /// booting), the first, as FBFramebuffer would.
    private static func pick(_ surfaces: [IOSurface?], previous: Int?) -> Int? {
        let lit = surfaces.indices.filter { surfaces[$0].map(isLit) ?? false }
        if lit.count == 1 { return lit[0] }
        if let previous, lit.isEmpty || lit.contains(previous) { return previous }
        return lit.first ?? surfaces.firstIndex { $0 != nil }
    }

    /// Whether any sampled pixel isn't black. An unused screen is entirely black.
    private static func isLit(_ surface: IOSurface) -> Bool {
        guard surface.lock(options: .readOnly, seed: nil) == kIOReturnSuccess else { return false }
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let base = surface.baseAddress.assumingMemoryBound(to: UInt32.self)
        let rowWords = surface.bytesPerRow / 4
        // BGRA: ignore alpha. A sparse grid is enough; a lit screen has a status bar if nothing else.
        for y in stride(from: 0, to: surface.height, by: 8) {
            let row = base + y * rowWords
            for x in stride(from: 0, to: surface.width, by: 4) where row[x] & 0x00FF_FFFF != 0 {
                return true
            }
        }
        return false
    }
}
