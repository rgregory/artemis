// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Artemis",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Artemis",
            path: "Sources/Artemis"
        )
    ]
)
