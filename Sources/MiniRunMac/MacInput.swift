import Foundation
import CoreGraphics
import MiniRunKit

/// How input reached a Mac app.
///
/// - `pid`: CGEvents posted straight to the app's process with the target window number set.
///   The user's cursor doesn't move and the window needn't be in front. The default.
/// - `hid`: the fallback for apps that ignore pid-posted events. The app is brought to the front,
///   its window raised, and events go through the system's HID event tap like real input, under
///   one global lock. This moves the real cursor (it's put back afterwards) and can type into
///   whatever is frontmost if someone else changes focus meanwhile.
public enum MacInputPath: String, Sendable, CaseIterable {
    case pid, hid
}

/// Where input goes: an app's process and one of its windows (global frame, in points).
struct MacInputTarget {
    let pid: Int32
    let windowID: UInt32
    let frame: MacRect
    let path: MacInputPath
}

/// Synthesizes mouse, scroll-wheel and keyboard events. Points are window points.
enum MacInput {
    static func source() -> CGEventSource? {
        // A private state, so the user's held keys and buttons don't leak into our events.
        CGEventSource(stateID: .privateState)
    }

    static func post(_ event: CGEvent, to target: MacInputTarget) {
        switch target.path {
        case .pid: event.postToPid(target.pid)
        case .hid: event.post(tap: .cghidEventTap)
        }
    }

