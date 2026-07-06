import Foundation
import Testing
import KompleteKontrol
@testable import KontrolSurfaceKit2

@Suite("Modal dialog")
struct ModalDialogTests {
    @Test("Dialog scene owns both displays and turns lamps off")
    func ownsDisplaysAndLamps() {
        let dialog = makeDialog(selectedIndex: 0, box: ModalDialogBox())

        let screens = dialog.doubleScreen()
        let scene = dialog.scene()

        #expect(screens.left.kind == .fullScreen)
        #expect(screens.right.kind == .fullScreen)
        #expect(scene.displays.count == 2)
        #expect(scene.displays[0] != nil)
        #expect(scene.displays[1] != nil)
        #expect(scene.lamps.isEmpty)
    }

    @Test("4-D rotation and up/down move selection without confirming")
    func navigationMovesSelection() {
        let box = ModalDialogBox()
        let dialog = makeDialog(selectedIndex: 1, box: box)
        let bindings = dialog.scene().bindings

        bindings.jogScroll?(-1, 0)
        bindings.jog?("down")
        bindings.jog?("up")

        #expect(box.events == ["select:0", "select:2", "select:0"])
    }

    @Test("4-D press confirms the selected action")
    func pressConfirms() {
        let box = ModalDialogBox()
        let dialog = makeDialog(selectedIndex: 1, box: box)
        let bindings = dialog.scene().bindings

        bindings.jog?("press")

        #expect(box.events == ["confirm:1"])
    }

    @Test("Other hardware buttons dismiss the dialog")
    func hardwareButtonDismisses() {
        let box = ModalDialogBox()
        let dialog = makeDialog(selectedIndex: 0, box: box)
        let bindings = dialog.scene().bindings

        bindings.buttonDown[.play]?()

        #expect(box.events == ["dismiss"])
    }

    @Test("Severity maps to stable icon colours")
    func severityColors() {
        let colors = MK2ModalDialogColors()

        #expect(colors.accent(for: .info) == colors.accent)
        #expect(colors.accent(for: .warning) == colors.warning)
        #expect(colors.accent(for: .error) == colors.destructive)
        #expect(colors.accent(for: .question) == colors.question)
    }

    @Test("Dialog draws FreeType icon and text regions")
    func drawsFreeTypeRegions() throws {
        let dialog = makeDialog(selectedIndex: 0, box: ModalDialogBox(), severity: .warning)

        let scene = dialog.scene()
        let left = try #require(scene.displays[0])
        let right = try #require(scene.displays[1])

        #expect(left.countPixels(in: MK2PixelRect(x: 16, y: 18, width: 96, height: 96), matching: MK2ModalDialogColors().warning) > 100)
        #expect(left.countNonBackgroundPixels(in: MK2PixelRect(x: 136, y: 28, width: 328, height: 48)) > 100)
        #expect(right.countNonBackgroundPixels(in: MK2PixelRect(x: 24, y: 12, width: 432, height: 48)) > 100)
    }

    @Test("Dialog wraps long message labels onto multiple body lines")
    func wrapsLongMessageLabels() throws {
        let dialog = makeDialog(
            selectedIndex: 0,
            box: ModalDialogBox(),
            severity: .warning,
            message: ["Wollen Sie das aktuelle Pattern wirklich löschen? Diese Aktion kann nicht rückgängig gemacht werden."]
        )

        let scene = dialog.scene()
        let left = try #require(scene.displays[0])

        #expect(left.countNonBackgroundPixels(in: MK2PixelRect(x: 136, y: 74, width: 328, height: 22)) > 100)
        #expect(left.countNonBackgroundPixels(in: MK2PixelRect(x: 136, y: 98, width: 328, height: 22)) > 100)
    }

    @Test("Dialog panels antialias rounded corners")
    func roundedPanelsAntialiasCorners() throws {
        let colors = MK2ModalDialogColors()
        let dialog = makeDialog(selectedIndex: 0, box: ModalDialogBox(), severity: .warning)

        let scene = dialog.scene()
        let left = try #require(scene.displays[0])
        let right = try #require(scene.displays[1])

        #expect(left.countIntermediatePixels(in: MK2PixelRect(x: 16, y: 18, width: 12, height: 12), excluding: [colors.background, colors.warning]) > 0)
        #expect(right.countIntermediatePixels(in: MK2PixelRect(x: 24, y: 62, width: 12, height: 12), excluding: [colors.background, colors.warning, colors.selectionFill]) > 0)
    }
}

private func makeDialog(
    selectedIndex: Int,
    box: ModalDialogBox,
    severity: MK2ModalDialogSeverity = .info,
    message: [String] = ["Really?"]
) -> MK2ModalDialog {
    MK2ModalDialog(
        severity: severity,
        title: "TEST",
        message: message,
        actions: [
            MK2ModalDialogAction("First"),
            MK2ModalDialogAction("Second"),
            MK2ModalDialogAction("Third"),
        ],
        selectedIndex: selectedIndex,
        onSelectionChange: { box.append("select:\($0)") },
        onConfirm: { box.append("confirm:\($0)") },
        onDismiss: { box.append("dismiss") }
    )
}

private final class ModalDialogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

private extension MK2PixelFrame {
    func countPixels(in rect: MK2PixelRect, matching color: UInt16) -> Int {
        guard let clipped = rect.clipped(to: MK2PixelFrame.bounds) else { return 0 }
        var count = 0
        for y in clipped.y..<clipped.maxY {
            for x in clipped.x..<clipped.maxX where self[x, y] == color {
                count += 1
            }
        }
        return count
    }

    func countNonBackgroundPixels(in rect: MK2PixelRect) -> Int {
        guard let clipped = rect.clipped(to: MK2PixelFrame.bounds) else { return 0 }
        var count = 0
        for y in clipped.y..<clipped.maxY {
            for x in clipped.x..<clipped.maxX where self[x, y] != 0x0000 {
                count += 1
            }
        }
        return count
    }

    func countIntermediatePixels(in rect: MK2PixelRect, excluding colors: Set<UInt16>) -> Int {
        guard let clipped = rect.clipped(to: MK2PixelFrame.bounds) else { return 0 }
        var count = 0
        for y in clipped.y..<clipped.maxY {
            for x in clipped.x..<clipped.maxX where !colors.contains(self[x, y]) {
                count += 1
            }
        }
        return count
    }
}
