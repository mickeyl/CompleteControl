import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The full-takeover confirmation dialog as its own catalogue entry: while
/// open, MK2ModalDialog owns both displays and every hardware binding — 4-D
/// moves the selection and confirms, any other button dismisses. E5 picks the
/// severity, E6 the number of actions, F1 opens the dialog.
final class ModalDialogDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "modal-dialog",
        title: "Modal Dialog",
        category: .catalogue,
        summary: "Full-takeover confirmation dialog",
        detail: "MK2ModalDialog owns both displays and all bindings while open: 4-D selects and confirms, any other button dismisses. E5 picks the severity, E6 the action count, F1 opens.",
        snapshotVariants: ["info", "warning", "error", "question"]
    )

    private var severityIndex = 1
    private var actionCount = 2
    private var dialogSelectedIndex: Int?
    private var outcome = "Not opened yet"
    private var focusedEncoder: Int?

    private var severity: MK2ModalDialogSeverity {
        MK2ModalDialogSeverity.allCases[severityIndex]
    }

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        if let dialogSelectedIndex {
            return dialogScene(selectedIndex: dialogSelectedIndex, context)
        }
        return MK2DoubleScreenDSL(
            left: explainerScreen(context),
            right: controlScreen(context)
        ).scene()
    }

    func prepareSnapshot(variant: String) {
        dialogSelectedIndex = nil
        if let index = MK2ModalDialogSeverity.allCases.firstIndex(where: { Self.severityName($0) == variant }) {
            severityIndex = index
            dialogSelectedIndex = 0
        }
    }

    private func dialogScene(selectedIndex: Int, _ context: LabContext) -> MK2SurfaceScene2 {
        let actions = Self.sampleActions(for: severity, count: actionCount)
        return MK2ModalDialog(
            severity: severity,
            title: Self.sampleTitle(for: severity),
            message: Self.sampleMessage(for: severity),
            actions: actions,
            selectedIndex: selectedIndex,
            onSelectionChange: { [weak self] index in
                context.update {
                    guard let self, self.dialogSelectedIndex != nil else { return }
                    self.dialogSelectedIndex = max(0, min(actions.count - 1, index))
                }
            },
            onConfirm: { [weak self] index in
                context.update {
                    guard let self else { return }
                    self.dialogSelectedIndex = nil
                    let title = actions.indices.contains(index) ? actions[index].title : "?"
                    self.outcome = "Confirmed: \(title)"
                }
            },
            onDismiss: { [weak self] in
                context.update {
                    guard let self else { return }
                    self.dialogSelectedIndex = nil
                    self.outcome = "Dismissed"
                }
            }
        ).scene()
    }

    private func explainerScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(
            header: .title(title: "Modal Dialog", subtitle: Self.severityName(severity)),
            footer: .hint(outcome)
        ) {
            MK2ContentText("Full-Takeover Dialog", x: 8, y: 0, role: .title)
            MK2ContentText(
                "While open, the dialog owns both displays and every binding: 4-D moves and confirms, any other hardware button dismisses.",
                x: 8,
                y: 40,
                maxWidth: 432,
                color: Palette.dim,
                maxLines: 3,
                lineSpacing: 2
            )
            MK2ContentText("Severity: \(Self.severityName(severity).uppercased())", x: 8, y: 110, maxWidth: 432)
            MK2ContentText("Actions: \(actionCount)", x: 8, y: 134, maxWidth: 432)
        }.build(renderer: context.renderer)
    }

    private func controlScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let severityValue = MK2EncoderDiscreteValue(
            encoder: 5,
            value: severityIndex,
            bounds: 0...(MK2ModalDialogSeverity.allCases.count - 1),
            defaultValue: 1,
            display: encoderDisplay(label: "SEVERITY", icon: MK2HIG.IconGlyph.warning, value: Self.severityName(severity).uppercased(), encoder: 5),
            onTouch: touch(5, context),
            onChange: { [weak self] value in
                context.update {
                    guard let self else { return }
                    self.severityIndex = max(0, min(MK2ModalDialogSeverity.allCases.count - 1, value))
                }
            }
        )
        let actionsValue = MK2EncoderDiscreteValue(
            encoder: 6,
            value: actionCount,
            bounds: 1...3,
            defaultValue: 2,
            display: encoderDisplay(label: "ACTIONS", icon: MK2HIG.IconGlyph.listBullets, value: "\(actionCount)", encoder: 6),
            onTouch: touch(6, context),
            onChange: { [weak self] value in
                context.update { self?.actionCount = max(1, min(3, value)) }
            }
        )
        return MK2FullScreenDSL(background: Palette.page) {
            MK2FunctionKeyBarElement(
                slots: [
                    MK2FunctionKeySlot("OPEN"),
                    MK2FunctionKeySlot(),
                    MK2FunctionKeySlot(),
                    MK2FunctionKeySlot(),
                ],
                side: .right,
                onPress: { [weak self] slot in
                    guard slot == 0 else { return }
                    context.update { self?.dialogSelectedIndex = 0 }
                }
            )
            MK2AnyScreenElement { frame, _, _ in
                MK2StatusLine(y: 30, items: [
                    MK2StatusLineItem("MODAL", x: 8, color: Palette.blue),
                    MK2StatusLineItem("F1 OPENS", x: 120, color: Palette.dim),
                ]).draw(into: &frame)
                frame.hline(y: 54, x: 0, width: 480, color: Palette.border)
                var y = 66
                for (text, color) in [
                    ("F1       OPEN THE DIALOG", Palette.text),
                    ("4-D      SELECT + CONFIRM (OPEN)", Palette.text),
                    ("ANY KEY  DISMISS (OPEN)", Palette.text),
                    ("E5/E6    SEVERITY / ACTION COUNT", Palette.dim),
                ] {
                    BitmapLabel(text, font: .grid, color: color).draw(into: &frame, x: 8, y: y)
                    y += SurfaceFont.grid.cellHeight + 6
                }
            }
            MK2EncoderDiscreteValuesElement([severityValue, actionsValue])
        }.build(renderer: context.renderer)
    }

    private func touch(_ encoder: Int, _ context: LabContext) -> (@Sendable (Bool) -> Void) {
        { [weak self] touched in
            context.update {
                guard let self else { return }
                if touched {
                    self.focusedEncoder = encoder
                } else if self.focusedEncoder == encoder {
                    self.focusedEncoder = nil
                }
            }
        }
    }

    private func encoderDisplay(label: String, icon: String, value: String, encoder: Int) -> MK2EncoderDiscreteValueDisplay {
        MK2EncoderDiscreteValueDisplay(
            label: label,
            iconGlyph: icon,
            value: value,
            rect: MK2ScreenLayout.encoderSlotRect(encoder - 5),
            isFocused: focusedEncoder == encoder,
            valueFont: .readoutBold,
            cornerRadius: 7,
            colors: labEditCellColors(value: Palette.text)
        )
    }

    private static func severityName(_ severity: MK2ModalDialogSeverity) -> String {
        switch severity {
            case .info: "info"
            case .warning: "warning"
            case .error: "error"
            case .question: "question"
        }
    }

    private static func sampleTitle(for severity: MK2ModalDialogSeverity) -> String {
        switch severity {
            case .info: "UPDATE AVAILABLE"
            case .warning: "CLEAR PATTERN"
            case .error: "SAVE FAILED"
            case .question: "UNSAVED CHANGES"
        }
    }

    private static func sampleMessage(for severity: MK2ModalDialogSeverity) -> [String] {
        switch severity {
            case .info:
                ["A new firmware version is ready", "to be installed."]
            case .warning:
                ["Do you really want to clear", "the current pattern?"]
            case .error:
                ["The song could not be written.", "The volume is read-only."]
            case .question:
                ["The song has unsaved changes.", "What should happen to them?"]
        }
    }

    private static func sampleActions(for severity: MK2ModalDialogSeverity, count: Int) -> [MK2ModalDialogAction] {
        let all: [MK2ModalDialogAction] = switch severity {
            case .info:
                [
                    MK2ModalDialogAction("Install now", detail: "Takes about two minutes"),
                    MK2ModalDialogAction("Remind me later"),
                    MK2ModalDialogAction("Skip this version"),
                ]
            case .warning:
                [
                    MK2ModalDialogAction("Yes, clear", detail: "The current pattern will be emptied"),
                    MK2ModalDialogAction("Clear all patterns", detail: "The whole song will be emptied"),
                    MK2ModalDialogAction("Keep a backup first"),
                ]
            case .error:
                [
                    MK2ModalDialogAction("Retry", detail: "Attempt the write again"),
                    MK2ModalDialogAction("Save elsewhere"),
                    MK2ModalDialogAction("Discard the song"),
                ]
            case .question:
                [
                    MK2ModalDialogAction("Save", detail: "Write the song, then continue"),
                    MK2ModalDialogAction("Discard", detail: "Continue without saving"),
                    MK2ModalDialogAction("Cancel"),
                ]
        }
        return Array(all.prefix(max(1, min(all.count, count))))
    }
}
