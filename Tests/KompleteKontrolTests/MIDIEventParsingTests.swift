import Testing
@testable import KompleteKontrol

@Suite("USB MIDI event parsing")
struct MIDIEventParsingTests {
    @Test("Channel pressure USB MIDI packets become MIDI aftertouch events")
    func channelPressurePacket() {
        let events = KKUSBMIDIParser.events([0x0d, 0xd0, 0x45, 0x00], receptionTimestamp: 0x1234)

        #expect(events == [
            KKMIDIEvent(channelPressure: 0x45, channel: 0, receptionTimestamp: 0x1234),
        ])
        #expect(events.first?.kind == .channelPressure)
        #expect(events.first?.pressure == 0x45)
        #expect(events.first?.description == "channel pressure ch 1 69")
    }

    @Test("Polyphonic pressure retains both note and pressure")
    func polyphonicPressurePacket() {
        let events = KKUSBMIDIParser.events([0x0a, 0xa2, 60, 93], receptionTimestamp: 0x5678)

        #expect(events == [
            KKMIDIEvent(polyphonicPressure: 93, note: 60, channel: 2, receptionTimestamp: 0x5678),
        ])
        #expect(events.first?.kind == .polyphonicPressure)
        #expect(events.first?.note == 60)
        #expect(events.first?.pressure == 93)
        #expect(events.first?.description == "poly pressure ch 3 note 60 pressure 93")
    }
}
