// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "demo-recorder",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../../../swift-typewriter-console"),
    ],
    targets: [
        .executableTarget(
            name: "demo-recorder",
            dependencies: [
                .product(name: "TypewriterConsole", package: "swift-typewriter-console"),
            ]
        ),
    ]
)
