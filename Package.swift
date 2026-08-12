// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NatesNotes",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Exposed so the iOS app target in NatesNotes.xcodeproj can depend on
        // it as a local package rather than duplicating the sources.
        .library(name: "SyncKit", targets: ["SyncKit"])
    ],
    targets: [
        // Transport + engine for the Personal File Sync server. Foundation only,
        // no AppKit, so it can be exercised headlessly by the test suite.
        .target(
            name: "SyncKit",
            path: "Sources/SyncKit"
        ),
        .executableTarget(
            name: "NatesNotes",
            dependencies: ["SyncKit"],
            path: "Sources/NatesNotes",
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        ),
        .testTarget(
            name: "SyncKitTests",
            dependencies: ["SyncKit"],
            path: "Tests/SyncKitTests"
        )
    ]
)
