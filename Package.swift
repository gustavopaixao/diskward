// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StorageHelper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StorageHelper", targets: ["StorageHelper"]),
        .executable(name: "storage-report", targets: ["storage-report"]),
    ],
    targets: [
        // All scanning / cleaning logic. No UI, fully unit-testable.
        .target(name: "StorageCore"),
        // SwiftUI app.
        .executableTarget(name: "StorageHelper", dependencies: ["StorageCore"]),
        // Read-only command-line report of the same scan (handy for scripts or pasting into a chat).
        .executableTarget(name: "storage-report", dependencies: ["StorageCore"]),
        .testTarget(
            name: "StorageCoreTests",
            dependencies: ["StorageCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
