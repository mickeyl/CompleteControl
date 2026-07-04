// swift-tools-version: 6.2
import PackageDescription

// macOS 26 minimum (decision 2026-07-02): unlocks Span/MutableSpan/InlineArray in the
// pixel hot paths; this software will not run on older systems.
let package = Package(
    name: "CompleteControl",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CompleteControl", targets: ["KompleteKontrol"]),
        .library(name: "KompleteKontrol", targets: ["KompleteKontrol"]),
        .library(name: "KontrolSurfaceKit", targets: ["KontrolSurfaceKit"]),
        .library(name: "KontrolSurfaceKit2", targets: ["KontrolSurfaceKit2"]),
        .library(name: "KontrolUSB", targets: ["KontrolUSB"]),
        .executable(name: "ccd", targets: ["ccd"]),
        .executable(name: "KontrolProbe", targets: ["KontrolProbe"]),
        .executable(name: "SurfaceDemo", targets: ["SurfaceDemo"]),
        .executable(name: "MK2SurfaceDemo", targets: ["MK2SurfaceDemo"]),
        .executable(name: "MK2WidgetLabDemo", targets: ["MK2WidgetLabDemo"]),
        .executable(name: "MK2FreeTypeDemo", targets: ["MK2FreeTypeDemo"]),
        .executable(name: "KontrolSimulator", targets: ["KontrolSimulator"]),
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
        .target(
            name: "KontrolSurfaceKit2",
            dependencies: ["KompleteKontrol", "CFreeType"],
            path: "Sources/KontrolSurfaceKit2",
            resources: [
                .copy("Resources/Fonts"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .systemLibrary(
            name: "CFreeType",
            path: "Sources/CFreeType",
            pkgConfig: "freetype2",
            providers: [
                .brew(["freetype"]),
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
            dependencies: ["KontrolSurfaceKit2", "KompleteKontrol"],
            path: "Tools/MK2SurfaceDemo",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "MK2WidgetLabDemo",
            dependencies: ["KontrolSurfaceKit2", "KompleteKontrol"],
            path: "Tools/MK2WidgetLabDemo",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "MK2FreeTypeDemo",
            dependencies: ["KontrolSurfaceKit2", "KompleteKontrol"],
            path: "Tools/MK2FreeTypeDemo",
            resources: [
                .copy("FontAwesomeIcons.pro.json"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "KontrolSimulator",
            dependencies: ["KompleteKontrol"],
            path: "Tools/KontrolSimulator",
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
            dependencies: ["KompleteKontrol", "KontrolSurfaceKit2"]
        ),
        .plugin(
            name: "GenerateBuildInfo",
            capability: .buildTool(),
            path: "Plugins/GenerateBuildInfo"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
