// swift-tools-version:5.10
import Foundation
import PackageDescription

// MiniRunKit is plain Swift and builds anywhere (its tests run on Linux CI).
// Everything that drives simulators needs macOS plus the FBSimulatorControl frameworks, which
// `scripts/build-frameworks.sh` builds into Vendor/ from AXe's pinned fork of idb.

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
        name: "MiniRunCore",
        dependencies: ["MiniRunKit", "MiniRunSim"],
        path: "Sources/MiniRunCore",
        swiftSettings: [.unsafeFlags(privateHeaderFlags)]
    ),
    .executableTarget(
        name: "minirun",
        dependencies: ["MiniRunCore", "MiniRunKit", "MiniRunSim"],
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
]
targets += frameworks.map { .binaryTarget(name: $0, path: "Vendor/XCFrameworks/\($0).xcframework") }
#endif

let package = Package(
    name: "minirun",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
