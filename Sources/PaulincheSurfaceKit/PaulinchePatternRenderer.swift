import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

public struct MK2PaulinchePatternCell: Sendable, Equatable {
    public var note: String?
    public var instrument: String?
    public var effect: String?

    public init(note: String? = nil, instrument: String? = nil, effect: String? = nil) {
        self.note = note
        self.instrument = instrument
        self.effect = effect
    }

    public var isEmpty: Bool {
        note == nil && instrument == nil && effect == nil
    }
}

public struct MK2PaulinchePatternRow: Sendable, Equatable {
    public var index: Int
    public var cells: [MK2PaulinchePatternCell]

    public init(index: Int, cells: [MK2PaulinchePatternCell]) {
        self.index = max(0, index)
        self.cells = cells
    }
}

public struct MK2PaulinchePatternChannel: Sendable, Equatable {
    public var label: String
    public var isMuted: Bool
    public var isSoloed: Bool

    public init(label: String, isMuted: Bool = false, isSoloed: Bool = false) {
        self.label = label
        self.isMuted = isMuted
        self.isSoloed = isSoloed
    }
}

public struct MK2PaulinchePatternParameter: Sendable, Equatable {
    public var label: String
    /// Optional Phosphor glyph rendered on the label line (see
    /// `MK2ValueCell.iconGlyph`); the app chooses it by parameter semantics.
    public var iconGlyph: String?
    public var value: String
    public var isFocused: Bool

    public init(label: String, iconGlyph: String? = nil, value: String, isFocused: Bool = false) {
        self.label = label
        self.iconGlyph = iconGlyph
        self.value = value
        self.isFocused = isFocused
    }
}

public enum MK2PaulinchePatternRowInfoKind: Sendable, Equatable {
    case instrument
    case volume
    case effect
}

public struct MK2PaulinchePatternRowInfo: Sendable, Equatable {
    public var kind: MK2PaulinchePatternRowInfoKind
    public var label: String
    public var value: String
    public var detail: String

    public init(kind: MK2PaulinchePatternRowInfoKind, label: String, value: String, detail: String) {
        self.kind = kind
        self.label = label
        self.value = value
        self.detail = detail
    }
}

public struct MK2PaulincheSoftKey: Sendable, Equatable {
    public var label: String
    public var commandID: String?
    public var integerPayload: Int?
    public var isEnabled: Bool

    public init(label: String, commandID: String? = nil, integerPayload: Int? = nil, isEnabled: Bool = true) {
        self.label = label
        self.commandID = commandID
        self.integerPayload = integerPayload
        self.isEnabled = isEnabled
    }
}

public struct MK2PaulinchePatternScene: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var isPlaying: Bool
    public var patternIndex: Int
    public var rowCount: Int
    /// Beat length in rows — the pattern grid highlights every `beatInterval`th
    /// row. The app derives it from the time signature (4/4 → 4).
    public var beatInterval: Int
    public var selectedRowIndex: Int
    public var selectedChannelIndex: Int
    public var channelPage: Int
    public var instrumentLabel: String
    public var rows: [MK2PaulinchePatternRow]
    public var rowActivity: [Bool]
    public var channels: [MK2PaulinchePatternChannel]
    public var parameters: [MK2PaulinchePatternParameter]
    public var rowInfo: [MK2PaulinchePatternRowInfo]
    public var softKeys: [MK2PaulincheSoftKey]

    public init(
        title: String,
        subtitle: String,
        isPlaying: Bool = false,
        patternIndex: Int = 0,
        rowCount: Int,
        beatInterval: Int = 4,
        selectedRowIndex: Int,
        selectedChannelIndex: Int,
        channelPage: Int = 0,
        instrumentLabel: String = "",
        rows: [MK2PaulinchePatternRow],
        rowActivity: [Bool] = [],
        channels: [MK2PaulinchePatternChannel] = [],
        parameters: [MK2PaulinchePatternParameter],
        rowInfo: [MK2PaulinchePatternRowInfo] = [],
        softKeys: [MK2PaulincheSoftKey] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isPlaying = isPlaying
        self.patternIndex = max(0, patternIndex)
        self.rowCount = max(1, rowCount)
        self.beatInterval = max(1, beatInterval)
        self.selectedRowIndex = max(0, selectedRowIndex)
        self.selectedChannelIndex = max(0, selectedChannelIndex)
        self.channelPage = max(0, channelPage)
        self.instrumentLabel = instrumentLabel
        self.rows = rows
        self.rowActivity = rowActivity
        self.channels = channels
        self.parameters = Array(parameters.prefix(8))
        self.rowInfo = rowInfo
        self.softKeys = Array(softKeys.prefix(8))
    }
}

public struct MK2PaulinchePatternActions: Sendable {
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

/// Renders the tracker pattern screens in the layout developed in the MK2 widget lab:
/// a full-bleed grid on the left (bitmap-atlas fonts only, no FreeType in the hot path)
/// and a full-screen edit pane with a parameter page on the right.
public enum MK2PaulinchePatternRenderer {
    public static let visibleRowCount = MK2PatternGridElement.visibleRowCount

