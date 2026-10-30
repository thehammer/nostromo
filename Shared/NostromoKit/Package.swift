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
        // A few lines of Objective-C: Swift cannot catch an NSException (see ObjCExceptionGuard).
        .target(
            name: "NostromoObjCGuard",
            path: "Sources/NostromoObjCGuard"
        ),
        .target(
            name: "NostromoKit",
            dependencies: ["NostromoObjCGuard"],
            path: "Sources/NostromoKit"
        ),
        .testTarget(
            name: "NostromoKitTests",
            dependencies: ["NostromoKit"],
            path: "Tests/NostromoKitTests",
            // Plan files the tests read by path (`PlanFixtures`), not SwiftPM resources.
            exclude: ["Fixtures"]
        ),
    ]
)
