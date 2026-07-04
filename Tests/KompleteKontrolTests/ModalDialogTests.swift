import Foundation
import Testing
import KompleteKontrol
@testable import KontrolSurfaceKit2

@Suite("Modal dialog")
struct ModalDialogTests {
    @Test("Dialog scene owns both displays and turns lamps off")
    func ownsDisplaysAndLamps() {
        let dialog = makeDialog(selectedIndex: 0, box: ModalDialogBox())

        let scene = dialog.scene()

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
}

private func makeDialog(selectedIndex: Int, box: ModalDialogBox) -> MK2ModalDialog {
    MK2ModalDialog(
        title: "TEST",
        message: ["Really?"],
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
