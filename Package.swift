// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacSync",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacSyncCore", targets: ["MacSyncCore"])
    ],
    targets: [
        .target(
            name: "MacSyncCore",
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Security")]
        ),
        .executableTarget(
            name: "MacSync",
            dependencies: ["MacSyncCore"]
        ),
        .testTarget(
            name: "MacSyncCoreTests",
            dependencies: ["MacSyncCore"]
        )
    ]
)
