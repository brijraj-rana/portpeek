// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Portpeek",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PortpeekCore", targets: ["PortpeekCore"]),
        .executable(name: "Portpeek", targets: ["Portpeek"]),
        .executable(name: "portpeek-cli", targets: ["portpeek-cli"]),
    ],
    targets: [
        // UI-free scanner: who is listening on which port, and how to stop them.
        .target(name: "PortpeekCore", path: "Sources/PortpeekCore"),
        // The menu bar item and its popover.
        .executableTarget(name: "Portpeek", dependencies: ["PortpeekCore"], path: "Sources/Portpeek"),
        // The `portpeek` command. Named apart from the app because the two would collide on a case-insensitive disk.
        .executableTarget(name: "portpeek-cli", dependencies: ["PortpeekCore"], path: "Sources/portpeek-cli"),
        .testTarget(name: "PortpeekCoreTests", dependencies: ["PortpeekCore"], path: "Tests/PortpeekCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
