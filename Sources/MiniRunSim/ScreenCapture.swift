import Foundation
import CoreVideo
import IOSurface
import VideoToolbox
import FBControlCore
import FBSimulatorControl

/// A simulator's screen as it changes: the framebuffer's IOSurface, and a wait that returns when
/// the simulator reports damage. `ScreenEncoder` (H.264 over the relay) and the WebRTC sessions
/// both read the screen through this.
public final class SimulatorScreenCapture: NSObject, FBFramebufferConsumer, @unchecked Sendable {
    /// Where frames come from: FBFramebuffer's main screen, or, on devices with several main
    /// screens (foldables), whichever of them is lit.
    enum Source {
        case framebuffer(FBFramebuffer)
        case displays(MainDisplays)
    }

    private let source: Source
    private let queue = DispatchQueue(label: "dev.minirun.framebuffer")
    private let lock = NSLock()
    private var surface: IOSurface?
    /// The simulator reported damage that no `waitForChange` has picked up yet.
    private var changePending = false
    /// The first damage since `takeSurface` last read the screen.
    private var damagedAt: Date?
    private var changeWaiter: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    private var waiterCount = 0

    init(source: Source) {
        self.source = source
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

    /// The screen as of now, or nil before the simulator has delivered its first surface. The
    /// simulator keeps drawing into it, so copy it before handing it to anything asynchronous.
    public func currentSurface() -> IOSurface? {
        switch source {
        case .framebuffer:
            lock.lock()
            defer { lock.unlock() }
            return surface
        case .displays(let displays):
            return displays.currentSurface()
        }
    }

    /// The screen as of now, and when the change it shows was first reported (the earliest
    /// damage since the last call; nil when none was, or for sources that don't report damage).
    public func takeSurface() -> (surface: IOSurface?, damagedAt: Date?) {
        switch source {
        case .framebuffer:
            lock.lock()
            defer { lock.unlock() }
            let damaged = damagedAt
            damagedAt = nil
            return (surface, damaged)
        case .displays(let displays):
            return (displays.currentSurface(), nil)
        }
    }

    /// Returns when the simulator reports that the screen changed (or already has since the last
    /// call), or after `timeout`. Only the main screen's framebuffer reports changes; for the other
    /// sources this always waits for the timeout, which makes it a plain polling interval. One
    /// waiter at a time.
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

    public func close() {
        if case .framebuffer(let framebuffer) = source { framebuffer.detach(self) }
        // Don't leave a waiter hanging.
        signalChange()
    }
}

/// Copies IOSurfaces into pixel buffers of their own (NV12, which video encoders take directly),
/// so a frame doesn't change while an encoder still holds it.
public final class SurfaceCopier: @unchecked Sendable {
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var size = (width: 0, height: 0)

    public init() {}

    /// A copy of `surface` at its own size, or nil if it can't be read.
    public func copy(_ surface: IOSurface) -> CVPixelBuffer? {
        let width = surface.width, height = surface.height
        if pool == nil || width != size.width || height != size.height {
            invalidate()
            var createdTransfer: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &createdTransfer) == noErr else { return nil }
            var createdPool: CVPixelBufferPool?
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                // Video wants even dimensions.
                kCVPixelBufferWidthKey: max(2, width & ~1),
                kCVPixelBufferHeightKey: max(2, height & ~1),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            ]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &createdPool) == kCVReturnSuccess else { return nil }
            transfer = createdTransfer
            pool = createdPool
            size = (width, height)
        }
        guard let transfer, let pool else { return nil }
        var unmanaged: Unmanaged<CVPixelBuffer>?
        let surfaceRef = unsafeBitCast(surface, to: IOSurfaceRef.self)
        guard CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surfaceRef, nil, &unmanaged) == kCVReturnSuccess,
              let source = unmanaged?.takeRetainedValue() else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess, let output else { return nil }
        guard VTPixelTransferSessionTransferImage(transfer, from: source, to: output) == noErr else { return nil }
        return output
    }

    public func invalidate() {
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        transfer = nil
        pool = nil
    }

    deinit {
        invalidate()
    }
}
