import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The arrangement (song / "scene") surface: the order list on the left, the
/// selected order's detail — a downscaled pattern preview and its editable
/// properties on E5–E8 — on the right. Reuses the Kit's list, scene-preview and
/// parameter-page elements; the app owns navigation and the order commands.
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

public struct MK2PaulincheArrangementPreview: Sendable, Equatable {
    public var rowCount: Int
    public var channelCount: Int
    public var markers: [MK2ScenePreviewElement.Marker]
    public var beatInterval: Int
    public var playheadRow: Int?

    public init(rowCount: Int, channelCount: Int, markers: [MK2ScenePreviewElement.Marker], beatInterval: Int = 4, playheadRow: Int? = nil) {
        self.rowCount = max(1, rowCount)
        self.channelCount = max(1, channelCount)
        self.markers = markers
        self.beatInterval = max(1, beatInterval)
        self.playheadRow = playheadRow
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
            left: orderListScreen(scene, renderer: renderer),
            right: detailScreen(scene, actions: actions, renderer: renderer)
        )
    }

    public static func surfaceScene(
        _ scene: MK2PaulincheArrangementScene,
        actions: MK2PaulincheArrangementActions = MK2PaulincheArrangementActions(),
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2SurfaceScene2 {
        render(scene, actions: actions, renderer: renderer).scene()
    }

    // MARK: - Left screen: order list

    private static func orderListScreen(
        _ scene: MK2PaulincheArrangementScene,
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
                rowHeight: 28,
                rowGap: 4,
                colors: selectionColors
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

    // MARK: - Right screen: selected-order detail

    private static func detailScreen(
        _ scene: MK2PaulincheArrangementScene,
        actions: MK2PaulincheArrangementActions,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        let preview = scene.preview
        return MK2FullScreenDSL(background: Palette.background) {
            MK2StatusLineElement(y: 8, items: [
                MK2StatusLineItem("ORDER", x: 8, color: Palette.blue),
                MK2StatusLineItem(String(format: "%02d", scene.selectedOrderIndex), x: 82, color: Palette.text, font: .gridBold),
                MK2StatusLineItem(scene.isPlaying ? "PLAY" : "STOP", x: 158, color: scene.isPlaying ? Palette.green : Palette.orange, font: .gridBold),
            ], relativeToContent: false)
            MK2SeparatorElement(y: 55, style: .line(Palette.border), relativeToContent: false)
            MK2ScenePreviewElement(
                rowCount: preview.rowCount,
                channelCount: preview.channelCount,
                markers: preview.markers,
                beatInterval: preview.beatInterval,
                playheadRow: preview.playheadRow,
                rect: MK2PixelRect(x: 8, y: 66, width: 464, height: 140)
            )
            MK2ParameterPageElement(
                slots: parameterSlots(scene.parameters),
                rect: MK2PixelRect(x: 8, y: 215, width: 464, height: 57),
                columns: 4,
                relativeToContent: false
            )
            editEncoderBindings(scene.parameters, actions: actions)
        }.build(renderer: renderer)
    }

    private static func parameterSlots(_ parameters: [MK2PaulinchePatternParameter]) -> [MK2ParameterPageSlot] {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        return parameters.prefix(4).enumerated().map { index, parameter in
            MK2ParameterPageSlot(
                label: parameter.label,
                iconGlyph: parameter.iconGlyph,
                value: parameter.value,
                isFocused: parameter.isFocused,
                colors: MK2ValueCellColors(
                    label: Palette.dim,
                    value: Palette.text,
                    border: Palette.border,
                    fill: Palette.editFieldFill,
                    focusedValue: 0x0000,
                    focusedFill: Palette.editFieldFocusedFill,
                    focusedBorder: Palette.text
                ),
                selectionEncoder: index + 5
            )
        }
    }

    private static func editEncoderBindings(
        _ parameters: [MK2PaulinchePatternParameter],
        actions: MK2PaulincheArrangementActions
    ) -> [any MK2ScreenElement] {
        parameters.prefix(4).enumerated().map { index, _ in
            let encoder = index + 5
            return MK2EncoderBindingElement(
                encoder,
                onTouch: { touched in actions.onEncoderTouch?(encoder, touched) },
                onChange: { delta, _, _ in actions.onEncoderChange?(encoder, delta) }
            )
        }
    }
}
