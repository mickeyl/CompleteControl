import Foundation

/// The dense tracker pattern grid — the left-screen body shared by the widget
/// lab's Tracker demo and Paulinche's live pattern renderer. It draws the
/// channel-header band (labels plus mute/solo indicators and the separating
/// rule), the windowed row grid (playhead/cursor fill, the green playhead
/// marker, the beat stripe, the row-index gutter and the per-field cells) and
/// the vertical channel rulers. The status line above the grid and every input
/// binding stay with the client; this element only draws.
///
/// Geometry, palette and stripe logic are the hardware-approved baseline
/// (signed off 2026-07-13). Rows arrive already windowed to at most
/// `visibleRowCount`, each carrying its absolute `index`, so the playhead and
/// the beat stripe test against song position rather than screen position.
///
/// The beat stripe interval is configurable (`beatInterval`, default 4): it is
/// the musical beat length in rows, so a 3/4 pattern stripes every third row.
/// The cells colour each field independently — a row that carries a note but no
/// effect renders the note lit and the effect placeholder dim, never the whole
/// cell as one.
public struct MK2PatternGridElement: MK2ScreenElement {
    public struct Cell: Sendable, Equatable {
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

    public struct Row: Sendable, Equatable {
        public var index: Int
        public var cells: [Cell]

        public init(index: Int, cells: [Cell]) {
            self.index = max(0, index)
            self.cells = cells
        }
    }

    public struct Channel: Sendable, Equatable {
        public var label: String
        public var isMuted: Bool
        public var isSoloed: Bool
        /// Whether this visible column is the focused edit channel — tints its
        /// header label and shades its cell column.
        public var isFocused: Bool

        public init(label: String, isMuted: Bool = false, isSoloed: Bool = false, isFocused: Bool = false) {
            self.label = label
            self.isMuted = isMuted
            self.isSoloed = isSoloed
            self.isFocused = isFocused
        }
    }

    /// Which rows carry the faint beat highlight. `.every(interval, phase:)` is
    /// the product rule — the beat length in rows, so a 3/4 pattern stripes
    /// every third row; the phase offsets the count. `.none` clears it.
    public enum BeatStripe: Sendable, Equatable {
        case none
        case every(Int, phase: Int = 0)

        func matches(_ row: Int) -> Bool {
            switch self {
                case .none:
                    return false
                case let .every(interval, phase):
                    guard interval > 0 else { return false }
                    return row.floorMod(interval) == phase.floorMod(interval)
            }
        }
    }

    public var rows: [Row]
    public var channels: [Channel]
    public var selectedRowIndex: Int
    public var isPlaying: Bool
    public var beatStripe: BeatStripe
    public var colors: MK2PatternGridColors

    /// The number of rows the grid shows at once — the client windows its song
    /// to at most this many rows before handing them over.
    public static let visibleRowCount = 13

    static let gridTop = 60
    static let rowHeight = 16
    static let rowIndexX = 8
    static let channelXs = [48, 153, 258, 363]
    static let rulerXs = [36, 141, 246, 351, 456]
    static let headerLabelY = 38
    static let toggleY = 34
    static let separatorY = 55
    private static let notePlaceholder = "..."
    private static let instrumentPlaceholder = ".."
    private static let effectPlaceholder = "..."

    public init(
        rows: [Row],
        channels: [Channel],
        selectedRowIndex: Int,
        isPlaying: Bool = false,
        beatStripe: BeatStripe = .every(4),
        colors: MK2PatternGridColors = MK2PatternGridColors()
    ) {
        self.rows = Array(rows.prefix(Self.visibleRowCount))
        self.channels = Array(channels.prefix(4))
        self.selectedRowIndex = max(0, selectedRowIndex)
        self.isPlaying = isPlaying
        self.beatStripe = beatStripe
        self.colors = colors
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        drawChannelHeaders(into: &frame)
        drawRows(into: &frame)
        drawRulers(into: &frame)
    }

