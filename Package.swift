// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KompleteKontrol",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KompleteKontrol", targets: ["KompleteKontrol"]),
        .library(name: "KontrolUSB", targets: ["KontrolUSB"]),
        .executable(name: "KontrolProbe", targets: ["KontrolProbe"]),
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
            name: "KontrolProbe",
            dependencies: ["KompleteKontrol", "KontrolUSB"],
            path: "Tools/KontrolProbe",
            swiftSettings: [
                .define("KK_DEBUG", .when(configuration: .debug)),
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
