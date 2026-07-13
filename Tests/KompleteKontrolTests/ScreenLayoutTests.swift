import Foundation
import KompleteKontrol
import Testing
@testable import KontrolSurfaceKit2

@Suite("MK2 screen layout")
struct ScreenLayoutTests {
    @Test("Header .none reclaims the header band")
    func headerNoneReclaimsSpace() {
        let headerless = MK2ScreenLayout.regular()
        #expect(headerless.headerRect == nil)
        #expect(headerless.contentRect == MK2PixelRect(x: 8, y: 8, width: 464, height: 256))

        let titled = MK2ScreenLayout.regular(header: .title(title: "T"))
        #expect(titled.headerRect == MK2PixelRect(x: 0, y: 0, width: 480, height: 32))
        #expect(titled.contentRect.y == 37)
    }

    @Test("Header and hint footer heights derive from the chrome typography")
    func chromeBandHeightsDeriveFromTypography() {
        let defaults = MK2ScreenLayout.regular(header: .title(title: "T"), footer: .hint("h"))
        #expect(defaults.headerRect?.height == 32)
        #expect(defaults.footerRect?.height == 25)

        let compact = MK2ScreenLayout.regular(
            header: .title(title: "T"),
            footer: .hint("h"),
            typography: MK2ScreenChromeTypography(captionPixelSize: 12, footnotePixelSize: 12)
        )
        #expect(compact.headerRect?.height == 26)
        #expect(compact.contentRect.y == 31)
        #expect(compact.footerRect?.height == 24)
    }

    @Test("Chrome text uses independently calibrated optical offsets")
    func chromeTextOpticalOffsets() {
        let typography = MK2ScreenChromeTypography()
        let layout = MK2ScreenLayout.regular(
            header: .title(title: "T"),
            footer: .hint("hint"),
            typography: typography
        )

        #expect(MK2RegularScreenChrome.titleHeaderTextY(for: typography) == 5)
        #expect(MK2RegularScreenChrome.statusHeaderTextY(for: typography) == 8)
        #expect(MK2RegularScreenChrome.footerTextY(in: layout.footerRect!, typography: typography) == 250)
    }

    @Test("Progress bar hugs the header bottom or the top edge")
    func progressBarTopPlacement() {
        let withHeader = MK2ScreenLayout.regular(header: .title(title: "T"), progress: .top)
        #expect(withHeader.progressRect == MK2PixelRect(x: 0, y: 32, width: 480, height: 2))
        #expect(withHeader.contentRect.y == 37)

        let withoutHeader = MK2ScreenLayout.regular(progress: .top)
        #expect(withoutHeader.progressRect == MK2PixelRect(x: 0, y: 0, width: 480, height: 2))
        #expect(withoutHeader.contentRect.y == 7)
    }

    @Test("Progress bar hugs the footer top or the bottom edge")
    func progressBarBottomPlacement() {
        let withFooter = MK2ScreenLayout.regular(footer: .filters(), progress: .bottom)
        #expect(withFooter.footerRect == MK2PixelRect(x: 0, y: 210, width: 480, height: 62))
        #expect(withFooter.progressRect == MK2PixelRect(x: 0, y: 208, width: 480, height: 2))
        #expect(withFooter.contentRect.maxY == 203)

        let withoutFooter = MK2ScreenLayout.regular(progress: .bottom)
        #expect(withoutFooter.progressRect == MK2PixelRect(x: 0, y: 270, width: 480, height: 2))
        #expect(withoutFooter.contentRect.maxY == 265)
    }

    @Test("Chrome bands fill with a subtle vertical gradient")
    func chromeBandsFillWithVerticalGradient() {
        let result = MK2RegularScreenDSL(
            header: .title(title: "T"),
            footer: .filters()
        ) {}.build(renderer: try? FreeTypeTextRenderer())
        let frame = result.screen.frame

        func luminance(_ color: UInt16) -> Int {
            Int((color >> 11) & 0x1f) + Int((color >> 5) & 0x3f) + Int(color & 0x1f)
        }

        // Header band 0..31: bevel, gradient rows falling toward the shadow.
        #expect(frame[300, 0] == MK2HIG.Chrome.headerTopLine)
        #expect(luminance(frame[300, 2]) > luminance(frame[300, 29]))
        #expect(frame[300, 31] == MK2HIG.Chrome.headerBottomLine)
        // Footer band 210..271 gets the same treatment.
        #expect(frame[300, 210] == MK2HIG.Chrome.headerTopLine)
        #expect(luminance(frame[300, 213]) > luminance(frame[300, 268]))
        #expect(frame[300, 271] == MK2HIG.Chrome.headerBottomLine)
    }

    @Test("Regular screen chrome renders the progress bar as a gradient")
    func chromeDrawsProgressBar() {
        let result = MK2RegularScreenDSL(
            header: .title(title: "Pattern"),
            progress: MK2ScreenProgressBar(placement: .top, progress: 0.5)
        ) {}.build(renderer: try? FreeTypeTextRenderer())

        let frame = result.screen.frame
        let barRect = MK2PixelRect(x: 0, y: 32, width: 480, height: 2)
        var fillCount = 0
        var trackCount = 0
        var distinctFillColors = Set<UInt16>()
        for y in barRect.y..<barRect.maxY {
            for x in barRect.x..<barRect.maxX {
                let pixel = frame[x, y]
                if pixel == MK2HIG.Chrome.footerFill {
                    trackCount += 1
                } else {
                    fillCount += 1
                    distinctFillColors.insert(pixel)
                }
            }
        }
        #expect(fillCount == 240 * 2)
        #expect(trackCount == 240 * 2)
        // The fill ramps from fillStart to fillEnd instead of being one flat color.
        #expect(distinctFillColors.count > 8)
        #expect(frame[0, 32] == MK2HIG.Chrome.progressFillStart)
        #expect(frame[239, 32] == MK2HIG.Chrome.progressFillEnd)
    }
}
