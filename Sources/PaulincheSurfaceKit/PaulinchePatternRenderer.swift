import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

public struct MK2PaulinchePatternRow: Sendable, Equatable {
    public var index: Int
    public var channelCells: [String]
    public var isPlaybackRow: Bool

    public init(index: Int, channelCells: [String], isPlaybackRow: Bool = false) {
        self.index = max(0, index)
        self.channelCells = channelCells
        self.isPlaybackRow = isPlaybackRow
    }
}

public struct MK2PaulinchePatternParameter: Sendable, Equatable {
    public var label: String
    public var value: String
    public var isFocused: Bool

    public init(label: String, value: String, isFocused: Bool = false) {
        self.label = label
        self.value = value
        self.isFocused = isFocused
    }
}

public struct MK2PaulinchePatternMeter: Sendable, Equatable {
    public var label: String
    public var level: Double
    public var peak: Double?
    public var isMuted: Bool
    public var isSoloed: Bool

    public init(label: String, level: Double, peak: Double? = nil, isMuted: Bool = false, isSoloed: Bool = false) {
        self.label = label
        self.level = level
        self.peak = peak
        self.isMuted = isMuted
        self.isSoloed = isSoloed
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
    public var rowProgress: Double
    public var selectedRowIndex: Int
    public var selectedChannelIndex: Int
    public var channelPage: Int
    public var rows: [MK2PaulinchePatternRow]
    public var parameters: [MK2PaulinchePatternParameter]
    public var meters: [MK2PaulinchePatternMeter]
    public var softKeys: [MK2PaulincheSoftKey]

    public init(
        title: String,
        subtitle: String,
        rowProgress: Double = 0,
        selectedRowIndex: Int,
        selectedChannelIndex: Int,
        channelPage: Int = 0,
        rows: [MK2PaulinchePatternRow],
        parameters: [MK2PaulinchePatternParameter],
        meters: [MK2PaulinchePatternMeter] = [],
        softKeys: [MK2PaulincheSoftKey] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.rowProgress = MK2PaulincheRendererSupport.clamped01(rowProgress)
        self.selectedRowIndex = max(0, selectedRowIndex)
        self.selectedChannelIndex = max(0, selectedChannelIndex)
        self.channelPage = max(0, channelPage)
        self.rows = rows
        self.parameters = Array(parameters.prefix(8))
        self.meters = meters
        self.softKeys = Array(softKeys.prefix(8))
    }
}

public struct MK2PaulinchePatternActions: Sendable {
    public var onSoftKey: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)?

    public init(onSoftKey: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)? = nil) {
        self.onSoftKey = onSoftKey
    }
}

public enum MK2PaulinchePatternRenderer {
    public static func render(
        _ scene: MK2PaulinchePatternScene,
        actions: MK2PaulinchePatternActions = MK2PaulinchePatternActions(),
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2DoubleScreenDSL {
        let textRenderer = renderer ?? (try? FreeTypeTextRenderer())
        let left = patternGridScreen(scene, renderer: textRenderer)
        let right = editScreen(scene, actions: actions, renderer: textRenderer)
        return MK2DoubleScreenDSL(left: left, right: right)
    }

    public static func surfaceScene(
        _ scene: MK2PaulinchePatternScene,
        actions: MK2PaulinchePatternActions = MK2PaulinchePatternActions(),
        renderer: FreeTypeTextRenderer? = nil
    ) -> MK2SurfaceScene2 {
        render(scene, actions: actions, renderer: renderer).scene()
    }

    private static func patternGridScreen(
        _ scene: MK2PaulinchePatternScene,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(background: MK2PaulincheRendererSupport.Palette.background) {
            MK2RenderBlock { frame, _ in
                drawTrackerHeader(scene, into: &frame, renderer: renderer)
                drawPatternGrid(scene, into: &frame, renderer: renderer)
            }
        }.build(renderer: renderer)
    }

    private static func editScreen(
        _ scene: MK2PaulinchePatternScene,
        actions: MK2PaulinchePatternActions,
        renderer: FreeTypeTextRenderer?
    ) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(background: MK2PaulincheRendererSupport.Palette.background) {
            MK2RenderBlock { frame, _ in
                drawTrackerHeader(scene, into: &frame, renderer: renderer)
                drawEditSummary(scene, into: &frame, renderer: renderer)
                MK2PaulincheRendererSupport.drawMeters(
                    scene.meters,
                    in: MK2PixelRect(x: 24, y: 110, width: 432, height: 64),
                    into: &frame,
                    renderer: renderer
                )
            }
            MK2ParameterPageElement(
                slots: parameterSlots(scene.parameters),
                rect: MK2PixelRect(x: 8, y: 215, width: 456, height: 57),
                columns: 4,
                relativeToContent: false
            )
        }.build(renderer: renderer)
    }

