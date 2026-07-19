import Foundation
import Testing
import KompleteKontrol

/// The transparency guarantee, proven without hardware: a semantic edit built into a raw
/// `0x01` report and run back through the real client decoder must yield exactly the event
/// that edit represents. If the builder and decoder ever drift, these fail.
@Suite("MK2 input report builder ↔ decoder round-trip")
struct MK2InputReportBuilderTests {
    private func decode(_ before: MK2InputReportBuilder, _ after: MK2InputReportBuilder) -> [KKMK2InputEvent] {
        KKMK2InputReportDecoder.eventsForReport(previous: before.bytes, current: after.bytes)
    }

    @Test("Function buttons 1…8 round-trip to their button events")
    func functionButtons() {
        let functions: [KKMK2ButtonLED] = [
            .function1, .function2, .function3, .function4,
            .function5, .function6, .function7, .function8,
        ]
        for led in functions {
            let before = MK2InputReportBuilder()
            var after = before
            after.setButton(led, pressed: true)
            #expect(decode(before, after) == [.button(led: led, pressed: true)])
            // And release.
            #expect(decode(after, before) == [.button(led: led, pressed: false)])
        }
    }

    @Test("A spread of non-function buttons round-trip")
    func otherButtons() {
        for led in [KKMK2ButtonLED.play, .shift, .mixer, .clear, .octaveUp] {
            let before = MK2InputReportBuilder()
            var after = before
            after.setButton(led, pressed: true)
            #expect(decode(before, after) == [.button(led: led, pressed: true)])
        }
    }

    @Test("Rotary encoder delta and absolute value round-trip")
    func encoderTurn() {
        let before = MK2InputReportBuilder()
        var after = before
        after.turnEncoder(3, delta: 5)
        #expect(decode(before, after) == [.knob(index: 3, delta: 5, value: 5)])
    }

    @Test("Encoder counter wraps 0…999 with a correct signed delta")
    func encoderWrap() {
        var before = MK2InputReportBuilder()
        before.turnEncoder(4, delta: 998)
        var after = before
        after.turnEncoder(4, delta: 4) // 998 -> 2
        #expect(decode(before, after) == [.knob(index: 4, delta: 4, value: 2)])
    }

    @Test("Encoder touch round-trips")
    func encoderTouch() {
        let before = MK2InputReportBuilder()
        var after = before
        after.setEncoderTouch(2, touched: true)
        #expect(decode(before, after) == [.touchEncoder(index: 2, touched: true)])
    }

    @Test("4-D wheel rotation round-trips as a jog scroll")
    func fourDWheel() {
        let before = MK2InputReportBuilder()
        var after = before
        after.turnFourDWheel(delta: 1)
        #expect(decode(before, after) == [.jogScroll(delta: 1, value: 1)])
    }

    @Test("4-D pushes and click round-trip to jog directions")
    func fourDPushes() {
        let cases: [(MK2InputReportBuilder.FourDState, KK4DNavigationDirection)] = [
            (.pushLeft, .left), (.pushUp, .up), (.pushDown, .down),
            (.pushRight, .right),
        ]
        for (state, direction) in cases {
            let before = MK2InputReportBuilder()
            var after = before
            after.setFourD(state)
            let events = decode(before, after)
            #expect(events.contains(.jog(direction: direction)))
            #expect(events.contains(.jogTouch(touched: true))) // pushes carry the touch bit
        }
    }

    @Test("4-D push release does not confirm; click release does")
    func fourDCenterSemantics() {
        var before = MK2InputReportBuilder()
        before.setFourD(.pushLeft)
        var after = before
        after.setFourD(.touched)
        #expect(decode(before, after) == [])

        var clicked = MK2InputReportBuilder()
        clicked.setFourD(.click)
        var released = clicked
        released.setFourD(.touched)
        #expect(decode(clicked, released) == [.jogCenter])
    }

    @Test("Report id and length are stable so the decoder's diff always applies")
    func reportShape() {
        let report = MK2InputReportBuilder()
        #expect(report.bytes.count == MK2InputReportBuilder.reportLength)
        #expect(report.bytes[0] == UInt8(KompleteKontrolMK2Protocol.inputReportID))
    }
}

@Suite("Simulator wire codec")
struct SimWireCodecTests {
    @Test("Versioned device descriptors round-trip with capabilities")
    func descriptorRoundTrip() throws {
        let descriptor = SimulatorDeviceDescriptor(
            productID: MaschineMK3Protocol.productID,
            keyCount: 0,
            firmwareVersion: 0x0146,
            instanceID: "mk3-test",
            reportedName: "Studio MK3",
            capabilities: [.rawSurfaceInput, .displayPackets, .outputReports]
        )
        let decoded = try SimulatorDeviceDescriptor(payload: descriptor.encodedPayload())
        #expect(decoded == descriptor)
        #expect(SimFrame.hello(descriptor: descriptor).type == .hello)
    }

