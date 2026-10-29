import Foundation

/// Where each repo + ref is checked out. Every ref gets its own checkout (and its own build
/// products), so two sessions building different branches of one app never share a folder.
public enum WorkspaceNaming {
    /// "owner/app" for the default branch, "owner/app@feature-x" for a ref. Branch names with
    /// characters that aren't safe in a folder name get a short hash so they can't collide.
    public static func directory(slug: String, ref: String?) -> String {
        guard let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty else { return slug }
        var safe = String(ref.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") ? $0 : "-" })
        if safe != ref || safe.hasPrefix(".") { safe += "-" + fnv1a(ref) }
        return slug + "@" + safe
    }

    /// How simulator reservations name a workspace: "owner/app@feature/x", or "owner/app".
    public static func label(slug: String, ref: String?) -> String {
        guard let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty else { return slug }
        return slug + "@" + ref
    }

    static func fnv1a(_ text: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return String(format: "%08x", hash)
    }
}

/// Serializes work per key: one build at a time per checkout, one simulator pick at a time.
public final class KeyedLock: Sendable {
    private actor State {
        var held: Set<String> = []
        var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

        func tryAcquire(_ key: String) -> Bool {
            guard !held.contains(key) else { return false }
            held.insert(key)
            return true
        }

        func acquire(_ key: String) async {
            if tryAcquire(key) { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters[key, default: []].append(continuation)
            }
        }

        func release(_ key: String) {
            if var queue = waiters[key], !queue.isEmpty {
                // Hand the lock straight to the next waiter; the key stays held.
                let next = queue.removeFirst()
                waiters[key] = queue.isEmpty ? nil : queue
                next.resume()
            } else {
                held.remove(key)
            }
        }
    }

    private let state = State()

    public init() {}

    /// Runs `body` while holding `key`. `onWait` runs first if someone else holds it.
    public func withLock<T>(_ key: String, onWait: () -> Void = {}, _ body: () async throws -> T) async throws -> T {
        if !(await state.tryAcquire(key)) {
            onWait()
            await state.acquire(key)
        }
        do {
            let value = try await body()
            await state.release(key)
            return value
        } catch {
            await state.release(key)
            throw error
        }
    }
}
