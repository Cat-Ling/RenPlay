// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RenPlay",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "RenPlay",
            targets: ["RenPlay"]
        ),
    ],
    targets: [
        .target(
            name: "CZlib",
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
        .target(
            name: "RenPlayCore",
            dependencies: ["CZlib"]
        ),
        .target(
            name: "CRenPlayBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-fobjc-arc"], .when(platforms: [.iOS])),
            ],
            linkerSettings: [
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
                .linkedFramework("Foundation", .when(platforms: [.iOS])),
                .linkedFramework("AVFoundation", .when(platforms: [.iOS])),
                .linkedFramework("QuartzCore", .when(platforms: [.iOS])),
                .linkedFramework("StoreKit", .when(platforms: [.iOS])),
            ]
        ),
        .target(
            name: "RenPlay",
            dependencies: ["RenPlayCore", "CRenPlayBridge"]
        ),
        .testTarget(
            name: "RenPlayCoreTests",
            dependencies: ["RenPlayCore"]
        ),
    ]
)
