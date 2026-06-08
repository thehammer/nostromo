// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NostromoKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "NostromoKit",
            targets: ["NostromoKit"]
        ),
    ],
    targets: [
        .target(
            name: "NostromoKit",
            dependencies: [],
            path: "Sources/NostromoKit"
        ),
        .testTarget(
            name: "NostromoKitTests",
            dependencies: ["NostromoKit"],
            path: "Tests/NostromoKitTests"
        ),
    ]
)