    static func pause(_ seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func global(_ point: (x: Double, y: Double), in target: MacInputTarget) -> CGPoint {
        let global = MacGeometry.toGlobal(windowPoint: point, window: target.frame)
        return CGPoint(x: global.x, y: global.y)
    }

    static func mouseTypes(_ button: MacMouseButton) -> (down: CGEventType, up: CGEventType, dragged: CGEventType, button: CGMouseButton) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left)
        case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right)
        }
    }

    static func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int = 1, target: MacInputTarget, source: CGEventSource?) {
        // No event source: on CI, clicks made from a private-state source never reached SwiftUI
        // buttons (keys did), while source-less events are what click tools like cliclick post.
        _ = source
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.flags = []
        if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState)) }
        if [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .rightMouseDragged].contains(type) {
            event.setDoubleValueField(.mouseEventPressure, value: 1)
        }
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowID))
        post(event, to: target)
    }

    /// A click (or double/triple click with `count`) at a window point.
    static func click(_ point: (x: Double, y: Double), button: MacMouseButton, count: Int, target: MacInputTarget) async {
        let source = source()
        let location = global(point, in: target)
        let types = mouseTypes(button)
        mouse(.mouseMoved, at: location, button: .left, target: target, source: source)
        await pause(0.01)
        let clicks = min(3, max(1, count))
        for click in 1...clicks {
            mouse(types.down, at: location, button: types.button, clickState: click, target: target, source: source)
            await pause(0.05)
            mouse(types.up, at: location, button: types.button, clickState: click, target: target, source: source)
            if click < clicks { await pause(0.05) }
        }
    }

    /// Button down at `start`, held for `hold`, moved to `end` over `duration`, released.
    static func drag(from start: (x: Double, y: Double), to end: (x: Double, y: Double), duration: Double, hold: Double, target: MacInputTarget) async {
        let source = source()
        let steps = max(2, Int(max(0, duration) * 60))
        let path = MacGeometry.path(from: start, to: end, steps: steps)
        mouse(.mouseMoved, at: global(start, in: target), button: .left, target: target, source: source)
        await pause(0.01)
        mouse(.leftMouseDown, at: global(start, in: target), button: .left, target: target, source: source)
        await pause(max(0.03, hold))
        for point in path.dropFirst() {
            mouse(.leftMouseDragged, at: global(point, in: target), button: .left, target: target, source: source)
            await pause(max(0, duration) / Double(steps))
        }
        await pause(0.03)
        mouse(.leftMouseUp, at: global(end, in: target), button: .left, target: target, source: source)
    }

    /// Scrolls by `dx`/`dy` points at a window point. Positive `dy` moves further down the
    /// content (like scrolling down a page); positive `dx` moves right.
    static func scroll(at point: (x: Double, y: Double), dx: Double, dy: Double, target: MacInputTarget) async {
        let source = source()
        let location = global(point, in: target)
        mouse(.mouseMoved, at: location, button: .left, target: target, source: source)
        await pause(0.01)
        // In several smaller steps, as a wheel or trackpad would send them.
        let steps = max(1, min(20, Int((max(abs(dx), abs(dy)) / 40).rounded(.up))))
        var sentX = 0.0, sentY = 0.0
        for step in 1...steps {
            let goalX = (dx * Double(step) / Double(steps)).rounded(), goalY = (dy * Double(step) / Double(steps)).rounded()
            let stepX = goalX - sentX, stepY = goalY - sentY
            sentX = goalX
            sentY = goalY
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                      wheel1: Int32(-stepY), wheel2: Int32(-stepX), wheel3: 0) else { continue }
            event.location = location
            event.flags = []
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowID))
            post(event, to: target)
            await pause(0.012)
        }
    }

    static let modifierOrder: [MacKeys.Modifiers] = [.function, .control, .option, .shift, .command]

    static func keyEvent(_ code: UInt16, down: Bool, flags: UInt64, text: [UInt16]? = nil, source: CGEventSource?) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { return nil }
        event.flags = CGEventFlags(rawValue: flags)
        if let text { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
        return event
    }

    /// Presses a key with modifiers: modifier keys down, the key down and up, modifiers up.
    static func key(_ code: UInt16, modifiers: MacKeys.Modifiers, target: MacInputTarget) async {
        let source = source()
        let held = modifierOrder.filter { modifiers.contains($0) }
        var flags: MacKeys.Modifiers = []
        for modifier in held {
            flags.insert(modifier)
            if let code = MacKeys.modifierKeyCodes(modifier).first, let event = keyEvent(code, down: true, flags: MacKeys.flags(flags), source: source) {
                event.type = .flagsChanged
                post(event, to: target)
            }
        }
        if !held.isEmpty { await pause(0.01) }
        let all = MacKeys.flags(modifiers)
        if let down = keyEvent(code, down: true, flags: all, source: source) { post(down, to: target) }
        await pause(0.02)
        if let up = keyEvent(code, down: false, flags: all, source: source) { post(up, to: target) }
        for modifier in held.reversed() {
            flags.remove(modifier)
            if let code = MacKeys.modifierKeyCodes(modifier).first, let event = keyEvent(code, down: false, flags: MacKeys.flags(flags), source: source) {
                event.type = .flagsChanged
                post(event, to: target)
            }
        }
    }

    /// Types any text, emoji included, as Unicode keyboard events. Newlines and tabs are sent
    /// as Return and Tab presses.
    static func type(_ text: String, target: MacInputTarget) async {
        let source = source()
        for chunk in MacKeys.textChunks(text) {
            if chunk == "\n" || chunk == "\t" {
                await key(chunk == "\n" ? 0x24 : 0x30, modifiers: [], target: target)
            } else {
                let units = Array(chunk.utf16)
                // A single character gets its real key, for apps that look at key codes.
                let stroke = chunk.count == 1 ? MacKeys.stroke(chunk) : nil
                let code = stroke?.code ?? 0
                let flags = MacKeys.flags(stroke?.modifiers ?? [])
                if let down = keyEvent(code, down: true, flags: flags, text: units, source: source) { post(down, to: target) }
                if let up = keyEvent(code, down: false, flags: flags, text: units, source: source) { post(up, to: target) }
            }
            await pause(0.015)
        }
    }
}

/// A FIFO lock for async code: input that goes through the shared HID tap takes it, so two
/// sessions never interleave their events or fight over the frontmost window.
actor MacInputLock {
    static let shared = MacInputLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
