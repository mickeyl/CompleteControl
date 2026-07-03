import Testing
import KompleteKontrol

@Suite("MK2 button LED capabilities")
struct MK2ButtonLEDCapabilityTests {
    @Test("Only Mute, Solo, and F1-F8 are RGB backlit")
    func rgbBacklitButtons() {
        let rgbButtons = Set(KKMK2ButtonLED.allCases.filter(\.isRGBBacklit))
        #expect(rgbButtons == [
            .m, .s,
            .function1, .function2, .function3, .function4,
            .function5, .function6, .function7, .function8,
        ])
    }

    @Test("Monochrome buttons encode requested colours as white intensity")
    func monochromeButtonsEncodeWhite() {
        let red = KKRGB(red: 0xff, green: 0x00, blue: 0x00)
        let white = KKRGB(red: 0xff, green: 0xff, blue: 0xff)

        #expect(KKMK2ButtonLED.clear.ledByte(for: red) == KKMK2ButtonLED.clear.ledByte(for: white))
        #expect(KKMK2ButtonLED.clear.ledByte(for: .off) == 0)
        #expect(KKMK2ButtonLED.function1.ledByte(for: red) != KKMK2ButtonLED.function1.ledByte(for: white))
    }

    @Test("Play and Stop are fixed-colour monochrome indicators")
    func fixedColorMonochromeButtons() {
        #expect(KKMK2ButtonLED.play.fixedMonochromeBacklightColor == KKRGB(red: 0x00, green: 0xff, blue: 0x00))
        #expect(KKMK2ButtonLED.stop.fixedMonochromeBacklightColor == KKRGB(red: 0xff, green: 0x00, blue: 0x00))
        #expect(KKMK2ButtonLED.clear.fixedMonochromeBacklightColor == KKRGB(red: 0xff, green: 0xff, blue: 0xff))
    }
}
