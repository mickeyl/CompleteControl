import Foundation
import KompleteKontrol

public struct MK2ModalDialogAction: Sendable, Equatable {
    public var title: String
    public var detail: String?

    public init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

public struct MK2ModalDialogColors: Sendable, Equatable {
    public var background: UInt16
    public var text: UInt16
    public var dim: UInt16
    public var accent: UInt16
    public var destructive: UInt16
    public var selectionFill: UInt16
    public var border: UInt16

    public init(
        background: UInt16 = 0x0000,
        text: UInt16 = 0xffff,
        dim: UInt16 = 0x8410,
        accent: UInt16 = 0x7dbf,
        destructive: UInt16 = 0xec88,
        selectionFill: UInt16 = 0x2126,
        border: UInt16 = 0x4208
    ) {
        self.background = background
        self.text = text
        self.dim = dim
        self.accent = accent
        self.destructive = destructive
        self.selectionFill = selectionFill
        self.border = border
    }
}

/// A modal surface dialog that owns both displays and the relevant hardware bindings.
///
/// The dialog is intentionally strict: 4-D wheel up/down and rotation move selection,
/// 4-D press confirms, and every other hardware button press dismisses the dialog.
public struct MK2ModalDialog: Sendable {
    public var iconPlaceholder: String
    public var title: String
    public var message: [String]
    public var actions: [MK2ModalDialogAction]
    public var selectedIndex: Int
    public var dismissHint: String
    public var colors: MK2ModalDialogColors

    private let onSelectionChange: @Sendable (_ index: Int) -> Void
    private let onConfirm: @Sendable (_ index: Int) -> Void
    private let onDismiss: @Sendable () -> Void

    public init(
        iconPlaceholder: String = "[!]",
        title: String,
        message: [String],
        actions: [MK2ModalDialogAction],
        selectedIndex: Int = 0,
        dismissHint: String = "Any other hardware button cancels.",
        colors: MK2ModalDialogColors = MK2ModalDialogColors(),
        onSelectionChange: @escaping @Sendable (_ index: Int) -> Void,
        onConfirm: @escaping @Sendable (_ index: Int) -> Void,
        onDismiss: @escaping @Sendable () -> Void
    ) {
        self.iconPlaceholder = iconPlaceholder
        self.title = title
        self.message = message
        self.actions = actions
        self.selectedIndex = selectedIndex
        self.dismissHint = dismissHint
        self.colors = colors
        self.onSelectionChange = onSelectionChange
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
    }

    public func scene() -> MK2SurfaceScene2 {
        var bindings = MK2InputBindings2()
        bindNavigation(into: &bindings)
        bindDismissButtons(into: &bindings)
        return MK2SurfaceScene2(
            left: leftFrame(),
            right: rightFrame(),
            lamps: [:],
            bindings: bindings
        )
    }

    private func bindNavigation(into bindings: inout MK2InputBindings2) {
        bindings.jog = { direction in
            switch direction {
                case "up":
                    select(delta: -1)
                case "down":
                    select(delta: 1)
                case "press":
                    confirm()
                default:
                    break
            }
        }
        bindings.jogScroll = { delta, _ in
            select(delta: delta)
        }
    }

    private func bindDismissButtons(into bindings: inout MK2InputBindings2) {
        for led in KKMK2ButtonLED.allCases where led.rawValue < KKMK2ButtonLED.strip1.rawValue {
            bindings.onPress(led, onDismiss)
        }
    }

    private func select(delta: Int) {
        guard !actions.isEmpty, delta != 0 else { return }
        let next = max(0, min(actions.count - 1, selectedIndex + delta))
        guard next != selectedIndex else { return }
        onSelectionChange(next)
    }

    private func confirm() {
        guard actions.indices.contains(selectedIndex) else { return }
        onConfirm(selectedIndex)
    }

    private func leftFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: colors.background)
        frame.stroke(MK2PixelRect(x: 16, y: 18, width: 96, height: 96), colors.border)
        BitmapLabel(iconPlaceholder, font: .readoutBold, color: colors.destructive)
            .draw(into: &frame, x: 36, y: 50)
        BitmapLabel(title, font: .gridBold, color: colors.destructive)
            .draw(into: &frame, x: 136, y: 30, clip: MK2PixelRect(x: 136, y: 30, width: 328, height: 20))

        var y = 82
        for line in message.prefix(5) {
            BitmapLabel(line, font: .grid, color: colors.text)
                .draw(into: &frame, x: 136, y: y, clip: MK2PixelRect(x: 136, y: y, width: 328, height: 20))
            y += 22
        }

        BitmapLabel("4D: Auswahl und Bestätigung", font: .label, color: colors.dim)
            .draw(into: &frame, x: 24, y: 246)
        return frame
    }

    private func rightFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: colors.background)
        BitmapLabel("AKTIONEN", font: .gridBold, color: colors.accent).draw(into: &frame, x: 24, y: 24)

        for (index, action) in actions.enumerated() {
            let y = 72 + index * 48
            let selected = index == selectedIndex
            let rect = MK2PixelRect(x: 24, y: y - 8, width: 432, height: 40)
            if selected {
                frame.fill(rect, colors.selectionFill)
                frame.stroke(rect, colors.accent)
            }
            BitmapLabel(selected ? "> \(action.title)" : "  \(action.title)", font: .grid, color: selected ? colors.text : colors.dim)
                .draw(into: &frame, x: 36, y: y, clip: MK2PixelRect(x: 36, y: y, width: 400, height: 18))
            if let detail = action.detail {
                BitmapLabel(detail, font: .label, color: colors.dim)
                    .draw(into: &frame, x: 56, y: y + 20, clip: MK2PixelRect(x: 56, y: y + 20, width: 380, height: 14))
            }
        }

        BitmapLabel(dismissHint, font: .label, color: colors.dim)
            .draw(into: &frame, x: 24, y: 246, clip: MK2PixelRect(x: 24, y: 246, width: 432, height: 14))
        return frame
    }
}
