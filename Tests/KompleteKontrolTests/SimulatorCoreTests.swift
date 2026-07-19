import Testing
import KompleteKontrol
import KontrolSimulatorCore

@Suite("Headless simulator core")
struct SimulatorCoreTests {
    @Test("MK3 geometry covers every native button exactly once and stays in bounds")
    func geometryCoverage() {
        let geometry = MaschineMK3PanelGeometry.calibrated
        let buttons = geometry.buttons.map(\.button)
        #expect(buttons.count == MaschineMK3Button.allCases.count)
        #expect(Set(buttons).count == buttons.count)
        #expect(Set(buttons) == Set(MaschineMK3Button.allCases))
        #expect(geometry.displays.count == 2)
        #expect(geometry.displayEncoders.count == 8)
        #expect(geometry.pads.count == 16)
        #expect(geometry.padShiftLabels == [
            "Undo", "Redo", "Step Undo", "Step Redo",
            "Quantize", "Quantize 50%", "Nudge <", "Nudge >",
            "Clear", "Clear Auto", "Copy", "Paste",
            "Semitone -", "Semitone +", "Octave -", "Octave +",
        ])

        let allRects = geometry.displays + geometry.displayEncoders + geometry.pads
            + [geometry.mainEncoder, geometry.touchStrip] + geometry.buttons.map(\.rect)
        for rect in allRects {
            #expect(rect.x >= 0)
            #expect(rect.y >= 0)
            #expect(rect.width > 0)
            #expect(rect.height > 0)
            #expect(rect.x + rect.width <= MaschineMK3PanelGeometry.panelWidth)
            #expect(rect.y + rect.height <= MaschineMK3PanelGeometry.panelHeight)
        }

        let descriptors = Dictionary(uniqueKeysWithValues: geometry.buttons.map { ($0.button, $0.rect) })
        let rightDisplay = geometry.displays[1]
        let pad16 = geometry.pads[15]
        #expect(
            rightDisplay.x + rightDisplay.width + MaschineMK3PanelGeometry.displayBezelOutset
                == descriptors[.displayButton8]!.x + descriptors[.displayButton8]!.width
        )
        #expect(descriptors[.step]!.x + descriptors[.step]!.width == pad16.x + pad16.width)
        let leftColumnRightEdge = descriptors[.notes]!.x + descriptors[.notes]!.width
        #expect(leftColumnRightEdge == descriptors[.follow]!.x + descriptors[.follow]!.width)
        #expect(leftColumnRightEdge == descriptors[.groupD]!.x + descriptors[.groupD]!.width)
        #expect(leftColumnRightEdge == descriptors[.groupH]!.x + descriptors[.groupH]!.width)
        #expect(geometry.touchStrip.x == descriptors[.pitch]!.x)
        #expect(geometry.touchStrip.x + geometry.touchStrip.width == leftColumnRightEdge)
        let padColumnBottom = geometry.pads.map { $0.y + $0.height }.max()!
        #expect(descriptors[.mute]!.y + descriptors[.mute]!.height == padColumnBottom)
        let transportButtons: [MaschineMK3Button] = [
            .restart, .erase, .tap, .follow, .play, .record, .stop, .shift,
        ]
        let transportBottom = transportButtons.map {
            descriptors[$0]!.y + descriptors[$0]!.height
        }.max()!
        #expect(transportBottom == padColumnBottom)
        #expect(descriptors[.noteRepeat]!.y == descriptors[.volume]!.y)
        #expect(
            descriptors[.noteRepeat]!.y + descriptors[.noteRepeat]!.height
                == descriptors[.swing]!.y + descriptors[.swing]!.height
        )
        #expect(descriptors[.noteRepeat]!.height > descriptors[.volume]!.height * 2)
        #expect(descriptors[.lock]!.y == descriptors[.tempo]!.y)
    }

    @Test("MK3 headless gestures emit native reports")
    func nativeGestures() throws {
        let definition = SimulatorDeviceDefinition.definition(for: .maschineMK3)
        let runtime = SimulatorDeviceRuntime(definition: definition)
        var frames: [SimFrame] = []
        runtime.onInputFrame = { frames.append($0) }

        runtime.setMaschineButton(.keyboard, pressed: true)
        runtime.turnMaschineEncoder(3, delta: 5)
        runtime.strikeMaschinePad(physicalPad: 16, velocity: 2048)

        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.type == .surfaceInput })
        #expect(MaschineMK3InputReportDecoder.surfaceEvents(previous: nil, current: frames[0].payload)
            .contains(.button(button: .keyboard, pressed: true)))
        #expect(MaschineMK3InputReportDecoder.surfaceEvents(previous: frames[0].payload, current: frames[1].payload)
            .contains(.encoder(index: 3, delta: 5, value: 5)))
        let pad = try #require(MaschineMK3InputReportDecoder.padInputs(in: frames[2].payload).first)
        #expect(pad.physicalPadNumber == 16)
        #expect(pad.value == .strikeVelocity(2048))
    }

    @Test("MK3 native output reports reduce to panel lamps")
    func nativeOutputReduction() throws {
        let definition = SimulatorDeviceDefinition.definition(for: .maschineMK3)
        let state = SimulatorOutputState(definition: definition)
        var buttons = MaschineMK3Protocol.clearedButtonLEDPayload()
        buttons[MaschineMK3ButtonLED.padMode.rawValue] = MaschineMK3Protocol.monochromeBrightLEDValue
        var stripAndPads = MaschineMK3Protocol.clearedStripLEDPayload()
        stripAndPads[MaschineMK3PadLED.pad1.rawValue] = 0x27

        #expect(try state.apply(.report(reportID: MaschineMK3Protocol.buttonLEDReportID, bytes: buttons)))
        #expect(try state.apply(.report(reportID: MaschineMK3Protocol.stripLEDReportID, bytes: stripAndPads)))
        let snapshot = state.lampSnapshot()
        #expect(snapshot.buttonBytes[MaschineMK3ButtonLED.padMode.rawValue] == MaschineMK3Protocol.monochromeBrightLEDValue)
        #expect(snapshot.stripAndPadBytes[MaschineMK3PadLED.pad1.rawValue] == 0x27)
    }

    @Test("Logical display blits land in the shared framebuffer")
    func displayBlit() throws {
        let state = SimulatorOutputState(definition: .definition(for: .maschineMK3))
        let pixels: [UInt8] = [0xf8, 0x00, 0x00, 0x1f]
        #expect(try state.apply(.displayBlit(
            screen: 1, x: 3, y: 4, width: 2, height: 1, pixelsBE: pixels
        )))
        let snapshot = state.screens[1].snapshot()
        let offset = (4 * snapshot.width + 3) * 2
        #expect(Array(snapshot.pixelsBE[offset..<(offset + 4)]) == pixels)
    }
}
