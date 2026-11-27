// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "GlassMonitor",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "Core"),
        .executableTarget(name: "GlassMonitor", dependencies: ["Core"]),
        .executableTarget(name: "sysdump", dependencies: ["Core"]),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
    ],
    swiftLanguageModes: [.v5]
)
