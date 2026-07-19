@_exported import KontrolSimulatorWire

public extension SimFrame {
    static func button(led: KKMK2ButtonLED, pressed: Bool) -> SimFrame {
        SimFrame(type: .button, payload: [UInt8(led.rawValue & 0xff), pressed ? 1 : 0])
    }

    static func encoder(index: Int, delta: Int) -> SimFrame {
        SimFrame(type: .encoder, payload: [UInt8(index & 0xff), UInt8(bitPattern: Int8(clamping: delta))])
    }

    static func encoderTouch(index: Int, touched: Bool) -> SimFrame {
        SimFrame(type: .encoderTouch, payload: [UInt8(index & 0xff), touched ? 1 : 0])
    }

    static func fourDWheel(delta: Int) -> SimFrame {
        SimFrame(type: .fourDWheel, payload: [UInt8(bitPattern: Int8(clamping: delta))])
    }

    static func fourDState(_ raw: UInt8) -> SimFrame {
        SimFrame(type: .fourDState, payload: [raw])
    }

    static func fourDTouch(touched: Bool) -> SimFrame {
        fourDState(touched ? MK2InputReportBuilder.FourDState.touched.rawValue : MK2InputReportBuilder.FourDState.released.rawValue)
    }

    static func note(_ note: UInt8, velocity: UInt8, on: Bool) -> SimFrame {
        SimFrame(type: .note, payload: [note, velocity, on ? 1 : 0])
    }

    static func midi(status: UInt8, data1: UInt8, data2: UInt8) -> SimFrame {
        SimFrame(type: .midi, payload: [status, data1, data2])
    }

    static func strip(position: Int?, time: Int) -> SimFrame {
        let value = UInt16(max(0, min(1024, position ?? 0)))
        let timestamp = UInt16(max(0, min(Int(UInt16.max), time)))
        return SimFrame(type: .strip, payload: [
            UInt8(value >> 8), UInt8(value & 0xff),
            UInt8(timestamp >> 8), UInt8(timestamp & 0xff),
        ])
    }
}
