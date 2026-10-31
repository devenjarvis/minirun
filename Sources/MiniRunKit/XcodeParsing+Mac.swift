import Foundation

extension XcodeParsing {
    /// A built macOS (or Mac Catalyst) app, with the executable to spawn.
    public struct MacAppProduct: Equatable, Sendable {
        public let appPath: String            // …/Build/Products/Debug/Fetch.app
        public let executablePath: String     // …/Fetch.app/Contents/MacOS/Fetch
        public let bundleIdentifier: String?
        public let productName: String?

        public init(appPath: String, executablePath: String, bundleIdentifier: String?, productName: String?) {
            self.appPath = appPath
            self.executablePath = executablePath
            self.bundleIdentifier = bundleIdentifier
            self.productName = productName
        }
    }

    /// Finds the built .app and its executable from `xcodebuild -showBuildSettings -json` for a
    /// macOS destination. Skips frameworks, test bundles and other non-app targets. When several
    /// targets are apps (a helper app, say), prefers the one named like `scheme`.
    public static func parseMacAppProduct(_ json: Data, scheme: String? = nil) -> MacAppProduct? {
        guard let entries = try? JSONValue.parse(json).arrayValue else { return nil }
        let apps = entries.filter { $0["buildSettings"]?["WRAPPER_EXTENSION"]?.stringValue == "app" }
        let named = scheme.flatMap { scheme in
            apps.first { $0["target"]?.stringValue == scheme || $0["buildSettings"]?["PRODUCT_NAME"]?.stringValue == scheme }
        }
        guard let entry = named ?? apps.first, let settings = entry["buildSettings"],
              let dir = settings["TARGET_BUILD_DIR"]?.stringValue,
              let wrapper = settings["WRAPPER_NAME"]?.stringValue else { return nil }
        let appPath = dir + "/" + wrapper
        let executable: String
        if let path = settings["EXECUTABLE_PATH"]?.stringValue, !path.isEmpty {
            executable = dir + "/" + path // relative to TARGET_BUILD_DIR, e.g. Fetch.app/Contents/MacOS/Fetch
        } else {
            let name = settings["EXECUTABLE_NAME"]?.stringValue ?? settings["PRODUCT_NAME"]?.stringValue
                ?? (wrapper as NSString).deletingPathExtension
            executable = appPath + "/Contents/MacOS/" + name
        }
        return MacAppProduct(
            appPath: appPath,
            executablePath: executable,
            bundleIdentifier: settings["PRODUCT_BUNDLE_IDENTIFIER"]?.stringValue,
            productName: settings["PRODUCT_NAME"]?.stringValue ?? entry["target"]?.stringValue
        )
    }

    /// Error wording xcodebuild uses when a build fails on code signing (no team, certificate,
    /// account or provisioning profile on this Mac).
    static let signingFailurePhrases = [
        "requires a development team",
        "no signing certificate",
        "no profiles for",
        "provisioning profile",
        "no account for team",
        "no certificate for team",
        "code signing is required for product type",
    ]

    /// True when xcodebuild's output has an error about code signing, so building again with
    /// ad-hoc signing may succeed. Only error lines count, not warnings.
    public static func isSigningFailure(_ output: String) -> Bool {
        output.split(separator: "\n").contains { raw in
            let line = raw.lowercased()
            // codesign's own message when it can't use the keychain; printed without "error:".
            if line.contains("errsecinternalcomponent") { return true }
            guard line.contains("error:") else { return false }
            if line.contains("signing for \""), line.contains("requires") { return true }
            return signingFailurePhrases.contains { line.contains($0) }
        }
    }
}
