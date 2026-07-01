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
        .executable(name: "MK2SurfaceDemo", targets: ["MK2SurfaceDemo"]),
        .executable(name: "MK2USBSpy", targets: ["MK2USBSpy"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CLibUSB",
            path: "Sources/CLibUSB",
            sources: [
                "src/core.c",
                "src/descriptor.c",
                "src/hotplug.c",
                "src/io.c",
                "src/strerror.c",
                "src/sync.c",
                "src/events_posix.c",
                "src/threads_posix.c",
                "src/darwin_usb.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../Vendor/libusb/libusb"),
                .headerSearchPath("../../Vendor/libusb/libusb/os"),
                .headerSearchPath("../../Vendor/libusb/Xcode"),
                .unsafeFlags(["-fvisibility=hidden"]),
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedLibrary("objc"),
            ]
        ),
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
            ],
            plugins: ["GenerateBuildInfo"]
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
        .executableTarget(
            name: "MK2SurfaceDemo",
            dependencies: ["KompleteKontrol"],
            path: "Tools/MK2SurfaceDemo",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "MK2USBSpy",
            dependencies: ["CLibUSB"],
            path: "Tools/MK2USBSpy"
        ),
        .testTarget(
            name: "KompleteKontrolTests",
            dependencies: ["KompleteKontrol"]
        ),
        .plugin(
            name: "GenerateBuildInfo",
            capability: .buildTool(),
            path: "Plugins/GenerateBuildInfo"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
