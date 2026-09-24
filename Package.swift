// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MihomoBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MihomoBar",
            path: "Sources/MihomoBar"
        )
    ]
)
