import Foundation
import KontrolSurfaceKit2

func labDiagnostic(_ message: String) {
    if CommandLine.arguments.contains("--control-stdin") {
        fputs(message + "\n", stderr)
        fflush(stderr)
    } else {
        print(message)
    }
}

/// Shared lab look: the palette every demo composes from, plus the small
/// helpers demos share. Internal so per-demo files stay palette-consistent.
enum Palette {
    static let page = MK2HIG.Chrome.background
    static let text = MK2HIG.Chrome.text
    static let dim = MK2HIG.Chrome.dim
    static let accent = MK2HIG.Chrome.accent
    static let border = MK2HIG.Chrome.border
    static let blue = MK2HIG.Chrome.accent
    static let green: UInt16 = 0x464f
    static let orange: UInt16 = 0xec88
    static let question: UInt16 = 0x9a7f
    static let solo: UInt16 = 0x03ff
    static let soloBorder: UInt16 = 0x5dff
    static let mute: UInt16 = 0xf8c3
    static let muteBorder: UInt16 = 0xf800
    static let note: UInt16 = 0xdedf
    static let instrument: UInt16 = 0x95f2
    static let effect: UInt16 = 0xec88
    static let empty: UInt16 = 0x4a69
    static let ruler: UInt16 = 0x632e
    static let rowStripe: UInt16 = 0x1083
    static let cursorFill: UInt16 = 0x19aa
    static let playheadFill: UInt16 = 0x1125
    static let focusedChannelFill: UInt16 = 0x1026
    static let channelButtonFill: UInt16 = 0x1083
    static let channelButtonBorder: UInt16 = 0x4208
    static let channelButtonActiveText: UInt16 = 0xffff
    static let editFieldFill: UInt16 = 0x1083
    static let editFieldFocusedFill: UInt16 = 0xc618
    static let track: UInt16 = 0x2126
    static let dialogSurface = MK2HIG.Chrome.headerFill
    static let selectionFill = MK2HIG.Selection.fill
    static let filterFill = MK2HIG.Chrome.footerFill
}

func labEditCellColors(value: UInt16) -> MK2ValueCellColors {
    MK2ValueCellColors(
        label: Palette.dim,
        value: value,
        border: Palette.border,
        fill: Palette.editFieldFill,
        focusedValue: 0x0000,
        focusedFill: Palette.editFieldFocusedFill,
        focusedBorder: Palette.text
    )
}

extension Int {
    func wrapped(to bounds: ClosedRange<Int>) -> Int {
        let count = bounds.upperBound - bounds.lowerBound + 1
        guard count > 0 else { return bounds.lowerBound }
        let raw = (self - bounds.lowerBound) % count
        let offset = raw >= 0 ? raw : raw + count
        return bounds.lowerBound + offset
    }
}

// MARK: - FreeType drawing helpers (shared by demos and legacy units)

func drawFreeTypeTitle(
    _ text: String,
    into frame: inout MK2PixelFrame,
    renderer freeTypeRenderer: FreeTypeTextRenderer?,
    x: Int,
    y: Int,
    size: Int,
    color: UInt16,
    maxWidth: Int
) {
    drawFreeTypeText(text, into: &frame, renderer: freeTypeRenderer, x: x, y: y, size: size, weight: MK2HIG.Fonts.titleWeight, color: color, maxWidth: maxWidth)
}

@discardableResult
func drawFreeTypeBody(
    _ text: String,
    into frame: inout MK2PixelFrame,
    renderer freeTypeRenderer: FreeTypeTextRenderer?,
    x: Int,
    y: Int,
    size: Int,
    color: UInt16,
    maxWidth: Int,
    maxLines: Int = 1
) -> Int {
    drawFreeTypeText(text, into: &frame, renderer: freeTypeRenderer, x: x, y: y, size: size, weight: MK2HIG.Fonts.bodyWeight, color: color, maxWidth: maxWidth, maxLines: maxLines)
}

