// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuerywellCore", targets: ["QuerywellCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.9.2"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.33.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.5"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.2"),
    ],
    targets: [
        .target(
            name: "QuerywellCore",
            dependencies: [
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(name: "QuerywellCoreTests", dependencies: ["QuerywellCore"]),
    ],
    swiftLanguageModes: [.v6]
)
