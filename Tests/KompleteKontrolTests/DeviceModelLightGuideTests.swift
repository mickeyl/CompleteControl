import KompleteKontrol
import Testing

@Suite("Device model identity and light-guide mapping")
struct DeviceModelLightGuideTests {
    @Test("deviceInfo ack messages parse to the device model")
    func parsesDeviceInfoMessage() {
        #expect(KompleteKontrolDeviceModel.parse(deviceInfoMessage: "product=0x1620 keys=61") == .s61MK2)
        #expect(KompleteKontrolDeviceModel.parse(deviceInfoMessage: "product=0x1610 keys=49") == .s49MK2)
        #expect(KompleteKontrolDeviceModel.parse(deviceInfoMessage: "product=0x1630 keys=88") == .s88MK2)
        #expect(KompleteKontrolDeviceModel.parse(deviceInfoMessage: "no session") == nil)
        #expect(KompleteKontrolDeviceModel.parse(deviceInfoMessage: "product=0xffff keys=0") == nil)
    }

    @Test("MIDI notes map onto the physical keybed, out-of-range notes to nil")
    func lightGuideKeyIndex() {
        // S61 spans C1 (MIDI 36) to C6 (MIDI 96).
        #expect(KompleteKontrolDeviceModel.s61MK2.lightGuideKeyIndex(forMIDINote: 36) == 0)
        #expect(KompleteKontrolDeviceModel.s61MK2.lightGuideKeyIndex(forMIDINote: 72) == 36)
        #expect(KompleteKontrolDeviceModel.s61MK2.lightGuideKeyIndex(forMIDINote: 96) == 60)
        #expect(KompleteKontrolDeviceModel.s61MK2.lightGuideKeyIndex(forMIDINote: 35) == nil)
        #expect(KompleteKontrolDeviceModel.s61MK2.lightGuideKeyIndex(forMIDINote: 97) == nil)
        // S88 starts at A0 (MIDI 21).
        #expect(KompleteKontrolDeviceModel.s88MK2.lightGuideKeyIndex(forMIDINote: 21) == 0)
        #expect(KompleteKontrolDeviceModel.s88MK2.lightGuideKeyIndex(forMIDINote: 108) == 87)
    }
}
