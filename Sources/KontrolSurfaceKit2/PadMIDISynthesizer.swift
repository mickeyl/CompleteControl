import Foundation
import KompleteKontrol

/// Musical policy for translating native controller pads into the same MIDI
/// stream used by a keyboard's USB-MIDI interface.
public struct KontrolPadMIDIMapping: Equatable, Sendable {
    /// One note per physical pad in panel order. The factory layout follows
    /// General MIDI percussion's 36...51 range without imposing drum semantics.
    public var notes: [UInt8]
    public var channel: UInt8
    public var calibration: KontrolPadVelocityCalibration
    /// Non-nil bypasses strike dynamics while retaining Note On's required
    /// non-zero velocity range.
    public var fixedVelocity: UInt8?
    public var sendsPolyphonicPressure: Bool

    public init(
        notes: [UInt8] = Array(UInt8(36)...UInt8(51)),
        channel: UInt8 = 0,
        calibration: KontrolPadVelocityCalibration = KontrolPadVelocityCalibration(),
        fixedVelocity: UInt8? = nil,
        sendsPolyphonicPressure: Bool = true
    ) {
        self.notes = notes
        self.channel = min(15, channel)
        self.calibration = calibration
        self.fixedVelocity = fixedVelocity.map { max(1, min(127, $0)) }
        self.sendsPolyphonicPressure = sendsPolyphonicPressure
    }
}

/// Bounded state machine that makes MK3 pad input look like ordinary MIDI to
/// every Kit2 scene. Deliberate touch-only contacts above the calibrated floor
/// become soft hits; a triggered pad produces Note On, note-addressed pressure,
/// and Note Off.
public struct KontrolPadMIDISynthesizer: Sendable {
    private struct HeldPad: Sendable {
        var note: UInt8
        var channel: UInt8
        var lastPressure: UInt8
    }

    public var mapping: KontrolPadMIDIMapping
    private var heldPads: [Int: HeldPad] = [:]

    public init(mapping: KontrolPadMIDIMapping = KontrolPadMIDIMapping()) {
        self.mapping = mapping
        heldPads.reserveCapacity(mapping.notes.count)
    }

    public mutating func reset() {
        heldPads.removeAll(keepingCapacity: true)
    }

    public mutating func receive(_ event: KontrolSurfacePadEvent) -> [KKMIDIEvent] {
        guard mapping.notes.indices.contains(event.index) else { return [] }
        let note = mapping.notes[event.index]
        let channel = min(15, mapping.channel)

        switch event.phase {
            case .touch:
                guard mapping.calibration.acceptsSoftHit(event.pressure),
                      heldPads[event.index] == nil else { return [] }
                return beginNote(
                    padIndex: event.index,
                    note: note,
                    channel: channel,
                    rawVelocity: event.pressure,
                    timestampNanos: event.timestampNanos
                )

            case .down:
                guard heldPads[event.index] == nil else { return [] }
                let rawVelocity: Int
                if let strikeVelocity = event.strikeVelocity {
                    rawVelocity = strikeVelocity
                } else {
                    guard mapping.calibration.acceptsSoftHit(event.pressure) else { return [] }
                    rawVelocity = event.pressure
                }
                return beginNote(
                    padIndex: event.index,
                    note: note,
                    channel: channel,
                    rawVelocity: rawVelocity,
                    timestampNanos: event.timestampNanos
                )

            case .pressure:
                guard mapping.sendsPolyphonicPressure,
                      var held = heldPads[event.index] else { return [] }
                let pressure = mapping.calibration.pressureValue(for: event.pressure)
                guard pressure != held.lastPressure else { return [] }
                held.lastPressure = pressure
                heldPads[event.index] = held
                return [KKMIDIEvent(
                    polyphonicPressure: pressure,
                    note: held.note,
                    channel: held.channel,
                    receptionTimestamp: event.timestampNanos
                )]

            case .up:
                guard let held = heldPads.removeValue(forKey: event.index) else { return [] }
                return [KKMIDIEvent(
                    kind: .noteOff,
                    channel: held.channel,
                    note: held.note,
                    velocity: 0,
                    receptionTimestamp: event.timestampNanos
                )]
        }
    }

    private mutating func beginNote(
        padIndex: Int,
        note: UInt8,
        channel: UInt8,
        rawVelocity: Int,
        timestampNanos: UInt64
    ) -> [KKMIDIEvent] {
        let velocity = mapping.fixedVelocity.map { max(1, min(127, $0)) }
            ?? mapping.calibration.velocityValue(for: rawVelocity)
        heldPads[padIndex] = HeldPad(note: note, channel: channel, lastPressure: 0)
        return [KKMIDIEvent(
            kind: .noteOn,
            channel: channel,
            note: note,
            velocity: velocity,
            receptionTimestamp: timestampNanos
        )]
    }
}
