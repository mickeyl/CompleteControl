import Foundation
import KompleteKontrol

/// One labeled slot in a `MK2FunctionKeyBarElement`. An empty label leaves the
/// slot dark; a disabled slot shows its label dimmed and never binds.
public struct MK2FunctionKeySlot: Sendable, Equatable {
    public var label: String
    public var isEnabled: Bool

    public init(_ label: String = "", isEnabled: Bool = true) {
        self.label = label
        self.isEnabled = isEnabled
    }

    public var isEmpty: Bool { label.isEmpty }
}

/// The canonical function-key bar: labels for the four physical buttons that
/// sit directly above each display. Top-flush for the same reason the encoder
/// cells are bottom-flush — the label must read as belonging to the hardware
/// control above it — and the slots reuse the encoder grid's Xs and width so
/// the top and bottom hardware rows form one aligned system.
///
/// The element owns both drawing and button bindings: pass `onPress` and each
/// enabled, labeled slot binds its physical button (left screen → F1–F4,
/// right screen → F5–F8) with the slot index within this bar.
public struct MK2FunctionKeyBarElement: MK2ScreenElement {
    public static let barHeight = 20

    public enum Side: Sendable {
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
    public var side: Side
    private let onPress: (@Sendable (_ slot: Int) -> Void)?

    public init(
        slots: [MK2FunctionKeySlot],
        side: Side,
        onPress: (@Sendable (_ slot: Int) -> Void)? = nil
    ) {
        self.slots = Array(slots.prefix(4))
        self.side = side
        self.onPress = onPress
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        draw(into: &frame)
        guard let onPress else { return }
        let buttons = side.buttons
        for (index, slot) in slots.enumerated() where slot.isEnabled && !slot.isEmpty {
            result.bindings.onPress(buttons[index], modifiers: .any) {
                onPress(index)
            }
        }
    }

    private func draw(into frame: inout MK2PixelFrame) {
        let height = Self.barHeight
        frame.fill(MK2PixelRect(x: 0, y: 0, width: MK2PixelFrame.width, height: height), MK2HIG.Chrome.headerFill)
        frame.fill(MK2PixelRect(x: 0, y: height - 1, width: MK2PixelFrame.width, height: 1), MK2HIG.Chrome.headerBottomLine)
        let font = SurfaceFont.label
        let textY = max(0, (height - 1 - font.cellHeight) / 2) + 1
        for (index, slot) in slots.enumerated() where !slot.isEmpty {
            let slotX = MK2ScreenLayout.encoderSlotXs[index]
            let slotWidth = MK2ScreenLayout.encoderSlotWidth
            let color = slot.isEnabled ? MK2HIG.Chrome.text : MK2HIG.Chrome.dim
            let glyph = BitmapLabel(slot.label.uppercased(), font: font, color: color)
            let x = slotX + max(0, (slotWidth - glyph.width) / 2)
            glyph.draw(
                into: &frame,
                x: x,
                y: textY,
                clip: MK2PixelRect(x: slotX, y: 0, width: slotWidth, height: height)
            )
        }
    }
}
