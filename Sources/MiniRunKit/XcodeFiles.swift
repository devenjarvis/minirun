import Foundation

/// Reads what Xcode keeps on disk, so minirun can skip an xcodebuild call or clean up after one.
public enum XcodeFiles {
    // MARK: Shared schemes

    /// The shared schemes of an .xcodeproj or .xcworkspace, from its `.xcscheme` files, sorted. A
    /// workspace adds the shared schemes of the projects it references. `xcodebuild -list` reports
    /// these and more: the schemes of local Swift packages, and made-up ones for a project that
    /// shares none. So this answers "which scheme to build" when it can (a named scheme that's
    /// shared, or a default among the shared ones), and xcodebuild is asked otherwise.
    ///
    /// Reading the files matters beyond speed: `xcodebuild -list` resolves Swift packages into
    /// `~/Library/Developer/Xcode/DerivedData/<Name>-<hash>` (it takes no `-derivedDataPath`),
    /// one folder per checkout path, that nothing ever deletes.
    public static func sharedSchemes(container path: String) -> [String] {
        var containers = [path]
        if path.hasSuffix(".xcworkspace"),
           let data = FileManager.default.contents(atPath: path + "/contents.xcworkspacedata") {
            containers += workspaceProjects(String(decoding: data, as: UTF8.self), workspace: path)
        }
        var names = Set<String>()
        for container in containers {
            let folder = container + "/xcshareddata/xcschemes"
            for file in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where file.hasSuffix(".xcscheme") {
                names.insert(String(file.dropLast(".xcscheme".count)))
            }
        }
        return names.sorted()
    }

    /// The .xcodeproj paths a workspace's `contents.xcworkspacedata` references.
    public static func workspaceProjects(_ xml: String, workspace: String) -> [String] {
        let folder = (workspace as NSString).deletingLastPathComponent
        let pattern = try! NSRegularExpression(pattern: #"location\s*=\s*"([^"]*)""#)
        let range = NSRange(xml.startIndex..., in: xml)
        var found: [String] = []
        for match in pattern.matches(in: xml, range: range) {
            guard let value = Range(match.range(at: 1), in: xml) else { continue }
            let location = String(xml[value])
            guard let colon = location.firstIndex(of: ":") else { continue }
            let kind = location[..<colon], target = String(location[location.index(after: colon)...])
            guard target.hasSuffix(".xcodeproj") else { continue }
            switch kind {
            case "absolute": found.append(target)
            case "group", "container": found.append(URL(fileURLWithPath: folder + "/" + target).standardizedFileURL.path)
            default: continue
            }
        }
        return found
    }

    // MARK: Global DerivedData

    /// Xcode's default DerivedData folder.
    public static var globalDerivedData: String {
        MiniRunConfig.home + "/Library/Developer/Xcode/DerivedData"
    }

    /// Folders of `derivedData` that Xcode made for a project under `workspaceRoot` that's gone
    /// (its checkout was deleted). Xcode records the project in each folder's info.plist
    /// (`WorkspacePath`); folders without one, and every other project's, are left alone.
    public static func orphanedDerivedData(_ derivedData: String = globalDerivedData, workspaceRoot: String) -> [String] {
        let fm = FileManager.default
        let root = WorkspaceInventory.standardized(workspaceRoot) + "/"
        return ((try? fm.contentsOfDirectory(atPath: derivedData)) ?? []).sorted().compactMap { name in
            let folder = derivedData + "/" + name
            guard let data = fm.contents(atPath: folder + "/info.plist"),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let project = plist["WorkspacePath"] as? String,
                  WorkspaceInventory.standardized(project).hasPrefix(root),
                  !fm.fileExists(atPath: project) else { return nil }
            return folder
        }
    }
}
