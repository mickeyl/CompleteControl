import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

enum MK2PaulincheRendererSupport {
    enum Palette {
        static let background: UInt16 = MK2HIG.Chrome.background
        static let header: UInt16 = MK2HIG.Chrome.headerFill
        static let headerTop: UInt16 = MK2HIG.Chrome.headerTopLine
        static let headerBottom: UInt16 = MK2HIG.Chrome.headerBottomLine
        static let track: UInt16 = 0x2104
        static let selectedRow: UInt16 = 0x2128
        static let playbackRow: UInt16 = 0x082c
        static let softKeyFill: UInt16 = 0x0003
        static let panelFill: UInt16 = 0x0845
        static let secondaryPanelFill: UInt16 = 0x0004
    }

    static func clamped01(_ value: Double) -> Double {
        Swift.max(0, Swift.min(1, value))
    }

    static func drawHeader(
        title: String,
        subtitle: String,
        progress: Double?,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?
    ) {
        frame.fill(MK2PixelRect(x: 0, y: 0, width: MK2PixelFrame.width, height: 44), Palette.header)
        frame.fill(MK2PixelRect(x: 0, y: 0, width: MK2PixelFrame.width, height: 1), Palette.headerTop)
        frame.fill(MK2PixelRect(x: 0, y: 43, width: MK2PixelFrame.width, height: 1), Palette.headerBottom)
        drawText(title, into: &frame, x: 14, y: 8, style: titleStyle, renderer: renderer, maxWidth: 240)
        drawText(subtitle, into: &frame, x: 296, y: 13, style: captionStyle(color: MK2HIG.Chrome.dim), renderer: renderer, maxWidth: 168)

        guard let progress else { return }
        let track = MK2PixelRect(x: 14, y: 34, width: 452, height: 4)
        frame.fill(track, Palette.track)
        let progressWidth = Int((Double(track.width) * clamped01(progress)).rounded())
        if progressWidth > 0 {
            frame.fill(MK2PixelRect(x: track.x, y: track.y, width: min(track.width, progressWidth), height: track.height), MK2HIG.Chrome.accent)
        }
    }

