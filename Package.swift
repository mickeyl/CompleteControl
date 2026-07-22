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
        .library(name: "KontrolSurfaceKit2", targets: ["KontrolSurfaceKit2"]),
        .library(name: "PaulincheSurfaceKit", targets: ["PaulincheSurfaceKit"]),
        .library(name: "KontrolUSB", targets: ["KontrolUSB"]),
        .library(name: "KontrolSimulatorWire", targets: ["KontrolSimulatorWire"]),
        .library(name: "KontrolSimulatorCore", targets: ["KontrolSimulatorCore"]),
        .executable(name: "ccd", targets: ["ccd"]),
        .executable(name: "MK2SurfaceDemo", targets: ["MK2SurfaceDemo"]),
        .executable(name: "widget-lab", targets: ["WidgetLab"]),
        .executable(name: "KontrolSimulator", targets: ["KontrolSimulator"]),
        .executable(name: "kontrol-sim-host", targets: ["KontrolSimHost"]),
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
            name: "KontrolSimulatorWire",
            path: "Sources/KontrolSimulatorWire",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "KompleteKontrol",
            dependencies: ["KontrolUSB", "KontrolSimulatorWire"],
            path: "Sources/KompleteKontrol",
            resources: [
                .copy("Resources/buddies.png"),
            ],
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
        .target(
            name: "KontrolSurfaceKit2",
            dependencies: ["KompleteKontrol", "CFreeType", "CHarfBuzz"],
            path: "Sources/KontrolSurfaceKit2",
            resources: [
                .copy("Resources/Fonts"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "PaulincheSurfaceKit",
            dependencies: ["KompleteKontrol", "KontrolSurfaceKit2"],
            path: "Sources/PaulincheSurfaceKit",
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
        .systemLibrary(
            name: "CHarfBuzz",
            path: "Sources/CHarfBuzz",
            pkgConfig: "harfbuzz",
            providers: [
                .brew(["harfbuzz"]),
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
            name: "WidgetLab",
            dependencies: ["KontrolSurfaceKit2", "KompleteKontrol"],
            path: "Tools/WidgetLab",
            exclude: ["SmokeScenarios.json"],
            resources: [
                .copy("PhosphorIcons.regular.json"),
                .copy("AboutHero.png"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "KontrolSimulator",
            dependencies: ["KompleteKontrol", "KontrolSimulatorCore"],
            path: "Tools/KontrolSimulator",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "KontrolSimHost",
            dependencies: ["KompleteKontrol", "KontrolSimulatorCore"],
            path: "Tools/KontrolSimHost",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "KontrolSimulatorCore",
            dependencies: ["KompleteKontrol", "KontrolSimulatorWire"],
            path: "Sources/KontrolSimulatorCore",
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
            dependencies: ["KompleteKontrol", "KontrolSurfaceKit2", "PaulincheSurfaceKit", "KontrolSimulatorCore"]
        ),
        .plugin(
            name: "GenerateBuildInfo",
            capability: .buildTool(),
            path: "Plugins/GenerateBuildInfo"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
