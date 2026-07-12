import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The top level of the lab: a filterable demo browser. The 4-D encoder
/// moves the selection and opens a demo, E4 drives the category filter,
/// the right screen shows the selected demo's detail card.
extension LabShell {
    // MARK: - Demo browser

    static let demoBrowserCategoryValues = ["All"] + DemoCategory.allCases.map(\.filterValue)

    func visibleBrowserDemos() -> [any LabDemo] {
        guard demoBrowserCategoryIndex > 0,
              let category = DemoCategory(rawValue: demoBrowserCategoryIndex - 1) else { return demoRegistry }
        return demoRegistry.filter { $0.descriptor.category == category }
    }

    func demoBrowserScene() -> MK2SurfaceScene2 {
        let visible = visibleBrowserDemos()
        let leftResult = demoBrowserListResult(visible)
        let rightResult = demoBrowserDetailPaneResult(visible)

        var lamps = leftResult.lamps
        lamps.merge(rightResult.lamps) { _, next in next }
        var bindings = leftResult.bindings
        bindings.merge(rightResult.bindings)

        applyLampOverrides(to: &lamps)
        var keyColors = leftResult.keyColors
        keyColors.merge(rightResult.keyColors) { _, next in next }
        applyGuideOverrides(to: &keyColors)
        return MK2SurfaceScene2(
            left: leftResult.screen.frame,
            right: rightResult.screen.frame,
            lamps: lamps,
            keyColors: keyColors,
            bindings: bindings
        )
    }

    func demoBrowserListResult(_ visible: [any LabDemo]) -> MK2ScreenBuildResult {
        let items = visible.map { demo in
            MK2SelectionItem(
                title: demo.descriptor.title,
                detail: demo.descriptor.summary,
                badge: demo.descriptor.category.badge
            )
        }
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
        return fullScreenResult {
            MK2SelectionListElement(
                title: "WIDGET LAB",
                subtitle: "4-D opens · E4 filters",
                items: items,
                selectedIndex: demoBrowserNavigation.selectedIndex,
                filters: [
                    MK2SelectionFilter(
                        label: "CATEGORY",
                        value: Self.demoBrowserCategoryValues[demoBrowserCategoryIndex].uppercased(),
                        encoder: 4,
                        isFocused: demoBrowserNavigation.focusedFilterEncoder == 4
                    ),
                ],
                rowHeight: 44,
                colors: colors
            )
            MK2SelectionInputElement(
                navigation: demoBrowserNavigation,
                itemCount: items.count,
                layout: .list(step: 4),
                availableLamp: Self.availableLamp(Self.actionWhite),
                onMove: { [weak self] delta in
                    Task { await self?.moveDemoBrowserSelection(delta) }
                },
                onConfirm: { [weak self] in
                    Task { await self?.confirmDemoBrowserSelection() }
                }
            )
            MK2SelectionFilterEncoderElement([
                MK2SelectionFilterEncoderBinding(
                    encoder: 4,
                    value: demoBrowserCategoryIndex,
                    bounds: 0...(Self.demoBrowserCategoryValues.count - 1),
                    wraps: true,
                    onFocus: { [weak self] _, touched in
                        Task { await self?.setDemoBrowserFilterFocus(touched) }
                    },
                    onChange: { [weak self] value in
                        Task { await self?.setDemoBrowserCategory(value) }
                    }
                ),
            ])
        }
    }

    func demoBrowserDetailPaneResult(_ visible: [any LabDemo]) -> MK2ScreenBuildResult {
        guard let index = demoBrowserNavigation.clampedSelectedIndex(itemCount: visible.count) else {
            return regularScreenResult(header: .title(title: "Widget Lab", subtitle: "Demo Browser")) {
                MK2EmptyStateElement(
                    title: "No demos in this category",
                    detail: "Turn E4 to widen the filter"
                )
            }
        }
        let descriptor = visible[index].descriptor
        return regularScreenResult(
            header: .title(title: descriptor.title, subtitle: descriptor.category.title),
            footer: .hint("4-D press opens the demo · SCENE returns here")
        ) {
            MK2BrowserDetailElement(
                title: descriptor.title,
                detail: descriptor.detail,
                metadata: "\(descriptor.category.title) · open \(descriptor.id)",
                y: 48
            )
        }
    }

    func moveDemoBrowserSelection(_ delta: Int) async {
        guard mode == .browser, delta != 0 else { return }
        if demoBrowserNavigation.move(by: delta, itemCount: visibleBrowserDemos().count) {
            await render()
        }
    }

    func confirmDemoBrowserSelection() async {
        guard mode == .browser else { return }
        let visible = visibleBrowserDemos()
        guard let index = demoBrowserNavigation.clampedSelectedIndex(itemCount: visible.count) else { return }
        await openDemo(visible[index])
    }

    func setDemoBrowserCategory(_ value: Int) async {
        let clamped = max(0, min(Self.demoBrowserCategoryValues.count - 1, value))
        guard clamped != demoBrowserCategoryIndex else { return }
        demoBrowserCategoryIndex = clamped
        demoBrowserNavigation.select(0, itemCount: visibleBrowserDemos().count)
        await render()
    }

    func setDemoBrowserFilterFocus(_ touched: Bool) async {
        demoBrowserNavigation.touchFilter(encoder: 4, touched: touched)
        await render()
    }
}
