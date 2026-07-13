import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The single source of truth for the REPL: drives help output, Tab completion, and the
/// documented argument shapes. Keep it in sync with `LabShell.command`.

let ledGroupNames = ["all", "palette", "rgb", "mono", "buttons", "strip", "jog", "functions", "transport"]
let ledCompletionValues = ledGroupNames
    + KKMK2ButtonLED.allCases.map(\.protocolName)
    + (1...8).map { "f\($0)" }
    + ["m", "s", "mute", "solo"]
let guideCompletionValues = ["all", "keys", "off"] + namedLEDColors.keys.sorted()

/// All lab demos, browser order comes from `DemoCategory`. Global so the
/// REPL help/completion can enumerate demo-local commands without touching
/// the shell actor; the instances themselves are only driven by the shell.
let labDemos: [any LabDemo] = [
    EncoderFeelDemo(),
    PanoramaDemo(),
    TypeSpecimenDemo(),
    IconBrowserDemo(),
    ChromeSlotsDemo(),
    FormsDemo(),
    SelectionBrowserDemo(),
    MeterDemo(),
    WaveformDemo(),
    TrackerPatternDemo(),
    ModalDialogDemo(),
    LightGuideDemo(),
]

let shellReplCommands: [ReplCommand] = [
    ReplCommand(name: "list", arg: "", summary: "list demos and their ids", values: []),
    ReplCommand(name: "open", arg: "<id>", summary: "open a demo", values: labDemos.map { $0.descriptor.id }),
    ReplCommand(name: "exit", arg: "", summary: "leave the demo, back to the browser", values: []),
    ReplCommand(name: "led", arg: "<led|group> <color|off> [0-3]", summary: "override 0x80 button/strip LEDs", values: ledCompletionValues),
    ReplCommand(name: "ledclear", arg: "[led|group]", summary: "toggle 0x80 LED override ownership", values: ledCompletionValues),
    ReplCommand(name: "ledlist", arg: "", summary: "list 0x80 LED names and capabilities", values: []),
    ReplCommand(name: "guide", arg: "<all|key> <color|off>", summary: "override 0x81 light-guide keys", values: guideCompletionValues),
    ReplCommand(name: "guideclear", arg: "[all|key]", summary: "clear light-guide override", values: guideCompletionValues),
    ReplCommand(name: "snap", arg: "[path]", summary: "write a two-screen PNG snapshot", values: []),
    ReplCommand(name: "screenshot", arg: "[path]", summary: "alias for snap", values: []),
    ReplCommand(name: "help", arg: "", summary: "show this help", values: []),
    ReplCommand(name: "quit", arg: "", summary: "exit", values: []),
]

/// Shell commands plus every demo's local commands: demo verbs only act while
/// their demo is open, but help and Tab completion list them all.
let replCommands: [ReplCommand] = shellReplCommands + labDemos.flatMap { $0.replCommands() }

func replComplete(_ tokens: [String]) -> [String] {
    if tokens.count <= 1 { return replCommands.map { $0.name } }
    guard tokens.count == 2, let command = replCommands.first(where: { $0.name == tokens[0].lowercased() }) else { return [] }
    return command.values
}

func printReplHelp() {
    print("MK2WidgetLabDemo REPL — commands (Tab completes):")
    for command in replCommands {
        let left = "\(command.name) \(command.arg)".padding(toLength: 26, withPad: " ", startingAt: 0)
        print("  \(left)\(command.summary)")
    }
}

