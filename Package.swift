// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lenscap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Lenscap",
            path: "Sources/Lenscap"
        )
    ]
)