    private func drawChannelHeaders(into frame: inout MK2PixelFrame) {
        for (index, x) in Self.rulerXs.dropLast().enumerated() {
            guard channels.indices.contains(index) else { continue }
            let channel = channels[index]
            BitmapLabel(channel.label, font: .label, color: channel.isFocused ? colors.channelLabelFocused : colors.channelLabel)
                .draw(into: &frame, x: x, y: Self.headerLabelY, clip: MK2PixelRect(x: x, y: Self.headerLabelY, width: 66, height: SurfaceFont.label.cellHeight))
            toggleDisplay("M", x: x + 69, accent: colors.muteAccent, border: colors.muteBorder).draw(isOn: channel.isMuted, into: &frame)
            toggleDisplay("S", x: x + 87, accent: colors.soloAccent, border: colors.soloBorder).draw(isOn: channel.isSoloed, into: &frame)
        }
        frame.hline(y: Self.separatorY, x: 0, width: MK2PixelFrame.width, color: colors.separator)
    }

    private func toggleDisplay(_ label: String, x: Int, accent: UInt16, border: UInt16) -> MK2ButtonToggleDisplay {
        MK2ButtonToggleDisplay(
            label: label,
            rect: MK2PixelRect(x: x, y: Self.toggleY, width: 14, height: 16),
            font: .label,
            colors: MK2ButtonToggleDisplayColors(
                onFill: accent,
                onBorder: border,
                onText: colors.channelButtonActiveText,
                offFill: colors.channelButtonFill,
                offBorder: colors.channelButtonBorder,
                offText: accent
            )
        )
    }

    private func drawRows(into frame: inout MK2PixelFrame) {
        for (visibleIndex, row) in rows.enumerated() {
            let y = Self.gridTop + visibleIndex * Self.rowHeight
            let isPlayhead = row.index == selectedRowIndex
            if isPlayhead {
                frame.fill(MK2PixelRect(x: 0, y: y, width: MK2PixelFrame.width, height: Self.rowHeight), isPlaying ? colors.playheadFill : colors.cursorFill)
                frame.fill(MK2PixelRect(x: Self.rulerXs[0], y: y, width: 5, height: Self.rowHeight), colors.playheadMarker)
            } else if beatStripe.matches(row.index) {
                frame.fill(MK2PixelRect(x: 0, y: y, width: MK2PixelFrame.width, height: Self.rowHeight), colors.beatStripe)
            }

            BitmapLabel(Self.hex2(row.index), font: .grid, color: isPlayhead ? colors.rowIndexHighlighted : colors.rowIndex)
                .draw(into: &frame, x: Self.rowIndexX, y: y)
            for channel in 0..<min(4, row.cells.count) {
                drawCell(
                    row.cells[channel],
                    into: &frame,
                    x: Self.channelXs[channel],
                    y: y,
                    highlighted: isPlayhead,
                    focusedColumn: channels.indices.contains(channel) && channels[channel].isFocused
                )
            }
        }
    }

    private func drawCell(_ cell: Cell, into frame: inout MK2PixelFrame, x: Int, y: Int, highlighted: Bool, focusedColumn: Bool) {
        if focusedColumn, !highlighted {
            frame.fill(MK2PixelRect(x: x - 4, y: y, width: 92, height: Self.rowHeight), colors.focusedChannelFill)
        }
        let noteColor = highlighted ? colors.highlightedText : (cell.note == nil ? colors.empty : colors.note)
        let instColor = highlighted ? colors.highlightedText : (cell.instrument == nil ? colors.empty : colors.instrument)
        let fxColor = highlighted ? colors.highlightedText : (cell.effect == nil ? colors.empty : colors.effect)
        BitmapLabel(cell.note ?? Self.notePlaceholder, font: .grid, color: noteColor).draw(into: &frame, x: x, y: y)
        BitmapLabel(cell.instrument ?? Self.instrumentPlaceholder, font: .grid, color: instColor).draw(into: &frame, x: x + 38, y: y)
        BitmapLabel(cell.effect ?? Self.effectPlaceholder, font: .grid, color: fxColor).draw(into: &frame, x: x + 64, y: y)
    }

