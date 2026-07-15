import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The arrangement ("song"/scene) surface: the order list plus its order-property
/// footer (E1–E4, physically under the left screen) on the left, and a read-only
/// pattern grid of the selected order — rendered like the pattern editor's grid —
/// on the right. Reuses the Kit's list, pattern-grid, minimap and parameter-page
/// elements; the app owns navigation and the order commands.
public struct MK2PaulincheArrangementOrder: Sendable, Equatable {
    public var patternLabel: String
    public var length: Int
    public var repeatCount: Int
    public var isPlaying: Bool

    public init(patternLabel: String, length: Int, repeatCount: Int = 1, isPlaying: Bool = false) {
        self.patternLabel = patternLabel
        self.length = max(0, length)
        self.repeatCount = max(1, repeatCount)
        self.isPlaying = isPlaying
    }
}

/// The selected order's pattern, projected for the right-screen preview grid.
public struct MK2PaulincheArrangementPreview: Sendable, Equatable {
    public var title: String
    public var rows: [MK2PatternGridElement.Row]
    public var channels: [MK2PatternGridElement.Channel]
    public var selectedRowIndex: Int
    public var rowCount: Int
    public var rowActivity: [Bool]
    public var isPlaying: Bool
    public var beatInterval: Int

    public init(
        title: String = "",
        rows: [MK2PatternGridElement.Row] = [],
        channels: [MK2PatternGridElement.Channel] = [],
        selectedRowIndex: Int = 0,
        rowCount: Int = 1,
        rowActivity: [Bool] = [],
        isPlaying: Bool = false,
        beatInterval: Int = 4
    ) {
        self.title = title
        self.rows = rows
        self.channels = channels
        self.selectedRowIndex = max(0, selectedRowIndex)
        self.rowCount = max(1, rowCount)
        self.rowActivity = rowActivity
        self.isPlaying = isPlaying
        self.beatInterval = max(1, beatInterval)
    }
}

public struct MK2PaulincheArrangementScene: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var isPlaying: Bool
    public var selectedOrderIndex: Int
    public var orders: [MK2PaulincheArrangementOrder]
    public var preview: MK2PaulincheArrangementPreview
    public var parameters: [MK2PaulinchePatternParameter]
    public var softKeys: [MK2PaulincheSoftKey]

    public init(
        title: String,
        subtitle: String,
        isPlaying: Bool = false,
        selectedOrderIndex: Int,
        orders: [MK2PaulincheArrangementOrder],
        preview: MK2PaulincheArrangementPreview,
        parameters: [MK2PaulinchePatternParameter] = [],
        softKeys: [MK2PaulincheSoftKey] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isPlaying = isPlaying
        self.selectedOrderIndex = max(0, selectedOrderIndex)
        self.orders = orders
        self.preview = preview
        self.parameters = Array(parameters.prefix(4))
        self.softKeys = Array(softKeys.prefix(8))
    }
}

public struct MK2PaulincheArrangementActions: Sendable {
    public var onSoftKey: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)?
    public var onEncoderTouch: (@Sendable (_ encoder: Int, _ touched: Bool) -> Void)?
    public var onEncoderChange: (@Sendable (_ encoder: Int, _ delta: Int) -> Void)?

    public init(
        onSoftKey: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)? = nil,
        onEncoderTouch: (@Sendable (_ encoder: Int, _ touched: Bool) -> Void)? = nil,
        onEncoderChange: (@Sendable (_ encoder: Int, _ delta: Int) -> Void)? = nil
    ) {
        self.onSoftKey = onSoftKey
        self.onEncoderTouch = onEncoderTouch
        self.onEncoderChange = onEncoderChange
    }
}

