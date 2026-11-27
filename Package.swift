// swift-tools-version: 6.0
import PackageDescription

let packageDir: String = {
    let file = #filePath
    if let slash = file.lastIndex(of: "/") {
        return String(file[..<slash])
    }
    return "."
}()

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
    dependencies: [
        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7"),
    ],
    targets: [
        .target(
            name: "CZlib",
            dependencies: [
                .product(name: "libzstd", package: "zstd"),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("bz2", .when(platforms: [.iOS, .macOS])),
                .linkedLibrary("lzma", .when(platforms: [.iOS, .macOS])),
                .linkedLibrary("archive", .when(platforms: [.iOS, .macOS])),
                .linkedLibrary("dl", .when(platforms: [.linux])),
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
                .unsafeFlags(
                    [
                        "-F", "\(packageDir)/BundleResources/Frameworks",
                        "-framework", "MetalANGLE",
                    ],
                    .when(platforms: [.iOS])
                ),
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
