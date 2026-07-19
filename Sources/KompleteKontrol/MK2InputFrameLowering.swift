import Foundation

/// Lowers a semantic `SimFrame` input gesture into raw MK2 report/MIDI bytes — the transparency
/// linchpin shared by `SimulatorDeviceSession` (semantic events arriving over the sim wire) and
/// the daemon's automation-socket handler (semantic events arriving over the automation REPL).
/// One source of truth keeps both callers byte-identical to real hardware, matching the layout
/// `KKMK2InputReportDecoder` reads (see `MK2InputReportBuilder`).
public enum MK2InputFrameLowering {
    public static func apply(
        _ frame: SimFrame,
        builder: inout MK2InputReportBuilder,
        emitInput: (UnsafePointer<UInt8>, UInt32) -> Void,
        emitMIDI: (UnsafePointer<UInt8>, UInt32) -> Void
    ) {
        switch frame.type {
            case .button:
                guard frame.payload.count >= 2, let led = KKMK2ButtonLED(rawValue: Int(frame.payload[0])) else { return }
                builder.setButton(led, pressed: frame.payload[1] != 0)
                emitInputReport(builder: builder, emitInput: emitInput)
            case .encoder:
                guard frame.payload.count >= 2 else { return }
                builder.turnEncoder(Int(frame.payload[0]), delta: Int(Int8(bitPattern: frame.payload[1])))
                emitInputReport(builder: builder, emitInput: emitInput)
            case .encoderTouch:
                guard frame.payload.count >= 2 else { return }
                builder.setEncoderTouch(Int(frame.payload[0]), touched: frame.payload[1] != 0)
                emitInputReport(builder: builder, emitInput: emitInput)
            case .fourDWheel:
                guard frame.payload.count >= 1 else { return }
                builder.turnFourDWheel(delta: Int(Int8(bitPattern: frame.payload[0])))
                emitInputReport(builder: builder, emitInput: emitInput)
            case .fourDState:
                guard frame.payload.count >= 1,
                      let state = MK2InputReportBuilder.FourDState(rawValue: frame.payload[0]) else { return }
                builder.setFourD(state)
                emitInputReport(builder: builder, emitInput: emitInput)
            case .note:
                guard frame.payload.count >= 3 else { return }
                let note = frame.payload[0]
                let velocity = frame.payload[1]
                let on = frame.payload[2] != 0
                emitMIDIBytes([on ? 0x09 : 0x08, on ? 0x90 : 0x80, note, on ? velocity : 0x00], emitMIDI: emitMIDI)
            case .midi:
                guard frame.payload.count >= 3 else { return }
                let status = frame.payload[0]
                let codeIndex: UInt8
                switch status & 0xf0 {
                    case 0x80:
                        codeIndex = 0x08
                    case 0x90:
                        codeIndex = frame.payload[2] == 0 ? 0x08 : 0x09
                    case 0xb0:
                        codeIndex = 0x0b
                    case 0xd0:
                        codeIndex = 0x0d
                    case 0xe0:
                        codeIndex = 0x0e
                    default:
                        codeIndex = 0x00
                }
                guard codeIndex != 0 else { return }
                emitMIDIBytes([codeIndex, status, frame.payload[1], frame.payload[2]], emitMIDI: emitMIDI)
            case .strip:
                guard frame.payload.count >= 4 else { return }
                let position = (UInt16(frame.payload[0]) << 8) | UInt16(frame.payload[1])
                let time = (UInt16(frame.payload[2]) << 8) | UInt16(frame.payload[3])
                emitStripReport(position: position, time: time, emitInput: emitInput)
            case .hello, .identity, .surfaceInput, .midiInput, .displayBlit, .displayPacket, .report:
                break // hello reserved; identity is handled by SimulatorDeviceSession itself; output frame types are never lowered
        }
    }

    private static func emitInputReport(
        builder: MK2InputReportBuilder,
        emitInput: (UnsafePointer<UInt8>, UInt32) -> Void
    ) {
        builder.bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            emitInput(base, UInt32(buffer.count))
        }
    }

    private static func emitStripReport(
        position: UInt16,
        time: UInt16,
        emitInput: (UnsafePointer<UInt8>, UInt32) -> Void
    ) {
        var bytes = [UInt8](repeating: 0, count: 9)
        bytes[0] = KompleteKontrolMK2Protocol.stripReportID
        bytes[5] = UInt8(time & 0xff)
        bytes[6] = UInt8(time >> 8)
        bytes[7] = UInt8(position & 0xff)
        bytes[8] = UInt8(position >> 8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            emitInput(base, UInt32(buffer.count))
        }
    }

    private static func emitMIDIBytes(
        _ bytes: [UInt8],
        emitMIDI: (UnsafePointer<UInt8>, UInt32) -> Void
    ) {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            emitMIDI(base, UInt32(buffer.count))
        }
    }
}
