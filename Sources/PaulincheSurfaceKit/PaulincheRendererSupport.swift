import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

enum MK2PaulincheRendererSupport {
    // The tracker palette developed in the MK2 widget lab (Tools/MK2WidgetLabDemo).
    enum Palette {
        static let background: UInt16 = 0x0841 // near-black blue
        static let text: UInt16 = 0xffff
        static let dim: UInt16 = 0x8410
        static let border: UInt16 = 0x4208
        static let blue: UInt16 = 0x7dbf
        static let green: UInt16 = 0x464f
        static let orange: UInt16 = 0xec88
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
        static let selectedRow: UInt16 = 0x2128
        static let playbackRow: UInt16 = 0x082c
        static let softKeyFill: UInt16 = 0x0003
        static let panelFill: UInt16 = 0x0845
        static let secondaryPanelFill: UInt16 = 0x0004
    }

    static func clamped01(_ value: Double) -> Double {
        Swift.max(0, Swift.min(1, value))
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

extension MK2PixelFrame {
    mutating func hline(y: Int, x: Int, width: Int, color: UInt16) {
        fill(MK2PixelRect(x: x, y: y, width: width, height: 1), color)
    }

    mutating func dottedVLine(x: Int, y: Int, height: Int, color: UInt16) {
        var offset = 0
        while offset < height {
            fill(MK2PixelRect(x: x, y: y + offset, width: 1, height: 1), color)
            offset += 2
        }
    }
}