@discardableResult
func drawFreeTypeText(
    _ text: String,
    into frame: inout MK2PixelFrame,
    renderer freeTypeRenderer: FreeTypeTextRenderer?,
    x: Int,
    y: Int,
    size: Int,
    weight: FreeTypeFontWeight,
    color: UInt16,
    maxWidth: Int,
    maxLines: Int = 1
) -> Int {
    let style = MK2HIG.textStyle(
        weight: weight,
        pixelSize: size,
        color: color
    )
    let lineAdvance = freeTypeLineAdvance(size: size)
    let lineLimit = max(1, maxLines)

    if let freeTypeRenderer {
        if lineLimit == 1,
           (try? freeTypeRenderer.drawText(text, into: &frame, x: x, y: y, style: style, maxWidth: maxWidth)) != nil {
            return 1
        }
        if let layout = try? freeTypeRenderer.wrappedLayout(text, style: style, maxWidth: maxWidth) {
            let count = min(lineLimit, max(1, layout.lines.count))
            for index in 0..<count {
                let line = layout.lines.indices.contains(index) ? layout.lines[index] : ""
                try? freeTypeRenderer.drawText(line, into: &frame, x: x, y: y + index * lineAdvance, style: style, maxWidth: maxWidth)
            }
            return count
        }
    }

    let font: SurfaceFont = weight == MK2HIG.Fonts.titleWeight ? .gridBold : .grid
    let lines = wrappedBitmapLines(text, font: font, maxWidth: maxWidth)
    let count = min(lineLimit, max(1, lines.count))
    for index in 0..<count {
        let line = lines.indices.contains(index) ? lines[index] : ""
        BitmapLabel(line, font: font, color: color)
            .draw(into: &frame, x: x, y: y + index * lineAdvance + 3, clip: MK2PixelRect(x: x, y: y + index * lineAdvance, width: maxWidth, height: max(18, size + 6)))
    }
    return count
}

func freeTypeLineAdvance(size: Int) -> Int {
    max(18, size + 4)
}

func wrappedBitmapLines(_ text: String, font: SurfaceFont, maxWidth: Int) -> [String] {
    let words = text
        .split(whereSeparator: { $0.unicodeScalars.allSatisfy(\.properties.isWhitespace) })
        .map(String.init)
    guard !words.isEmpty else { return text.isEmpty ? [] : [""] }

    var lines: [String] = []
    var current = ""
    for word in words {
        let candidate = current.isEmpty ? word : current + " " + word
        if font.measure(candidate) <= maxWidth {
            current = candidate
        } else {
            if !current.isEmpty { lines.append(current) }
            current = word
        }
    }
    if !current.isEmpty {
        lines.append(current)
    }
    return lines
}

func drawFreeTypeIcon(
    _ glyph: String,
    into frame: inout MK2PixelFrame,
    renderer freeTypeRenderer: FreeTypeTextRenderer?,
    x: Int,
    y: Int,
    size: Int,
    color: UInt16
) {
    let style = MK2HIG.iconStyle(pixelSize: size, color: color)
    guard let freeTypeRenderer,
          (try? freeTypeRenderer.drawText(glyph, into: &frame, x: x, y: y, style: style, maxWidth: max(80, size + 20))) != nil else {
        BitmapLabel("?", font: .readoutBold, color: color)
            .draw(into: &frame, x: x + 12, y: y + 14)
        return
    }
}

func drawFreeTypeIconCentered(
    _ glyph: String,
    into frame: inout MK2PixelFrame,
    renderer freeTypeRenderer: FreeTypeTextRenderer?,
    centerX: Int,
    y: Int,
    size: Int,
    color: UInt16
) {
    let style = MK2HIG.iconStyle(pixelSize: size, color: color)
    let width = (try? freeTypeRenderer?.measure(glyph, style: style)) ?? size
    guard let freeTypeRenderer,
          (try? freeTypeRenderer.drawText(glyph, into: &frame, x: centerX - width / 2, y: y, style: style, maxWidth: max(80, size + 20))) != nil else {
        BitmapLabel("?", font: .readoutBold, color: color)
            .draw(into: &frame, x: centerX - 8, y: y + 14)
        return
    }
}


struct ReplCommand {
    let name: String
    let arg: String
    let summary: String
    let values: [String] // completion candidates for the first argument (empty = free/none)
}
