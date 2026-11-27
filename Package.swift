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
            name: "CSMB2",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("config_shim"),
                .headerSearchPath("upstream/include"),
                .headerSearchPath("upstream/include/smb2"),
                .headerSearchPath("upstream/lib"),
                .define("HAVE_CONFIG_H", to: "1"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_GNU_SOURCE"),
                .define("_U_", to: "__attribute__((unused))"),
                .unsafeFlags(["-w"]),
            ]
        ),
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
            dependencies: ["CZlib", "CSMB2"],
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.iOS])),
            ]
        ),
        .target(
            name: "CRenPlayBridge",
            dependencies: ["CSMB2"],
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
                .linkedFramework("Photos", .when(platforms: [.iOS])),
                .linkedFramework("QuartzCore", .when(platforms: [.iOS])),
                .linkedFramework("StoreKit", .when(platforms: [.iOS])),
            ]
        ),
        .target(
            name: "RenPlay",
            dependencies: ["RenPlayCore", "CRenPlayBridge"],
            linkerSettings: [
                .linkedFramework("PhotosUI", .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(
            name: "RenPlayCoreTests",
            dependencies: ["RenPlayCore", "CSMB2"]
        ),
    ]
)
