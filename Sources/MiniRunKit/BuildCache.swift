import Foundation

/// Where build state shared between the checkouts of one repository lives, and the xcodebuild
/// arguments that point a build at it (`sharedBuildCache`).
///
/// Copying DerivedData between checkouts doesn't help: Xcode's build database records absolute
/// paths, and they differ per checkout. Two things can be shared:
/// - Swift package checkouts, in one folder per repo and Package.resolved, so refs that pin the
///   same versions clone them once and see their sources at the same absolute path.
/// - Xcode's compilation cache (a content-addressed store), one per repo.
public enum BuildCache {
    /// Under the workspace root. A dot folder, so `WorkspaceInventory` doesn't list it as a checkout.
    public static let folder = ".cache"

    /// `<root>/.cache/compilation/<owner>/<name>`
    public static func compilationCacheDirectory(root: String, slug: String) -> String {
        trimmed(root) + "/" + folder + "/compilation/" + slug
    }

    /// `<root>/.cache/packages/<owner>/<name>/<hash of Package.resolved>`
    public static func packagesDirectory(root: String, slug: String, resolved: Data) -> String {
        trimmed(root) + "/" + folder + "/packages/" + slug + "/" + hash(resolved)
    }

    /// The written-once marker that says a packages folder has been resolved and can be used by
    /// builds without holding its lock.
    public static let resolvedMarker = ".minirun-resolved"

    /// The repository a checkout belongs to: "owner/name" for `<root>/owner/name` or
    /// `<root>/owner/name@ref`, nil for a folder anywhere else.
    public static func slug(checkout: String, root: String) -> String? {
        let rootPath = trimmed(root)
        var path = checkout
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let parts = path.dropFirst(rootPath.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[0].hasPrefix("."), !parts[1].hasPrefix(".") else { return nil }
        let name = parts[1].split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !name.isEmpty else { return nil }
        return "\(parts[0])/\(name)"
    }

    /// Where Xcode keeps Package.resolved for a container: an .xcworkspace, an .xcodeproj, or a
    /// Swift package's folder (or its Package.swift).
    public static func resolvedFile(container: String) -> String {
        var path = container
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".xcworkspace") { return path + "/xcshareddata/swiftpm/Package.resolved" }
        if path.hasSuffix(".xcodeproj") { return path + "/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" }
        if path.hasSuffix("/Package.swift") { return (path as NSString).deletingLastPathComponent + "/Package.resolved" }
        return path + "/Package.resolved"
    }

    /// The arguments to add to an xcodebuild call. Each is left out when the caller's
    /// `extraArgs` already decide it, so a build can always opt out or point elsewhere.
    public static func arguments(extraArgs: [String], packagesDirectory: String?, compilationCacheDirectory: String?) -> [String] {
        var args: [String] = []
        if let packagesDirectory, !extraArgs.contains(where: { $0.hasPrefix("-clonedSourcePackagesDirPath") }) {
            args += ["-clonedSourcePackagesDirPath", packagesDirectory]
        }
        if let compilationCacheDirectory {
            if !extraArgs.contains(where: { $0.hasPrefix("COMPILATION_CACHE_ENABLE_CACHING=") }) {
                args.append("COMPILATION_CACHE_ENABLE_CACHING=YES")
            }
            if !extraArgs.contains(where: { $0.hasPrefix("COMPILATION_CACHE_CAS_PATH=") }) {
                args.append("COMPILATION_CACHE_CAS_PATH=" + compilationCacheDirectory)
            }
        }
        return args
    }

    /// 64-bit FNV-1a as 16 hex digits: a folder name, not a security boundary.
    static func hash(_ data: Data) -> String {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in data {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    private static func trimmed(_ root: String) -> String {
        var path = root
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
