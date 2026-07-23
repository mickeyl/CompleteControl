import Foundation
import KompleteKontrol

/// One labeled slot in a `MK2FunctionKeyBarElement`. An empty label (and no
/// icon) leaves the slot dark; a disabled slot shows its content dimmed and
/// never binds; a selected slot uses the accent treatment; a destructive slot
/// uses the semantic warning color. An optional leading Phosphor icon (see
/// `MK2HIG.IconGlyph`) makes frequent actions read faster — COPY, PASTE, CLEAR,
/// TRIM.
public struct MK2FunctionKeySlot: Sendable, Equatable {
    public var label: String
    public var iconGlyph: String?
    public var isEnabled: Bool
    public var isSelected: Bool
    public var isDestructive: Bool

    public init(
        _ label: String = "",
        iconGlyph: String? = nil,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        isDestructive: Bool = false
    ) {
        self.label = label
        self.iconGlyph = iconGlyph
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.isDestructive = isDestructive
    }

    public var isEmpty: Bool { label.isEmpty && iconGlyph == nil }
}

/// The canonical function-key bar: labels for the four physical buttons that
/// sit directly above each display. Top-flush for the same reason the encoder
/// cells are bottom-flush — the label must read as belonging to the hardware
/// control above it — and the slots reuse the encoder grid's Xs and width so
/// the top and bottom hardware rows form one aligned system.
///
/// The element owns both drawing and button bindings: pass `onPress` and each
/// enabled, non-empty slot binds its physical button (left screen → F1–F4,
/// right screen → F5–F8) with the slot index within this bar.
///
/// `style` matches the bar to the facing display's header: `.plain` is the flat
/// strip for dense/plain-top screens (the pattern editor), `.chromeBand` is a
/// raised chrome band the height of a status/title header with each mapping as
/// an embossed chip, so a screen with a chrome header reads as one system.
///
/// Passing `shiftSlots` declares a shift layer for the bar: while SHIFT is
/// held the bar shows the shift labels (accent-tinted) and routes presses to
/// `onShiftPress`. A shift slot that is empty or disabled swallows the press —
/// the base action must never fire behind a label that does not announce it.
public struct MK2FunctionKeyBarElement: MK2ScreenElement {
    public static let plainHeight = 20
    /// The height of a default status/title chrome header, so `.chromeBand`
    /// lines up with a header on the facing display.
    public static var chromeBandHeight: Int { MK2HIG.Typography.captionPixelSize * 2 + 2 }

    public enum Style: Sendable, Equatable {
        /// Flat strip, content centered — the plain content-top look.
        case plain
        /// Raised chrome band with embossed per-mapping chips.
        case chromeBand
    }

    public enum Side: Sendable, Equatable {
        case left
        case right

        var buttons: [KKMK2ButtonLED] {
            switch self {
                case .left: [.function1, .function2, .function3, .function4]
                case .right: [.function5, .function6, .function7, .function8]
            }
        }
    }

    public var slots: [MK2FunctionKeySlot]
    public var shiftSlots: [MK2FunctionKeySlot]?
    public var side: Side
    public var style: Style
    private let onPress: (@Sendable (_ slot: Int) -> Void)?
    private let onShiftPress: (@Sendable (_ slot: Int) -> Void)?

    public var height: Int { style == .plain ? Self.plainHeight : Self.chromeBandHeight }

    public init(
        slots: [MK2FunctionKeySlot],
        side: Side,
        style: Style = .plain,
        onPress: (@Sendable (_ slot: Int) -> Void)? = nil
    ) {
        self.slots = Array(slots.prefix(4))
        shiftSlots = nil
        self.side = side
        self.style = style
        self.onPress = onPress
        onShiftPress = nil
    }

    public init(
        slots: [MK2FunctionKeySlot],
        shiftSlots: [MK2FunctionKeySlot],
        side: Side,
        style: Style = .plain,
        onPress: (@Sendable (_ slot: Int) -> Void)? = nil,
        onShiftPress: (@Sendable (_ slot: Int) -> Void)? = nil
    ) {
        self.slots = Array(slots.prefix(4))
        self.shiftSlots = Array(shiftSlots.prefix(4))
        self.side = side
        self.style = style
        self.onPress = onPress
        self.onShiftPress = onShiftPress
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        if shiftSlots != nil {
            result.wantsShiftPass = true
        }
        if context.isShiftPass, let shiftSlots {
            draw(shiftSlots, into: &frame, labelColor: MK2HIG.Chrome.shiftAccent, renderer: context.renderer)
            bindShift(shiftSlots, result: &result)
        } else {
            draw(slots, into: &frame, labelColor: MK2HIG.Chrome.text, renderer: context.renderer)
            bindBase(result: &result)
        }
    }

    private func bindBase(result: inout MK2ScreenBuildResult) {
        guard let onPress else { return }
        let buttons = side.buttons
        for (index, slot) in slots.enumerated() where slot.isEnabled && !slot.isEmpty {
            result.bindings.onPress(buttons[index], modifiers: .any) {
                onPress(index)
            }
        }
    }

    private func bindShift(_ shiftSlots: [MK2FunctionKeySlot], result: inout MK2ScreenBuildResult) {
        for (index, button) in side.buttons.enumerated() {
            let slot = shiftSlots.indices.contains(index) ? shiftSlots[index] : MK2FunctionKeySlot()
            if slot.isEnabled, !slot.isEmpty, let onShiftPress {
                result.bindings.onPress(button, modifiers: .any) {
                    onShiftPress(index)
                }
            } else {
                // Swallow the press: without this, the layer's binding fallback
                // would fire the base action behind an empty or disabled label.
                result.bindings.onPress(button, modifiers: .any) {}
            }
        }
    }

