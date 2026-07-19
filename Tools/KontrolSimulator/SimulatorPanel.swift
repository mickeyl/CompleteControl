import AppKit
import KompleteKontrol

enum SimulatorDaemonStatus {
    case none
    case starting
    case connected
    case protocolError
}

struct SimulatorTrueSizeReference {
    var physicalWidthMM: CGFloat
    var baseWidthPoints: CGFloat
}

@MainActor
protocol SimulatorPanel: AnyObject {
    var view: NSView { get }
    var onInput: ((SimFrame) -> Void)? { get set }
    var onDaemonStatus: ((SimulatorDaemonStatus) -> Void)? { get set }
    var backgroundColor: NSColor { get }
    var keyboardCheatSheetText: String { get }
    var displayBlockRect: NSRect { get }
    var displayWorkAreaRect: NSRect { get }
    var trueSizeReference: SimulatorTrueSizeReference { get }

    func apply(_ frame: SimFrame)
    func clearAll()
    func handleKeyDown(_ event: NSEvent) -> Bool
    func handleKeyUp(_ event: NSEvent) -> Bool
    func handleFlagsChanged(_ event: NSEvent) -> Bool
    func releaseKeyboardInputs()
}
