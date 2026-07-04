import Foundation
import KompleteKontrol

/// A hardware button that toggles a Boolean value and keeps its lamp state with
/// the binding. Optionally, the same toggle can render a small display button.
public struct MK2ButtonToggle: Sendable {
    public var button: KKMK2ButtonLED
    public var isOn: Bool
    public var onLamp: MK2LampState2
    public var offLamp: MK2LampState2
    public var display: MK2ButtonToggleDisplay?

    private let onToggle: @Sendable (_ isOn: Bool) -> Void

    public init(
        button: KKMK2ButtonLED,
        isOn: Bool,
        onLamp: MK2LampState2 = .white,
        offLamp: MK2LampState2 = .off,
        display: MK2ButtonToggleDisplay? = nil,
        onToggle: @escaping @Sendable (_ isOn: Bool) -> Void = { _ in }
    ) {
        self.button = button
        self.isOn = isOn
        self.onLamp = onLamp
        self.offLamp = offLamp
        self.display = display
        self.onToggle = onToggle
    }

    public var toggledValue: Bool {
        !isOn
    }

    public func apply(
        lamps: inout [KKMK2ButtonLED: MK2LampState2],
        bindings: inout MK2InputBindings2
    ) {
        lamps[button] = isOn ? onLamp : offLamp
        bindings.onPress(button) {
            onToggle(toggledValue)
        }
    }

    public func drawDisplay(into frame: inout MK2PixelFrame) {
        display?.draw(isOn: isOn, into: &frame)
    }
}

public struct MK2ButtonToggleDisplay: Sendable {
    public var label: String
    public var rect: MK2PixelRect
    public var font: SurfaceFont
    public var colors: MK2ButtonToggleDisplayColors

    public init(
        label: String,
        rect: MK2PixelRect,
        font: SurfaceFont = .label,
        colors: MK2ButtonToggleDisplayColors
    ) {
        self.label = label
        self.rect = rect
        self.font = font
        self.colors = colors
    }

    public func draw(isOn: Bool, into frame: inout MK2PixelFrame) {
        frame.fill(rect, isOn ? colors.onFill : colors.offFill)
        frame.stroke(rect, isOn ? colors.onBorder : colors.offBorder)

        let glyph = BitmapLabel(label, font: font, color: isOn ? colors.onText : colors.offText)
        glyph.draw(
            into: &frame,
            x: rect.x + max(0, (rect.width - glyph.width) / 2),
            y: rect.y + max(0, (rect.height - glyph.height) / 2)
        )
    }
}

public struct MK2ButtonToggleDisplayColors: Sendable, Equatable {
    public var onFill: UInt16
    public var onBorder: UInt16
    public var onText: UInt16
    public var offFill: UInt16
    public var offBorder: UInt16
    public var offText: UInt16

    public init(
        onFill: UInt16,
        onBorder: UInt16,
        onText: UInt16 = 0xffff,
        offFill: UInt16,
        offBorder: UInt16,
        offText: UInt16
    ) {
        self.onFill = onFill
        self.onBorder = onBorder
        self.onText = onText
        self.offFill = offFill
        self.offBorder = offBorder
        self.offText = offText
    }
}
