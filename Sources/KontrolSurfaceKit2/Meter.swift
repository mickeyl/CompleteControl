import Foundation

public struct MK2MeterChannel: Sendable, Equatable {
    public var label: String?
    public var level: Double
    public var peak: Double?

    public init(label: String? = nil, level: Double, peak: Double? = nil) {
        self.label = label
        self.level = level
        self.peak = peak
    }
}

public struct MK2MeterElement: MK2ScreenElement {
    public enum Orientation: Sendable {
        case horizontal
        case vertical
    }

    public var channels: [MK2MeterChannel]
    public var rect: MK2PixelRect
    public var orientation: Orientation
    public var channelGap: Int
    public var track: UInt16
    public var fill: UInt16
    public var warningFill: UInt16
    public var dangerFill: UInt16
    public var peakColor: UInt16
    public var border: UInt16
    public var labelColor: UInt16
    public var warningThreshold: Double
    public var dangerThreshold: Double
    public var relativeToContent: Bool

    public init(
        channels: [MK2MeterChannel],
        rect: MK2PixelRect,
        orientation: Orientation = .horizontal,
        channelGap: Int = 4,
        track: UInt16 = MK2HIG.Chrome.footerFill,
        fill: UInt16 = 0x464f,
        warningFill: UInt16 = MK2HIG.Chrome.accent,
        dangerFill: UInt16 = 0xf8c3,
        peakColor: UInt16 = MK2HIG.Chrome.text,
        border: UInt16 = MK2HIG.Chrome.border,
        labelColor: UInt16 = MK2HIG.Chrome.dim,
        warningThreshold: Double = 0.72,
        dangerThreshold: Double = 0.92,
        relativeToContent: Bool = true
    ) {
        self.channels = channels
        self.rect = rect
        self.orientation = orientation
        self.channelGap = max(0, channelGap)
        self.track = track
        self.fill = fill
        self.warningFill = warningFill
        self.dangerFill = dangerFill
        self.peakColor = peakColor
        self.border = border
        self.labelColor = labelColor
        self.warningThreshold = warningThreshold
        self.dangerThreshold = dangerThreshold
        self.relativeToContent = relativeToContent
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        guard !channels.isEmpty else { return }
        let contentRect = context.layout?.contentRect
        let drawRect = relativeToContent
            ? MK2PixelRect(x: (contentRect?.x ?? 0) + rect.x, y: (contentRect?.y ?? 0) + rect.y, width: rect.width, height: rect.height)
            : rect
        guard !drawRect.isEmpty else { return }

        switch orientation {
            case .horizontal:
                drawHorizontalMeters(in: drawRect, into: &frame)
            case .vertical:
                drawVerticalMeters(in: drawRect, into: &frame)
        }
    }

    private func drawHorizontalMeters(in rect: MK2PixelRect, into frame: inout MK2PixelFrame) {
        let channelCount = channels.count
        let channelHeight = max(1, (rect.height - channelGap * (channelCount - 1)) / channelCount)
        let labelWidth = channels.contains { ($0.label?.isEmpty == false) } ? 34 : 0
        for (index, channel) in channels.enumerated() {
            let y = rect.y + index * (channelHeight + channelGap)
            let rowRect = MK2PixelRect(x: rect.x, y: y, width: rect.width, height: channelHeight)
            if let label = channel.label, !label.isEmpty {
                BitmapLabel(label.uppercased(), font: .label, color: labelColor)
                    .draw(
                        into: &frame,
                        x: rowRect.x,
                        y: rowRect.y + max(0, (rowRect.height - SurfaceFont.label.cellHeight) / 2),
                        clip: MK2PixelRect(x: rowRect.x, y: rowRect.y, width: max(0, labelWidth - 4), height: rowRect.height)
                    )
            }
            let barRect = MK2PixelRect(x: rowRect.x + labelWidth, y: rowRect.y, width: max(0, rowRect.width - labelWidth), height: rowRect.height)
            drawHorizontalBar(channel, in: barRect, into: &frame)
        }
    }

    private func drawHorizontalBar(_ channel: MK2MeterChannel, in rect: MK2PixelRect, into frame: inout MK2PixelFrame) {
        frame.fill(rect, track)
        frame.stroke(rect, border)
        let inner = rect.insetBy(dx: 1, dy: 1)
        let level = channel.level.clamped01()
        let fillWidth = Int((Double(inner.width) * level).rounded())
        if fillWidth > 0 {
            frame.fill(MK2PixelRect(x: inner.x, y: inner.y, width: min(inner.width, fillWidth), height: inner.height), fillColor(for: level))
        }
        if let peak = channel.peak {
            let peakX = inner.x + Int((Double(max(0, inner.width - 1)) * peak.clamped01()).rounded())
            frame.fill(MK2PixelRect(x: peakX, y: inner.y, width: 2, height: inner.height), peakColor)
        }
    }

    private func drawVerticalMeters(in rect: MK2PixelRect, into frame: inout MK2PixelFrame) {
        let channelCount = channels.count
        let channelWidth = max(1, (rect.width - channelGap * (channelCount - 1)) / channelCount)
        for (index, channel) in channels.enumerated() {
            let x = rect.x + index * (channelWidth + channelGap)
            let columnRect = MK2PixelRect(x: x, y: rect.y, width: channelWidth, height: rect.height)
            drawVerticalBar(channel, in: columnRect, into: &frame)
        }
    }

    private func drawVerticalBar(_ channel: MK2MeterChannel, in rect: MK2PixelRect, into frame: inout MK2PixelFrame) {
        frame.fill(rect, track)
        frame.stroke(rect, border)
        let inner = rect.insetBy(dx: 1, dy: 1)
        let level = channel.level.clamped01()
        let fillHeight = Int((Double(inner.height) * level).rounded())
        if fillHeight > 0 {
            frame.fill(MK2PixelRect(x: inner.x, y: inner.maxY - fillHeight, width: inner.width, height: min(inner.height, fillHeight)), fillColor(for: level))
        }
        if let peak = channel.peak {
            let peakY = inner.maxY - 1 - Int((Double(max(0, inner.height - 1)) * peak.clamped01()).rounded())
            frame.fill(MK2PixelRect(x: inner.x, y: peakY, width: inner.width, height: 2), peakColor)
        }
    }

    private func fillColor(for level: Double) -> UInt16 {
        if level >= dangerThreshold {
            return dangerFill
        }
        if level >= warningThreshold {
            return warningFill
        }
        return fill
    }
}

private extension Double {
    func clamped01() -> Double {
        Swift.max(0, Swift.min(1, self))
    }
}

private extension MK2PixelRect {
    func insetBy(dx: Int, dy: Int) -> MK2PixelRect {
        MK2PixelRect(x: x + dx, y: y + dy, width: max(0, width - dx * 2), height: max(0, height - dy * 2))
    }
}