    @Test("Oversized payload headers are rejected before buffering their body")
    func oversizedPayload() {
        let oversized = UInt32(SimWireProtocol.maximumPayloadLength + 1)
        let bytes: [UInt8] = [
            SimFrameType.surfaceInput.rawValue,
            UInt8(oversized >> 24), UInt8((oversized >> 16) & 0xff),
            UInt8((oversized >> 8) & 0xff), UInt8(oversized & 0xff),
        ]
        #expect(throws: SimWireError.payloadTooLarge(Int(oversized))) {
            _ = try SimWireCodec.decodeChecked(bytes)
        }
    }

    @Test("Encode → decode round-trips a single frame and reports consumption")
    func roundTrip() {
        let frame = SimFrame.button(led: .function3, pressed: true)
        let (frames, consumed) = SimWireCodec.decode(SimWireCodec.encode(frame))
        #expect(frames == [frame])
        #expect(consumed == SimWireCodec.encode(frame).count)
    }

    @Test("Multiple concatenated frames all decode in order")
    func multiple() {
        let a = SimFrame.hello(productID: 0x1610, keyCount: 61)
        let b = SimFrame.encoder(index: 2, delta: -3)
        let c = SimFrame.fourDWheel(delta: 1)
        let bytes = SimWireCodec.encode(a) + SimWireCodec.encode(b) + SimWireCodec.encode(c)
        let (frames, consumed) = SimWireCodec.decode(bytes)
        #expect(frames == [a, b, c])
        #expect(consumed == bytes.count)
    }

    @Test("A truncated trailing frame is left unconsumed for the next read")
    func partial() {
        let frame = SimFrame.displayBlit(screen: 0, x: 0, y: 0, width: 2, height: 1, pixelsBE: [0xf8, 0x00, 0x00, 0x1f])
        var bytes = SimWireCodec.encode(frame)
        let full = bytes.count
        bytes.removeLast() // truncate mid-payload
        let (frames, consumed) = SimWireCodec.decode(bytes)
        #expect(frames.isEmpty)
        #expect(consumed == 0)
        // Re-append the missing byte and it decodes cleanly.
        bytes.append(0x1f)
        let (frames2, consumed2) = SimWireCodec.decode(bytes)
        #expect(frames2 == [frame])
        #expect(consumed2 == full)
    }

    @Test("Encoder delta survives as a signed byte")
    func signedEncoder() {
        let (frames, _) = SimWireCodec.decode(SimWireCodec.encode(SimFrame.encoder(index: 5, delta: -7)))
        #expect(frames.first?.type == .encoder)
        #expect(frames.first?.payload[0] == 5)
        #expect(Int8(bitPattern: frames.first!.payload[1]) == -7)
    }

    @Test("Raw display packets round-trip without interpretation in SimWire")
    func displayPacketRoundTrip() {
        let packet: [UInt8] = [0x84, 0x00, 0x00, 0x60, 0x00, 0x00]
        let frame = SimFrame.displayPacket(packet)
        let (frames, consumed) = SimWireCodec.decode(SimWireCodec.encode(frame))
        #expect(frames == [frame])
        #expect(consumed == SimWireCodec.encode(frame).count)
    }
}

@Suite("MASCHINE MK3 input report builder ↔ decoder round-trip")
struct MaschineMK3InputReportBuilderTests {
    @Test("Every mapped button uses the production decoder table")
    func buttons() {
        for button in MaschineMK3Button.allCases {
            let before = MaschineMK3InputReportBuilder()
            var after = before
            after.setButton(button, pressed: true)
            #expect(MaschineMK3InputReportDecoder.surfaceEvents(
                previous: before.surfaceBytes,
                current: after.surfaceBytes
            ) == [.button(button: button, pressed: true)])
        }
    }

    @Test("Main/display encoders, touch and strip are native surface changes")
    func surfaceControls() {
        var builder = MaschineMK3InputReportBuilder()
        var previous = builder.surfaceBytes
        builder.turnEncoder(0, delta: -1)
        #expect(MaschineMK3InputReportDecoder.surfaceEvents(previous: previous, current: builder.surfaceBytes)
            == [.encoder(index: 0, delta: -1, value: 15)])

        previous = builder.surfaceBytes
        builder.turnEncoder(5, delta: 7)
        #expect(MaschineMK3InputReportDecoder.surfaceEvents(previous: previous, current: builder.surfaceBytes)
            == [.encoder(index: 5, delta: 7, value: 7)])

        previous = builder.surfaceBytes
        builder.setEncoderTouch(5, touched: true)
        #expect(MaschineMK3InputReportDecoder.surfaceEvents(previous: previous, current: builder.surfaceBytes)
            == [.encoderTouch(index: 5, touched: true)])

        previous = builder.surfaceBytes
        builder.setTouchStrip(finger: 2, position: 800)
        #expect(MaschineMK3InputReportDecoder.surfaceEvents(previous: previous, current: builder.surfaceBytes)
            == [.touchStrip(finger: 2, position: 800)])
    }

    @Test("Pad strike, pressure and release form a complete native lifecycle")
    func padLifecycle() throws {
        var builder = MaschineMK3InputReportBuilder()
        let hardwareIndex = try #require(MaschineMK3InputReportBuilder.hardwareIndex(forPhysicalPadNumber: 1))
        var tracker = MaschineMK3PadStateTracker()

        let strikeReport = builder.padStrike(hardwareIndex: hardwareIndex, velocity: 3000)
        let strike = try #require(strikeReport)
        #expect(tracker.events(for: MaschineMK3InputReportDecoder.padInputs(in: strike)).first?.phase == .down)
        let pressureReport = builder.padPressure(hardwareIndex: hardwareIndex, pressure: 1700)
        let pressure = try #require(pressureReport)
        #expect(tracker.events(for: MaschineMK3InputReportDecoder.padInputs(in: pressure)).first?.phase == .pressure)
        let releaseReport = builder.padRelease(hardwareIndex: hardwareIndex)
        let release = try #require(releaseReport)
        #expect(tracker.events(for: MaschineMK3InputReportDecoder.padInputs(in: release)).first?.phase == .up)
    }
}
