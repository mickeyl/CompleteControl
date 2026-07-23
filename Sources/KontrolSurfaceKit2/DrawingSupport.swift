import Foundation

/// Small drawing/geometry helpers shared across the Kit's elements. Each of
/// these was previously copied privately into several element files; they live
/// here once so a fix or a tweak lands in one place.

extension UInt16 {
    /// Scale an RGB565 colour channel-wise by `factor`, clamping each channel to
    /// its range. `factor` < 1 darkens, > 1 lightens — the basis for the raised
    /// bevels (bright top edge, dim bottom edge) throughout the chrome.
    func scaled565(by factor: Double) -> UInt16 {
        // `min` inside a UInt16 extension resolves to the static `UInt16.min`
        // property, so the global clamp must be spelled `Swift.min`.
        let r = UInt16(Swift.min(31, (Double((self >> 11) & 0x1f) * factor).rounded()))
        let g = UInt16(Swift.min(63, (Double((self >> 5) & 0x3f) * factor).rounded()))
        let b = UInt16(Swift.min(31, (Double(self & 0x1f) * factor).rounded()))
        return (r << 11) | (g << 5) | b
    }
}

extension MK2PixelRect {
    /// Shrink the rect symmetrically by `dx`/`dy` on each side, never below zero.
    func insetBy(dx: Int, dy: Int) -> MK2PixelRect {
        MK2PixelRect(x: x + dx, y: y + dy, width: max(0, width - dx * 2), height: max(0, height - dy * 2))
    }
}

extension Int {
    /// Wrap the value into `bounds`, cycling past either end (for encoder domains
    /// that roll over rather than clamp).
    func wrapped(to bounds: ClosedRange<Int>) -> Int {
        let count = bounds.upperBound - bounds.lowerBound + 1
        guard count > 0 else { return bounds.lowerBound }
        let raw = (self - bounds.lowerBound) % count
        let offset = raw >= 0 ? raw : raw + count
        return bounds.lowerBound + offset
    }
}

extension MK2PixelFrame {
    /// A filled rounded panel with a concentric border: the border colour fills
    /// the outer rounded rect, the fill colour an inner rect inset by
    /// `borderWidth`, so the border reads as a uniform ring.
    mutating func drawRoundedPanel(_ rect: MK2PixelRect, fill: UInt16, border: UInt16, radius: Int, borderWidth: Int = 1) {
        fillRounded(rect, radius: radius, border, antialiased: true)
        let inset = max(1, borderWidth)
        let inner = MK2PixelRect(
            x: rect.x + inset,
            y: rect.y + inset,
            width: max(0, rect.width - inset * 2),
            height: max(0, rect.height - inset * 2)
        )
        fillRounded(inner, radius: max(0, radius - inset), fill, antialiased: true)
    }

    /// The Aurora selection highlight: an accent ring around a vertically
    /// falling gradient with a bright light edge under the ring — the
    /// selection reads as illuminated, never as pressed-in or inverted. One
    /// treatment for every selectable surface (list rows, grid cells, dialog
    /// actions), so selection stays recognizable across scenes.
    public mutating func drawSelectionHighlight(_ rect: MK2PixelRect, radius: Int, fill: UInt16, accent: UInt16) {
        fillRounded(rect, radius: radius, accent, antialiased: true)
        let inner = rect.insetBy(dx: 1, dy: 1)
        guard inner.width > 2, inner.height > 2 else { return }
        fillRoundedVerticalGradient(
            inner,
            radius: max(0, radius - 1),
            top: fill.scaled565(by: MK2HIG.Selection.fillTopLift),
            bottom: fill.scaled565(by: MK2HIG.Selection.fillBottomDrop),
            antialiased: true
        )
        // The light edge sits inside the corner arcs so it never cuts through
        // the antialiased radius.
        let edgeInset = max(1, radius - 1)
        self.fill(
            MK2PixelRect(x: inner.x + edgeInset, y: inner.y, width: max(0, inner.width - edgeInset * 2), height: 1),
            fill.scaled565(by: MK2HIG.Selection.lightEdgeLift)
        )
    }

    /// A debossed 1px stroke: the top edge falls into shadow, the bottom edge
    /// catches the light — under the shared top-left light source the framed
    /// area reads as sunk into the panel (meter tracks, wells).
    public mutating func strokeInset(_ rect: MK2PixelRect, _ color: UInt16) {
        guard rect.width > 0, rect.height > 0 else { return }
        fill(MK2PixelRect(x: rect.x, y: rect.y, width: rect.width, height: 1), color.scaled565(by: 0.55))
        fill(MK2PixelRect(x: rect.x, y: rect.maxY - 1, width: rect.width, height: 1), color.scaled565(by: 1.7))
        fill(MK2PixelRect(x: rect.x, y: rect.y + 1, width: 1, height: max(0, rect.height - 2)), color)
        fill(MK2PixelRect(x: rect.maxX - 1, y: rect.y + 1, width: 1, height: max(0, rect.height - 2)), color)
    }
}
