import Testing
@testable import KompleteKontrol

@Suite("USB MIDI event parsing")
struct MIDIEventParsingTests {
    @Test("Channel pressure USB MIDI packets become MIDI aftertouch events")
    func channelPressurePacket() {
        let events = KompleteKontrolS25MK1.parseUSBMIDIEvents([0x0d, 0xd0, 0x45, 0x00], receptionTimestamp: 0x1234)

        #expect(events == [
            KKMIDIEvent(channelPressure: 0x45, channel: 0, receptionTimestamp: 0x1234),
        ])
        #expect(events.first?.kind == .channelPressure)
        #expect(events.first?.pressure == 0x45)
        #expect(events.first?.description == "channel pressure ch 1 69")
    }
}
