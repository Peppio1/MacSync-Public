// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacSync",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacSyncCore", targets: ["MacSyncCore"])
    ],
    targets: [
        .binaryTarget(name: "Sparkle", url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip", checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"),
        .target(
            name: "MacSyncCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "MacSync",
            dependencies: ["MacSyncCore", "Sparkle"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "MacSyncCoreTests",
            dependencies: ["MacSyncCore"]
        ),
        .testTarget(
            name: "MacSyncUIPreviewTests",
            dependencies: ["MacSync", "MacSyncCore"]
        )
    ]
)
