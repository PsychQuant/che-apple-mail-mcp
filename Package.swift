// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheAppleMailMCP",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0")
    ],
    targets: [
        .target(
            name: "MailSQLite",
            path: "Sources/MailSQLite",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "CheAppleMailMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                "MailSQLite"
            ],
            path: "Sources/CheAppleMailMCP",
            // Entitlements.plist is consumed by scripts/sign-and-notarize.sh at
            // release time, not compiled — exclude it so SwiftPM doesn't warn
            // about an unhandled resource (#211).
            exclude: ["Entitlements.plist"]
        ),
        .testTarget(
            name: "MailSQLiteTests",
            dependencies: ["MailSQLite"],
            path: "Tests/MailSQLiteTests"
        ),
        .testTarget(
            name: "CheAppleMailMCPTests",
            dependencies: ["CheAppleMailMCP"],
            path: "Tests/CheAppleMailMCPTests"
        )
    ]
)