    static func drawSoftKeyStrip(
        _ softKeys: [MK2PaulincheSoftKey],
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?,
        y: Int = 230,
        height: Int = 34
    ) {
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
            drawText(softKey.label.uppercased(), into: &frame, x: x + 6, y: y + max(4, (height - 14) / 2), style: captionStyle(color: color), renderer: renderer, maxWidth: slotWidth - 12)
        }
    }

    static func drawParameterSlots(
        _ parameters: [MK2PaulinchePatternParameter],
        in rect: MK2PixelRect,
        columns: Int = 4,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?
    ) {
        let columns = min(4, max(1, columns))
        let slots = Array(parameters.prefix(8))
        guard !slots.isEmpty, !rect.isEmpty else { return }

        let columnGap = 12
        let rowGap = 14
        let rows = max(1, Int((Double(slots.count) / Double(columns)).rounded(.up)))
        let cellWidth = max(1, (rect.width - columnGap * (columns - 1)) / columns)
        let cellHeight = max(30, min(58, (rect.height - rowGap * (rows - 1)) / rows))

        for (index, slot) in slots.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = rect.x + column * (cellWidth + columnGap)
            let y = rect.y + row * (cellHeight + rowGap)
            let valueRect = MK2PixelRect(x: x, y: y + 16, width: cellWidth, height: max(22, cellHeight - 16))
            let fill = slot.isFocused ? MK2HIG.Chrome.accent : MK2HIG.Chrome.background
            let border = slot.isFocused ? MK2HIG.Chrome.accent : MK2HIG.Chrome.border
            let valueColor = slot.isFocused ? UInt16(0x0000) : MK2HIG.Chrome.text
            frame.fillRounded(valueRect, radius: 5, fill, antialiased: true)
            frame.stroke(valueRect, border)
            drawText(slot.label.uppercased(), into: &frame, x: x + 2, y: y, style: captionStyle(color: MK2HIG.Chrome.dim), renderer: renderer, maxWidth: cellWidth - 4)
            drawText(slot.value, into: &frame, x: valueRect.x + 7, y: valueRect.y + 6, style: textStyle(weight: .bold, pixelSize: 18, color: valueColor), renderer: renderer, maxWidth: valueRect.width - 14)
        }
    }

    static func drawMeters(
        _ meters: [MK2PaulinchePatternMeter],
        in rect: MK2PixelRect,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?
    ) {
        guard !meters.isEmpty, !rect.isEmpty else { return }
        let gap = 4
        let channelHeight = max(4, (rect.height - gap * max(0, meters.count - 1)) / meters.count)
        let labelWidth = meters.contains { !$0.label.isEmpty } ? 34 : 0
        for (index, meter) in meters.enumerated() {
            let y = rect.y + index * (channelHeight + gap)
            if !meter.label.isEmpty {
                drawText(meter.label.uppercased(), into: &frame, x: rect.x, y: y + max(0, (channelHeight - 14) / 2), style: captionStyle(color: MK2HIG.Chrome.dim), renderer: renderer, maxWidth: max(0, labelWidth - 4))
            }
            let barRect = MK2PixelRect(x: rect.x + labelWidth, y: y, width: max(0, rect.width - labelWidth), height: channelHeight)
            frame.fill(barRect, MK2HIG.Chrome.footerFill)
            frame.stroke(barRect, MK2HIG.Chrome.border)
            let inner = MK2PixelRect(x: barRect.x + 1, y: barRect.y + 1, width: max(0, barRect.width - 2), height: max(0, barRect.height - 2))
            let level = clamped01(meter.level)
            let fillWidth = Int((Double(inner.width) * level).rounded())
            if fillWidth > 0 {
                frame.fill(MK2PixelRect(x: inner.x, y: inner.y, width: min(inner.width, fillWidth), height: inner.height), meterFillColor(for: level))
            }
            if let peak = meter.peak {
                let peakX = inner.x + Int((Double(max(0, inner.width - 1)) * clamped01(peak)).rounded())
                frame.fill(MK2PixelRect(x: peakX, y: inner.y, width: 2, height: inner.height), MK2HIG.Chrome.text)
            }
        }
    }

    static func softKeyBindings(
        _ softKeys: [MK2PaulincheSoftKey],
        onSoftKey: (@Sendable (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void)?
    ) -> [any MK2ScreenElement] {
        guard let onSoftKey else { return [] }
        return softKeys.enumerated().compactMap { index, softKey in
            guard softKey.isEnabled, let button = functionButton(at: index) else { return nil }
            return MK2ButtonBindingElement(button) {
                onSoftKey(index, softKey)
            }
        }
    }

    static func drawText(
        _ text: String,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        style: FreeTypeTextStyle,
        renderer: FreeTypeTextRenderer?,
        maxWidth: Int
    ) {
        guard let renderer else { return }
        _ = try? renderer.drawText(text, into: &frame, x: x, y: y, style: style, maxWidth: maxWidth)
    }

    static func drawWrappedText(
        _ text: String,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        style: FreeTypeTextStyle,
        renderer: FreeTypeTextRenderer?,
        maxWidth: Int,
        maxLines: Int,
        lineSpacing: Int = 1
    ) {
        guard let renderer else { return }
        _ = try? renderer.drawWrappedText(text, into: &frame, x: x, y: y, style: style, maxWidth: maxWidth, maxLines: maxLines, lineSpacing: lineSpacing)
    }

    static let titleStyle = MK2HIG.textStyle(
        weight: .medium,
        pixelSize: 16,
        color: MK2HIG.Chrome.text
    )

    static func captionStyle(color: UInt16) -> FreeTypeTextStyle {
        MK2HIG.textStyle(weight: .medium, pixelSize: 12, color: color)
    }

    static func bodyStyle(color: UInt16) -> FreeTypeTextStyle {
        MK2HIG.bodyTextStyle(color: color)
    }

    static func monoBodyStyle(color: UInt16) -> FreeTypeTextStyle {
        FreeTypeTextStyle(
            familyID: MK2HIG.Fonts.monoFamilyID,
            weight: .regular,
            pixelSize: 13,
            color: color,
            rasterMode: MK2HIG.Fonts.rasterMode
        )
    }

    static func monoCaptionStyle(color: UInt16) -> FreeTypeTextStyle {
        FreeTypeTextStyle(
            familyID: MK2HIG.Fonts.monoFamilyID,
            weight: .bold,
            pixelSize: 11,
            color: color,
            rasterMode: MK2HIG.Fonts.rasterMode
        )
    }

    static func textStyle(weight: FreeTypeFontWeight, pixelSize: Int, color: UInt16) -> FreeTypeTextStyle {
        MK2HIG.textStyle(weight: weight, pixelSize: pixelSize, color: color)
    }

    private static func meterFillColor(for level: Double) -> UInt16 {
        if level >= 0.92 { return 0xf8c3 }
        if level >= 0.72 { return MK2HIG.Chrome.accent }
        return 0x464f
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
}