    private func drawRulers(into frame: inout MK2PixelFrame) {
        for x in Self.rulerXs {
            frame.dottedVLine(x: x, y: 50, height: 218, color: colors.ruler)
        }
    }

    static func hex2(_ value: Int) -> String {
        String(format: "%02X", max(0, min(255, value)))
    }
}

private extension Int {
    func floorMod(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

/// The hardware-approved pattern-grid palette (signed off 2026-07-13). Defaults
/// are the single source of truth for the tracker identity shared by Paulinche
/// and the widget lab; callers override only to theme.
public struct MK2PatternGridColors: Sendable, Equatable {
    // Row backgrounds
    public var beatStripe: UInt16
    public var cursorFill: UInt16
    public var playheadFill: UInt16
    public var focusedChannelFill: UInt16
    public var playheadMarker: UInt16
    // Row-index gutter
    public var rowIndex: UInt16
    public var rowIndexHighlighted: UInt16
    // Cell fields
    public var note: UInt16
    public var instrument: UInt16
    public var effect: UInt16
    public var empty: UInt16
    public var highlightedText: UInt16
    // Channel header band
    public var channelLabel: UInt16
    public var channelLabelFocused: UInt16
    public var ruler: UInt16
    public var separator: UInt16
    // Mute/solo indicators
    public var muteAccent: UInt16
    public var muteBorder: UInt16
    public var soloAccent: UInt16
    public var soloBorder: UInt16
    public var channelButtonFill: UInt16
    public var channelButtonBorder: UInt16
    public var channelButtonActiveText: UInt16

    public init(
        beatStripe: UInt16 = 0x1083,
        cursorFill: UInt16 = 0x19aa,
        playheadFill: UInt16 = 0x1125,
        focusedChannelFill: UInt16 = 0x1026,
        playheadMarker: UInt16 = 0x464f,
        rowIndex: UInt16 = 0x8410,
        rowIndexHighlighted: UInt16 = 0xffff,
        note: UInt16 = 0xdedf,
        instrument: UInt16 = 0x95f2,
        effect: UInt16 = 0xec88,
        empty: UInt16 = 0x4a69,
        highlightedText: UInt16 = 0xffff,
        channelLabel: UInt16 = 0x8410,
        channelLabelFocused: UInt16 = 0x7dbf,
        ruler: UInt16 = 0x632e,
        separator: UInt16 = 0x4208,
        muteAccent: UInt16 = 0xf8c3,
        muteBorder: UInt16 = 0xf800,
        soloAccent: UInt16 = 0x03ff,
        soloBorder: UInt16 = 0x5dff,
        channelButtonFill: UInt16 = 0x1083,
        channelButtonBorder: UInt16 = 0x4208,
        channelButtonActiveText: UInt16 = 0xffff
    ) {
        self.beatStripe = beatStripe
        self.cursorFill = cursorFill
        self.playheadFill = playheadFill
        self.focusedChannelFill = focusedChannelFill
        self.playheadMarker = playheadMarker
        self.rowIndex = rowIndex
        self.rowIndexHighlighted = rowIndexHighlighted
        self.note = note
        self.instrument = instrument
        self.effect = effect
        self.empty = empty
        self.highlightedText = highlightedText
        self.channelLabel = channelLabel
        self.channelLabelFocused = channelLabelFocused
        self.ruler = ruler
        self.separator = separator
        self.muteAccent = muteAccent
        self.muteBorder = muteBorder
        self.soloAccent = soloAccent
        self.soloBorder = soloBorder
        self.channelButtonFill = channelButtonFill
        self.channelButtonBorder = channelButtonBorder
        self.channelButtonActiveText = channelButtonActiveText
    }
}
