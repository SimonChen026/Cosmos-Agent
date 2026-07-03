// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Forge",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ForgeKit",
            path: "Sources/ForgeKit",
            swiftSettings: [
                // CLT ships no XCTest; the forge-tests runner uses
                // @testable import, which needs testability in debug.
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "Cosmos",
            dependencies: ["ForgeKit"],
            path: "Sources/ForgeApp"
        ),
        .executableTarget(
            name: "forge-tests",
            dependencies: ["ForgeKit"],
            path: "Tests/ForgeTests"
        ),
    ]
)
