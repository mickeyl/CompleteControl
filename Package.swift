// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompleteControl",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CompleteControl", targets: ["KompleteKontrol"]),
        .library(name: "KompleteKontrol", targets: ["KompleteKontrol"]),
        .library(name: "KontrolSurfaceKit", targets: ["KontrolSurfaceKit"]),
        .library(name: "KontrolUSB", targets: ["KontrolUSB"]),
        .executable(name: "ccd", targets: ["ccd"]),
        .executable(name: "KontrolProbe", targets: ["KontrolProbe"]),
        .executable(name: "SurfaceDemo", targets: ["SurfaceDemo"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "KontrolUSB",
            dependencies: ["CLibUSB"],
            path: "Sources/KontrolUSB",
            publicHeadersPath: "include",
            cSettings: [
                .define("KK_DEBUG", .when(configuration: .debug)),
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
            ]
        ),
        .target(
            name: "KompleteKontrol",
            dependencies: ["KontrolUSB"],
            path: "Sources/KompleteKontrol",
            swiftSettings: [
                .define("KK_DEBUG", .when(configuration: .debug)),
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "ccd",
            dependencies: ["KompleteKontrol"],
            path: "Tools/ccd",
            swiftSettings: [
                .define("KK_DEBUG", .when(configuration: .debug)),
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "KontrolProbe",
            dependencies: ["KompleteKontrol", "KontrolUSB"],
            path: "Tools/KontrolProbe",
            swiftSettings: [
                .define("KK_DEBUG", .when(configuration: .debug)),
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "KontrolSurfaceKit",
            dependencies: ["KompleteKontrol"],
            path: "Sources/KontrolSurfaceKit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "SurfaceDemo",
            dependencies: ["KontrolSurfaceKit", "KompleteKontrol"],
            path: "Tools/SurfaceDemo",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .systemLibrary(
            name: "CLibUSB",
            path: "Sources/CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [
                .brew(["libusb"]),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
