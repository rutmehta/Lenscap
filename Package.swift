// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lenscap",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle powers automatic + manual update checks. Version 2.x uses SPM
        // natively; the framework is embedded + code-signed by Scripts/make-app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Lenscap",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .target(name: "LenscapPermission"),
                .target(name: "LenscapUXCore")
            ],
            path: "Sources/Lenscap"
        ),
        .target(
            name: "LenscapUXCore",
            path: "Sources/LenscapUXCore"
        ),
        .target(
            name: "LenscapPermission",
            path: "Sources/LenscapPermission"
        ),
        .testTarget(
            name: "LenscapPermissionTests",
            dependencies: ["LenscapPermission"],
            path: "Tests/LenscapPermissionTests"
        ),
        .testTarget(
            name: "LenscapUXCoreTests",
            dependencies: ["LenscapUXCore"],
            path: "Tests/LenscapUXCoreTests"
        )
    ]
)
