import Foundation
import Testing
@testable import KontrolSurfaceKit2
import KompleteKontrol

@Suite("Pad MIDI synthesis")
struct PadMIDISynthesizerTests {
    @Test("triggered pad becomes note, poly pressure, and release without velocity zero")
    func triggeredLifecycle() {
        let mapping = KontrolPadMIDIMapping(
            calibration: KontrolPadVelocityCalibration(
                strikeFloor: 100,
                strikeCeiling: 1_000,
                pressureFloor: 100,
                pressureCeiling: 1_000
            )
        )
        var synthesizer = KontrolPadMIDISynthesizer(mapping: mapping)

        #expect(synthesizer.receive(event(.touch, pressure: 20, timestamp: 1)).isEmpty)
        #expect(synthesizer.receive(event(.down, strike: 0, timestamp: 2)) == [
            KKMIDIEvent(kind: .noteOn, channel: 0, note: 36, velocity: 1, receptionTimestamp: 2),
        ])
        #expect(synthesizer.receive(event(.pressure, pressure: 550, timestamp: 3)) == [
            KKMIDIEvent(polyphonicPressure: 64, note: 36, channel: 0, receptionTimestamp: 3),
        ])
        #expect(synthesizer.receive(event(.pressure, pressure: 550, timestamp: 4)).isEmpty)
        #expect(synthesizer.receive(event(.up, timestamp: 5)) == [
            KKMIDIEvent(kind: .noteOff, channel: 0, note: 36, velocity: 0, receptionTimestamp: 5),
        ])
    }

    @Test("touch-only pad never creates a MIDI note")
    func touchOnly() {
        var synthesizer = KontrolPadMIDISynthesizer(mapping: KontrolPadMIDIMapping(
            calibration: KontrolPadVelocityCalibration(strikeFloor: 100)
        ))

        #expect(synthesizer.receive(event(.touch, pressure: 40, timestamp: 1)).isEmpty)
        #expect(synthesizer.receive(event(.pressure, pressure: 300, timestamp: 2)).isEmpty)
        #expect(synthesizer.receive(event(.up, timestamp: 3)).isEmpty)
    }

    @Test("accepted soft contact has the same MIDI lifecycle as a native strike")
    func softHitLifecycle() {
        let mapping = KontrolPadMIDIMapping(
            calibration: KontrolPadVelocityCalibration(
                strikeFloor: 8,
                strikeCeiling: 1_008,
                pressureFloor: 0,
                pressureCeiling: 1_000
            )
        )
        var synthesizer = KontrolPadMIDISynthesizer(mapping: mapping)

        #expect(synthesizer.receive(event(.touch, pressure: 108, timestamp: 1)) == [
            KKMIDIEvent(kind: .noteOn, channel: 0, note: 36, velocity: 13, receptionTimestamp: 1),
        ])
        #expect(synthesizer.receive(event(.pressure, pressure: 500, timestamp: 2)) == [
            KKMIDIEvent(polyphonicPressure: 64, note: 36, channel: 0, receptionTimestamp: 2),
        ])
        #expect(synthesizer.receive(event(.up, timestamp: 3)) == [
            KKMIDIEvent(kind: .noteOff, channel: 0, note: 36, velocity: 0, receptionTimestamp: 3),
        ])
    }

    @Test("pressure-only contact becomes one soft MIDI note")
    func pressureOnlyHitLifecycle() {
        var synthesizer = KontrolPadMIDISynthesizer(mapping: KontrolPadMIDIMapping(
            calibration: KontrolPadVelocityCalibration(
                strikeFloor: 8,
                strikeCeiling: 1_008
            )
        ))

        #expect(synthesizer.receive(event(.down, pressure: 108, timestamp: 1)) == [
            KKMIDIEvent(kind: .noteOn, channel: 0, note: 36, velocity: 13, receptionTimestamp: 1),
        ])
        #expect(synthesizer.receive(event(.down, strike: 200, timestamp: 2)).isEmpty)
        #expect(synthesizer.receive(event(.up, timestamp: 3)) == [
            KKMIDIEvent(kind: .noteOff, channel: 0, note: 36, velocity: 0, receptionTimestamp: 3),
        ])
    }

    @Test("native strike after a soft trigger does not retrigger the held note")
    func noDuplicateTrigger() {
        var synthesizer = KontrolPadMIDISynthesizer()

        #expect(synthesizer.receive(event(.touch, pressure: 20, timestamp: 1)).count == 1)
        #expect(synthesizer.receive(event(.down, strike: 200, timestamp: 2)).isEmpty)
        #expect(synthesizer.receive(event(.up, timestamp: 3)).count == 1)
    }

    @Test("fixed velocity applies to an accepted soft contact")
    func fixedSoftHitVelocity() {
        var synthesizer = KontrolPadMIDISynthesizer(mapping: KontrolPadMIDIMapping(
            fixedVelocity: 96
        ))

        #expect(synthesizer.receive(event(.touch, pressure: 8, timestamp: 1)) == [
            KKMIDIEvent(kind: .noteOn, channel: 0, note: 36, velocity: 96, receptionTimestamp: 1),
        ])
    }

    @Test("multiple physical pads form independent chromatic notes")
    func chord() {
        var synthesizer = KontrolPadMIDISynthesizer()

        let first = synthesizer.receive(event(.down, index: 0, strike: 1_000, timestamp: 1))
        let second = synthesizer.receive(event(.down, index: 4, strike: 1_500, timestamp: 2))
        let third = synthesizer.receive(event(.down, index: 7, strike: 2_000, timestamp: 3))

        #expect(first.first?.note == 36)
        #expect(second.first?.note == 40)
        #expect(third.first?.note == 43)
        #expect(first.first?.velocity ?? 0 > 0)
        #expect(second.first?.velocity ?? 0 > 0)
        #expect(third.first?.velocity ?? 0 > 0)
    }

    @Test("surface routes synthesized pads through the ordinary MIDI binding")
    func surfaceIntegration() async {
        let box = MIDIEventBox()
        var bindings = MK2InputBindings2()
        bindings.midi = { box.append($0) }
        let surface = MK2Surface2(options: .init(padMIDIMapping: KontrolPadMIDIMapping(
            notes: [72],
            fixedVelocity: 100,
            sendsPolyphonicPressure: false
        )))
        await surface.present(MK2SurfaceScene2(bindings: bindings))

        await surface.handlePadForTesting([
            event(.down, strike: 0, timestamp: 10),
            event(.up, timestamp: 20),
        ])

        #expect(box.events == [
            KKMIDIEvent(kind: .noteOn, channel: 0, note: 72, velocity: 100, receptionTimestamp: 10),
            KKMIDIEvent(kind: .noteOff, channel: 0, note: 72, velocity: 0, receptionTimestamp: 20),
        ])
    }

    private func event(
        _ phase: KontrolSurfacePadEvent.Phase,
        index: Int = 0,
        pressure: Int = 0,
        strike: Int? = nil,
        timestamp: UInt64
    ) -> KontrolSurfacePadEvent {
        KontrolSurfacePadEvent(
            index: index,
            phase: phase,
            pressure: pressure,
            maximumPressure: MaschineMK3Protocol.padMaximumPressure,
            strikeVelocity: strike,
            maximumStrikeVelocity: MaschineMK3Protocol.padMaximumStrikeVelocity,
            timestampNanos: timestamp
        )
    }
}

private final class MIDIEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [KKMIDIEvent] = []

    var events: [KKMIDIEvent] {
        lock.withLock { storage }
    }

    func append(_ event: KKMIDIEvent) {
        lock.withLock { storage.append(event) }
    }
}
