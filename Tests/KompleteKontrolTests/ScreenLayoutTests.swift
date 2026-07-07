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
        #expect(titled.headerRect == MK2PixelRect(x: 0, y: 0, width: 480, height: 38))
        #expect(titled.contentRect.y == 43)
    }

    @Test("Progress bar hugs the header bottom or the top edge")
    func progressBarTopPlacement() {
        let withHeader = MK2ScreenLayout.regular(header: .title(title: "T"), progress: .top)
        #expect(withHeader.progressRect == MK2PixelRect(x: 0, y: 38, width: 480, height: 4))
        #expect(withHeader.contentRect.y == 43)

        let withoutHeader = MK2ScreenLayout.regular(progress: .top)
        #expect(withoutHeader.progressRect == MK2PixelRect(x: 0, y: 0, width: 480, height: 4))
        #expect(withoutHeader.contentRect.y == 9)
    }

    @Test("Progress bar hugs the footer top or the bottom edge")
    func progressBarBottomPlacement() {
        let withFooter = MK2ScreenLayout.regular(footer: .filters(), progress: .bottom)
        #expect(withFooter.footerRect == MK2PixelRect(x: 0, y: 184, width: 480, height: 88))
        #expect(withFooter.progressRect == MK2PixelRect(x: 0, y: 180, width: 480, height: 4))
        #expect(withFooter.contentRect.maxY == 177)

        let withoutFooter = MK2ScreenLayout.regular(progress: .bottom)
        #expect(withoutFooter.progressRect == MK2PixelRect(x: 0, y: 268, width: 480, height: 4))
        #expect(withoutFooter.contentRect.maxY == 263)
    }

    @Test("Regular screen chrome renders the progress bar slot")
    func chromeDrawsProgressBar() {
        let result = MK2RegularScreenDSL(
            header: .title(title: "Pattern"),
            progress: MK2ScreenProgressBar(placement: .top, progress: 0.5)
        ) {}.build(renderer: try? FreeTypeTextRenderer())

        let frame = result.screen.frame
        let barRect = MK2PixelRect(x: 0, y: 38, width: 480, height: 4)
        var fillCount = 0
        var trackCount = 0
        for y in barRect.y..<barRect.maxY {
            for x in barRect.x..<barRect.maxX {
                if frame[x, y] == MK2HIG.Chrome.accent { fillCount += 1 }
                if frame[x, y] == MK2HIG.Chrome.footerFill { trackCount += 1 }
            }
        }
        #expect(fillCount == 240 * 4)
        #expect(trackCount == 240 * 4)
    }
}
