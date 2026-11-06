import Foundation

/// A clipped label whose caller supplies elapsed time, so animation has no
/// hidden timer and can be paused or captured deterministically.
public struct MK2Marquee: Sendable {
    public var text: String
    public var rect: MK2PixelRect
    public var elapsed: Double
    public var font: SurfaceFont
    public var color: UInt16
    public var speed: Double
    public init(_ text: String, rect: MK2PixelRect, elapsed: Double, font: SurfaceFont = .grid, color: UInt16 = 0xffff, speed: Double = 24) {
        self.text = text; self.rect = rect; self.elapsed = elapsed; self.font = font; self.color = color; self.speed = speed
    }
    public var offset: Int {
        let distance = max(0, font.measure(text) - rect.width)
        guard distance > 0, elapsed.isFinite, speed.isFinite, speed > 0 else { return 0 }
        let duration = Double(distance) / speed
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: duration + 3)
        return min(distance, max(0, Int((phase - 1.5) * speed)))
    }
    public func draw(into frame: inout MK2PixelFrame) {
        guard !rect.isEmpty else { return }
        BitmapLabel(text, font: font, color: color).draw(into: &frame, x: rect.x - offset, y: rect.y, clip: rect)
    }
}

/// Sixteen cells in physical pad order: pad 1 is at the bottom left.
public struct MK2PadMatrix: Sendable {
    public struct Pad: Sendable {
        public var label: String
        public var occupied: Bool
        public var selected: Bool
        public init(_ label: String, occupied: Bool = false, selected: Bool = false) {
            self.label = label; self.occupied = occupied; self.selected = selected
        }
    }
    public var pads: [Pad]
    public var rect: MK2PixelRect
    public init(pads: [Pad], rect: MK2PixelRect) { self.pads = pads; self.rect = rect }
    public func draw(into frame: inout MK2PixelFrame) {
        guard rect.width >= 16, rect.height >= 16 else { return }
        let gap = 3
        for index in 0..<min(16, pads.count) {
            let col = index % 4, row = 3 - index / 4
            let x0 = rect.x + col * rect.width / 4, x1 = rect.x + (col + 1) * rect.width / 4
            let y0 = rect.y + row * rect.height / 4, y1 = rect.y + (row + 1) * rect.height / 4
            let cell = MK2PixelRect(x: x0, y: y0, width: max(1, x1 - x0 - gap), height: max(1, y1 - y0 - gap))
            let pad = pads[index]
            frame.fillRounded(cell, radius: 3, pad.occupied ? 0x4328 : 0x18c4)
            if pad.selected { frame.stroke(cell, 0xffff, width: 2) }
            let label = BitmapLabel(pad.label, font: .gridBold, color: pad.occupied ? 0xffff : 0x8410)
            label.draw(into: &frame, x: cell.x + max(2, (cell.width - label.width) / 2), y: cell.y + max(1, (cell.height - label.height) / 2), clip: cell)
        }
    }
}

/// A normalized polyline, suitable for envelopes and modulation shapes.
public struct MK2CurvePlot: Sendable {
    public struct Point: Sendable { public var x: Double; public var y: Double; public init(_ x: Double, _ y: Double) { self.x = x; self.y = y } }
    public var points: [Point]
    public var rect: MK2PixelRect
    public var color: UInt16
    public init(points: [Point], rect: MK2PixelRect, color: UInt16 = 0x07ff) { self.points = points; self.rect = rect; self.color = color }
    public func draw(into frame: inout MK2PixelFrame) {
        guard rect.width > 1, rect.height > 1 else { return }
        frame.fill(rect, 0x18c4); frame.stroke(rect, 0x4208)
        var previous: (Int, Int)?
        for point in points where point.x.isFinite && point.y.isFinite {
            let x = rect.x + Int((min(1, max(0, point.x)) * Double(rect.width - 1)).rounded())
            let y = rect.y + Int(((1 - min(1, max(0, point.y))) * Double(rect.height - 1)).rounded())
            if let (px, py) = previous {
                let steps = max(abs(x - px), abs(y - py), 1)
                for step in 0...steps {
                    let xx = px + (x - px) * step / steps, yy = py + (y - py) * step / steps
                    frame.fill(MK2PixelRect(x: xx, y: yy, width: 1, height: 1), color)
                }
            } else { frame.fill(MK2PixelRect(x: x, y: y, width: 1, height: 1), color) }
            previous = (x, y)
        }
    }
}

/// A compact channel strip. Levels and peak are normalized display values;
/// callers own metering ballistics and the actual gain mapping.
public struct MK2MixerStrip: Sendable {
    public var label: String; public var rect: MK2PixelRect
    public var levels: [Double]; public var peaks: [Double]; public var gain: Double
    public var muted: Bool; public var soloed: Bool; public var selected: Bool
    public init(label: String, rect: MK2PixelRect, levels: [Double], peaks: [Double] = [], gain: Double, muted: Bool = false, soloed: Bool = false, selected: Bool = false) {
        self.label = label; self.rect = rect; self.levels = levels; self.peaks = peaks; self.gain = gain
        self.muted = muted; self.soloed = soloed; self.selected = selected
    }
    public func draw(into frame: inout MK2PixelFrame) {
        guard rect.width >= 40, rect.height >= 60 else { return }
        frame.fillRounded(rect, radius: 4, 0x18c4)
        if selected { frame.stroke(rect, 0xffff) }
        BitmapLabel(label, font: .gridBold, color: 0xffff).draw(into: &frame, x: rect.x + 5, y: rect.y + 5, clip: rect)
        let top = rect.y + 24, height = rect.height - 45
        for channel in 0..<min(2, levels.count) {
            let x = rect.x + 8 + channel * 13
            frame.fill(MK2PixelRect(x: x, y: top, width: 9, height: height), 0x2945)
            let level = levels[channel].isFinite ? max(0, min(1, levels[channel])) : 0
            let h = Int((Double(height) * level).rounded())
            frame.fill(MK2PixelRect(x: x, y: top + height - h, width: 9, height: h), 0x07e0)
            if channel < peaks.count, peaks[channel].isFinite {
                let p = max(0, min(1, peaks[channel]))
                frame.fill(MK2PixelRect(x: x, y: top + height - 1 - Int((Double(height - 1) * p).rounded()), width: 9, height: 2), 0xffff)
            }
        }
        let x = rect.maxX - 17
        frame.fill(MK2PixelRect(x: x, y: top, width: 2, height: height), 0x8410)
        let value = gain.isFinite ? max(0, min(1, gain)) : 0
        let fy = top + height - 1 - Int((Double(height - 1) * value).rounded())
        frame.fill(MK2PixelRect(x: x - 4, y: max(top, min(top + height - 4, fy - 2)), width: 10, height: 4), 0xffff)
        let state = muted ? "MUTE" : soloed ? "SOLO" : ""
        BitmapLabel(state, font: .grid, color: muted ? 0xf800 : 0xffe0).draw(into: &frame, x: rect.x + 5, y: rect.maxY - 17, clip: rect)
    }
}
