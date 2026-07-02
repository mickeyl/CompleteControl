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

    @Test("single pixel change sends full screen")
    func singlePixelChangeSendsFullScreen() {
        var reconciler = PixelDisplayReconciler2(tileWidth: 120, tileHeight: 34)
        var frame = MK2PixelFrame(fill: 0x0000)
        _ = reconciler.reconcile(frames: [frame, nil])

        frame[3, 2] = 0xffff
        let blits = reconciler.reconcile(frames: [frame, nil])

        #expect(blits.count == 1)
        #expect(blits[0].rect == MK2PixelFrame.bounds)
        #expect(blits[0].pixels.count == MK2PixelFrame.width * MK2PixelFrame.height)
    }

    @Test("adjacent dirty tiles send full screen")
    func adjacentDirtyTilesSendFullScreen() {
        var reconciler = PixelDisplayReconciler2(tileWidth: 120, tileHeight: 34)
        var frame = MK2PixelFrame(fill: 0x0000)
        _ = reconciler.reconcile(frames: [frame, nil])

        frame[1, 1] = 0xffff
        frame[130, 1] = 0xffff
        let blits = reconciler.reconcile(frames: [frame, nil])

        #expect(blits.count == 1)
        #expect(blits[0].rect == MK2PixelFrame.bounds)
    }

    @Test("separate dirty tiles still send full screen")
    func separateDirtyTilesStillSendFullScreen() {
        var reconciler = PixelDisplayReconciler2(tileWidth: 120, tileHeight: 34)
        var frame = MK2PixelFrame(fill: 0x0000)
        _ = reconciler.reconcile(frames: [frame, nil])

        frame[1, 1] = 0xffff
        frame[360, 100] = 0xffff
        let blits = reconciler.reconcile(frames: [frame, nil])

        #expect(blits.count == 1)
        #expect(blits[0].rect == MK2PixelFrame.bounds)
    }
}
