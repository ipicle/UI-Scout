// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UIScout",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "uisct-cli", targets: ["UIScoutCLI"]),
        .library(name: "UIScoutCore", targets: ["UIScoutCore"]),
    .executable(name: "uisct-service", targets: ["UIScoutService"]),
    .executable(name: "uisct-testflow", targets: ["UIScoutTestflow"]),
    .executable(name: "uisct-read", targets: ["UIScoutRead"]) 
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.83.1"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.3"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.3"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "UIScoutCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/UIScoutCore"
        ),
        .executableTarget(
            name: "UIScoutTestflow",
            dependencies: [
                "UIScoutCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "cmd/uisct-testflow"
        ),
        .executableTarget(
            name: "UIScoutCLI",
            dependencies: [
                "UIScoutCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "cmd/uisct-cli"
        ),
        .executableTarget(
            name: "UIScoutRead",
            dependencies: [
                "UIScoutCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "cmd/uisct-read"
        ),
        .executableTarget(
            name: "UIScoutService",
            dependencies: [
                "UIScoutCore",
                .product(name: "Vapor", package: "vapor")
            ],
            path: "svc/http"
        ),
        .testTarget(
            name: "UIScoutTests",
            dependencies: ["UIScoutCore"],
            path: "Tests"
        )
    ]
)
