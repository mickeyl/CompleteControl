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
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
            ]
        ),
        .target(
            name: "KompleteKontrol",
            dependencies: ["KontrolUSB"],
            path: "Sources/KompleteKontrol",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "KontrolProbe",
            dependencies: ["KompleteKontrol", "KontrolUSB"],
            path: "Tools/KontrolProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
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
