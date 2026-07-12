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
    public var selectedRowIndex: Int
    public var selectedChannelIndex: Int
    public var channelPage: Int
    public var instrumentLabel: String
    public var rows: [MK2PaulinchePatternRow]
    public var rowActivity: [Bool]
    public var channels: [MK2PaulinchePatternChannel]
    public var parameters: [MK2PaulinchePatternParameter]
    public var softKeys: [MK2PaulincheSoftKey]

    public init(
        title: String,
        subtitle: String,
        isPlaying: Bool = false,
        patternIndex: Int = 0,
        rowCount: Int,
        selectedRowIndex: Int,
        selectedChannelIndex: Int,
        channelPage: Int = 0,
        instrumentLabel: String = "",
        rows: [MK2PaulinchePatternRow],
        rowActivity: [Bool] = [],
        channels: [MK2PaulinchePatternChannel] = [],
        parameters: [MK2PaulinchePatternParameter],
        softKeys: [MK2PaulincheSoftKey] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isPlaying = isPlaying
        self.patternIndex = max(0, patternIndex)
        self.rowCount = max(1, rowCount)
        self.selectedRowIndex = max(0, selectedRowIndex)
        self.selectedChannelIndex = max(0, selectedChannelIndex)
        self.channelPage = max(0, channelPage)
        self.instrumentLabel = instrumentLabel
        self.rows = rows
        self.rowActivity = rowActivity
        self.channels = channels
        self.parameters = Array(parameters.prefix(8))
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
    public static let visibleRowCount = 13

    public static func render(
        _ scene: MK2PaulinchePatternScene,
        actions: MK2PaulinchePatternActions = MK2PaulinchePatternActions(),
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2DoubleScreenDSL {
        MK2DoubleScreenDSL(
            left: patternGridScreen(scene, renderer: renderer),
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

    private static let gridTop = 60
    private static let rowHeight = 16
    private static let rowIndexX = 8
    private static let channelXs = [48, 153, 258, 363]
    private static let rulerXs = [36, 141, 246, 351, 456]
    private static let rowStripeInterval = 4

    private static func patternGridScreen(
        _ scene: MK2PaulinchePatternScene,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(background: MK2PaulincheRendererSupport.Palette.background) {
            MK2RenderBlock { frame, _ in
                drawGridStatusLine(scene, into: &frame)
                drawChannelHeaders(scene, into: &frame)
                drawPatternGrid(scene, into: &frame)
                drawPatternOverview(scene, into: &frame, x: 466, y: 62, height: 200)
            }
        }.build(renderer: renderer)
    }

    private static func drawGridStatusLine(_ scene: MK2PaulinchePatternScene, into frame: inout MK2PixelFrame) {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        BitmapLabel(String(format: "PAT %02d", scene.patternIndex), font: .grid, color: Palette.blue)
            .draw(into: &frame, x: 8, y: 8)
        BitmapLabel("ROW \(hex2(scene.selectedRowIndex))", font: .gridBold, color: Palette.text).draw(into: &frame, x: 110, y: 8)
        BitmapLabel(scene.isPlaying ? "PLAY" : "STOP", font: .gridBold, color: scene.isPlaying ? Palette.green : Palette.orange)
            .draw(into: &frame, x: 222, y: 8)
        BitmapLabel(scene.subtitle, font: .grid, color: Palette.dim)
            .draw(into: &frame, x: 310, y: 8, clip: MK2PixelRect(x: 310, y: 8, width: 150, height: SurfaceFont.grid.cellHeight))
    }

    private static func drawChannelHeaders(_ scene: MK2PaulinchePatternScene, into frame: inout MK2PixelFrame) {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        for (index, x) in rulerXs.dropLast().enumerated() {
            guard scene.channels.indices.contains(index) else { continue }
            let channel = scene.channels[index]
            let absoluteChannel = scene.channelPage * 4 + index
            let active = absoluteChannel == scene.selectedChannelIndex
            BitmapLabel(channel.label, font: .label, color: active ? Palette.blue : Palette.dim)
                .draw(into: &frame, x: x, y: 38, clip: MK2PixelRect(x: x, y: 38, width: 66, height: SurfaceFont.label.cellHeight))
            drawChannelToggle("M", isOn: channel.isMuted, into: &frame, x: x + 69, y: 34, accent: Palette.mute, border: Palette.muteBorder)
            drawChannelToggle("S", isOn: channel.isSoloed, into: &frame, x: x + 87, y: 34, accent: Palette.solo, border: Palette.soloBorder)
        }
        frame.hline(y: 55, x: 0, width: MK2PixelFrame.width, color: MK2PaulincheRendererSupport.Palette.border)
    }

    private static func drawPatternGrid(_ scene: MK2PaulinchePatternScene, into frame: inout MK2PixelFrame) {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        for (visibleIndex, row) in scene.rows.prefix(visibleRowCount).enumerated() {
            let y = gridTop + visibleIndex * rowHeight
            let isPlayhead = row.index == scene.selectedRowIndex
            if isPlayhead {
                frame.fill(MK2PixelRect(x: 0, y: y, width: MK2PixelFrame.width, height: rowHeight), scene.isPlaying ? Palette.playheadFill : Palette.cursorFill)
                frame.fill(MK2PixelRect(x: 36, y: y, width: 5, height: rowHeight), Palette.green)
            } else if row.index.isMultiple(of: rowStripeInterval) {
                frame.fill(MK2PixelRect(x: 0, y: y, width: MK2PixelFrame.width, height: rowHeight), Palette.rowStripe)
            }

            BitmapLabel(hex2(row.index), font: .grid, color: isPlayhead ? Palette.text : Palette.dim)
                .draw(into: &frame, x: rowIndexX, y: y)
            for channel in 0..<min(4, row.cells.count) {
                let absoluteChannel = scene.channelPage * 4 + channel
                drawTrackerCell(
                    row.cells[channel],
                    into: &frame,
                    x: channelXs[channel],
                    y: y,
                    highlighted: isPlayhead,
                    focusedChannel: absoluteChannel == scene.selectedChannelIndex
                )
            }
        }
        for x in rulerXs {
            frame.dottedVLine(x: x, y: 50, height: 218, color: MK2PaulincheRendererSupport.Palette.ruler)
        }
    }

    private static func drawTrackerCell(
        _ cell: MK2PaulinchePatternCell,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        highlighted: Bool,
        focusedChannel: Bool
    ) {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        if focusedChannel, !highlighted {
            frame.fill(MK2PixelRect(x: x - 4, y: y, width: 92, height: rowHeight), Palette.focusedChannelFill)
        }
        let noteColor = highlighted ? Palette.text : (cell.note == nil ? Palette.empty : Palette.note)
        let instColor = highlighted ? Palette.text : (cell.instrument == nil ? Palette.empty : Palette.instrument)
        let fxColor = highlighted ? Palette.text : (cell.effect == nil ? Palette.empty : Palette.effect)
        BitmapLabel(cell.note ?? "...", font: .grid, color: noteColor).draw(into: &frame, x: x, y: y)
        BitmapLabel(cell.instrument ?? "..", font: .grid, color: instColor).draw(into: &frame, x: x + 38, y: y)
        BitmapLabel(cell.effect ?? "...", font: .grid, color: fxColor).draw(into: &frame, x: x + 64, y: y)
    }

    private static func drawChannelToggle(
        _ label: String,
        isOn: Bool,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        accent: UInt16,
        border: UInt16
    ) {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        MK2ButtonToggleDisplay(
            label: label,
            rect: MK2PixelRect(x: x, y: y, width: 14, height: 16),
            font: .label,
            colors: MK2ButtonToggleDisplayColors(
                onFill: accent,
                onBorder: border,
                onText: Palette.channelButtonActiveText,
                offFill: Palette.channelButtonFill,
                offBorder: Palette.channelButtonBorder,
                offText: accent
            )
        ).draw(isOn: isOn, into: &frame)
    }

    private static func drawPatternOverview(
        _ scene: MK2PaulinchePatternScene,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        height: Int
    ) {
        typealias Palette = MK2PaulincheRendererSupport.Palette
        guard scene.rowCount > 1 else { return }
        frame.fill(MK2PixelRect(x: x, y: y, width: 5, height: height), Palette.track)
        for row in 0..<scene.rowCount {
            let markerY = y + Int((Double(row) / Double(scene.rowCount - 1) * Double(height - 1)).rounded())
            let active = scene.rowActivity.indices.contains(row) && scene.rowActivity[row]
            let isPlayhead = row == scene.selectedRowIndex
            let color = isPlayhead ? Palette.green : (active ? Palette.blue : Palette.ruler)
            frame.fill(MK2PixelRect(x: x, y: markerY, width: isPlayhead ? 9 : 5, height: 1), color)
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
            MK2StatusLineItem("CH\(scene.selectedChannelIndex + 1)", x: 92, color: Palette.dim),
        ]
        let instrumentLabel = scene.instrumentLabel

        return MK2FullScreenDSL(background: Palette.background) {
            MK2AnyScreenElement { frame, _, _ in
                MK2StatusLine(y: 8, items: statusItems).draw(into: &frame)
                BitmapLabel(instrumentLabel, font: .grid, color: Palette.instrument)
                    .draw(into: &frame, x: 158, y: 8, clip: MK2PixelRect(x: 158, y: 8, width: 314, height: SurfaceFont.grid.cellHeight))
                frame.hline(y: 55, x: 0, width: MK2PixelFrame.width, color: Palette.border)
            }
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
