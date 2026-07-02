import Testing
@testable import KontrolSurfaceKit2

@Suite("PixelDisplayReconciler2")
struct PixelDisplayReconciler2Tests {
    @Test("first frame sends full screen")
    func firstFrameSendsFullScreen() {
        var reconciler = PixelDisplayReconciler2()
        let frame = MK2PixelFrame(fill: 0x1234)

        let blits = reconciler.reconcile(frames: [frame, nil])

        #expect(blits.count == 1)
        #expect(blits[0].screen == 0)
        #expect(blits[0].rect == MK2PixelFrame.bounds)
        #expect(blits[0].pixels.count == MK2PixelFrame.width * MK2PixelFrame.height)
    }

    @Test("unchanged frame sends nothing")
    func unchangedFrameSendsNothing() {
        var reconciler = PixelDisplayReconciler2()
        let frame = MK2PixelFrame(fill: 0x1234)
        _ = reconciler.reconcile(frames: [frame, nil])

        let blits = reconciler.reconcile(frames: [frame, nil])

        #expect(blits.isEmpty)
    }

    @Test("single pixel change sends its full-width row band")
    func singlePixelChangeSendsRowBand() {
        var reconciler = PixelDisplayReconciler2()
        var frame = MK2PixelFrame(fill: 0x0000)
        _ = reconciler.reconcile(frames: [frame, nil])

        frame[3, 2] = 0xffff
        let blits = reconciler.reconcile(frames: [frame, nil])

        #expect(blits.count == 1)
        #expect(blits[0].rect == MK2PixelRect(x: 0, y: 2, width: MK2PixelFrame.width, height: 1))
        #expect(blits[0].pixels.count == MK2PixelFrame.width)
        #expect(blits[0].pixels[3] == 0xffff)
    }

    @Test("changes on one row merge into one band")
    func sameRowChangesMergeIntoOneBand() {
        var reconciler = PixelDisplayReconciler2()
        var frame = MK2PixelFrame(fill: 0x0000)
        _ = reconciler.reconcile(frames: [frame, nil])

        frame[1, 1] = 0xffff
        frame[130, 1] = 0xffff
        let blits = reconciler.reconcile(frames: [frame, nil])

        #expect(blits.count == 1)
        #expect(blits[0].rect == MK2PixelRect(x: 0, y: 1, width: MK2PixelFrame.width, height: 1))
    }

    @Test("distant changes span one covering band")
    func distantChangesSpanCoveringBand() {
        var reconciler = PixelDisplayReconciler2()
        var frame = MK2PixelFrame(fill: 0x0000)
        _ = reconciler.reconcile(frames: [frame, nil])

        frame[1, 1] = 0xffff
        frame[360, 100] = 0xffff
        let blits = reconciler.reconcile(frames: [frame, nil])

        #expect(blits.count == 1)
        #expect(blits[0].rect == MK2PixelRect(x: 0, y: 1, width: MK2PixelFrame.width, height: 100))
        #expect(blits[0].pixels.count == MK2PixelFrame.width * 100)
    }

    @Test("force sends full screens regardless of history")
    func forceSendsFullScreens() {
        var reconciler = PixelDisplayReconciler2()
        let frame = MK2PixelFrame(fill: 0x0f0f)
        _ = reconciler.reconcile(frames: [frame, nil])

        let blits = reconciler.reconcile(frames: [frame, nil], force: true)

        #expect(blits.count == 1)
        #expect(blits[0].rect == MK2PixelFrame.bounds)
    }
}
