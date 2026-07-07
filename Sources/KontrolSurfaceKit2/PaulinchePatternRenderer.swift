import Foundation
import KompleteKontrol

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

    public init(label: String, level: Double, peak: Double? = nil) {
        self.label = label
        self.level = level
        self.peak = peak
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
        self.rowProgress = rowProgress.clamped01()
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
        let left = patternGridScreen(scene, renderer: renderer)
        let right = editScreen(scene, actions: actions, renderer: renderer)
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
        MK2FullScreenDSL(background: Palette.background) {
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
        MK2FullScreenDSL(background: Palette.background) {
            MK2RenderBlock { frame, _ in
                drawTrackerHeader(scene, into: &frame, renderer: renderer)
                drawSoftKeyStrip(scene.softKeys, into: &frame, renderer: renderer)
            }
            MK2ParameterPageElement(
                slots: scene.parameters.enumerated().map { index, parameter in
                    MK2ParameterPageSlot(
                        label: parameter.label,
                        value: parameter.value,
                        isFocused: parameter.isFocused,
                        encoderValue: MK2EncoderDiscreteValue(
                            encoder: index + 1,
                            value: 0,
                            bounds: -128...127,
                            wraps: false,
                            onChange: { _ in }
                        )
                    )
                },
                rect: MK2PixelRect(x: 18, y: 58, width: 444, height: 104),
                columns: 4,
                relativeToContent: false
            )
            MK2MeterElement(
                channels: scene.meters.map { MK2MeterChannel(label: $0.label, level: $0.level, peak: $0.peak) },
                rect: MK2PixelRect(x: 24, y: 174, width: 432, height: 42),
                relativeToContent: false
            )
            softKeyBindings(scene.softKeys, actions: actions)
        }.build(renderer: renderer)
    }

    private static func softKeyBindings(
        _ softKeys: [MK2PaulincheSoftKey],
        actions: MK2PaulinchePatternActions
    ) -> [any MK2ScreenElement] {
        guard let onSoftKey = actions.onSoftKey else { return [] }
        return softKeys.enumerated().compactMap { index, softKey in
            guard softKey.isEnabled, let button = functionButton(at: index) else { return nil }
            return MK2ButtonBindingElement(button) {
                onSoftKey(index, softKey)
            }
        }
    }

    private static func drawTrackerHeader(
        _ scene: MK2PaulinchePatternScene,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?
    ) {
        frame.fill(MK2PixelRect(x: 0, y: 0, width: MK2PixelFrame.width, height: 44), Palette.header)
        frame.fill(MK2PixelRect(x: 0, y: 0, width: MK2PixelFrame.width, height: 1), Palette.headerTop)
        frame.fill(MK2PixelRect(x: 0, y: 43, width: MK2PixelFrame.width, height: 1), Palette.headerBottom)
        drawText(scene.title, into: &frame, x: 14, y: 8, style: titleStyle, fallback: .gridBold, color: MK2HIG.Chrome.text, renderer: renderer, maxWidth: 240)
        drawText(scene.subtitle, into: &frame, x: 296, y: 13, style: captionStyle(color: MK2HIG.Chrome.dim), fallback: .label, color: MK2HIG.Chrome.dim, renderer: renderer, maxWidth: 168)
        let track = MK2PixelRect(x: 14, y: 34, width: 452, height: 4)
        frame.fill(track, Palette.track)
        let progressWidth = Int((Double(track.width) * scene.rowProgress).rounded())
        if progressWidth > 0 {
            frame.fill(MK2PixelRect(x: track.x, y: track.y, width: min(track.width, progressWidth), height: track.height), MK2HIG.Chrome.accent)
        }
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
        drawText("ROW", into: &frame, x: originX, y: headerY, style: monoCaptionStyle(color: MK2HIG.Chrome.dim), fallback: .label, color: MK2HIG.Chrome.dim, renderer: renderer, maxWidth: rowLabelWidth)
        for channel in 0..<min(4, maxChannelCount(scene.rows)) {
            let channelIndex = scene.channelPage * 4 + channel
            let label = "CH\(channelIndex + 1)"
            let color = channelIndex == scene.selectedChannelIndex ? MK2HIG.Chrome.accent : MK2HIG.Chrome.dim
            drawText(label, into: &frame, x: originX + rowLabelWidth + channel * channelWidth, y: headerY, style: monoCaptionStyle(color: color), fallback: .label, color: color, renderer: renderer, maxWidth: channelWidth - 6)
        }

        for (visibleIndex, row) in scene.rows.prefix(12).enumerated() {
            let y = firstRowY + visibleIndex * rowHeight
            let isSelected = row.index == scene.selectedRowIndex
            if row.isPlaybackRow {
                frame.fill(MK2PixelRect(x: originX - 3, y: y - 1, width: 452, height: rowHeight), Palette.playbackRow)
            }
            if isSelected {
                frame.fill(MK2PixelRect(x: originX - 3, y: y - 1, width: 452, height: rowHeight), Palette.selectedRow)
                frame.fill(MK2PixelRect(x: originX - 8, y: y + 3, width: 4, height: 7), MK2HIG.Chrome.accent)
            }
            let rowLabel = String(format: "%02X", row.index)
            drawText(rowLabel, into: &frame, x: originX, y: y, style: monoBodyStyle(color: isSelected ? MK2HIG.Chrome.text : MK2HIG.Chrome.dim), fallback: .grid, color: isSelected ? MK2HIG.Chrome.text : MK2HIG.Chrome.dim, renderer: renderer, maxWidth: rowLabelWidth)
            for channel in 0..<min(4, row.channelCells.count) {
                let channelIndex = scene.channelPage * 4 + channel
                let x = originX + rowLabelWidth + channel * channelWidth
                let selectedChannel = isSelected && channelIndex == scene.selectedChannelIndex
                let color = selectedChannel ? MK2HIG.Chrome.accent : (isSelected ? MK2HIG.Chrome.text : 0xbdf7)
                drawText(row.channelCells[channel], into: &frame, x: x, y: y, style: monoBodyStyle(color: color), fallback: .grid, color: color, renderer: renderer, maxWidth: channelWidth - 8)
            }
        }
    }

    private static func drawSoftKeyStrip(
        _ softKeys: [MK2PaulincheSoftKey],
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?
    ) {
        let y = 230
        let height = 34
        let slotWidth = MK2PixelFrame.width / 8
        frame.fill(MK2PixelRect(x: 0, y: y, width: MK2PixelFrame.width, height: height), Palette.softKeyFill)
        frame.fill(MK2PixelRect(x: 0, y: y, width: MK2PixelFrame.width, height: 1), MK2HIG.Chrome.border)
        for index in 0..<8 {
            let x = index * slotWidth
            if index > 0 {
                frame.fill(MK2PixelRect(x: x, y: y, width: 1, height: height), MK2HIG.Chrome.border)
            }
            guard softKeys.indices.contains(index) else { continue }
            let softKey = softKeys[index]
            let color = softKey.isEnabled ? MK2HIG.Chrome.text : MK2HIG.Chrome.dim
            drawText(softKey.label.uppercased(), into: &frame, x: x + 6, y: y + 10, style: captionStyle(color: color), fallback: .label, color: color, renderer: renderer, maxWidth: slotWidth - 12)
        }
    }

    private static func drawText(
        _ text: String,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        style: FreeTypeTextStyle,
        fallback: SurfaceFont,
        color: UInt16,
        renderer: FreeTypeTextRenderer?,
        maxWidth: Int
    ) {
        if let renderer,
           (try? renderer.drawText(text, into: &frame, x: x, y: y, style: style, maxWidth: maxWidth)) != nil {
            return
        }
        BitmapLabel(text, font: fallback, color: color)
            .draw(into: &frame, x: x, y: y + 2, clip: MK2PixelRect(x: x, y: y, width: maxWidth, height: fallback.cellHeight))
    }

    private static func maxChannelCount(_ rows: [MK2PaulinchePatternRow]) -> Int {
        rows.map(\.channelCells.count).max() ?? 0
    }

    private static func functionButton(at index: Int) -> KKMK2ButtonLED? {
        switch index {
            case 0: return .function1
            case 1: return .function2
            case 2: return .function3
            case 3: return .function4
            case 4: return .function5
            case 5: return .function6
            case 6: return .function7
            case 7: return .function8
            default: return nil
        }
    }

    private static let titleStyle = MK2HIG.textStyle(
        weight: .medium,
        pixelSize: 22,
        color: MK2HIG.Chrome.text
    )

    private static func captionStyle(color: UInt16) -> FreeTypeTextStyle {
        MK2HIG.textStyle(weight: .medium, pixelSize: 14, color: color)
    }

    private static func monoBodyStyle(color: UInt16) -> FreeTypeTextStyle {
        FreeTypeTextStyle(
            familyID: MK2HIG.Fonts.monoFamilyID,
            weight: .regular,
            pixelSize: 13,
            color: color,
            rasterMode: MK2HIG.Fonts.rasterMode
        )
    }

    private static func monoCaptionStyle(color: UInt16) -> FreeTypeTextStyle {
        FreeTypeTextStyle(
            familyID: MK2HIG.Fonts.monoFamilyID,
            weight: .bold,
            pixelSize: 11,
            color: color,
            rasterMode: MK2HIG.Fonts.rasterMode
        )
    }
}

private enum Palette {
    static let background: UInt16 = MK2HIG.Chrome.background
    static let header: UInt16 = MK2HIG.Chrome.headerFill
    static let headerTop: UInt16 = MK2HIG.Chrome.headerTopLine
    static let headerBottom: UInt16 = MK2HIG.Chrome.headerBottomLine
    static let track: UInt16 = 0x2104
    static let selectedRow: UInt16 = 0x2128
    static let playbackRow: UInt16 = 0x082c
    static let softKeyFill: UInt16 = 0x0003
}

private extension Double {
    func clamped01() -> Double {
        Swift.max(0, Swift.min(1, self))
    }
}
