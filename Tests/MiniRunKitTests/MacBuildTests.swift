import XCTest
@testable import MiniRunKit

final class MacBuildTests: XCTestCase {
    func testDestinations() {
        XCTAssertEqual(BuildPlatform.ios.destination(udid: "ABC-123"), "platform=iOS Simulator,id=ABC-123")
        XCTAssertEqual(BuildPlatform.ios.destination(udid: nil), "generic/platform=iOS Simulator")
        XCTAssertEqual(BuildPlatform.macos.destination(udid: nil, arch: "arm64"), "platform=macOS,arch=arm64")
        XCTAssertEqual(BuildPlatform.macos.destination(udid: "ignored", arch: "x86_64"), "platform=macOS,arch=x86_64")
        XCTAssertEqual(BuildPlatform.macCatalyst.destination(udid: nil, arch: "arm64"), "platform=macOS,variant=Mac Catalyst,arch=arm64")
        XCTAssertEqual(BuildPlatform.macos.destination(udid: nil), "platform=macOS,arch=\(BuildPlatform.hostArch)")
        XCTAssertEqual(BuildPlatform(rawValue: "mac-catalyst"), .macCatalyst)
        XCTAssertFalse(BuildPlatform.ios.isMac)
        XCTAssertTrue(BuildPlatform.macos.isMac)
        XCTAssertTrue(BuildPlatform.macCatalyst.isMac)
    }

    /// One `-showBuildSettings -json` entry, trimmed to the settings that matter here.
    private func entry(_ target: String, _ settings: [String: String]) -> JSONValue {
        ["action": "build", "target": .string(target), "buildSettings": .object(settings.mapValues { .string($0) })]
    }

    private func json(_ entries: [JSONValue]) -> Data { (try? JSONValue.array(entries).encoded()) ?? Data() }

    func testDetectPlatform() {
        let iosOnly = json([entry("App", [
            "WRAPPER_EXTENSION": "app", "PLATFORM_NAME": "iphoneos", "SDKROOT": "iphoneos",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO",
        ])])
        XCTAssertEqual(BuildPlatform.detect(fromBuildSettings: iosOnly), .ios)

        let macOnly = json([
            entry("FetchKit", ["WRAPPER_EXTENSION": "framework", "SUPPORTED_PLATFORMS": "macosx"]),
            entry("Fetch", ["WRAPPER_EXTENSION": "app", "PLATFORM_NAME": "macosx", "SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx"]),
        ])
        XCTAssertEqual(BuildPlatform.detect(fromBuildSettings: macOnly), .macos)

        let multiplatform = json([entry("Edition", [
            "WRAPPER_EXTENSION": "app", "PLATFORM_NAME": "iphoneos", "SDKROOT": "auto",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx xros xrsimulator",
        ])])
        XCTAssertEqual(BuildPlatform.detect(fromBuildSettings: multiplatform), .ios)

        let catalyst = json([entry("App", [
            "WRAPPER_EXTENSION": "app", "PLATFORM_NAME": "iphoneos",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "YES",
        ])])
        XCTAssertEqual(BuildPlatform.detect(fromBuildSettings: catalyst), .ios)

        // A scheme whose only target is a macOS framework.
        XCTAssertEqual(BuildPlatform.detect(fromBuildSettings: json([entry("Kit", ["WRAPPER_EXTENSION": "framework", "SUPPORTED_PLATFORMS": "macosx"])])), .macos)
        XCTAssertEqual(BuildPlatform.detect(fromBuildSettings: Data("not json".utf8)), .ios)
        XCTAssertEqual(BuildPlatform.detect(fromBuildSettings: Data("[]".utf8)), .ios)
    }

