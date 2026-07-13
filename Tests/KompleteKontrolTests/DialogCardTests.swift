import Foundation
import Testing
@testable import KontrolSurfaceKit2

@Suite("Dialog card", .serialized)
struct DialogCardTests {
    @Test("Severity card draws a rounded ring, surface, icon and title")
    func severityCardRendersRingAndContent() throws {
        UserDefaults.standard.set(true, forKey: MK2RenderSettings.antialiasingEnabledDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: MK2RenderSettings.antialiasingEnabledDefaultsKey) }

        let renderer = try FreeTypeTextRenderer()
        let rect = MK2PixelRect(x: 8, y: 40, width: 456, height: 150)
        var frame = MK2PixelFrame()
        MK2DialogCard(
            rect: rect,
            severity: .warning,
            title: "Clear pattern?",
            body: "This removes every note in the selected pattern.",
            footnote: "4-D confirms, any other button cancels."
        ).draw(into: &frame, renderer: renderer)

        let tone = MK2ModalDialogColors().accent(for: .warning)
        // The ring tint runs along the straight left edge (mid-height, clear of
        // the rounded corners)…
        var hasRing = false
        for y in (rect.y + rect.height / 3)..<(rect.y + 2 * rect.height / 3) where frame[rect.x, y] == tone { hasRing = true }
        #expect(hasRing)
        // …the surface fills the interior…
        #expect(frame[rect.x + rect.width / 2, rect.y + rect.height / 2] == MK2HIG.Chrome.headerFill)
        // …the rounded corner leaves the extreme pixel as background…
        #expect(frame[rect.x, rect.y] == 0x0000)
        // …and the leading icon column and title column both carry glyph pixels.
        func hasPixel(_ r: MK2PixelRect) -> Bool {
            for y in r.y..<r.maxY {
                for x in r.x..<r.maxX where frame[x, y] != 0x0000 && frame[x, y] != MK2HIG.Chrome.headerFill && frame[x, y] != tone {
                    return true
                }
            }
            return false
        }
        #expect(hasPixel(MK2PixelRect(x: rect.x + 20, y: rect.y + 22, width: 48, height: 48)))
        #expect(hasPixel(MK2PixelRect(x: rect.x + 92, y: rect.y + 56, width: 300, height: 40)))
    }

    @Test("Top placement centers the icon above the text")
    func topPlacementCentersIcon() throws {
        let renderer = try FreeTypeTextRenderer()
        let rect = MK2PixelRect(x: 46, y: 56, width: 388, height: 172)
        var frame = MK2PixelFrame()
        MK2DialogCard(
            rect: rect,
            iconGlyph: MK2HIG.IconGlyph.warning,
            iconPlacement: .top,
            title: "Load Instrument?",
            body: "Replace the current sound."
        ).draw(into: &frame, renderer: renderer)

        // Icon glyph pixels straddle the card's horizontal center near the top.
        let centerX = rect.x + rect.width / 2
        var hasCenteredIcon = false
        for y in (rect.y + 20)..<(rect.y + 20 + 48) {
            for x in (centerX - 24)..<(centerX + 24) where frame[x, y] != 0x0000 && frame[x, y] != MK2HIG.Chrome.headerFill {
                hasCenteredIcon = true
            }
        }
        #expect(hasCenteredIcon)
    }
}
