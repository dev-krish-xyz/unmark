// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Unmark",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Unmark", targets: ["Unmark"]),
    ],
    targets: [
        .target(name: "UnmarkCore"),
        .executableTarget(name: "Unmark", dependencies: ["UnmarkCore"]),
        .testTarget(name: "UnmarkCoreTests", dependencies: ["UnmarkCore"]),
    ]
)