actor LabShell {
    private let surface: MK2Surface2
    private let freeTypeRenderer: FreeTypeTextRenderer?
    /// Browser/demo navigation (rework 2026-07-12): the browser owns the
    /// surface until a demo is opened; an open demo owns everything except
    /// the reserved SCENE exit.
    enum LabMode { case browser, demo }
    var mode: LabMode = .browser
    var demoBrowserNavigation = MK2SelectionNavigation()
    /// 0 = All, 1… = DemoCategory raw value + 1.
    var demoBrowserCategoryIndex = 0
    let demoRegistry: [any LabDemo] = DemoCategory.allCases.flatMap { category in
        labDemos.filter { $0.descriptor.category == category }
    }
    private var activeDemo: (any LabDemo)?
    private var lampOverrides: [KKMK2ButtonLED: MK2LampState2] = [:]
    private var guideOverrides: [Int: KKRGB] = [:]
    private static let availableIntensity: UInt8 = 0x01
    static let actionWhite = KKRGB(red: 0xff, green: 0xff, blue: 0xff)

    init(surface: MK2Surface2) {
        self.surface = surface
        self.freeTypeRenderer = try? FreeTypeTextRenderer()
    }

    func render() async {
        await surface.present(scene())
    }

    // MARK: - Scene

    private func scene() -> MK2SurfaceScene2 {
        switch mode {
            case .browser:
                return demoBrowserScene()
            case .demo:
                guard let activeDemo else { return demoBrowserScene() }
                return demoScene(activeDemo)
        }
    }

    private func labContext() -> LabContext {
        LabContext(
            renderer: freeTypeRenderer,
            update: { [weak self] mutation in
                Task { await self?.applyDemoMutation(mutation, rerender: true) }
            },
            mutate: { [weak self] mutation in
                Task { await self?.applyDemoMutation(mutation, rerender: false) }
            }
        )
    }

    private func applyDemoMutation(_ mutation: @escaping @Sendable () -> Void, rerender: Bool) async {
        mutation()
        if rerender {
            await render()
        }
    }

    private func activeModernDemo() -> (any LabDemo)? {
        guard mode == .demo else { return nil }
        return activeDemo
    }

    private func demoScene(_ demo: any LabDemo) -> MK2SurfaceScene2 {
        var scene = demo.buildScene(labContext())
        // The one control a demo never owns: SCENE always exits to the browser.
        scene.lamps[.scene] = Self.availableLamp(Self.actionWhite)
        scene.bindings.onPress(.scene) { [weak self] in
            Task { await self?.showBrowser() }
        }
        applyLampOverrides(to: &scene.lamps)
        applyGuideOverrides(to: &scene.keyColors)
        return scene
    }

    func showBrowser() async {
        activeDemo?.demoWillClose()
        activeDemo = nil
        mode = .browser
        demoBrowserNavigation.clamp(itemCount: visibleBrowserDemos().count)
        await render()
    }

    func openDemo(_ demo: any LabDemo) async {
        activeDemo?.demoWillClose()
        activeDemo = demo
        mode = .demo
        await render()
    }

    func applyLampOverrides(to lamps: inout [KKMK2ButtonLED: MK2LampState2]) {
        for (led, state) in lampOverrides {
            lamps[led] = state
        }
    }

    func applyGuideOverrides(to keyColors: inout [Int: KKRGB]) {
        for (index, color) in guideOverrides {
            keyColors[index] = color
        }
    }

    static func availableLamp(_ color: KKRGB) -> MK2LampState2 {
        .on(color, intensity: availableIntensity)
    }

    func regularScreenResult(
        header: MK2ScreenHeader,
        footer: MK2ScreenFooter = .none,
        progress: MK2ScreenProgressBar? = nil,
        @MK2ScreenBuilder content: () -> [any MK2ScreenElement]
    ) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(header: header, footer: footer, progress: progress, content: content)
            .build(renderer: freeTypeRenderer)
    }

    func fullScreenResult(
        @MK2ScreenBuilder content: () -> [any MK2ScreenElement]
    ) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(content: content)
            .build(renderer: freeTypeRenderer)
    }

    // MARK: - REPL

    func command(_ line: String) async {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let verb = parts.first.map(String.init)?.lowercased() ?? ""
        let rest = parts.count > 1 ? String(parts[1]) : ""

        switch verb {
            case "list":
                for category in DemoCategory.allCases {
                    let demos = demoRegistry.filter { $0.descriptor.category == category }
                    guard !demos.isEmpty else { continue }
                    print("\(category.title):")
                    for demo in demos {
                        let id = demo.descriptor.id.padding(toLength: 18, withPad: " ", startingAt: 0)
                        print("  \(id)\(demo.descriptor.summary)")
                    }
                }

            case "open":
                guard let target = demoRegistry.first(where: { $0.descriptor.id == rest.lowercased() }) else {
                    print("? open <id> — see 'list'"); return
                }
                await openDemo(target)
                print("→ \(target.descriptor.title)")

            case "exit":
                await showBrowser()
                print("→ browser")

            case _ where activeModernDemo()?.handleRepl(verb: verb, rest: rest, labContext()) == true:
                break

            case "led":
                await handleLEDCommand(rest)

            case "ledclear":
                await clearLEDOverrides(rest)

            case "ledlist":
                Self.printLEDList()

            case "guide", "lightguide", "keys":
                await handleGuideCommand(rest)

            case "guideclear", "lightguideclear", "keyclear":
                await clearGuideOverrides(rest)

            case "snap", "screenshot":
                await snapshot(to: rest.isEmpty ? nil : rest)

            case "help", "?":
                printReplHelp()

            case "quit", "q":
                print("bye"); exit(0)

            default:
                print("? unknown '\(verb)' — try help")
        }
    }

    // Headless verification hook: render each implemented unit's two-screen scene to a PNG
    // without a surface/daemon connection. Driven by WIDGETLAB_SNAPSHOT_DIR at launch.
    func snapshotAll(to directory: String) async {
        // The browser itself, once per category filter.
        mode = .browser
        for index in 0..<Self.demoBrowserCategoryValues.count {
            demoBrowserCategoryIndex = index
            demoBrowserNavigation.select(0, itemCount: visibleBrowserDemos().count)
            await snapshot(to: directory + "/widgetlab-browser-\(Self.snapshotSlug(Self.demoBrowserCategoryValues[index])).png")
        }
        demoBrowserCategoryIndex = 0

        mode = .demo
        for demo in demoRegistry {
            activeDemo = demo
            for variant in [""] + demo.descriptor.snapshotVariants {
                demo.prepareSnapshot(variant: variant)
                let suffix = variant.isEmpty ? "" : "-\(variant)"
                await snapshot(to: directory + "/widgetlab-\(demo.descriptor.id)\(suffix).png")
                if variant.isEmpty, scene().shift != nil {
                    await snapshot(to: directory + "/widgetlab-\(demo.descriptor.id)-shift.png", layer: .shift)
                }
            }
            demo.prepareSnapshot(variant: "")
            demo.demoWillClose()
        }
    }

    private static func snapshotSlug(_ text: String) -> String {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }

    private enum SnapshotLayer {
        case base
        case shift
    }

    private func snapshot(to path: String?, layer: SnapshotLayer = .base) async {
        let currentScene = scene()
        var displays = currentScene.displays
        if layer == .shift, let shift = currentScene.shift {
            displays = displays.enumerated().map { index, base in
                shift.displays.indices.contains(index) ? shift.displays[index] ?? base : base
            }
        }
        let frames = displays.map { $0 ?? MK2PixelFrame() }
        let target = path ?? FileManager.default.currentDirectoryPath + "/widgetlab-snapshot.png"
        do {
            let written = try PixelSnapshot.write(frames, to: target)
            print("snapshot → \(written)")
        } catch {
            print("snapshot failed: \(error)")
        }
    }

    private func handleGuideCommand(_ rest: String) async {
        let parts = rest
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard parts.count == 2 else {
            print("? guide <all|0-87> <color|off>"); return
        }
        guard let targets = Self.guideTargets(parts[0]), !targets.isEmpty else {
            print("? unknown light-guide target '\(parts[0])'"); return
        }

        let colorToken = parts[1].lowercased()
        let color: KKRGB
        if colorToken == "off" {
            color = .off
        } else if let parsed = Self.ledColor(parts[1]) {
            color = parsed
        } else {
            print("? color <rrggbb|name|off>"); return
        }

        for index in targets {
            guideOverrides[index] = color
        }
        await render()
        print("guide \(parts[0]) = \(Self.guideColorDescription(color)) (\(targets.count) key\(targets.count == 1 ? "" : "s"))")
    }

    private func clearGuideOverrides(_ rest: String) async {
        let target = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            let count = guideOverrides.count
            guideOverrides.removeAll()
            await render()
            print("guide middleware control restored for all (\(count) override\(count == 1 ? "" : "s"))")
            return
        }
        guard let targets = Self.guideTargets(target), !targets.isEmpty else {
            print("? unknown light-guide target '\(target)'"); return
        }
        for index in targets {
            guideOverrides.removeValue(forKey: index)
        }
        await render()
        print("guide middleware control restored for \(target) (\(targets.count) key\(targets.count == 1 ? "" : "s"))")
    }

    private func handleLEDCommand(_ rest: String) async {
        let parts = rest
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard parts.count == 2 || parts.count == 3 else {
            print("? led <led|group> <color|off> [0-3]"); return
        }
        guard let targets = Self.ledTargets(parts[0]), !targets.isEmpty else {
            print("? unknown LED/group '\(parts[0])' — try ledlist"); return
        }

        let colorToken = parts[1].lowercased()
        let intensity = parts.count == 3 ? Self.ledIntensity(parts[2]) : 3
        guard let intensity else {
            print("? brightness 0-3, off, dim, mid, full"); return
        }

        let state: MK2LampState2
        if colorToken == "off" || intensity == 0 {
            state = .off
        } else if let color = Self.ledColor(parts[1]) {
            state = .on(color, intensity: intensity)
        } else {
            print("? color <rrggbb|name|off>"); return
        }

        for led in targets {
            lampOverrides[led] = state
        }
        await render()
        print("led \(parts[0]) = \(Self.ledStateDescription(state)) (\(targets.count) target\(targets.count == 1 ? "" : "s"))")
    }

    private func clearLEDOverrides(_ rest: String) async {
        let target = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetLabel = target.isEmpty ? "all" : target
        guard let targets = Self.ledTargets(targetLabel), !targets.isEmpty else {
            print("? unknown LED/group '\(targetLabel)' — try ledlist"); return
        }

        let hasFullOwnership = targets.allSatisfy { lampOverrides[$0] != nil }
        if hasFullOwnership {
            for led in targets {
                lampOverrides.removeValue(forKey: led)
            }
            await render()
            print("led middleware control restored for \(targetLabel) (\(targets.count) target\(targets.count == 1 ? "" : "s"))")
        } else {
            for led in targets {
                lampOverrides[led] = .off
            }
            await render()
            print("led \(targetLabel) override ownership active: off (\(targets.count) target\(targets.count == 1 ? "" : "s"))")
        }
    }

    private static func printLEDList() {
        let rgb = KKMK2ButtonLED.allCases.filter(\.isRGBBacklit).map(\.protocolName).joined(separator: " ")
        let mono = KKMK2ButtonLED.allCases.filter { $0.isMonochromeBacklit && !$0.protocolName.hasPrefix("strip") }.map(\.protocolName).joined(separator: " ")
        let strips = KKMK2ButtonLED.allCases.filter { $0.protocolName.hasPrefix("strip") }.map(\.protocolName).joined(separator: " ")
        print("0x80 palette LEDs: \(rgb)")
        print("0x80 fixed monochrome LEDs: \(mono)")
        print("0x80 touch strip LEDs: \(strips)")
        print("0x80 groups: all palette rgb mono buttons strip jog functions transport")
        print("Usage: led <led|group> <color|off> [0-3], ledclear [led|group]")
        print("Light guide: guide <all|0-87> <color|off>, guideclear [all|0-87]")
        print("ledclear toggles ownership: first call forces off, second call returns control to the scene.")
    }

    // MARK: - Parsing helpers

    // Accepts RRGGBB hex or a small set of names, returns wire-order-agnostic RGB565.

    private static func guideTargets(_ text: String) -> [Int]? {
        let key = ledKey(text)
        switch key {
            case "all", "keys", "lightguide", "guide":
                return Array(0..<88)
            default:
                guard let index = Int(text), (0..<88).contains(index) else { return nil }
                return [index]
        }
    }

    private static func ledTargets(_ text: String) -> [KKMK2ButtonLED]? {
        let key = ledKey(text)
        switch key {
            case "all":
                return KKMK2ButtonLED.allCases
            case "palette", "rgb":
                return KKMK2ButtonLED.allCases.filter(\.isRGBBacklit)
            case "mono":
                return KKMK2ButtonLED.allCases.filter(\.isMonochromeBacklit)
            case "buttons":
                return KKMK2ButtonLED.allCases.filter { !$0.protocolName.hasPrefix("strip") }
            case "strip", "strips", "touchstrip":
                return KKMK2ButtonLED.allCases.filter { $0.protocolName.hasPrefix("strip") }
            case "jog", "4d", "4dencoder":
                return [.jogLeft, .jogRight, .jogUp, .jogDown]
            case "functions", "function", "func", "f":
                return [.function1, .function2, .function3, .function4, .function5, .function6, .function7, .function8]
            case "transport":
                return [.play, .record, .stop, .loop, .metro, .tempo]
            default:
                if let led = ledAliases[key] {
                    return [led]
                }
                return nil
        }
    }

    private static var ledAliases: [String: KKMK2ButtonLED] {
        var aliases: [String: KKMK2ButtonLED] = [:]
        for led in KKMK2ButtonLED.allCases {
            aliases[ledKey(led.protocolName)] = led
        }
        aliases["m"] = .m
        aliases["mute"] = .m
        aliases["s"] = .s
        aliases["solo"] = .s
        aliases["left"] = .jogLeft
        aliases["right"] = .jogRight
        aliases["up"] = .jogUp
        aliases["down"] = .jogDown
        aliases["pageleft"] = .pageLeft
        aliases["pageright"] = .pageRight
        for index in 1...8 {
            aliases["f\(index)"] = KKMK2ButtonLED(rawValue: KKMK2ButtonLED.function1.rawValue + index - 1)
        }
        return aliases
    }

    private static func ledKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func ledColor(_ text: String) -> KKRGB? {
        if let hit = namedLEDColors[text.lowercased()] {
            return hit
        }
        let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
        return KKRGB(
            red: UInt8((rgb >> 16) & 0xff),
            green: UInt8((rgb >> 8) & 0xff),
            blue: UInt8(rgb & 0xff)
        )
    }

    private static func ledIntensity(_ text: String) -> UInt8? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "off", "none", "0":
                return 0
            case "dim", "low", "half", "1":
                return 1
            case "mid", "medium", "2":
                return 2
            case "full", "high", "on", "3":
                return 3
            default:
                return nil
        }
    }

    private static func ledStateDescription(_ state: MK2LampState2) -> String {
        switch state {
            case .off:
                return "off"
            case let .on(color, intensity):
                return "\(String(format: "#%02x%02x%02x", color.red, color.green, color.blue)) @ \(intensity)"
            case let .blink(color, _, intensity):
                return "blink \(String(format: "#%02x%02x%02x", color.red, color.green, color.blue)) @ \(intensity)"
            case let .pulse(color, _):
                return "pulse \(String(format: "#%02x%02x%02x", color.red, color.green, color.blue))"
        }
    }

    private static func guideColorDescription(_ color: KKRGB) -> String {
        color == .off ? "off" : String(format: "#%02x%02x%02x", color.red, color.green, color.blue)
    }
}

let namedLEDColors: [String: KKRGB] = [
    "white": KKRGB(red: 0xff, green: 0xff, blue: 0xff),
    "black": KKRGB(red: 0x00, green: 0x00, blue: 0x00),
    "red": KKRGB(red: 0xff, green: 0x00, blue: 0x00),
    "green": KKRGB(red: 0x00, green: 0xff, blue: 0x00),
    "blue": KKRGB(red: 0x00, green: 0x00, blue: 0xff),
    "yellow": KKRGB(red: 0xff, green: 0xff, blue: 0x00),
    "cyan": KKRGB(red: 0x00, green: 0xff, blue: 0xff),
    "magenta": KKRGB(red: 0xff, green: 0x00, blue: 0xff),
    "orange": KKRGB(red: 0xff, green: 0x7f, blue: 0x00),
    "grey": KKRGB(red: 0x80, green: 0x80, blue: 0x80),
    "gray": KKRGB(red: 0x80, green: 0x80, blue: 0x80),
    "dim": KKRGB(red: 0x40, green: 0x40, blue: 0x40),
]