    private static func drawTrackerHeader(
        _ scene: MK2PaulinchePatternScene,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?
    ) {
        MK2PaulincheRendererSupport.drawHeader(
            title: scene.title,
            subtitle: scene.subtitle,
            progress: scene.rowProgress,
            into: &frame,
            renderer: renderer
        )
    }

    private static func drawPatternGrid(
        _ scene: MK2PaulinchePatternScene,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?
    ) {
        let originX = 14
        let headerY = 52
        let firstRowY = 72
        let rowHeight = 15
        let rowLabelWidth = 34
        let channelWidth = 96
        drawText("ROW", into: &frame, x: originX, y: headerY, style: MK2PaulincheRendererSupport.monoCaptionStyle(color: MK2HIG.Chrome.dim), renderer: renderer, maxWidth: rowLabelWidth)
        for channel in 0..<min(4, maxChannelCount(scene.rows)) {
            let channelIndex = scene.channelPage * 4 + channel
            let label = "CH\(channelIndex + 1)"
            let color = channelIndex == scene.selectedChannelIndex ? MK2HIG.Chrome.accent : MK2HIG.Chrome.dim
            drawText(label, into: &frame, x: originX + rowLabelWidth + channel * channelWidth, y: headerY, style: MK2PaulincheRendererSupport.monoCaptionStyle(color: color), renderer: renderer, maxWidth: channelWidth - 6)
            drawChannelToggles(
                scene.meters.indices.contains(channel) ? scene.meters[channel] : nil,
                into: &frame,
                x: originX + rowLabelWidth + channel * channelWidth + 58,
                y: headerY - 2
            )
        }

        for (visibleIndex, row) in scene.rows.prefix(12).enumerated() {
            let y = firstRowY + visibleIndex * rowHeight
            let isSelected = row.index == scene.selectedRowIndex
            if row.isPlaybackRow {
                frame.fill(MK2PixelRect(x: originX - 3, y: y - 1, width: 452, height: rowHeight), MK2PaulincheRendererSupport.Palette.playbackRow)
            }
            if isSelected {
                frame.fill(MK2PixelRect(x: originX - 3, y: y - 1, width: 452, height: rowHeight), MK2PaulincheRendererSupport.Palette.selectedRow)
                frame.fill(MK2PixelRect(x: originX - 8, y: y + 3, width: 4, height: 7), MK2HIG.Chrome.accent)
            }
            let rowLabel = String(format: "%02X", row.index)
            drawText(rowLabel, into: &frame, x: originX, y: y, style: MK2PaulincheRendererSupport.monoBodyStyle(color: isSelected ? MK2HIG.Chrome.text : MK2HIG.Chrome.dim), renderer: renderer, maxWidth: rowLabelWidth)
            for channel in 0..<min(4, row.channelCells.count) {
                let channelIndex = scene.channelPage * 4 + channel
                let x = originX + rowLabelWidth + channel * channelWidth
                let selectedChannel = isSelected && channelIndex == scene.selectedChannelIndex
                let color = selectedChannel ? MK2HIG.Chrome.accent : (isSelected ? MK2HIG.Chrome.text : 0xbdf7)
                drawText(row.channelCells[channel], into: &frame, x: x, y: y, style: MK2PaulincheRendererSupport.monoBodyStyle(color: color), renderer: renderer, maxWidth: channelWidth - 8)
            }
        }
    }

