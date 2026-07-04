import Foundation
import Darwin
import KompleteKontrol
import KontrolSurfaceKit2

@main
struct MK2FreeTypeDemo {
    static func main() async {
        do {
            let surface = MK2Surface2(options: .init(tickHz: 30))
            let demo = try FreeTypeDemo(surface: surface)
            let runner = MK2SurfaceEventRunner(name: "surface", surface: surface)
            demo.printHelp()
            fflush(stdout)
            await runner.run(
                initialRender: { _ in await demo.render() },
                onConnected: { _, _ in await demo.render() }
            )
        } catch {
            fputs("MK2FreeTypeDemo: \(error)\n", stderr)
            exit(1)
        }
    }
}

private actor FreeTypeDemo {
    private enum Page: Int, CaseIterable, Sendable {
        case typography
        case icons
        case actionDialog

        var title: String {
            switch self {
                case .typography: "TYPOGRAPHY"
                case .icons: "ICON BROWSER"
                case .actionDialog: "ACTION DIALOG"
            }
        }

        var functionLED: KKMK2ButtonLED {
            KKMK2ButtonLED(rawValue: KKMK2ButtonLED.function1.rawValue + rawValue)!
        }
    }

    private struct ActionCandidate: Sendable {
        let iconName: String
        let title: String
        let body: String
        let action: String
    }

    private static let textFamilyID = FreeTypeFontCatalog.textFamilyID
    private static let rasterMode = FreeTypeRasterMode.grayscaleHinted
    private static let bodySize = 16
    private static let titleSize = 24
    private static let iconPageStep = 7
    private static let actionDialogIconSize = 48
    private static let iconStyleLabel = "Pro Light"

    private let surface: MK2Surface2
    private let renderer: FreeTypeTextRenderer
    private let catalog = FreeTypeFontCatalog.production
    private let iconSource: String
    private let icons: [FontAwesomeIcon]
    private let iconSizes = [20, 24, 28, 32, 36, 42, 48, 56, 64, 72, 88]
    private let actionCandidates = [
        ActionCandidate(iconName: "circle-info", title: "Load Instrument?", body: "Replace the current sound and keep pattern data.", action: "LOAD"),
        ActionCandidate(iconName: "triangle-exclamation", title: "Clear Pattern?", body: "This removes all notes in the selected pattern.", action: "CLEAR"),
        ActionCandidate(iconName: "floppy-disk", title: "Save Snapshot", body: "Write the current display pair as a PNG reference.", action: "SAVE"),
        ActionCandidate(iconName: "arrow-right-from-bracket", title: "Leave Browser?", body: "Return to the tracker without changing selection.", action: "LEAVE"),
    ]

    private var page: Page = .typography
    private var iconIndex: Int
    private var iconSizeIndex = 7
    private var actionIndex = 0

    init(surface: MK2Surface2) throws {
        self.surface = surface
        self.renderer = try FreeTypeTextRenderer(catalog: catalog)
        let iconCatalog = try FontAwesomeIconCatalog.load()
        self.iconSource = iconCatalog.source
        self.icons = iconCatalog.icons
        self.iconIndex = iconCatalog.icons.firstIndex { $0.name == "circle-info" } ?? 0
    }

    nonisolated func printHelp() {
        print("""
        MK2FreeTypeDemo - production typography and icon demo

        Fixed rendering contract:
          Text family                  IBM Plex Sans Condensed
          Body                         Regular 16 px
          Title                        Medium 24 px
          Raster                       Gray hinted; no LCD/subpixel rendering
          Icon family                  Font Awesome 7 Pro Light

        Pages:
          F1                           typography specimens
          F2                           Font Awesome icon browser
          F3                           action-dialog icon test

        Icon controls:
          Main rotary                  scroll right icon list
          4D Up / 4D Down              scroll right icon list by one page
          Page Left / Page Right       previous / next icon
          Plugin / Mixer               jump -16 / +16 icons
          Preset Down / Preset Up      smaller / larger icon size

        Action-dialog page:
          F3                           dialog test page
          Icon size                    fixed 48 px
          Mixer                        also cycles dialog copy when on F3

        Lamp states:
          Bright blue                  active page
          Dim white                    available action
          Off                          unavailable range edge

        Notes:
          Duotone and Brands are intentionally not shown in this pass.
        """)
    }

    func render() async {
        await surface.present(scene())
    }

    private var icon: FontAwesomeIcon { icons[iconIndex] }
    private var iconSize: Int { iconSizes[iconSizeIndex] }

    private func scene() -> MK2SurfaceScene2 {
        var bindings = MK2InputBindings2()
        var lamps = stateLamps()
        bindPageButtons(lamps: &lamps, bindings: &bindings)
        bindIconControls(lamps: &lamps, bindings: &bindings)
        return MK2SurfaceScene2(left: leftFrame(), right: rightFrame(), lamps: lamps, bindings: bindings)
    }

    private static var availableLamp: MK2LampState2 {
        .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)
    }

    private static var activePageLamp: MK2LampState2 {
        .on(KKRGB(red: 0x00, green: 0x7f, blue: 0xff), intensity: 0x03)
    }

    private func stateLamps() -> [KKMK2ButtonLED: MK2LampState2] {
        var lamps: [KKMK2ButtonLED: MK2LampState2] = [:]
        for candidate in Page.allCases {
            lamps[candidate.functionLED] = candidate == page ? Self.activePageLamp : Self.availableLamp
        }
        lamps[.pageLeft] = Self.availableLamp
        lamps[.pageRight] = Self.availableLamp
        lamps[.plugin] = Self.availableLamp
        lamps[.mixer] = Self.availableLamp
        if page == .icons {
            lamps[.jogLeft] = Self.availableLamp
            lamps[.jogRight] = Self.availableLamp
            lamps[.jogUp] = Self.availableLamp
            lamps[.jogDown] = Self.availableLamp
        }
        return lamps
    }

    private func bindPageButtons(lamps: inout [KKMK2ButtonLED: MK2LampState2], bindings: inout MK2InputBindings2) {
        for candidate in Page.allCases {
            bindings.onPress(candidate.functionLED) { [weak self] in
                Task { await self?.setPage(candidate) }
            }
        }
    }

    private func bindIconControls(lamps: inout [KKMK2ButtonLED: MK2LampState2], bindings: inout MK2InputBindings2) {
        bindings.onPress(.pageLeft) { [weak self] in Task { await self?.moveIcon(-1) } }
        bindings.onPress(.pageRight) { [weak self] in Task { await self?.moveIcon(1) } }
        bindings.onPress(.plugin) { [weak self] in Task { await self?.moveIcon(-16) } }
        bindings.onPress(.mixer) { [weak self] in Task { await self?.mixerAction() } }
        if page == .icons {
            bindings.jogScroll = { [weak self] delta, _ in
                Task { await self?.moveIcon(delta) }
            }
            bindings.jog = { [weak self] direction in
                Task { await self?.jogIconList(direction) }
            }
        }

        MK2ButtonRangeSelection(
            value: iconSizeIndex,
            bounds: 0...(iconSizes.count - 1),
            previousButton: .presetDown,
            nextButton: .presetUp,
            availableLamp: Self.availableLamp
        ) { [weak self] index in
            Task { await self?.setIconSizeIndex(index) }
        }.apply(lamps: &lamps, bindings: &bindings)
    }

    private func setPage(_ next: Page) async {
        page = next
        await render()
    }

    private func moveIcon(_ delta: Int) async {
        iconIndex = (iconIndex + delta).wrapped(to: 0...(icons.count - 1))
        await render()
    }

    private func jogIconList(_ direction: String) async {
        switch direction {
            case "up":
                await moveIcon(-Self.iconPageStep)
            case "down":
                await moveIcon(Self.iconPageStep)
            default:
                break
        }
    }

    private func setIconSizeIndex(_ index: Int) async {
        iconSizeIndex = index
        await render()
    }

    private func mixerAction() async {
        if page == .actionDialog {
            actionIndex = (actionIndex + 1).wrapped(to: 0...(actionCandidates.count - 1))
            if let index = icons.firstIndex(where: { $0.name == actionCandidates[actionIndex].iconName }) {
                iconIndex = index
            }
        } else {
            await moveIcon(16)
            return
        }
        await render()
    }

    private func leftFrame() -> MK2PixelFrame {
        switch page {
            case .typography:
                return typographySpecimenFrame()
            case .icons:
                return iconBrowserFrame()
            case .actionDialog:
                return actionDialogFrame()
        }
    }

    private func rightFrame() -> MK2PixelFrame {
        switch page {
            case .typography:
                return typographyContextFrame()
            case .icons:
                return iconListFrame()
            case .actionDialog:
                return actionDialogControlsFrame()
        }
    }

    private func typographySpecimenFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.background)
        drawBitmapHeader(into: &frame, title: page.title, subtitle: "plex condensed production styles")
        drawTitle("Browser Selection", into: &frame, x: 18, y: 56, color: Palette.text)
        drawBody("Body Regular 16 px. Calm, readable text for longer MK2 surfaces.", into: &frame, x: 18, y: 91, color: Palette.dim, maxWidth: 432)
        drawTitle("Settings", into: &frame, x: 18, y: 132, color: Palette.text)
        drawBody("Lists, dialogs, browser panes, and preferences use one body rhythm.", into: &frame, x: 18, y: 167, color: Palette.dim, maxWidth: 432)
        drawBody("Tracker grids remain bitmap-sharp and separate from this FreeType path.", into: &frame, x: 18, y: 209, color: Palette.muted, maxWidth: 432)
        BitmapLabel("BITMAP GRID 0123456789", font: .grid, color: Palette.bitmap).draw(into: &frame, x: 18, y: 252)
        return frame
    }

    private func typographyContextFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.panel)
        drawBitmapHeader(into: &frame, title: "COMBINATIONS", subtitle: "title 24 medium + body 16 regular")
        drawListRow(into: &frame, y: 54, title: "Piano Noir", body: "Felt grand with quiet release samples", focused: true)
        drawListRow(into: &frame, y: 114, title: "Tape Strings", body: "Warm ensemble, filtered attack", focused: false)
        drawListRow(into: &frame, y: 174, title: "System", body: "Display brightness, browser defaults", focused: false)
        drawBody("F1 Typo  F2 Icons  F3 Dialog", into: &frame, x: 18, y: 246, color: Palette.muted, maxWidth: 432)
        return frame
    }

    private func iconBrowserFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.background)
        drawBitmapHeader(into: &frame, title: page.title, subtitle: "\(iconIndex + 1)/\(icons.count) \(Self.iconStyleLabel)")
        drawIcon(icon, into: &frame, centerX: 240, baselineY: 72, size: iconSize, color: Palette.text)
        drawTitle(icon.label, into: &frame, x: 18, y: 158, color: Palette.text, maxWidth: 432)
        drawBody(icon.name, into: &frame, x: 18, y: 194, color: Palette.dim, maxWidth: 432)
        drawBody(String(format: "U+%04X  size %d px  %@", icon.codepoint, iconSize, Self.iconStyleLabel), into: &frame, x: 18, y: 222, color: Palette.dim, maxWidth: 432)
        drawBody("Main rotary +/-1   4D up/down +/-7   Preset size", into: &frame, x: 18, y: 248, color: Palette.muted, maxWidth: 432)
        return frame
    }

    private func iconListFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.panel)
        drawBitmapHeader(into: &frame, title: "NEARBY ICONS", subtitle: "\(icons.count) icons, Pro Light")
        let offsets = [-3, -2, -1, 0, 1, 2, 3]
        for (row, offset) in offsets.enumerated() {
            let index = (iconIndex + offset).wrapped(to: 0...(icons.count - 1))
            let item = icons[index]
            let y = 50 + row * 30
            if index == iconIndex {
                frame.fill(MK2PixelRect(x: 8, y: y - 4, width: 464, height: 27), Palette.selection)
            }
            drawIcon(item, into: &frame, x: 20, y: y - 2, size: 22, color: Palette.text)
            drawBody(item.name, into: &frame, x: 58, y: y, color: index == iconIndex ? Palette.text : Palette.dim, maxWidth: 280)
            drawBody("PLT", into: &frame, x: 360, y: y, color: Palette.text)
        }
        return frame
    }

    private func actionDialogFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.background)
        drawBitmapHeader(into: &frame, title: page.title, subtitle: "Pro Light, icon 48 px")
        let candidate = actionCandidates[actionIndex]
        frame.fill(MK2PixelRect(x: 46, y: 56, width: 388, height: 172), Palette.dialog)
        frame.stroke(MK2PixelRect(x: 46, y: 56, width: 388, height: 172), Palette.border)
        drawIcon(icon, into: &frame, centerX: 240, baselineY: 77, size: Self.actionDialogIconSize, color: Palette.accent)
        drawTitle(candidate.title, into: &frame, x: 74, y: 133, color: Palette.text, maxWidth: 332)
        drawBody(candidate.body, into: &frame, x: 74, y: 171, color: Palette.dim, maxWidth: 332)
        drawBody("[\(candidate.action)]        CANCEL", into: &frame, x: 142, y: 204, color: Palette.text, maxWidth: 240)
        drawBody("Mixer cycles dialog copy. Page/Plugin browse icons.", into: &frame, x: 18, y: 246, color: Palette.muted, maxWidth: 432)
        return frame
    }

    private func actionDialogControlsFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.panel)
        drawBitmapHeader(into: &frame, title: "DIALOG TEST", subtitle: "global action style")
        drawTitle("Current Icon", into: &frame, x: 18, y: 58, color: Palette.text)
        drawBody(icon.name, into: &frame, x: 18, y: 94, color: Palette.dim, maxWidth: 300)
        drawBody(String(format: "Pro Light  U+%04X  action 48 px", icon.codepoint), into: &frame, x: 18, y: 122, color: Palette.dim, maxWidth: 420)
        var x = 18
        for size in [24, 32, 42, 56, 72] {
            let item = MK2PixelRect(x: x - 3, y: 158, width: 58, height: 74)
            if size == iconSize { frame.stroke(item, Palette.accent) }
            drawIcon(icon, into: &frame, centerX: x + 25, baselineY: 164, size: size, color: Palette.text)
            drawBody("\(size)", into: &frame, x: x + 9, y: 216, color: size == iconSize ? Palette.text : Palette.muted)
            x += 84
        }
        drawBody(iconSource, into: &frame, x: 18, y: 248, color: Palette.muted, maxWidth: 432)
        return frame
    }

    private func drawListRow(into frame: inout MK2PixelFrame, y: Int, title: String, body: String, focused: Bool) {
        if focused {
            frame.fill(MK2PixelRect(x: 12, y: y - 6, width: 456, height: 54), Palette.selection)
        }
        drawTitle(title, into: &frame, x: 22, y: y, color: focused ? Palette.text : Palette.dim, maxWidth: 420)
        drawBody(body, into: &frame, x: 22, y: y + 31, color: focused ? Palette.dim : Palette.muted, maxWidth: 420)
    }

    private func drawTitle(_ text: String, into frame: inout MK2PixelFrame, x: Int, y: Int, color: UInt16, maxWidth: Int? = nil) {
        try? renderer.drawText(text, into: &frame, x: x, y: y, style: titleStyle(color: color), maxWidth: maxWidth)
    }

    private func drawBody(_ text: String, into frame: inout MK2PixelFrame, x: Int, y: Int, color: UInt16, maxWidth: Int? = nil) {
        try? renderer.drawText(text, into: &frame, x: x, y: y, style: bodyStyle(color: color), maxWidth: maxWidth)
    }

    private func drawIcon(_ icon: FontAwesomeIcon, into frame: inout MK2PixelFrame, centerX: Int, baselineY: Int, size: Int, color: UInt16) {
        let style = iconTextStyle(size: size, color: color)
        let width = (try? renderer.measure(icon.glyph, style: style)) ?? size
        try? renderer.drawText(icon.glyph, into: &frame, x: centerX - width / 2, y: baselineY, style: style)
    }

    private func drawIcon(_ icon: FontAwesomeIcon, into frame: inout MK2PixelFrame, x: Int, y: Int, size: Int, color: UInt16) {
        try? renderer.drawText(icon.glyph, into: &frame, x: x, y: y, style: iconTextStyle(size: size, color: color))
    }

    private func bodyStyle(color: UInt16) -> FreeTypeTextStyle {
        FreeTypeTextStyle(
            familyID: Self.textFamilyID,
            weight: .regular,
            pixelSize: Self.bodySize,
            color: color,
            rasterMode: Self.rasterMode
        )
    }

    private func titleStyle(color: UInt16) -> FreeTypeTextStyle {
        FreeTypeTextStyle(
            familyID: Self.textFamilyID,
            weight: .medium,
            pixelSize: Self.titleSize,
            color: color,
            rasterMode: Self.rasterMode
        )
    }

    private func iconTextStyle(size: Int, color: UInt16) -> FreeTypeTextStyle {
        FreeTypeTextStyle(
            familyID: FreeTypeFontCatalog.iconProLightFamilyID,
            weight: .regular,
            pixelSize: size,
            color: color,
            rasterMode: Self.rasterMode
        )
    }

    private func drawBitmapHeader(into frame: inout MK2PixelFrame, title: String, subtitle: String) {
        frame.fill(MK2PixelRect(x: 0, y: 0, width: MK2PixelFrame.width, height: 38), Palette.header)
        BitmapLabel(title, font: .gridBold, color: Palette.accent).draw(into: &frame, x: 8, y: 8)
        BitmapLabel(subtitle.uppercased(), font: .label, color: Palette.dim).draw(into: &frame, x: 8, y: 25)
    }
}