    public static func render(
        _ scene: MK2PaulinchePatternScene,
        actions: MK2PaulinchePatternActions = MK2PaulinchePatternActions(),
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2DoubleScreenDSL {
        MK2DoubleScreenDSL(
            left: patternGridScreen(scene, actions: actions, renderer: renderer),
            right: editScreen(scene, actions: actions, renderer: renderer)
        )
    }

    public static func surfaceScene(
        _ scene: MK2PaulinchePatternScene,
        actions: MK2PaulinchePatternActions = MK2PaulinchePatternActions(),
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2SurfaceScene2 {
        render(scene, actions: actions, renderer: renderer).scene()
    }

    // MARK: - Left screen: pattern grid

    private static func patternGridScreen(
        _ scene: MK2PaulinchePatternScene,
        actions: MK2PaulinchePatternActions,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        return MK2FullScreenDSL(background: Palette.background) {
            MK2StatusLineElement(y: 8, items: [
                MK2StatusLineItem(String(format: "PAT %02d", scene.patternIndex), x: 8, color: Palette.blue),
                MK2StatusLineItem("ROW \(hex2(scene.selectedRowIndex))", x: 110, color: Palette.text, font: .gridBold),
                MK2StatusLineItem(scene.isPlaying ? "PLAY" : "STOP", x: 222, color: scene.isPlaying ? Palette.green : Palette.orange, font: .gridBold),
                MK2StatusLineItem(scene.subtitle, x: 310, color: Palette.dim, maxWidth: 150),
            ], relativeToContent: false)
            MK2PatternGridElement(
                rows: patternGridRows(scene),
                channels: patternGridChannels(scene),
                selectedRowIndex: scene.selectedRowIndex,
                isPlaying: scene.isPlaying,
                beatStripe: .every(scene.beatInterval)
            )
            MK2OverviewScrollbarElement(
                rowCount: scene.rowCount,
                selectedRowIndex: scene.selectedRowIndex,
                rowActivity: scene.rowActivity,
                rect: MK2PixelRect(x: 466, y: 62, width: 5, height: 200)
            )
            // E1–E4 are the top-flush channel encoders above the grid: touch
            // selects the channel directly, rotation moves the cursor row (the
            // same axis as the 4-D wheel). They carry no value cells — the
            // bottom-flush E5–E8 slots own that layout. Wired here, inside the
            // DSL, so `render()` and `surfaceScene()` agree.
            channelEncoderBindings(actions)
        }.build(renderer: renderer)
    }

    private static func channelEncoderBindings(_ actions: MK2PaulinchePatternActions) -> [any MK2ScreenElement] {
        (1...4).map { encoder in
            MK2EncoderBindingElement(
                encoder,
                onTouch: { touched in actions.onEncoderTouch?(encoder, touched) },
                onChange: { delta, _, _ in actions.onEncoderChange?(encoder, delta) }
            )
        }
    }

    private static func patternGridRows(_ scene: MK2PaulinchePatternScene) -> [MK2PatternGridElement.Row] {
        scene.rows.prefix(visibleRowCount).map { row in
            MK2PatternGridElement.Row(
                index: row.index,
                cells: row.cells.map { MK2PatternGridElement.Cell(note: $0.note, instrument: $0.instrument, effect: $0.effect) }
            )
        }
    }

    private static func patternGridChannels(_ scene: MK2PaulinchePatternScene) -> [MK2PatternGridElement.Channel] {
        scene.channels.enumerated().map { index, channel in
            let absoluteChannel = scene.channelPage * 4 + index
            return MK2PatternGridElement.Channel(
                label: channel.label,
                isMuted: channel.isMuted,
                isSoloed: channel.isSoloed,
                isFocused: absoluteChannel == scene.selectedChannelIndex
            )
        }
    }

    // MARK: - Right screen: edit pane

    private static func editScreen(
        _ scene: MK2PaulinchePatternScene,
        actions: MK2PaulinchePatternActions,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        let statusItems = [
            MK2StatusLineItem("EDIT", x: 8, color: Palette.blue),
            MK2StatusLineItem("ROW \(hex2(scene.selectedRowIndex))", x: 76, color: Palette.text, font: .gridBold),
            MK2StatusLineItem("CH\(scene.selectedChannelIndex + 1)", x: 150, color: Palette.dim),
        ]
        let instrumentLabel = scene.instrumentLabel

        return MK2FullScreenDSL(background: Palette.background) {
            MK2StatusLineElement(y: 8, items: statusItems + [
                MK2StatusLineItem(instrumentLabel, x: 206, color: Palette.instrument, maxWidth: 266),
            ], relativeToContent: false)
            MK2SeparatorElement(y: 55, style: .line(Palette.border), relativeToContent: false)
            rowInspectorElements(scene.rowInfo)
            MK2ParameterPageElement(
                slots: parameterSlots(scene.parameters),
                rect: MK2PixelRect(x: 8, y: 215, width: 464, height: 57),
                columns: 4,
                relativeToContent: false
            )
            editEncoderBindings(scene.parameters, actions: actions)
        }.build(renderer: renderer)
    }

    private static func rowInspectorElements(
        _ rowInfo: [MK2PaulinchePatternRowInfo]
    ) -> [any MK2ScreenElement] {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        guard !rowInfo.isEmpty else { return [] }
        let instrument = rowInfo.first { $0.kind == .instrument }
        let volume = rowInfo.first { $0.kind == .volume }
        let effect = rowInfo.first { $0.kind == .effect }
        var elements: [any MK2ScreenElement] = []

        if let instrument {
            elements.append(MK2ContentText(
                instrument.label,
                x: 8,
                y: 66,
                maxWidth: 288,
                role: .custom(weight: .bold, pixelSize: 11),
                color: Palette.instrument,
                relativeToContent: false
            ))
            elements.append(MK2ContentText(
                instrument.value,
                x: 8,
                y: 84,
                maxWidth: 288,
                role: .custom(weight: .medium, pixelSize: 14),
                color: Palette.text,
                relativeToContent: false
            ))
            elements.append(MK2ContentText(
                instrument.detail,
                x: 8,
                y: 108,
                maxWidth: 288,
                role: .footnote,
                color: Palette.dim,
                relativeToContent: false
            ))
        }

        if let volume {
            elements.append(MK2ContentText(
                volume.label,
                x: 316,
                y: 66,
                maxWidth: 156,
                role: .custom(weight: .bold, pixelSize: 11),
                color: Palette.blue,
                relativeToContent: false
            ))
            elements.append(MK2ContentText(
                volume.value,
                x: 316,
                y: 84,
                maxWidth: 156,
                role: .custom(weight: .medium, pixelSize: 14),
                color: Palette.text,
                relativeToContent: false
            ))
            elements.append(MK2ContentText(
                volume.detail,
                x: 316,
                y: 108,
                maxWidth: 156,
                role: .footnote,
                color: Palette.dim,
                relativeToContent: false
            ))
        }

        if let effect {
            elements.append(MK2SeparatorElement(y: 139, style: .line(Palette.border), relativeToContent: false))
            elements.append(MK2ContentText(
                effect.label,
                x: 8,
                y: 150,
                maxWidth: 464,
                role: .custom(weight: .bold, pixelSize: 11),
                color: Palette.effect,
                relativeToContent: false
            ))
            elements.append(MK2ContentText(
                effect.value,
                x: 8,
                y: 168,
                maxWidth: 464,
                role: .custom(weight: .medium, pixelSize: 14),
                color: Palette.text,
                relativeToContent: false
            ))
            elements.append(MK2ContentText(
                effect.detail,
                x: 8,
                y: 191,
                maxWidth: 464,
                role: .footnote,
                color: Palette.dim,
                relativeToContent: false
            ))
        }

        return elements
    }

    private static func parameterSlots(_ parameters: [MK2PaulinchePatternParameter]) -> [MK2ParameterPageSlot] {
        parameters.prefix(4).enumerated().map { index, parameter in
            MK2ParameterPageSlot(
                label: parameter.label,
                iconGlyph: parameter.iconGlyph,
                value: parameter.value,
                isFocused: parameter.isFocused,
                colors: editCellColors(value: editValueColor(at: index)),
                // The touch highlight bridges the app round trip: the runtime
                // inverts instantly, the app confirms by moving `cursor.field`
                // (→ isFocused) with no further visible change.
                selectionEncoder: index + 5
            )
        }
    }

    private static func editEncoderBindings(
        _ parameters: [MK2PaulinchePatternParameter],
        actions: MK2PaulinchePatternActions
    ) -> [any MK2ScreenElement] {
        parameters.prefix(4).enumerated().map { index, _ in
            let encoder = index + 5
            return MK2EncoderBindingElement(
                encoder,
                onTouch: { touched in
                    actions.onEncoderTouch?(encoder, touched)
                },
                onChange: { delta, _, _ in
                    actions.onEncoderChange?(encoder, delta)
                }
            )
        }
    }

    private static func editValueColor(at index: Int) -> UInt16 {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        return switch index {
            case 1: Palette.instrument
            case 3: Palette.effect
            default: Palette.text
        }
    }

    private static func editCellColors(value: UInt16) -> MK2ValueCellColors {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        return MK2ValueCellColors(
            label: Palette.dim,
            value: value,
            border: Palette.border,
            fill: Palette.editFieldFill,
            focusedValue: 0x0000,
            focusedFill: Palette.editFieldFocusedFill,
            focusedBorder: Palette.text
        )
    }

    private static func hex2(_ value: Int) -> String {
        String(format: "%02X", max(0, min(255, value)))
    }
}
