// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Portpeek",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PortpeekCore", targets: ["PortpeekCore"]),
        .executable(name: "Portpeek", targets: ["Portpeek"]),
    ],
    targets: [
        // UI-free scanner: who is listening on which port, and how to stop them.
        .target(name: "PortpeekCore", path: "Sources/PortpeekCore"),
        // The menu bar item and its popover.
        .executableTarget(name: "Portpeek", dependencies: ["PortpeekCore"], path: "Sources/Portpeek"),
        .testTarget(name: "PortpeekCoreTests", dependencies: ["PortpeekCore"], path: "Tests/PortpeekCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