    private static func drawEditSummary(
        _ scene: MK2PaulinchePatternScene,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?
    ) {
        let selectedChannel = scene.selectedChannelIndex + 1
        drawText(
            "EDIT CH\(selectedChannel) ROW \(String(format: "%02X", scene.selectedRowIndex))",
            into: &frame,
            x: 18,
            y: 58,
            style: MK2PaulincheRendererSupport.monoCaptionStyle(color: MK2HIG.Chrome.accent),
            renderer: renderer,
            maxWidth: 210
        )
        let hint = "Encoder 1-8 bearbeiten die unten angezeigten Werte."
        MK2PaulincheRendererSupport.drawWrappedText(
            hint,
            into: &frame,
            x: 18,
            y: 76,
            style: MK2PaulincheRendererSupport.bodyStyle(color: MK2HIG.Chrome.dim),
            renderer: renderer,
            maxWidth: 420,
            maxLines: 1
        )
    }

    private static func drawChannelToggles(
        _ meter: MK2PaulinchePatternMeter?,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int
    ) {
        drawToggle("M", isOn: meter?.isMuted == true, into: &frame, x: x, y: y, colors: .mute)
        drawToggle("S", isOn: meter?.isSoloed == true, into: &frame, x: x + 18, y: y, colors: .solo)
    }

    private static func drawToggle(
        _ label: String,
        isOn: Bool,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        colors: ChannelToggleColors
    ) {
        let display = MK2ButtonToggleDisplay(
            label: label,
            rect: MK2PixelRect(x: x, y: y, width: 14, height: 16),
            font: .label,
            colors: MK2ButtonToggleDisplayColors(
                onFill: colors.fill,
                onBorder: colors.border,
                onText: 0x0000,
                offFill: MK2PaulincheRendererSupport.Palette.background,
                offBorder: MK2HIG.Chrome.border,
                offText: colors.fill
            )
        )
        display.draw(isOn: isOn, into: &frame)
    }

    private static func drawText(
        _ text: String,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        style: FreeTypeTextStyle,
        renderer: FreeTypeTextRenderer?,
        maxWidth: Int
    ) {
        MK2PaulincheRendererSupport.drawText(
            text,
            into: &frame,
            x: x,
            y: y,
            style: style,
            renderer: renderer,
            maxWidth: maxWidth
        )
    }

    private static func maxChannelCount(_ rows: [MK2PaulinchePatternRow]) -> Int {
        rows.map(\.channelCells.count).max() ?? 0
    }

    private static func parameterSlots(_ parameters: [MK2PaulinchePatternParameter]) -> [MK2ParameterPageSlot] {
        parameters.prefix(8).map { parameter in
            MK2ParameterPageSlot(
                label: parameter.label,
                value: parameter.value,
                isFocused: parameter.isFocused,
                colors: editCellColors(value: parameter.isFocused ? 0x0000 : MK2HIG.Chrome.text)
            )
        }
    }

    private static func editCellColors(value: UInt16) -> MK2ValueCellColors {
        MK2ValueCellColors(
            label: MK2HIG.Chrome.dim,
            value: value,
            border: MK2HIG.Chrome.border,
            fill: MK2PaulincheRendererSupport.Palette.secondaryPanelFill,
            focusedValue: 0x0000,
            focusedFill: MK2HIG.Chrome.accent,
            focusedBorder: MK2HIG.Chrome.text
        )
    }
}

private struct ChannelToggleColors {
    var fill: UInt16
    var border: UInt16

    static let mute = ChannelToggleColors(fill: 0xfaa0, border: 0xfbe0)
    static let solo = ChannelToggleColors(fill: 0xffe0, border: 0xffff)
}
