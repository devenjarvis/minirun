import Foundation
import ApplicationServices
import CoreGraphics

/// What the Mac driver can do right now. macOS grants Screen Recording and Accessibility per
/// binary (here the minirun daemon), and window capture needs an active display.
public struct MacPermissionStatus: Sendable, Equatable {
    public let screenRecording: Bool
    public let accessibility: Bool
    public let hasDisplay: Bool

    public init(screenRecording: Bool, accessibility: Bool, hasDisplay: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.hasDisplay = hasDisplay
    }
}

/// An error from driving a Mac app, with a message written for the agent.
public struct MacDriverError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// TCC checks and requests. All of these answer for the current process, so they only mean
/// something when called from `minirun serve` itself.
public enum MacPermissions {
    public static func status() -> MacPermissionStatus {
        MacPermissionStatus(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted(), hasDisplay: hasActiveDisplay())
    }

    /// Shows the system prompts for whichever of Screen Recording and Accessibility is missing,
    /// naming this process. Each prompt only appears once; after that the user has to use
    /// System Settings.
    public static func request() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if !AXIsProcessTrusted() {
            // The value of kAXTrustedCheckOptionPrompt, spelled out to avoid its global var.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    public static func hasActiveDisplay() -> Bool {
        var count: UInt32 = 0
        return CGGetActiveDisplayList(0, nil, &count) == .success && count > 0
    }

    static let binary = ProcessInfo.processInfo.arguments.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? "minirun"

    static func missing(_ permission: String, for action: String) -> MacDriverError {
        MacDriverError("""
            minirun needs the \(permission) permission to \(action). Grant it to the minirun binary \
            (\(binary)) in System Settings → Privacy & Security → \(permission), then restart minirun serve \
            (`minirun doctor` checks it; the menu bar app's Setup window can request it).
            """)
    }

    public static func requireScreenRecording(for action: String = "see Mac app windows") throws {
        guard CGPreflightScreenCaptureAccess() else { throw missing("Screen Recording", for: action) }
        guard hasActiveDisplay() else {
            throw MacDriverError("The Mac has no active display, so windows can't be captured. A headless Mac mini needs a user logged in and a display or an HDMI dummy plug connected.")
        }
    }

    public static func requireAccessibility(for action: String = "read and control Mac apps") throws {
        guard AXIsProcessTrusted() else { throw missing("Accessibility", for: action) }
    }
}