    // MARK: - Drawing

    private func draw(_ slots: [MK2FunctionKeySlot], into frame: inout MK2PixelFrame, labelColor: UInt16, renderer: FreeTypeTextRenderer?) {
        let height = self.height
        switch style {
            case .plain:
                frame.fill(MK2PixelRect(x: 0, y: 0, width: MK2PixelFrame.width, height: height), MK2HIG.Chrome.headerFill)
                frame.fill(MK2PixelRect(x: 0, y: height - 1, width: MK2PixelFrame.width, height: 1), MK2HIG.Chrome.headerBottomLine)
            case .chromeBand:
                let band = MK2PixelRect(x: 0, y: 0, width: MK2PixelFrame.width, height: height)
                frame.fillRoundedVerticalGradient(
                    band,
                    radius: 0,
                    top: MK2HIG.Chrome.headerFill.scaled565(by: 1.4),
                    bottom: MK2HIG.Chrome.headerFill.scaled565(by: 0.6)
                )
                frame.fill(MK2PixelRect(x: 0, y: 0, width: MK2PixelFrame.width, height: 1), MK2HIG.Chrome.headerTopLine)
                frame.fill(MK2PixelRect(x: 0, y: height - 1, width: MK2PixelFrame.width, height: 1), MK2HIG.Chrome.headerBottomLine)
        }

        for (index, slot) in slots.enumerated() where !slot.isEmpty {
            let slotX = MK2ScreenLayout.encoderSlotXs[index]
            let slotWidth = MK2ScreenLayout.encoderSlotWidth
            let color: UInt16 = if !slot.isEnabled {
                MK2HIG.Chrome.dim
            } else if slot.isSelected {
                0x0000
            } else if slot.isDestructive {
                MK2HIG.Chrome.destructive
            } else {
                labelColor
            }

            if style == .chromeBand {
                // Embossed chip: raised bevel (lit from above), the opposite of
                // the debossed value wells — soft keys are pressable.
                let chip = MK2PixelRect(x: slotX + 3, y: 3, width: slotWidth - 6, height: height - 7)
                frame.fillRoundedVerticalGradient(
                    chip,
                    radius: 5,
                    top: slot.isSelected
                        ? MK2HIG.Chrome.accent.scaled565(by: 1.25)
                        : MK2HIG.Chrome.headerFill.scaled565(by: 1.8),
                    bottom: slot.isSelected
                        ? MK2HIG.Chrome.accent.scaled565(by: 0.75)
                        : MK2HIG.Chrome.headerFill.scaled565(by: 0.9),
                    antialiased: true
                )
                frame.fill(
                    MK2PixelRect(x: chip.x + 2, y: chip.y, width: chip.width - 4, height: 1),
                    slot.isSelected ? MK2HIG.Chrome.accent : MK2HIG.Chrome.headerTopLine
                )
            } else if slot.isSelected {
                frame.fill(
                    MK2PixelRect(x: slotX + 2, y: 2, width: slotWidth - 4, height: height - 4),
                    MK2HIG.Chrome.accent
                )
            }

            drawSlotContent(slot, slotX: slotX, slotWidth: slotWidth, height: height, color: color, renderer: renderer, into: &frame)
        }
    }

    /// Icon (optional, leading) plus label, centered in the slot.
    private func drawSlotContent(_ slot: MK2FunctionKeySlot, slotX: Int, slotWidth: Int, height: Int, color: UInt16, renderer: FreeTypeTextRenderer?, into frame: inout MK2PixelFrame) {
        let font = SurfaceFont.label
        let iconSize = min(14, height - 6)
        let gap = 4

        let glyph = BitmapLabel(slot.label.uppercased(), font: font, color: color)
        let labelWidth = slot.label.isEmpty ? 0 : glyph.width

        var iconWidth = 0
        var iconStyle: FreeTypeTextStyle?
        if let iconGlyph = slot.iconGlyph, let renderer {
            let style = MK2HIG.iconStyle(pixelSize: iconSize, color: color)
            if let measured = try? renderer.measure(iconGlyph, style: style), measured > 0 {
                iconWidth = measured
                iconStyle = style
            }
        }

        let spacing = (iconWidth > 0 && labelWidth > 0) ? gap : 0
        let totalWidth = iconWidth + spacing + labelWidth
        var x = slotX + max(0, (slotWidth - totalWidth) / 2)
        let clip = MK2PixelRect(x: slotX, y: 0, width: slotWidth, height: height)
        let textY = max(0, (height - 1 - font.cellHeight) / 2) + 1

        if let iconGlyph = slot.iconGlyph, let iconStyle, let renderer, iconWidth > 0 {
            // Icon-only chips center the ink in the chip; labelled chips
            // anchor it to the label's cap band.
            let anchor = slot.label.isEmpty
                ? height / 2
                : MK2IconAlignment.capBandCenter(labelTop: textY, font: font, renderer: renderer) ?? height / 2
            let iconY = MK2IconAlignment.iconTop(glyph: iconGlyph, style: iconStyle, centeredOn: anchor, renderer: renderer)
                ?? max(0, (height - iconSize) / 2) - 1
            _ = try? renderer.drawText(iconGlyph, into: &frame, x: x, y: iconY, style: iconStyle, maxWidth: iconWidth + 4)
            x += iconWidth + spacing
        }
        if !slot.label.isEmpty {
            glyph.draw(into: &frame, x: x, y: textY, clip: clip)
        }
    }

}
