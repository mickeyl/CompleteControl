import AppKit

/// Fixed window chrome for simulator connection state. It deliberately lives outside the
/// magnifiable hardware document so status text never covers physical controls.
final class SimulatorStatusBarView: NSView {
    static let height: CGFloat = 27

    private let modelName: String
    private var modelDetail: String?
    private var status = SimulatorDaemonStatus.none

    init(modelName: String, modelDetail: String? = nil) {
        self.modelName = modelName
        self.modelDetail = modelDetail
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        setAccessibilityRole(.group)
        updateAccessibilityLabel()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    func update(status: SimulatorDaemonStatus) {
        self.status = status
        updateAccessibilityLabel()
        needsDisplay = true
    }

    func update(modelDetail: String?) {
        self.modelDetail = modelDetail
        updateAccessibilityLabel()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
        bounds.fill()
        NSColor(calibratedWhite: 0.20, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let presentation = statusPresentation
        drawText(
            presentation.text,
            in: NSRect(x: 11, y: 6, width: max(0, bounds.width - 172), height: 16),
            color: presentation.color,
            alignment: .left,
            weight: .medium
        )
        drawText(
            modelPresentation,
            in: NSRect(x: max(11, bounds.width - 161), y: 6, width: 150, height: 16),
            color: NSColor(calibratedWhite: 0.52, alpha: 1),
            alignment: .right,
            weight: .semibold
        )
    }

    private var statusPresentation: (text: String, color: NSColor) {
        switch status {
            case .connected:
                return ("● daemon connected", .systemGreen)
            case .starting:
                return ("◐ starting daemon …", .systemYellow)
            case .protocolError:
                return ("! simulator protocol error", .systemRed)
            case .none:
                return ("○ waiting for daemon", NSColor(calibratedWhite: 0.52, alpha: 1))
        }
    }

    private var modelPresentation: String {
        guard let modelDetail, !modelDetail.isEmpty else { return modelName }
        return "\(modelName) · \(modelDetail)"
    }

    private func updateAccessibilityLabel() {
        setAccessibilityLabel("\(modelPresentation), \(statusPresentation.text)")
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        color: NSColor,
        alignment: NSTextAlignment,
        weight: NSFont.Weight
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]).draw(in: rect)
    }
}
