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
    public enum Orientation: Sendable, Equatable {
        case horizontal
        case vertical
    }

    public enum Style: String, CaseIterable, Sendable, Equatable {
        case solid
        case gradient
        case segmented
        case segmentedGradient
        case protracker
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
    public var style: Style
    public var showsPeak: Bool
    public var relativeToContent: Bool

    public init(
        channels: [MK2MeterChannel],
        rect: MK2PixelRect,
        orientation: Orientation = .horizontal,
        channelGap: Int = 4,
        track: UInt16 = MK2HIG.Chrome.footerFill,
        fill: UInt16 = MK2HIG.Meter.normal,
        warningFill: UInt16 = MK2HIG.Meter.warning,
        dangerFill: UInt16 = MK2HIG.Meter.danger,
        peakColor: UInt16 = MK2HIG.Chrome.text,
        border: UInt16 = MK2HIG.Chrome.border,
        labelColor: UInt16 = MK2HIG.Chrome.dim,
        warningThreshold: Double = 0.72,
        dangerThreshold: Double = 0.92,
        style: Style = .solid,
        showsPeak: Bool = true,
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
        self.style = style
        self.showsPeak = showsPeak
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
        frame.fill(rect, trackColor)
        frame.stroke(rect, borderColor)
        let inner = rect.insetBy(dx: 1, dy: 1)
        let level = channel.level.clamped01()
        let fillWidth = Int((Double(inner.width) * level).rounded())
        if fillWidth > 0 {
            drawLevel(
                in: MK2PixelRect(x: inner.x, y: inner.y, width: min(inner.width, fillWidth), height: inner.height),
                fullRect: inner,
                orientation: .horizontal,
                into: &frame
            )
        }
        if showsPeak, let peak = channel.peak {
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
        frame.fill(rect, trackColor)
        frame.stroke(rect, borderColor)
        let inner = rect.insetBy(dx: 1, dy: 1)
        let level = channel.level.clamped01()
        let fillHeight = Int((Double(inner.height) * level).rounded())
        if fillHeight > 0 {
            drawLevel(
                in: MK2PixelRect(x: inner.x, y: inner.maxY - fillHeight, width: inner.width, height: min(inner.height, fillHeight)),
                fullRect: inner,
                orientation: .vertical,
                into: &frame
            )
        }
        if showsPeak, let peak = channel.peak {
            let peakY = inner.maxY - 1 - Int((Double(max(0, inner.height - 1)) * peak.clamped01()).rounded())
            frame.fill(MK2PixelRect(x: inner.x, y: peakY, width: inner.width, height: 2), peakColor)
        }
    }

    private var trackColor: UInt16 {
        style == .protracker ? MK2HIG.Meter.ProTracker.track : track
    }

    private var borderColor: UInt16 {
        style == .protracker ? MK2HIG.Meter.ProTracker.border : border
    }

    private func drawLevel(
        in fillRect: MK2PixelRect,
        fullRect: MK2PixelRect,
        orientation: Orientation,
        into frame: inout MK2PixelFrame
    ) {
        switch style {
            case .solid:
                drawZoneBands(in: fillRect, fullRect: fullRect, orientation: orientation, into: &frame)
            case .gradient:
                drawGradient(in: fillRect, fullRect: fullRect, orientation: orientation, into: &frame)
            case .segmented:
                drawSegments(in: fillRect, fullRect: fullRect, orientation: orientation, color: { pos, _, _ in zoneColor(at: pos) }, into: &frame)
            case .segmentedGradient:
                drawSegments(in: fillRect, fullRect: fullRect, orientation: orientation, color: scaleColor, into: &frame)
            case .protracker:
                drawProTracker(in: fillRect, fullRect: fullRect, orientation: orientation, into: &frame)
        }
    }

    private func drawGradient(
        in rect: MK2PixelRect,
        fullRect: MK2PixelRect,
        orientation: Orientation,
        into frame: inout MK2PixelFrame
    ) {
        for y in rect.y..<rect.maxY {
            for x in rect.x..<rect.maxX {
                let progress = axisProgress(x: x, y: y, in: fullRect, orientation: orientation)
                frame[x, y] = scaleColor(at: progress, x: x, y: y)
            }
        }
    }

    private func drawZoneBands(
        in fillRect: MK2PixelRect,
        fullRect: MK2PixelRect,
        orientation: Orientation,
        into frame: inout MK2PixelFrame
    ) {
        switch orientation {
            case .horizontal:
                let warningX = fullRect.x + Int((Double(fullRect.width) * warningThreshold).rounded())
                let dangerX = fullRect.x + Int((Double(fullRect.width) * dangerThreshold).rounded())
                fillHorizontalSpan(from: fillRect.x, to: min(fillRect.maxX, warningX), in: fillRect, color: fill, into: &frame)
                fillHorizontalSpan(from: max(fillRect.x, warningX), to: min(fillRect.maxX, dangerX), in: fillRect, color: warningFill, into: &frame)
                fillHorizontalSpan(from: max(fillRect.x, dangerX), to: fillRect.maxX, in: fillRect, color: dangerFill, into: &frame)
            case .vertical:
                let warningY = fullRect.maxY - Int((Double(fullRect.height) * warningThreshold).rounded())
                let dangerY = fullRect.maxY - Int((Double(fullRect.height) * dangerThreshold).rounded())
                fillVerticalSpan(from: max(fillRect.y, warningY), to: fillRect.maxY, in: fillRect, color: fill, into: &frame)
                fillVerticalSpan(from: max(fillRect.y, dangerY), to: min(fillRect.maxY, warningY), in: fillRect, color: warningFill, into: &frame)
                fillVerticalSpan(from: fillRect.y, to: min(fillRect.maxY, dangerY), in: fillRect, color: dangerFill, into: &frame)
        }
    }

    private func fillHorizontalSpan(from start: Int, to end: Int, in rect: MK2PixelRect, color: UInt16, into frame: inout MK2PixelFrame) {
        guard end > start else { return }
        frame.fill(MK2PixelRect(x: start, y: rect.y, width: end - start, height: rect.height), color)
    }

    private func fillVerticalSpan(from start: Int, to end: Int, in rect: MK2PixelRect, color: UInt16, into frame: inout MK2PixelFrame) {
        guard end > start else { return }
        frame.fill(MK2PixelRect(x: rect.x, y: start, width: rect.width, height: end - start), color)
    }

    private func drawSegments(
        in fillRect: MK2PixelRect,
        fullRect: MK2PixelRect,
        orientation: Orientation,
        color: (Double, Int, Int) -> UInt16,
        into frame: inout MK2PixelFrame
    ) {
        let block = 7
        let gap = 2
        switch orientation {
            case .horizontal:
                var x = fullRect.x
                while x < fillRect.maxX {
                    let width = min(block, fillRect.maxX - x)
                    let position = Double(x + max(0, width - 1) - fullRect.x) / Double(max(1, fullRect.width - 1))
                    frame.fill(MK2PixelRect(x: x, y: fillRect.y, width: width, height: fillRect.height), color(position, x, fillRect.y))
                    x += block + gap
                }
            case .vertical:
                var bottom = fullRect.maxY
                while bottom > fillRect.y {
                    let top = max(fillRect.y, bottom - block)
                    let position = Double(fullRect.maxY - top) / Double(max(1, fullRect.height))
                    frame.fill(MK2PixelRect(x: fillRect.x, y: top, width: fillRect.width, height: bottom - top), color(position, fillRect.x, top))
                    bottom -= block + gap
                }
        }
    }

    private func drawProTracker(
        in fillRect: MK2PixelRect,
        fullRect: MK2PixelRect,
        orientation: Orientation,
        into frame: inout MK2PixelFrame
    ) {
        for y in fillRect.y..<fillRect.maxY {
            for x in fillRect.x..<fillRect.maxX {
                let position = axisProgress(x: x, y: y, in: fullRect, orientation: orientation)
                let crossPosition = orientation == .horizontal
                    ? Double(y - fullRect.y) / Double(max(1, fullRect.height - 1))
                    : Double(x - fullRect.x) / Double(max(1, fullRect.width - 1))
                let color = proTrackerColor(at: position, x: x, y: y)
                frame[x, y] = MK2OrderedDither.scaled(color, by: proTrackerCrossFactor(at: crossPosition), x: x, y: y)
            }
        }
    }

    /// Smooth cylindrical tube shading — the 3D "lit pipe" illusion from the
    /// original ProTracker VU meters. A specular highlight peak near the left
    /// edge sits over a continuous body falloff toward the right; a narrow rim
    /// shadow at the very edge gives the rounded cross-section its depth. The
    /// previous stepped approximation produced visible bands that broke the
    /// effect on the OLED.
    private func proTrackerCrossFactor(at position: Double) -> Double {
        let t = min(1, max(0, position))
        let highlight = exp(-pow((t - 0.09) / 0.07, 2.0))
        let body = pow(1.0 - t, 0.5)
        let rimShadow = exp(-pow(t / 0.04, 2.0))
        return 0.50 + 0.45 * body + 0.28 * highlight - 0.35 * rimShadow
    }

    private func axisProgress(x: Int, y: Int, in rect: MK2PixelRect, orientation: Orientation) -> Double {
        switch orientation {
            case .horizontal:
                Double(x - rect.x) / Double(max(1, rect.width - 1))
            case .vertical:
                Double(rect.maxY - 1 - y) / Double(max(1, rect.height - 1))
        }
    }

    private func zoneColor(at position: Double) -> UInt16 {
        if position >= dangerThreshold { return dangerFill }
        if position >= warningThreshold { return warningFill }
        return fill
    }

    private func scaleColor(at position: Double, x: Int, y: Int) -> UInt16 {
        if position <= warningThreshold {
            return MK2OrderedDither.lerp(
                fill,
                warningFill,
                t: position / max(0.001, warningThreshold),
                x: x,
                y: y
            )
        }
        return MK2OrderedDither.lerp(
            warningFill,
            dangerFill,
            t: (position - warningThreshold) / max(0.001, dangerThreshold - warningThreshold),
            x: x,
            y: y
        )
    }

    private func proTrackerColor(at position: Double, x: Int, y: Int) -> UInt16 {
        let yellowPosition = MK2HIG.Meter.ProTracker.yellowPosition
        let redPosition = MK2HIG.Meter.ProTracker.redPosition
        if position <= yellowPosition {
            return MK2OrderedDither.lerp(
                MK2HIG.Meter.normal,
                MK2HIG.Meter.warning,
                t: position / max(0.001, yellowPosition),
                x: x,
                y: y
            )
        }
        return MK2OrderedDither.lerp(
            MK2HIG.Meter.warning,
            MK2HIG.Meter.danger,
            t: (position - yellowPosition) / max(0.001, redPosition - yellowPosition),
            x: x,
            y: y
        )
    }

}

private extension Double {
    func clamped01() -> Double {
        Swift.max(0, Swift.min(1, self))
    }
}
