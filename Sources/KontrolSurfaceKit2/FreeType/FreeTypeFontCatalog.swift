import Foundation

public enum FreeTypeFontWeight: Int, CaseIterable, Sendable, Comparable {
    case light = 300
    case regular = 400
    case text = 450
    case medium = 500
    case semiBold = 600
    case bold = 700

    public static func < (lhs: FreeTypeFontWeight, rhs: FreeTypeFontWeight) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
            case .light: "Light"
            case .regular: "Regular"
            case .text: "Text"
            case .medium: "Medium"
            case .semiBold: "SemiBold"
            case .bold: "Bold"
        }
    }
}

public struct FreeTypeFontSource: Sendable, Equatable {
    public var resourceName: String
    public var faceIndex: Int
    public var variationWeight: Int?

    public init(resourceName: String, faceIndex: Int = 0, variationWeight: Int? = nil) {
        self.resourceName = resourceName
        self.faceIndex = faceIndex
        self.variationWeight = variationWeight
    }
}

public struct FreeTypeFontFamily: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var faces: [FreeTypeFontWeight: FreeTypeFontSource]

    public init(id: String, label: String, faces: [FreeTypeFontWeight: FreeTypeFontSource]) {
        self.id = id
        self.label = label
        self.faces = faces
    }

    public func source(for weight: FreeTypeFontWeight) -> FreeTypeFontSource {
        if let exact = faces[weight] { return exact }
        return faces.min { abs($0.key.rawValue - weight.rawValue) < abs($1.key.rawValue - weight.rawValue) }!.value
    }
}

public struct FreeTypeFontCatalog: Sendable, Equatable {
    public static let textFamilyID = MK2HIG.Fonts.textFamilyID
    public static let iconFamilyID = MK2HIG.Fonts.iconFamilyID
    public static let monoFamilyID = MK2HIG.Fonts.monoFamilyID

    public var families: [FreeTypeFontFamily]

    public init(families: [FreeTypeFontFamily]) {
        self.families = families
    }

    public func family(id: String) -> FreeTypeFontFamily? {
        families.first { $0.id == id }
    }

    public static let production = FreeTypeFontCatalog(families: [
        FreeTypeFontFamily(
            id: Self.textFamilyID,
            label: MK2HIG.Fonts.textFamilyName,
            faces: [
                .regular: FreeTypeFontSource(resourceName: MK2HIG.Fonts.textRegularResourceName),
                .medium: FreeTypeFontSource(resourceName: MK2HIG.Fonts.textMediumResourceName),
            ]
        ),
        FreeTypeFontFamily(
            id: Self.iconFamilyID,
            label: MK2HIG.Fonts.iconFamilyName,
            faces: [
                .regular: FreeTypeFontSource(resourceName: MK2HIG.Fonts.iconResourceName),
            ]
        ),
        FreeTypeFontFamily(
            id: Self.monoFamilyID,
            label: MK2HIG.Fonts.monoFamilyName,
            faces: [
                .regular: FreeTypeFontSource(resourceName: MK2HIG.Fonts.monoRegularResourceName),
                .bold: FreeTypeFontSource(resourceName: MK2HIG.Fonts.monoBoldResourceName),
            ]
        ),
    ])

    public static let exploratory = production
}
