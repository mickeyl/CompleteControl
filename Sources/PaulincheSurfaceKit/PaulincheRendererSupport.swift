import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

enum MK2PaulincheRendererSupport {
    // The tracker palette developed in the MK2 widget lab (Tools/MK2WidgetLabDemo).
    enum Palette {
        static let background: UInt16 = 0x0841 // near-black blue
        static let text: UInt16 = 0xffff
        static let dim: UInt16 = 0x8410
        static let credit: UInt16 = 0xbdf7
        static let creditDim: UInt16 = 0x632c
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
        static let panelFill: UInt16 = 0x0845
        static let secondaryPanelFill: UInt16 = 0x0004
    }

    static func clamped01(_ value: Double) -> Double {
        Swift.max(0, Swift.min(1, value))
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

}
