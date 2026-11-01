// swift-tools-version:5.10
import Foundation
import PackageDescription

// MiniRunKit is plain Swift and builds anywhere (its tests run on Linux CI).
// Everything that drives simulators needs macOS plus the FBSimulatorControl frameworks, which
// `scripts/build-frameworks.sh` builds into Vendor/ from AXe's pinned fork of idb.
// MiniRunMac drives native macOS apps with public Apple frameworks only.
// WebRTC (live view over a direct connection) uses a prebuilt libwebrtc from stasel/WebRTC,
// pinned by version and checksum, so its framework is downloaded with the package.

var products: [Product] = [.library(name: "MiniRunKit", targets: ["MiniRunKit"])]
var targets: [Target] = [
    .target(name: "MiniRunKit", path: "Sources/MiniRunKit"),
    .testTarget(name: "MiniRunKitTests", dependencies: ["MiniRunKit"], path: "Tests/MiniRunKitTests"),
]

#if os(macOS)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let privateHeaders = root.appendingPathComponent("Vendor/PrivateHeaders")
// Compile-time only: FBSimulatorControl's module maps reference these private Apple headers.
let privateHeaderFlags = ["", "AccessibilityPlatformTranslation", "AXRuntime", "CoreSimDeviceIO", "CoreSimulator", "CoreSimulatorUtilities", "SimulatorKit"]
    .map { "-I" + privateHeaders.appendingPathComponent($0).path }

let frameworks = ["FBControlCore", "FBSimulatorControl", "FBDeviceControl", "XCTestBootstrap"]

products.append(.executable(name: "minirun", targets: ["minirun"]))
targets += [
    .target(
        name: "MiniRunSim",
        dependencies: frameworks.map { .target(name: $0) },
        path: "Sources/MiniRunSim",
        exclude: ["AXe/LICENSE-AXe"],
        swiftSettings: [.unsafeFlags(privateHeaderFlags)]
    ),
    .target(
        name: "MiniRunMac",
        dependencies: ["MiniRunKit"],
        path: "Sources/MiniRunMac",
        linkerSettings: ["AppKit", "ApplicationServices", "ScreenCaptureKit", "VideoToolbox", "CoreMedia"].map { LinkerSetting.linkedFramework($0) }
    ),
    .target(
        name: "MiniRunCore",
        dependencies: ["MiniRunKit", "MiniRunSim", "MiniRunMac", "WebRTC"],
        path: "Sources/MiniRunCore",
        swiftSettings: [.unsafeFlags(privateHeaderFlags)]
    ),
    .executableTarget(
        name: "minirun",
        dependencies: ["MiniRunCore", "MiniRunKit", "MiniRunSim", "MiniRunMac"],
        path: "Sources/minirun",
        swiftSettings: [.unsafeFlags(privateHeaderFlags)],
        linkerSettings: [
            // Frameworks sit next to the binary (`install.sh --no-app`, `swift build`), or in
            // Contents/Frameworks when the binary is the app's helper (Contents/Helpers/minirun).
            .unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-headerpad_max_install_names",
            ]),
        ]
    ),
    // Mac-only tests: WebRTC sessions against a viewer peer connection in the same process.
    .testTarget(
        name: "MiniRunCoreTests",
        dependencies: ["MiniRunCore", "MiniRunKit", "MiniRunSim", "WebRTC"],
        path: "Tests/MiniRunCoreTests",
        swiftSettings: [.unsafeFlags(privateHeaderFlags)]
    ),
]
targets += frameworks.map { .binaryTarget(name: $0, path: "Vendor/XCFrameworks/\($0).xcframework") }
targets.append(.binaryTarget(
    name: "WebRTC",
    url: "https://github.com/stasel/WebRTC/releases/download/156.0.0/WebRTC-M156.xcframework.zip",
    checksum: "43c2a6f7a650185bbc911d7605a979589671886e8fc0ac283f54fdf3f511dc46"
))
#endif

let package = Package(
    name: "minirun",
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets
)
