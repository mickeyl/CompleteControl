import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The selection elements as a product-shaped browser: detail pane on the
/// left, list/grid picker on the right. INSTANCE cycles plain and filtered
/// modes, 4-D navigates and confirms, E5/E6 drive the area and source
/// filters. (The former separate browser and selection labs merged here —
/// they demonstrated the same picker twice.)
final class SelectionBrowserDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "selection-browser",
        title: "Selection & Browser",
        category: .catalogue,
        summary: "Detail pane, list/grid picker, filters, table",
        detail: "Browser detail pane next to the selection picker. INSTANCE cycles list, grid, filtered and order-table modes; 4-D navigates and confirms, E5/E6 filter by area and source.",
        snapshotVariants: ["grid", "filtered", "filtered-grid", "table"]
    )

    private var mode: BrowserDemoMode = .plainList
    private var navigation = MK2SelectionNavigation()
    private var areaIndex = 0
    private var sourceIndex = 0
    private var confirmation = "Nothing opened yet"

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        var scene = MK2DoubleScreenDSL(
            left: detailScreen(context),
            right: pickerScreen(context)
        ).scene()
        scene.lamps[.instance] = .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)
        scene.bindings.onPress(.instance) { [weak self] in
            context.update {
                guard let self else { return }
                self.mode = self.mode.next
                if !self.mode.hasFilters {
                    self.navigation.setFilterFocus(encoder: nil)
                }
                self.navigation.clamp(itemCount: self.itemCount())
            }
        }
        return scene
    }

    func prepareSnapshot(variant: String) {
        switch variant {
            case "grid": mode = .plainGrid
            case "filtered": mode = .filteredList
            case "filtered-grid": mode = .filteredGrid
            case "table": mode = .orderTable
            default: mode = .plainList
        }
        navigation.clamp(itemCount: itemCount())
    }

    private func filteredItems() -> [BrowserDemoItem] {
        guard mode.hasFilters else { return BrowserLabFixtures.items }
        let area = BrowserLabFixtures.areas[areaIndex]
        let source = BrowserLabFixtures.sources[sourceIndex]
        return BrowserLabFixtures.items.filter { item in
            (area == "All" || item.area == area)
                && (source == "All" || item.source == source)
        }
    }

    private func itemCount() -> Int {
        mode == .orderTable ? BrowserLabFixtures.orderRows.count : filteredItems().count
    }

    private func selectedTitle() -> String? {
        guard let index = navigation.clampedSelectedIndex(itemCount: itemCount()) else { return nil }
        return mode == .orderTable
            ? BrowserLabFixtures.orderRows[index].title
            : filteredItems()[index].title
    }

    private func selectedItem() -> BrowserDemoItem? {
        guard mode != .orderTable else { return nil }
        let items = filteredItems()
        guard let index = navigation.clampedSelectedIndex(itemCount: items.count) else { return nil }
        return items[index]
    }

    private var jogLayout: MK2SelectionJogLayout {
        mode.isGrid ? .grid(cellSize: BrowserLabFixtures.gridCellSizes[0]) : .list()
    }

    private func detailScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let items = filteredItems()
        let selected = selectedItem()

        let subtitle = mode == .orderTable
            ? mode.shortTitle
            : "\(mode.shortTitle) · \(items.count)/\(BrowserLabFixtures.items.count)"
        return MK2RegularScreenDSL(
            header: .title(title: "Selection & Browser", subtitle: subtitle),
            footer: .hint(confirmation)
        ) {
            MK2ContentText(mode.title, x: 8, y: 0, role: .title)
            MK2ContentText(
                mode == .orderTable
                    ? "Optional columns turn the list into a table — position, pattern, title and row count with headers; navigation and lamps stay the standard picker."
                    : "INSTANCE cycles list/grid/filters. 4-D selects, 4-D press opens.",
                x: 8,
                y: 40,
                maxWidth: 432,
                color: Palette.dim,
                // The grid/list branch adds a full detail card below and shares
                // the footer-shortened content band, so it keeps the blurb to
                // two lines; the order-table branch has room for three.
                maxLines: mode == .orderTable ? 3 : 2,
                lineSpacing: 2
            )
            if mode == .orderTable {
                MK2ContentText("Entries: \(BrowserLabFixtures.orderRows.count) order positions", x: 8, y: 104, maxWidth: 432)
                MK2ContentText("Selected: \(selectedTitle() ?? "—")", x: 8, y: 132, maxWidth: 432, color: Palette.text)
            } else if let selected {
                MK2BrowserDetailElement(
                    title: selected.title,
                    detail: selected.detail,
                    metadata: "\(selected.area) · \(selected.source) · \(selected.status)",
                    iconGlyph: selected.icon,
                    y: 84,
                    iconColor: Palette.accent,
                    accentColor: Palette.blue
                )
            } else {
                MK2EmptyStateElement(title: "No entries", detail: "These filters produce no matches.")
            }
        }.build(renderer: context.renderer)
    }

    private func pickerScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let items = filteredItems().map(\.selectionItem)
        let filters = mode.hasFilters ? selectionFilters() : []
        let colors = MK2SelectionViewColors(
            background: Palette.page,
            text: Palette.text,
            dim: Palette.dim,
            muted: Palette.empty,
            accent: Palette.accent,
            selectionFill: Palette.selectionFill,
            border: Palette.border,
            filterFill: Palette.filterFill
        )
        let subtitle = mode.hasFilters ? "4-D select, E5/E6 filter" : "4-D select, INSTANCE mode"
        return MK2FullScreenDSL {
            if mode == .orderTable {
                MK2SelectionListElement(
                    title: mode.shortTitle,
                    subtitle: subtitle,
                    items: BrowserLabFixtures.orderRows.map(\.selectionItem),
                    selectedIndex: navigation.selectedIndex,
                    columns: [
                        MK2SelectionColumn(header: "POS", x: 0, width: 36, alignment: .trailing, fixedPitch: true),
                        MK2SelectionColumn(header: "PAT", x: 56, width: 36, alignment: .trailing, color: Palette.accent, fixedPitch: true),
                        MK2SelectionColumn(header: "Title", x: 120, width: 210),
                        MK2SelectionColumn(header: "ROWS", x: 350, width: 44, alignment: .trailing, fixedPitch: true),
                    ],
                    rowHeight: 28,
                    rowGap: 4,
                    colors: colors
                )
            } else if mode.isGrid {
                MK2SelectionGridElement(
                    title: mode.shortTitle,
                    subtitle: subtitle,
                    items: items,
                    selectedIndex: navigation.selectedIndex,
                    cellSize: BrowserLabFixtures.gridCellSizes[0],
                    filters: filters,
                    colors: colors
                )
            } else {
                MK2SelectionListElement(
                    title: mode.shortTitle,
                    subtitle: subtitle,
                    items: items,
                    selectedIndex: navigation.selectedIndex,
                    filters: filters,
                    rowHeight: mode.hasFilters ? 44 : 36,
                    colors: colors
                )
            }
            MK2SelectionInputElement(
                navigation: navigation,
                itemCount: mode == .orderTable ? BrowserLabFixtures.orderRows.count : items.count,
                layout: jogLayout,
                availableLamp: .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01),
                onMove: { [weak self] delta in
                    context.update {
                        guard let self else { return }
                        _ = self.navigation.move(by: delta, itemCount: self.itemCount())
                    }
                },
                onConfirm: { [weak self] in
                    context.update {
                        guard let self, let selected = self.selectedTitle() else { return }
                        self.confirmation = "Opened: \(selected)"
                    }
                }
            )
            MK2SelectionFilterEncoderElement(filterEncoderBindings(context))
        }.build(renderer: context.renderer)
    }

    private func selectionFilters() -> [MK2SelectionFilter] {
        [
            MK2SelectionFilter(label: "AREA", value: BrowserLabFixtures.areas[areaIndex], encoder: 5, isActive: areaIndex != 0, isFocused: navigation.focusedFilterEncoder == 5),
            MK2SelectionFilter(label: "SRC", value: BrowserLabFixtures.sources[sourceIndex], encoder: 6, isActive: sourceIndex != 0, isFocused: navigation.focusedFilterEncoder == 6),
        ]
    }

    private func filterEncoderBindings(_ context: LabContext) -> [MK2SelectionFilterEncoderBinding] {
        guard mode.hasFilters else { return [] }
        return [
            MK2SelectionFilterEncoderBinding(
                encoder: 5,
                value: areaIndex,
                bounds: 0...(BrowserLabFixtures.areas.count - 1),
                wraps: true,
                onFocus: { [weak self] _, touched in
                    context.update { self?.navigation.touchFilter(encoder: 5, touched: touched) }
                },
                onChange: { [weak self] value in
                    context.update {
                        guard let self else { return }
                        self.navigation.setFilterFocus(encoder: 5)
                        self.areaIndex = value.wrapped(to: 0...(BrowserLabFixtures.areas.count - 1))
                        self.navigation.clamp(itemCount: self.filteredItems().count)
                    }
                }
            ),
            MK2SelectionFilterEncoderBinding(
                encoder: 6,
                value: sourceIndex,
                bounds: 0...(BrowserLabFixtures.sources.count - 1),
                wraps: true,
                onFocus: { [weak self] _, touched in
                    context.update { self?.navigation.touchFilter(encoder: 6, touched: touched) }
                },
                onChange: { [weak self] value in
                    context.update {
                        guard let self else { return }
                        self.navigation.setFilterFocus(encoder: 6)
                        self.sourceIndex = value.wrapped(to: 0...(BrowserLabFixtures.sources.count - 1))
                        self.navigation.clamp(itemCount: self.filteredItems().count)
                    }
                }
            ),
        ]
    }
}
