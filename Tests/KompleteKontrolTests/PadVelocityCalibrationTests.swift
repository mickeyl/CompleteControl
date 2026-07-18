import Testing
@testable import KontrolSurfaceKit2
import KompleteKontrol

@Suite("Pad velocity calibration")
struct PadVelocityCalibrationTests {
    @Test("native strike velocity and pressure have independent linear mappings")
    func independentMappings() {
        let calibration = KontrolPadVelocityCalibration(
            strikeFloor: 0,
            strikeCeiling: 1_000,
            pressureFloor: 0,
            pressureCeiling: 500
        )

        #expect(calibration.velocityValue(for: 0) == 1)
        #expect(calibration.velocityValue(for: 500) == 64)
        #expect(calibration.velocityValue(for: 1_000) == 127)
        #expect(calibration.pressureValue(for: 250) == 64)
        #expect(calibration.pressureValue(for: 500) == 127)
    }

    @Test("strike velocity remains stable while held pressure changes")
    func separateSignals() throws {
        var analyzer = KontrolPadStrikeAnalyzer(
            calibration: KontrolPadVelocityCalibration(
                strikeFloor: 0,
                strikeCeiling: 1_000,
                pressureFloor: 0,
                pressureCeiling: 1_000
            )
        )

        let downResult = analyzer.receive(event(
            phase: .down,
            pressure: 0,
            strikeVelocity: 600
        ))
        let down = try #require(downResult)
        #expect(down.rawStrikeVelocity == 600)
        #expect(down.velocityValue == 76)
        #expect(down.pressureValue == 0)
        #expect(down.strikeCount == 1)

        let heldResult = analyzer.receive(event(
            phase: .pressure,
            pressure: 900
        ))
        let held = try #require(heldResult)
        #expect(held.rawStrikeVelocity == 600)
        #expect(held.velocityValue == 76)
        #expect(held.currentPressure == 900)
        #expect(held.pressureValue == 114)

        analyzer.calibration = KontrolPadVelocityCalibration(
            strikeFloor: 0,
            strikeCeiling: 1_200,
            pressureFloor: 0,
            pressureCeiling: 1_800
        )
        let recalibrated = try #require(analyzer.analyses[0])
        #expect(recalibrated.velocityValue == 64)
        #expect(recalibrated.pressureValue == 64)

        let releasedResult = analyzer.receive(event(phase: .up, pressure: 0))
        let released = try #require(releasedResult)
        #expect(!released.isHeld)
        #expect(released.velocityValue == 64)
        #expect(released.pressureValue == 0)
    }

    @Test("pad bindings follow the same shift fallback policy as continuous controls")
    func padBindingRouting() async {
        let box = PadEventBox()
        var base = MK2InputBindings2()
        base.pad = { box.base.append($0) }
        var layer = MK2InputBindings2()
        layer.pad = { box.shift.append($0) }

        let surface = MK2Surface2()
        await surface.present(MK2SurfaceScene2(
            bindings: base,
            shift: MK2SurfaceScene2.ShiftLayer(bindings: layer)
        ))

        let input = event(phase: .down, pressure: 0, strikeVelocity: 200)
        await surface.handlePadForTesting([input])
        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        await surface.handlePadForTesting([input])
        await surface.handleForTesting([.button(led: .shift, pressed: false)])

        #expect(box.base == [input])
        #expect(box.shift == [input])
    }

    private func event(
        phase: KontrolSurfacePadEvent.Phase,
        pressure: Int,
        strikeVelocity: Int? = nil
    ) -> KontrolSurfacePadEvent {
        KontrolSurfacePadEvent(
            index: 0,
            phase: phase,
            pressure: pressure,
            maximumPressure: MaschineMK3Protocol.padMaximumPressure,
            strikeVelocity: strikeVelocity,
            maximumStrikeVelocity: MaschineMK3Protocol.padMaximumStrikeVelocity,
            timestampNanos: 1_000_000
        )
    }
}

private final class PadEventBox: @unchecked Sendable {
    var base: [KontrolSurfacePadEvent] = []
    var shift: [KontrolSurfacePadEvent] = []
}