public enum MK2PaulincheArrangementRenderer {
    public static func render(
        _ scene: MK2PaulincheArrangementScene,
        actions: MK2PaulincheArrangementActions = MK2PaulincheArrangementActions(),
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2DoubleScreenDSL {
        MK2DoubleScreenDSL(
            left: orderListScreen(scene, actions: actions, renderer: renderer),
            right: previewScreen(scene, renderer: renderer)
        )
    }

    public static func surfaceScene(
        _ scene: MK2PaulincheArrangementScene,
        actions: MK2PaulincheArrangementActions = MK2PaulincheArrangementActions(),
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2SurfaceScene2 {
        render(scene, actions: actions, renderer: renderer).scene()
    }

    // MARK: - Left screen: order list + order-property footer (E1–E4)

    private static func orderListScreen(
        _ scene: MK2PaulincheArrangementScene,
        actions: MK2PaulincheArrangementActions,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        return MK2FullScreenDSL(background: Palette.background) {
            MK2SelectionListElement(
                title: scene.title,
                subtitle: scene.subtitle,
                items: orderItems(scene),
                selectedIndex: scene.selectedOrderIndex,
                columns: [
                    MK2SelectionColumn(header: "POS", x: 0, width: 44, alignment: .trailing, fixedPitch: true),
                    MK2SelectionColumn(header: "PATTERN", x: 68, width: 150, color: Palette.blue),
                    MK2SelectionColumn(header: "LEN", x: 250, width: 56, alignment: .trailing, fixedPitch: true),
                    MK2SelectionColumn(header: "REP", x: 330, width: 56, alignment: .trailing, color: Palette.orange, fixedPitch: true),
                    MK2SelectionColumn(header: "", x: 400, width: 40, alignment: .trailing, color: Palette.green, fixedPitch: true),
                ],
                rowHeight: 24,
                rowGap: 3,
                reservesFooter: true,
                colors: selectionColors
            )
            MK2ParameterPageElement(
                slots: parameterSlots(scene, actions: actions),
                rect: MK2PixelRect(x: 8, y: 215, width: 464, height: 57),
                columns: 4,
                relativeToContent: false
            )
        }.build(renderer: renderer)
    }

    private static func orderItems(_ scene: MK2PaulincheArrangementScene) -> [MK2SelectionItem] {
        scene.orders.enumerated().map { index, order in
            MK2SelectionItem(title: "", columns: [
                String(format: "%02d", index),
                order.patternLabel,
                "\(order.length)",
                order.repeatCount > 1 ? "x\(order.repeatCount)" : "-",
                order.isPlaying ? ">" : "",
            ])
        }
    }

    private static var selectionColors: MK2SelectionViewColors {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        return MK2SelectionViewColors(
            background: Palette.background,
            text: Palette.text,
            dim: Palette.dim,
            muted: Palette.empty,
            accent: Palette.blue,
            selectionFill: Palette.selectedRow,
            border: Palette.border,
            filterFill: Palette.channelButtonFill
        )
    }

    private static func parameterSlots(
        _ scene: MK2PaulincheArrangementScene,
        actions: MK2PaulincheArrangementActions
    ) -> [MK2ParameterPageSlot] {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        return scene.parameters.prefix(4).enumerated().map { index, parameter in
            MK2ParameterPageSlot(
                label: parameter.label,
                iconGlyph: parameter.iconGlyph,
                value: parameter.value,
                isFocused: parameter.isFocused,
                encoderValue: orderPropertyEncoderValue(index: index, scene: scene, actions: actions),
                colors: MK2ValueCellColors(
                    label: Palette.dim,
                    value: Palette.text,
                    border: Palette.border,
                    fill: Palette.editFieldFill,
                    focusedValue: 0x0000,
                    focusedFill: Palette.editFieldFocusedFill,
                    focusedBorder: Palette.text
                )
            )
        }
    }

    /// Arrangement values use the same calibrated discrete-value path as the
    /// widget lab. Previously these slots forwarded every raw high-resolution
    /// count as an app step, bypassing Kit2's domain-scaled detents entirely.
    private static func orderPropertyEncoderValue(
        index: Int,
        scene: MK2PaulincheArrangementScene,
        actions: MK2PaulincheArrangementActions
    ) -> MK2EncoderDiscreteValue? {
        let encoder = index + 1
        let touch: @Sendable (Bool) -> Void = { touched in
            actions.onEncoderTouch?(encoder, touched)
        }
        switch encoder {
            case 1:
                // Pattern IDs need not be contiguous and the app owns their
                // ordering. A relative tiny domain gives E1 the calibrated
                // throw while the app resolves -1/+1 to the adjacent pattern.
                return MK2EncoderDiscreteValue(
                    encoder: encoder,
                    value: 0,
                    bounds: -1...1,
                    onTouch: touch,
                    onChange: { delta in actions.onEncoderChange?(encoder, delta) }
                )
            case 2:
                // Repeat count has no product-level maximum. Use a relative
                // three-value domain solely for the calibrated tiny-domain
                // throw, then forward its -1/+1 result as a delta.
                return MK2EncoderDiscreteValue(
                    encoder: encoder,
                    value: 0,
                    bounds: -1...1,
                    onTouch: touch,
                    onChange: { delta in actions.onEncoderChange?(encoder, delta) }
                )
            case 3:
                let selected = min(max(0, scene.selectedOrderIndex), max(0, scene.orders.count - 1))
                let rows = scene.orders.indices.contains(selected) ? scene.orders[selected].length : 16
                let currentBars = min(16, max(1, rows / 16))
                return MK2EncoderDiscreteValue(
                    encoder: encoder,
                    value: currentBars,
                    bounds: 1...16,
                    onTouch: touch,
                    onChange: { nextBars in actions.onEncoderChange?(encoder, nextBars - currentBars) }
                )
            case 4 where scene.orders.count > 1:
                let current = min(scene.orders.count - 1, max(0, scene.selectedOrderIndex))
                return MK2EncoderDiscreteValue(
                    encoder: encoder,
                    value: current,
                    bounds: 0...(scene.orders.count - 1),
                    onTouch: touch,
                    onChange: { next in actions.onEncoderChange?(encoder, next - current) }
                )
            default:
                // POS has no destination in a one-entry arrangement.
                return nil
        }
    }

    // MARK: - Right screen: read-only pattern preview of the selected order

    private static func previewScreen(
        _ scene: MK2PaulincheArrangementScene,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        let preview = scene.preview
        return MK2FullScreenDSL(background: Palette.background) {
            MK2StatusLineElement(y: 8, items: [
                MK2StatusLineItem("PAT", x: 8, color: Palette.blue),
                MK2StatusLineItem(preview.title, x: 44, color: Palette.text, maxWidth: 260),
                MK2StatusLineItem(preview.isPlaying ? "PLAY" : "STOP", x: 330, color: preview.isPlaying ? Palette.green : Palette.orange, font: .gridBold),
            ], relativeToContent: false)
            MK2PatternGridElement(
                rows: preview.rows,
                channels: preview.channels,
                selectedRowIndex: preview.selectedRowIndex,
                isPlaying: preview.isPlaying,
                beatStripe: .every(preview.beatInterval)
            )
            MK2OverviewScrollbarElement(
                rowCount: preview.rowCount,
                selectedRowIndex: preview.selectedRowIndex,
                rowActivity: preview.rowActivity,
                rect: MK2PixelRect(x: 466, y: 62, width: 5, height: 200)
            )
        }.build(renderer: renderer)
    }
}
