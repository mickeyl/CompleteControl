import Foundation
import KompleteKontrol
import KontrolSimulatorWire

public enum SimulatorDeviceKind: String, CaseIterable, Sendable {
    case kompleteKontrolS61MK2 = "komplete-kontrol-s61-mk2"
    case maschineMK3 = "maschine-mk3"

    public init?(argument: String) {
        switch argument.lowercased() {
            case "komplete-kontrol-s61-mk2", "kontrol-mk2", "mk2", "s61":
                self = .kompleteKontrolS61MK2
            case "maschine-mk3", "maschine", "mk3":
                self = .maschineMK3
            default:
                return nil
        }
    }
}

public struct SimulatorPhysicalSize: Sendable, Equatable {
    public var widthMM: Double
    public var heightMM: Double

    public init(widthMM: Double, heightMM: Double) {
        self.widthMM = widthMM
        self.heightMM = heightMM
    }
}

public struct SimulatorDeviceDefinition: Sendable, Equatable {
    public var kind: SimulatorDeviceKind
    public var descriptor: SimulatorDeviceDescriptor
    public var displayName: String
    public var shortName: String
    public var physicalSize: SimulatorPhysicalSize

    public init(
        kind: SimulatorDeviceKind,
        descriptor: SimulatorDeviceDescriptor,
        displayName: String,
        shortName: String,
        physicalSize: SimulatorPhysicalSize
    ) {
        self.kind = kind
        self.descriptor = descriptor
        self.displayName = displayName
        self.shortName = shortName
        self.physicalSize = physicalSize
    }

    public static func definition(
        for kind: SimulatorDeviceKind,
        instanceID: String = "main"
    ) -> SimulatorDeviceDefinition {
        switch kind {
            case .kompleteKontrolS61MK2:
                return SimulatorDeviceDefinition(
                    kind: kind,
                    descriptor: SimulatorDeviceDescriptor(
                        productID: 0x1620,
                        keyCount: 61,
                        firmwareVersion: 0x0100,
                        instanceID: instanceID,
                        capabilities: [.rawSurfaceInput, .rawMIDIInput, .displayBlits, .displayPackets, .outputReports]
                    ),
                    displayName: "Komplete Kontrol S61 MK2",
                    shortName: "KONTROL MK2",
                    physicalSize: SimulatorPhysicalSize(widthMM: 1006, heightMM: 297)
                )
            case .maschineMK3:
                return SimulatorDeviceDefinition(
                    kind: kind,
                    descriptor: SimulatorDeviceDescriptor(
                        productID: MaschineMK3Protocol.productID,
                        keyCount: 0,
                        firmwareVersion: 0x0146,
                        instanceID: instanceID,
                        capabilities: [.rawSurfaceInput, .displayBlits, .displayPackets, .outputReports]
                    ),
                    displayName: "MASCHINE MK3",
                    shortName: "MASCHINE MK3",
                    physicalSize: SimulatorPhysicalSize(widthMM: 320, heightMM: 301)
                )
        }
    }
}