    func testMacAppProduct() throws {
        let dir = "/src/.minirun/DerivedData/Build/Products/Debug"
        let settings = json([
            entry("FetchKit", [
                "WRAPPER_EXTENSION": "framework", "WRAPPER_NAME": "FetchKit.framework", "TARGET_BUILD_DIR": dir,
                "EXECUTABLE_NAME": "FetchKit", "EXECUTABLE_PATH": "FetchKit.framework/Versions/A/FetchKit",
                "PRODUCT_BUNDLE_IDENTIFIER": "dev.fetch.FetchKit", "PRODUCT_NAME": "FetchKit",
            ]),
            entry("Fetch", [
                "WRAPPER_EXTENSION": "app", "WRAPPER_NAME": "Fetch.app", "TARGET_BUILD_DIR": dir,
                "EXECUTABLE_NAME": "Fetch", "EXECUTABLE_PATH": "Fetch.app/Contents/MacOS/Fetch",
                "PRODUCT_BUNDLE_IDENTIFIER": "dev.fetch.Fetch", "PRODUCT_NAME": "Fetch",
                "PLATFORM_NAME": "macosx", "SUPPORTED_PLATFORMS": "macosx",
            ]),
            entry("FetchTests", [
                "WRAPPER_EXTENSION": "xctest", "WRAPPER_NAME": "FetchTests.xctest", "TARGET_BUILD_DIR": dir + "/Fetch.app/Contents/PlugIns",
                "EXECUTABLE_NAME": "FetchTests", "PRODUCT_BUNDLE_IDENTIFIER": "dev.fetch.FetchTests", "PRODUCT_NAME": "FetchTests",
            ]),
        ])
        let product = try XCTUnwrap(XcodeParsing.parseMacAppProduct(settings, scheme: "Fetch"))
        XCTAssertEqual(product, XcodeParsing.MacAppProduct(
            appPath: dir + "/Fetch.app",
            executablePath: dir + "/Fetch.app/Contents/MacOS/Fetch",
            bundleIdentifier: "dev.fetch.Fetch",
            productName: "Fetch"
        ))
        XCTAssertEqual(XcodeParsing.parseMacAppProduct(settings), product)

        // Without EXECUTABLE_PATH, the executable is Contents/MacOS/EXECUTABLE_NAME.
        let noPath = json([entry("Hello", [
            "WRAPPER_EXTENSION": "app", "WRAPPER_NAME": "Hello World.app", "TARGET_BUILD_DIR": "/dd/Debug-maccatalyst",
            "EXECUTABLE_NAME": "Hello World",
        ])])
        XCTAssertEqual(XcodeParsing.parseMacAppProduct(noPath)?.executablePath, "/dd/Debug-maccatalyst/Hello World.app/Contents/MacOS/Hello World")
        XCTAssertEqual(XcodeParsing.parseMacAppProduct(noPath)?.productName, "Hello")
        XCTAssertNil(XcodeParsing.parseMacAppProduct(noPath)?.bundleIdentifier)

        // A helper app built first doesn't win over the scheme's app.
        let helper = json([
            entry("FetchHelper", ["WRAPPER_EXTENSION": "app", "WRAPPER_NAME": "FetchHelper.app", "TARGET_BUILD_DIR": dir, "EXECUTABLE_NAME": "FetchHelper"]),
            entry("Fetch", ["WRAPPER_EXTENSION": "app", "WRAPPER_NAME": "Fetch.app", "TARGET_BUILD_DIR": dir, "EXECUTABLE_NAME": "Fetch"]),
        ])
        XCTAssertEqual(XcodeParsing.parseMacAppProduct(helper, scheme: "Fetch")?.appPath, dir + "/Fetch.app")
        XCTAssertEqual(XcodeParsing.parseMacAppProduct(helper, scheme: "Other")?.appPath, dir + "/FetchHelper.app")

        // Only frameworks and tests: no app.
        let noApp = json([entry("Kit", ["WRAPPER_EXTENSION": "framework", "WRAPPER_NAME": "Kit.framework", "TARGET_BUILD_DIR": dir])])
        XCTAssertNil(XcodeParsing.parseMacAppProduct(noApp))
        XCTAssertNil(XcodeParsing.parseMacAppProduct(Data("oops".utf8)))
    }

    func testSigningFailure() {
        let failures = [
            #"/src/Fetch.xcodeproj: error: Signing for "Fetch" requires a development team. Select a development team in the Signing & Capabilities editor. (in target 'Fetch' from project 'Fetch')"#,
            #"/src/Fetch.xcodeproj: error: No signing certificate "Mac Development" found: No "Mac Development" signing certificate matching team ID "ABCDE12345" with a private key was found. (in target 'Fetch' from project 'Fetch')"#,
            #"/src/Fetch.xcodeproj: error: No profiles for 'dev.fetch.Fetch' were found: Xcode couldn't find any Mac App Development provisioning profiles matching 'dev.fetch.Fetch'. Automatic signing is disabled and unable to generate a profile. To enable automatic signing, pass -allowProvisioningUpdates to xcodebuild. (in target 'Fetch' from project 'Fetch')"#,
            #"/src/Fetch.xcodeproj: error: "Fetch" requires a provisioning profile with the iCloud feature. Select a provisioning profile in the Signing & Capabilities editor. (in target 'Fetch' from project 'Fetch')"#,
            #"error: No Account for Team "ABCDE12345". Add a new account in Accounts settings or verify that your accounts have valid credentials. (in target 'Fetch' from project 'Fetch')"#,
            #"error: Code signing is required for product type 'Application' in SDK 'macOS 26.0' (in target 'Fetch' from project 'Fetch')"#,
            "/src/.minirun/DerivedData/Build/Products/Debug/Fetch.app: errSecInternalComponent\nCommand CodeSign failed with a nonzero exit code",
        ]
        for output in failures {
            XCTAssertTrue(XcodeParsing.isSigningFailure("Prepare packages\n" + output + "\n** BUILD FAILED **"), output)
        }

        let others = [
            "/src/App/ContentView.swift:12:9: error: cannot find 'foo' in scope\n** BUILD FAILED **",
            "ld: error: undefined symbol: _bar",
            "xcodebuild: error: Unable to find a destination matching the provided destination specifier",
            // Warnings about signing aren't why a build failed.
            "/src/Fetch.xcodeproj: warning: The provisioning profile is expiring soon.\n/src/A.swift:1:1: error: expected expression",
            "",
        ]
        for output in others {
            XCTAssertFalse(XcodeParsing.isSigningFailure(output), output)
        }
    }
}
