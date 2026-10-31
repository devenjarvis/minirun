import Foundation

/// What a build runs on: an iOS simulator, the Mac itself, or the Mac through Mac Catalyst.
public enum BuildPlatform: String, Sendable, CaseIterable {
    case ios, macos, macCatalyst = "mac-catalyst"

    public var isMac: Bool { self != .ios }

    /// The architecture of the Mac running minirun, for macOS destinations.
    public static var hostArch: String {
        #if arch(x86_64)
        return "x86_64"
        #else
        return "arm64"
        #endif
    }

    /// The xcodebuild `-destination` value. `udid` picks the simulator for .ios; without one the
    /// build is for any simulator (fine for `build`, not for `test`).
    public func destination(udid: String?, arch: String = BuildPlatform.hostArch) -> String {
        switch self {
        case .ios: return udid.map { "platform=iOS Simulator,id=\($0)" } ?? "generic/platform=iOS Simulator"
        case .macos: return "platform=macOS,arch=\(arch)"
        case .macCatalyst: return "platform=macOS,variant=Mac Catalyst,arch=\(arch)"
        }
    }

    /// Picks a platform from a scheme's `xcodebuild -showBuildSettings -json` run without a
    /// destination: macos when the app target supports macOS and not iOS, otherwise ios.
    /// Multiplatform and Catalyst-enabled iOS apps stay on ios; ask for macos explicitly.
    public static func detect(fromBuildSettings json: Data) -> BuildPlatform {
        guard let entries = try? JSONValue.parse(json).arrayValue else { return .ios }
        let settings = entries.compactMap { $0["buildSettings"] }
        // The app target decides; a scheme without one (a framework, a package) goes by its first target.
        guard let main = settings.first(where: { $0["WRAPPER_EXTENSION"]?.stringValue == "app" }) ?? settings.first,
              let supported = main["SUPPORTED_PLATFORMS"]?.stringValue else { return .ios }
        let platforms = Set(supported.split(separator: " ").map(String.init))
        if platforms.contains("macosx"), !platforms.contains("iphonesimulator"), !platforms.contains("iphoneos") {
            return .macos
        }
        return .ios
    }
}
