// swift-tools-version:6.2
import Foundation
import PackageDescription

// The Rust core arrives as an xcframework built by scripts/build-core.sh. Until it exists the app
// builds against PreviewBackend only, so the UI can be developed and rendered without Rust.
let root = Context.packageDirectory
let hasEngine = FileManager.default.fileExists(atPath: root + "/Frameworks/TideCoreFFI.xcframework")

var targets: [Target] = [
    // Pure Swift: UI-facing models, AppModel, presentation, system watchers. Unit-tested.
    .target(name: "TideKit", path: "Sources/TideKit"),
    .testTarget(name: "TideKitTests", dependencies: ["TideKit"], path: "Tests/TideKitTests"),
]
var appDeps: [Target.Dependency] = ["TideKit"]
var appSettings: [SwiftSetting] = []

if hasEngine {
    targets += [
        .binaryTarget(name: "TideCoreFFI", path: "Frameworks/TideCoreFFI.xcframework"),
        // Generated UniFFI bindings (tide_core.swift).
        .target(name: "TideFFI", dependencies: ["TideCoreFFI"], path: "Sources/TideFFI"),
        // EngineBackend implementation over the Rust core.
        .target(name: "TideEngine", dependencies: ["TideKit", "TideFFI"], path: "Sources/TideEngine"),
    ]
    appDeps.append("TideEngine")
    appSettings.append(.define("TIDE_ENGINE"))
}

targets.append(
    .executableTarget(
        name: "Tide",
        dependencies: appDeps,
        path: "Sources/Tide",
        swiftSettings: appSettings,
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("SystemConfiguration"),
            .linkedFramework("IOKit"),
            .linkedFramework("ServiceManagement"),
            .linkedFramework("UserNotifications"),
            .linkedFramework("Network"),
            .linkedFramework("QuickLookUI"),
        ]
    )
)

let package = Package(
    name: "Tide",
    platforms: [.macOS(.v26)],
    targets: targets,
    swiftLanguageModes: [.v5]
)
