import Foundation

public enum KontrolDeviceFamily: String, Sendable {
    case kompleteKontrolMK2 = "komplete-kontrol-mk2"
    case maschineMK3 = "maschine-mk3"
}

public struct KontrolDeviceCapabilities: Sendable, Equatable {
    public var screenCount: Int
    public var keyCount: Int
    public var padCount: Int
    public var hasLightGuide: Bool
    public var hasTouchStrip: Bool
    public var claimsUSBMIDI: Bool

    public init(
        screenCount: Int,
        keyCount: Int,
        padCount: Int,
        hasLightGuide: Bool,
        hasTouchStrip: Bool,
        claimsUSBMIDI: Bool
    ) {
        self.screenCount = screenCount
        self.keyCount = keyCount
        self.padCount = padCount
        self.hasLightGuide = hasLightGuide
        self.hasTouchStrip = hasTouchStrip
        self.claimsUSBMIDI = claimsUSBMIDI
    }
}

public struct KontrolDeviceProfile: Sendable, Equatable {
    public var productID: UInt16
    public var name: String
    public var family: KontrolDeviceFamily
    public var capabilities: KontrolDeviceCapabilities

    public init(
        productID: UInt16,
        name: String,
        family: KontrolDeviceFamily,
        capabilities: KontrolDeviceCapabilities
    ) {
        self.productID = productID
        self.name = name
        self.family = family
        self.capabilities = capabilities
    }

    public static func productID(_ productID: UInt16, reportedKeyCount: UInt8 = 0) -> KontrolDeviceProfile? {
        if productID == MaschineMK3Protocol.productID {
            return KontrolDeviceProfile(
                productID: productID,
                name: "MASCHINE MK3",
                family: .maschineMK3,
                capabilities: KontrolDeviceCapabilities(
                    screenCount: 2,
                    keyCount: 0,
                    padCount: 16,
                    hasLightGuide: false,
                    hasTouchStrip: true,
                    claimsUSBMIDI: false
                )
            )
        }
        guard let model = KompleteKontrolDeviceModel.productID(Int(productID)) else { return nil }
        return KontrolDeviceProfile(
            productID: productID,
            name: model.name,
            family: .kompleteKontrolMK2,
            capabilities: KontrolDeviceCapabilities(
                screenCount: 2,
                keyCount: reportedKeyCount == 0 ? model.keyCount : Int(reportedKeyCount),
                padCount: 0,
                hasLightGuide: true,
                hasTouchStrip: true,
                claimsUSBMIDI: true
            )
        )
    }
}
