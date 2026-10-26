// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuerywellCore", targets: ["QuerywellCore"]),
    ],
    targets: [
        .target(name: "QuerywellCore"),
        .testTarget(name: "QuerywellCoreTests", dependencies: ["QuerywellCore"]),
    ],
    swiftLanguageModes: [.v6]
)
