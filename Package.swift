// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheAppleMailMCP",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
        // Direct SMTP/IMAP transport (#742). Pinned to the commit of its 1.17.0 tag, not to the
        // version: SwiftMail itself pins swift-nio-imap to a revision, and SwiftPM refuses a version
        // requirement on a package with a revision dependency.
        //
        // The macOS 26 floor above comes from this dependency. SwiftMail needs macOS 15, and below
        // macOS 26 the release binary hard-links libswiftCompatibilitySpan.dylib (NIOCore and
        // swift-collections use RawSpan), which macOS 15 does not have; from macOS 26 it is part of
        // the system. Lowering the floor needs that library shipped next to the binary (#742).
        .package(url: "https://github.com/Cocoanetics/SwiftMail.git", revision: "17e85ded3f249ae8c2d2a2bdeeb67c11e59ba9f6")
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
                .product(name: "SwiftMail", package: "SwiftMail"),
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
            dependencies: ["CheAppleMailMCP", .product(name: "SwiftMail", package: "SwiftMail")],
            path: "Tests/CheAppleMailMCPTests",
            // Synthetic ndjson inputs for the mail-log tests (#465) are read via
            // #filePath, not bundled — exclude so SwiftPM does not warn about them.
            exclude: ["Fixtures"]
        )
    ]
)
