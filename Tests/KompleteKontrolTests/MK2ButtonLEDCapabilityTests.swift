import Testing
import KompleteKontrol

@Suite("MK2 button LED capabilities")
struct MK2ButtonLEDCapabilityTests {
    @Test("Mute, Solo, F1-F8, and touch-strip LEDs are palette backlit")
    func rgbBacklitButtons() {
        let stripLEDs = (KKMK2ButtonLED.strip1.rawValue...KKMK2ButtonLED.strip25.rawValue)
            .compactMap(KKMK2ButtonLED.init(rawValue:))
        let rgbButtons = Set(KKMK2ButtonLED.allCases.filter(\.isRGBBacklit))
        #expect(rgbButtons == Set([
            .m, .s,
            .function1, .function2, .function3, .function4,
            .function5, .function6, .function7, .function8,
        ] + stripLEDs))
    }

    @Test("Monochrome buttons encode requested colours as white intensity")
    func monochromeButtonsEncodeWhite() {
        let red = KKRGB(red: 0xff, green: 0x00, blue: 0x00)
        let white = KKRGB(red: 0xff, green: 0xff, blue: 0xff)

        #expect(KKMK2ButtonLED.clear.ledByte(for: red) == KKMK2ButtonLED.clear.ledByte(for: white))
        #expect(KKMK2ButtonLED.clear.ledByte(for: .off) == 0)
        #expect(KKMK2ButtonLED.function1.ledByte(for: red) != KKMK2ButtonLED.function1.ledByte(for: white))
        #expect(KKMK2ButtonLED.strip1.ledByte(for: red) != KKMK2ButtonLED.strip1.ledByte(for: white))
    }

    @Test("Play and Record are fixed-colour monochrome indicators")
    func fixedColorMonochromeButtons() {
        #expect(KKMK2ButtonLED.play.fixedMonochromeBacklightColor == KKRGB(red: 0x00, green: 0xff, blue: 0x00))
        #expect(KKMK2ButtonLED.record.fixedMonochromeBacklightColor == KKRGB(red: 0xff, green: 0x00, blue: 0x00))
        #expect(KKMK2ButtonLED.stop.fixedMonochromeBacklightColor == KKRGB(red: 0xff, green: 0xff, blue: 0xff))
        #expect(KKMK2ButtonLED.clear.fixedMonochromeBacklightColor == KKRGB(red: 0xff, green: 0xff, blue: 0xff))
    }

    @Test("Explicit MK2 LED intensity is encoded for RGB and monochrome buttons")
    func explicitIntensity() {
        let green = KKRGB(red: 0x00, green: 0xff, blue: 0x66)
        let white = KKRGB(red: 0xff, green: 0xff, blue: 0xff)

        #expect(KKMK2ButtonLED.function1.ledByte(for: green, intensity: 0x01) & 0x03 == 0x01)
        #expect(KKMK2ButtonLED.function1.ledByte(for: green, intensity: 0x03) & 0x03 == 0x03)
        #expect(KKMK2ButtonLED.pageRight.ledByte(for: white, intensity: 0x01) & 0x03 == 0x01)
        #expect(KKMK2ButtonLED.stop.ledByte(for: green, intensity: 0x03) == KKMK2ButtonLED.stop.ledByte(for: white, intensity: 0x03))
    }

    @Test("Simulator palette decoding preserves half and full brightness")
    func simulatorPaletteBrightness() {
        let white = KKRGB(red: 0xff, green: 0xff, blue: 0xff)
        let halfCode = KompleteKontrolSSeriesMK2.paletteCode(for: white, intensity: 0x01)
        let fullCode = KompleteKontrolSSeriesMK2.paletteCode(for: white, intensity: 0x03)
        let half = KompleteKontrolSSeriesMK2.paletteColor(forCode: halfCode)
        let full = KompleteKontrolSSeriesMK2.paletteColor(forCode: fullCode)

        #expect(max(half.red, half.green, half.blue) == 127)
        #expect(max(full.red, full.green, full.blue) == 255)
    }
}