private enum Palette {
    static let background: UInt16 = 0x0841
    static let panel: UInt16 = 0x1082
    static let header: UInt16 = 0x0000
    static let dialog: UInt16 = 0x18e3
    static let selection: UInt16 = 0x2148
    static let border: UInt16 = 0x6b6d
    static let text: UInt16 = 0xffff
    static let dim: UInt16 = 0xbdf7
    static let muted: UInt16 = 0x8410
    static let accent: UInt16 = 0x07ff
    static let bitmap: UInt16 = 0xffa0
}

private extension MK2PixelFrame {
    mutating func stroke(_ rect: MK2PixelRect, _ color: UInt16) {
        fill(MK2PixelRect(x: rect.x, y: rect.y, width: rect.width, height: 1), color)
        fill(MK2PixelRect(x: rect.x, y: rect.maxY - 1, width: rect.width, height: 1), color)
        fill(MK2PixelRect(x: rect.x, y: rect.y, width: 1, height: rect.height), color)
        fill(MK2PixelRect(x: rect.maxX - 1, y: rect.y, width: 1, height: rect.height), color)
    }
}

private extension Int {
    func wrapped(to bounds: ClosedRange<Int>) -> Int {
        let count = bounds.upperBound - bounds.lowerBound + 1
        guard count > 0 else { return bounds.lowerBound }
        let raw = (self - bounds.lowerBound) % count
        let offset = raw >= 0 ? raw : raw + count
        return bounds.lowerBound + offset
    }
}
