import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The Phosphor icon catalog in the selection list/grid elements: the left
/// screen shows the focused icon at the chosen size, the right screen the
/// browsable catalog. INSTANCE cycles list/grid and the A-Z filter modes,
/// 4-D and PAGE browse, PRESET steps the preview size, E5 drives the letter
/// filter and E8 the mode.
final class IconBrowserDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "icon-browser",
        title: "Icon Browser",
        category: .lookAndFeel,
        summary: "Phosphor catalog in list and grid",
        detail: "Browse the icon catalog through the selection elements. 4-D and PAGE move, PRESET steps the preview size, E5 filters by letter, E8 switches list/grid modes.",
        snapshotVariants: ["grid", "a-z-list", "a-z-grid"]
    )

    private enum Mode: Int, CaseIterable {
        case plainList, plainGrid, filteredList, filteredGrid

        var next: Mode { Self(rawValue: (rawValue + 1) % Self.allCases.count)! }
        var isGrid: Bool { self == .plainGrid || self == .filteredGrid }
        var hasFilter: Bool { self == .filteredList || self == .filteredGrid }

        var title: String {
            switch self {
                case .plainList: "ICON LIST"
                case .plainGrid: "ICON GRID"
                case .filteredList: "FILTERED LIST"
                case .filteredGrid: "FILTERED GRID"
            }
        }

        var shortTitle: String {
            switch self {
                case .plainList: "LIST"
                case .plainGrid: "GRID"
                case .filteredList: "A-Z LIST"
                case .filteredGrid: "A-Z GRID"
            }
        }
    }

    private static let letterFilters = ["ALL"] + (65...90).map { String(UnicodeScalar($0)!) }
    private static let sizes = [20, 24, 28, 32, 36, 42, 48, 56, 64, 72, 88]
    // 54 px cells fit three rows into the 166 px filtered content band (58 px
    // only fit two, leaving a dead row of air above the filters).
    private static let gridCellSize = MK2SelectionCellSize(width: 54, height: 54)
    private static let pageStep = 7
    private static let styleLabel = "Regular"

    private let iconSource: String
    private let icons: [PhosphorIcon]
    private var iconIndex: Int
    private var mode: Mode = .plainList
    private var filterNavigation = MK2SelectionNavigation()
    private var sizeIndex = 7

    init() {
        let catalog = (try? PhosphorIconCatalog.load()) ?? (source: "Phosphor catalog unavailable", icons: [])
        iconSource = catalog.source
        icons = catalog.icons
        iconIndex = catalog.icons.firstIndex { $0.name == "info" } ?? 0
    }

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        var lamps: [KKMK2ButtonLED: MK2LampState2] = [
            .instance: .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01),
            .pageLeft: .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01),
            .pageRight: .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01),
        ]
        let visible = visibleIcons()
        MK2SelectionNavigation(selectedIndex: selectedVisibleIndex(in: visible))
            .applyJogLamps(
                to: &lamps,
                itemCount: visible.count,
                layout: jogLayout,
                availableLamp: .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01),
                wraps: true
            )

        var scene = MK2SurfaceScene2(
            left: detailFrame(context.renderer),
            right: listFrame(context.renderer),
            lamps: lamps
        )
        scene.bindings.onPress(.instance) { [weak self] in
            context.update { self?.cycleMode() }
        }
        scene.bindings.onPress(.pageLeft) { [weak self] in
            context.update { self?.moveIcon(-1) }
        }
        scene.bindings.onPress(.pageRight) { [weak self] in
            context.update { self?.moveIcon(1) }
        }
        scene.bindings.jogScroll = { [weak self] delta, _ in
            context.update { self?.moveIcon(delta) }
        }
        scene.bindings.jog = { [weak self] direction in
            context.update {
                guard let self,
                      let delta = MK2SelectionLayout.jogDelta(for: direction, layout: self.jogLayout) else { return }
                self.moveIcon(delta)
            }
        }
        MK2ButtonRangeSelection(
            value: sizeIndex,
            bounds: 0...(Self.sizes.count - 1),
            previousButton: .presetDown,
            nextButton: .presetUp,
            availableLamp: .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)
        ) { [weak self] index in
            context.update { self?.sizeIndex = max(0, min(Self.sizes.count - 1, index)) }
        }
        .apply(lamps: &scene.lamps, bindings: &scene.bindings)
        for value in filterEncoderValues(context) {
            value.apply(bindings: &scene.bindings)
        }
        return scene
    }

    func prepareSnapshot(variant: String) {
        switch variant {
            case "grid": mode = .plainGrid
            case "a-z-list": mode = .filteredList
            case "a-z-grid": mode = .filteredGrid
            default: mode = .plainList
        }
        clampToVisibleSelection()
    }

    func replCommands() -> [ReplCommand] {
        [
            ReplCommand(name: "icon", arg: "<index|name>", summary: "select icon", values: []),
            ReplCommand(name: "iconsize", arg: "<20-88>", summary: "preview size", values: []),
            ReplCommand(name: "iconmode", arg: "list|grid|filterlist|filtergrid|next", summary: "list/grid mode", values: ["list", "grid", "filterlist", "filtergrid", "next"]),
        ]
    }

    func handleRepl(verb: String, rest: String, _ context: LabContext) -> Bool {
        switch verb {
            case "icon":
                context.update { [weak self] in
                    guard let self else { return }
                    if let index = Int(rest), self.icons.indices.contains(index) {
                        self.iconIndex = index
                    } else if let index = self.icons.firstIndex(where: { $0.name == rest.lowercased() }) {
                        self.iconIndex = index
                    }
                    self.clampToVisibleSelection()
                }
            case "iconsize":
                guard let size = Int(rest) else { return false }
                context.update { [weak self] in
                    guard let self else { return }
                    self.sizeIndex = Self.sizes.enumerated().min {
                        abs($0.element - size) < abs($1.element - size)
                    }?.offset ?? self.sizeIndex
                }
            case "iconmode":
                context.update { [weak self] in
                    guard let self else { return }
                    switch rest.lowercased() {
                        case "list": self.mode = .plainList
                        case "grid": self.mode = .plainGrid
                        case "filterlist": self.mode = .filteredList
                        case "filtergrid": self.mode = .filteredGrid
                        default: self.mode = self.mode.next
                    }
                    self.clampToVisibleSelection()
                }
            default:
                return false
        }
        return true
    }

    // MARK: - State

    private var jogLayout: MK2SelectionJogLayout {
        mode.isGrid ? .grid(cellSize: Self.gridCellSize) : .list(step: Self.pageStep)
    }

    private var selectedIcon: PhosphorIcon? {
        icons.indices.contains(iconIndex) ? icons[iconIndex] : nil
    }

    private var currentSize: Int {
        Self.sizes[max(0, min(Self.sizes.count - 1, sizeIndex))]
    }

    private func cycleMode() {
        mode = mode.next
        if !mode.hasFilter {
            filterNavigation.setFilterFocus(encoder: nil)
        }
        clampToVisibleSelection()
    }

    private func moveIcon(_ delta: Int) {
        let visible = visibleIcons()
        guard !visible.isEmpty, delta != 0 else { return }
        let current = selectedVisibleIndex(in: visible)
        let next = (current + delta).wrapped(to: 0...(visible.count - 1))
        iconIndex = visible[next].globalIndex
    }

    private func visibleIcons() -> [(globalIndex: Int, icon: PhosphorIcon)] {
        let indexed = icons.enumerated().map { (globalIndex: $0.offset, icon: $0.element) }
        guard mode.hasFilter else { return indexed }
        let letter = Self.letterFilters[filterNavigation.selectedIndex]
        guard letter != "ALL" else { return indexed }
        return indexed.filter { $0.icon.name.uppercased().hasPrefix(letter) }
    }

    private func selectedVisibleIndex(in visible: [(globalIndex: Int, icon: PhosphorIcon)]) -> Int {
        visible.firstIndex { $0.globalIndex == iconIndex } ?? 0
    }

    private func clampToVisibleSelection() {
        let visible = visibleIcons()
        guard !visible.isEmpty else { return }
        if !visible.contains(where: { $0.globalIndex == iconIndex }) {
            iconIndex = visible[0].globalIndex
        }
    }

    private func filterEncoderValues(_ context: LabContext) -> [MK2EncoderDiscreteValue] {
        var values = [
            MK2EncoderDiscreteValue(
                encoder: 8,
                value: mode.rawValue,
                bounds: 0...(Mode.allCases.count - 1),
                onChange: { [weak self] value in
                    context.update {
                        guard let self,
                              let next = Mode(rawValue: value.wrapped(to: 0...(Mode.allCases.count - 1))) else { return }
                        self.mode = next
                        if !next.hasFilter {
                            self.filterNavigation.setFilterFocus(encoder: nil)
                        }
                        self.clampToVisibleSelection()
                    }
                }
            ),
        ]
        if mode.hasFilter {
            values.append(MK2EncoderDiscreteValue(
                encoder: 5,
                value: filterNavigation.selectedIndex,
                bounds: 0...(Self.letterFilters.count - 1),
                wraps: true,
                onTouch: { [weak self] touched in
                    context.update {
                        self?.filterNavigation.touchFilter(encoder: 5, touched: touched)
                    }
                },
                onChange: { [weak self] value in
                    context.update {
                        guard let self else { return }
                        self.filterNavigation.setFilterFocus(encoder: 5)
                        self.filterNavigation.select(value, itemCount: Self.letterFilters.count)
                        self.clampToVisibleSelection()
                    }
                }
            ))
        }
        return values
    }

    // MARK: - Screens

    private func detailFrame(_ renderer: FreeTypeTextRenderer?) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        guard let icon = selectedIcon else {
            drawHeader(into: &frame, title: "ICON BROWSER", subtitle: "catalog missing")
            drawFreeTypeBody("PhosphorIcons.pro.json was not loaded.", into: &frame, renderer: renderer, x: 18, y: 62, size: MK2HIG.Typography.bodyPixelSize, color: Palette.orange, maxWidth: 432)
            return frame
        }
        let visible = visibleIcons()
        let visibleIndex = selectedVisibleIndex(in: visible)
        drawHeader(into: &frame, title: "ICON BROWSER", subtitle: "\(visibleIndex + 1)/\(max(1, visible.count)) \(mode.title)")
        drawFreeTypeIconCentered(icon.glyph, into: &frame, renderer: renderer, centerX: 240, y: 72, size: currentSize, color: Palette.text)
        drawFreeTypeTitle(icon.label, into: &frame, renderer: renderer, x: 18, y: 158, size: MK2HIG.Typography.titlePixelSize, color: Palette.text, maxWidth: 432)
        drawFreeTypeBody(icon.name, into: &frame, renderer: renderer, x: 18, y: 194, size: MK2HIG.Typography.bodyPixelSize, color: Palette.dim, maxWidth: 432)
        drawFreeTypeBody(String(format: "U+%04X  size %d px  %@", icon.codepoint, currentSize, Self.styleLabel), into: &frame, renderer: renderer, x: 18, y: 222, size: MK2HIG.Typography.bodyPixelSize, color: Palette.dim, maxWidth: 432)
        drawFreeTypeBody("INSTANCE mode  4-D/PAGE icons  E5 A-Z filter", into: &frame, renderer: renderer, x: 18, y: 248, size: MK2HIG.Typography.bodyPixelSize, color: Palette.empty, maxWidth: 432)
        return frame
    }

    private func listFrame(_ renderer: FreeTypeTextRenderer?) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        let visible = visibleIcons()
        let items = visible.map { entry in
            MK2SelectionItem(
                title: entry.icon.name,
                detail: entry.icon.label,
                badge: Self.styleLabel,
                iconGlyph: entry.icon.glyph
            )
        }
        let selected = selectedVisibleIndex(in: visible)
        let filters = mode.hasFilter ? selectionFilters() : []
        let colors = MK2SelectionViewColors(
            background: Palette.page,
            text: Palette.text,
            dim: Palette.dim,
            muted: Palette.empty,
            accent: Palette.accent,
            selectionFill: Palette.selectionFill,
            border: Palette.border,
            filterFill: Palette.filterFill,
            filterValue: Palette.text
        )
        if mode.isGrid {
            MK2SelectionGrid(
                title: mode.shortTitle,
                subtitle: "\(visible.count) icons, \(Self.styleLabel)",
                items: items,
                selectedIndex: selected,
                cellSize: Self.gridCellSize,
                filters: filters,
                colors: colors,
                cellContent: .iconOnly(iconSize: 30)
            ).draw(into: &frame, renderer: renderer)
        } else {
            MK2SelectionList(
                title: mode.shortTitle,
                subtitle: "\(visible.count) icons, \(Self.styleLabel)",
                items: items,
                selectedIndex: selected,
                filters: filters,
                rowHeight: mode.hasFilter ? 44 : 30,
                colors: colors
            ).draw(into: &frame, renderer: renderer)
        }
        return frame
    }

    private func selectionFilters() -> [MK2SelectionFilter] {
        [
            MK2SelectionFilter(
                label: "LETTER",
                value: Self.letterFilters[filterNavigation.selectedIndex],
                encoder: 5,
                isActive: filterNavigation.selectedIndex != 0,
                isFocused: filterNavigation.focusedFilterEncoder == 5,
                iconGlyph: MK2HIG.IconGlyph.textAa
            ),
            MK2SelectionFilter(
                label: "MODE",
                value: mode.shortTitle,
                encoder: 8,
                isActive: true,
                isFocused: false,
                iconGlyph: mode.isGrid ? MK2HIG.IconGlyph.squaresFour : MK2HIG.IconGlyph.listBullets
            ),
        ]
    }

    private func drawHeader(into frame: inout MK2PixelFrame, title: String, subtitle: String) {
        frame.fill(MK2PixelRect(x: 0, y: 0, width: MK2PixelFrame.width, height: 38), 0x0000)
        BitmapLabel(title, font: .gridBold, color: Palette.accent).draw(into: &frame, x: 8, y: 8)
        BitmapLabel(subtitle.uppercased(), font: .label, color: Palette.dim).draw(into: &frame, x: 8, y: 25)
    }
}
