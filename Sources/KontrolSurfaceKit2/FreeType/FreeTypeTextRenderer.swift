import CFreeType
import Foundation

public enum FreeTypeRasterMode: Int, CaseIterable, Sendable, Equatable {
    case grayscaleHinted
    case grayscaleLightHinted
    case grayscaleUnhinted
    case monochromeHinted

    public var label: String {
        switch self {
            case .grayscaleHinted: "Gray hinted"
            case .grayscaleLightHinted: "Gray light"
            case .grayscaleUnhinted: "Gray unhinted"
            case .monochromeHinted: "Mono hinted"
        }
    }

    public var shortLabel: String {
        switch self {
            case .grayscaleHinted: "HINT"
            case .grayscaleLightHinted: "LIGHT"
            case .grayscaleUnhinted: "NOHINT"
            case .monochromeHinted: "MONO"
        }
    }
}

public struct FreeTypeTextStyle: Sendable, Equatable {
    public var familyID: String
    public var weight: FreeTypeFontWeight
    public var pixelSize: Int
    public var color: UInt16
    public var rasterMode: FreeTypeRasterMode

    public init(
        familyID: String,
        weight: FreeTypeFontWeight = .regular,
        pixelSize: Int,
        color: UInt16 = 0xffff,
        rasterMode: FreeTypeRasterMode = .grayscaleHinted
    ) {
        self.familyID = familyID
        self.weight = weight
        self.pixelSize = max(1, pixelSize)
        self.color = color
        self.rasterMode = rasterMode
    }
}

public struct FreeTypeTextMetrics: Sendable, Equatable {
    public var ascender: Int
    public var descender: Int
    public var lineHeight: Int

    public var bodyHeight: Int { ascender - descender }
}

public struct FreeTypeTextLayout: Sendable, Equatable {
    public var lines: [String]
    public var lineHeight: Int

    public init(lines: [String], lineHeight: Int) {
        self.lines = lines
        self.lineHeight = lineHeight
    }
}

public enum FreeTypeTextError: Error, Sendable, CustomStringConvertible {
    case initFailed(Int32)
    case missingFamily(String)
    case missingResource(String)
    case loadFaceFailed(String, Int32)
    case setSizeFailed(Int32)

    public var description: String {
        switch self {
            case let .initFailed(code): "FreeType init failed (\(code))"
            case let .missingFamily(id): "Unknown FreeType family '\(id)'"
            case let .missingResource(name): "Missing bundled font resource '\(name)'"
            case let .loadFaceFailed(name, code): "Could not load font '\(name)' (\(code))"
            case let .setSizeFailed(code): "Could not set FreeType pixel size (\(code))"
        }
    }
}

public final class FreeTypeTextRenderer: @unchecked Sendable {
    private static let loadDefault: FT_Int32 = 0
    private static let loadTargetNormal: FT_Int32 = 0
    private static let loadTargetLight: FT_Int32 = 1 << 16
    private static let loadTargetMono: FT_Int32 = 2 << 16
    private static let loadNoHinting: FT_Int32 = 2
    private static let loadRender: FT_Int32 = 4
    private static let loadMonochrome: FT_Int32 = 4096

    private struct FaceKey: Hashable {
        var resourceName: String
        var faceIndex: Int
    }

    private final class FaceBox {
        let source: FreeTypeFontSource
        let face: FT_Face

        init(source: FreeTypeFontSource, face: FT_Face) {
            self.source = source
            self.face = face
        }

        deinit {
            FT_Done_Face(face)
        }
    }

    private let catalog: FreeTypeFontCatalog
    private var library: FT_Library?
    private var faces: [FaceKey: FaceBox] = [:]
    private let renderLock = NSLock()

    /// Process-wide renderer backing the monospace `SurfaceFont` path. All bitmap-font
    /// drawing now lowers to JetBrains Mono through this instance, so it is shared and
    /// its FreeType face state is guarded by `renderLock`.
    public static let shared: FreeTypeTextRenderer? = try? FreeTypeTextRenderer()

    public init(catalog: FreeTypeFontCatalog = .production) throws {
        self.catalog = catalog
        var library: FT_Library?
        let error = FT_Init_FreeType(&library)
        guard error == 0 else { throw FreeTypeTextError.initFailed(error) }
        self.library = library
    }

    deinit {
        faces.removeAll()
        if let library {
            FT_Done_FreeType(library)
        }
    }

    public func metrics(style: FreeTypeTextStyle) throws -> FreeTypeTextMetrics {
        let face = try configuredFace(style: style).face
        guard let size = face.pointee.size else {
            return FreeTypeTextMetrics(ascender: style.pixelSize, descender: 0, lineHeight: style.pixelSize)
        }
        let metrics = size.pointee.metrics
        return FreeTypeTextMetrics(
            ascender: Int(metrics.ascender >> 6),
            descender: Int(metrics.descender >> 6),
            lineHeight: Int(metrics.height >> 6)
        )
    }

    public func measure(_ text: String, style: FreeTypeTextStyle) throws -> Int {
        let face = try configuredFace(style: style).face
        var penX = 0
        for scalar in text.unicodeScalars {
            let error = FT_Load_Char(face, FT_ULong(scalar.value), Self.loadFlags(for: style.rasterMode, render: false))
            guard error == 0, let glyph = face.pointee.glyph else { continue }
            penX += Int((glyph.pointee.advance.x + 32) >> 6)
        }
        return penX
    }

    public func drawText(
        _ text: String,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        style: FreeTypeTextStyle,
        maxWidth: Int? = nil,
        clip: MK2PixelRect? = nil
    ) throws {
        let face = try configuredFace(style: style).face
        let metrics = try metrics(style: style)
        let bounds = clip.flatMap { $0.clipped(to: MK2PixelFrame.bounds) } ?? MK2PixelFrame.bounds
        let widthLimit = maxWidth.map { x + max(0, $0) } ?? MK2PixelFrame.width
        let baselineY = y + metrics.ascender
        var penX = 0

        for scalar in text.unicodeScalars {
            let loadError = FT_Load_Char(face, FT_ULong(scalar.value), Self.loadFlags(for: style.rasterMode, render: true))
            guard loadError == 0, let glyph = face.pointee.glyph else { continue }
            let slot = glyph.pointee
            let bitmap = slot.bitmap
            let bitmapLeft = Int(slot.bitmap_left)
            let bitmapTop = Int(slot.bitmap_top)
            let drawX = x + penX + bitmapLeft
            let drawY = baselineY - bitmapTop

            if drawX < widthLimit {
                draw(bitmap: bitmap, into: &frame, x: drawX, y: drawY, color: style.color, limitX: widthLimit, clip: bounds)
            }
            penX += Int((slot.advance.x + 32) >> 6)
            if x + penX >= widthLimit { break }
        }
    }

    /// Draw `text` as a fixed-pitch run: the pen steps by exactly `advance` per scalar
    /// regardless of the glyph's natural advance, reproducing a monospace bitmap grid so
    /// character-per-row capacity and column positions stay identical to the old atlas
    /// path. Glyphs self-center via their side bearing (JetBrains Mono is monospace).
    /// `advance`, `ascent`, and `cellHeight` are in device pixels (already scaled).
    public func drawMonospaced(
        _ text: String,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        style: FreeTypeTextStyle,
        advance: Int,
        ascent: Int,
        cellHeight: Int,
        background: UInt16? = nil,
        maxWidth: Int? = nil,
        clip: MK2PixelRect? = nil
    ) throws {
        renderLock.lock()
        defer { renderLock.unlock() }

        let face = try configuredFace(style: style).face
        let bounds = clip.flatMap { $0.clipped(to: MK2PixelFrame.bounds) } ?? MK2PixelFrame.bounds
        let scalars = Array(text.unicodeScalars)
        let widthLimit = maxWidth.map { min(x + max(0, $0), MK2PixelFrame.width) } ?? MK2PixelFrame.width

        if let background {
            let bgRect = MK2PixelRect(x: x, y: y, width: scalars.count * advance, height: cellHeight)
            if let filled = bgRect.clipped(to: bounds) { frame.fill(filled, background) }
        }

        let baselineY = y + ascent
        var penX = x
        for scalar in scalars {
            if penX >= bounds.maxX || penX >= widthLimit { break }
            let loadError = FT_Load_Char(face, FT_ULong(scalar.value), Self.loadFlags(for: style.rasterMode, render: true))
            if loadError == 0, let glyph = face.pointee.glyph {
                let slot = glyph.pointee
                draw(
                    bitmap: slot.bitmap,
                    into: &frame,
                    x: penX + Int(slot.bitmap_left),
                    y: baselineY - Int(slot.bitmap_top),
                    color: style.color,
                    limitX: widthLimit,
                    clip: bounds
                )
            }
            penX += advance
        }
    }

    public func wrappedLayout(
        _ text: String,
        style: FreeTypeTextStyle,
        maxWidth: Int
    ) throws -> FreeTypeTextLayout {
        let metrics = try metrics(style: style)
        let width = max(0, maxWidth)
        guard !text.isEmpty else {
            return FreeTypeTextLayout(lines: [], lineHeight: metrics.lineHeight)
        }
        guard width > 0 else {
            return FreeTypeTextLayout(lines: [text], lineHeight: metrics.lineHeight)
        }

        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let wrapped = try wrappedParagraph(String(paragraph), style: style, maxWidth: width)
            if wrapped.isEmpty {
                lines.append("")
            } else {
                lines.append(contentsOf: wrapped)
            }
        }
        return FreeTypeTextLayout(lines: lines, lineHeight: metrics.lineHeight)
    }

    @discardableResult
    public func drawWrappedText(
        _ text: String,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        style: FreeTypeTextStyle,
        maxWidth: Int,
        maxLines: Int? = nil,
        lineSpacing: Int = 0,
        clip: MK2PixelRect? = nil
    ) throws -> Int {
        let layout = try wrappedLayout(text, style: style, maxWidth: maxWidth)
        let lineLimit = maxLines.map { max(0, $0) } ?? layout.lines.count
        let drawnLines = min(layout.lines.count, lineLimit)
        let lineAdvance = max(1, layout.lineHeight + lineSpacing)

        for index in 0..<drawnLines {
            try drawText(
                layout.lines[index],
                into: &frame,
                x: x,
                y: y + index * lineAdvance,
                style: style,
                maxWidth: maxWidth,
                clip: clip
            )
        }
        return drawnLines
    }

    private func wrappedParagraph(
        _ paragraph: String,
        style: FreeTypeTextStyle,
        maxWidth: Int
    ) throws -> [String] {
        let words = paragraph
            .split(whereSeparator: { $0.unicodeScalars.allSatisfy(\.properties.isWhitespace) })
            .map(String.init)
        guard !words.isEmpty else { return [] }

        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                let broken = try linesForUnbreakableWord(word, style: style, maxWidth: maxWidth)
                if broken.count == 1 {
                    current = broken[0]
                } else {
                    lines.append(contentsOf: broken.dropLast())
                    current = broken.last ?? ""
                }
                continue
            }

            let candidate = current + " " + word
            if try measure(candidate, style: style) <= maxWidth {
                current = candidate
            } else {
                lines.append(current)
                let broken = try linesForUnbreakableWord(word, style: style, maxWidth: maxWidth)
                if broken.count == 1 {
                    current = broken[0]
                } else {
                    lines.append(contentsOf: broken.dropLast())
                    current = broken.last ?? ""
                }
            }
        }

        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    private func linesForUnbreakableWord(
        _ word: String,
        style: FreeTypeTextStyle,
        maxWidth: Int
    ) throws -> [String] {
        guard try measure(word, style: style) > maxWidth else { return [word] }

        var lines: [String] = []
        var current = ""
        for character in word {
            let piece = String(character)
            let candidate = current + piece
            if !current.isEmpty, try measure(candidate, style: style) > maxWidth {
                lines.append(current)
                current = piece
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    private static func loadFlags(for mode: FreeTypeRasterMode, render: Bool) -> FT_Int32 {
        let renderFlag = render ? loadRender : loadDefault
        switch mode {
            case .grayscaleHinted:
                return renderFlag | loadTargetNormal
            case .grayscaleLightHinted:
                return renderFlag | loadTargetLight
            case .grayscaleUnhinted:
                return renderFlag | loadNoHinting
            case .monochromeHinted:
                return renderFlag | loadMonochrome | loadTargetMono
        }
    }

    private func configuredFace(style: FreeTypeTextStyle) throws -> FaceBox {
        guard let family = catalog.family(id: style.familyID) else {
            throw FreeTypeTextError.missingFamily(style.familyID)
        }
        let source = family.source(for: style.weight)
        let box = try face(source: source)
        let sizeError = FT_Set_Pixel_Sizes(box.face, 0, FT_UInt(style.pixelSize))
        guard sizeError == 0 else { throw FreeTypeTextError.setSizeFailed(sizeError) }
        if let variationWeight = source.variationWeight {
            setVariationWeight(variationWeight, on: box.face)
        }
        return box
    }

    private func setVariationWeight(_ weight: Int, on face: FT_Face) {
        var mmVar: UnsafeMutablePointer<FT_MM_Var>?
        guard FT_Get_MM_Var(face, &mmVar) == 0, let mmVar else { return }
        defer {
            if let library {
                FT_Done_MM_Var(library, mmVar)
            }
        }

        let axisCount = Int(mmVar.pointee.num_axis)
        guard axisCount > 0, let axis = mmVar.pointee.axis else { return }
        var coords = [FT_Fixed](repeating: 0, count: axisCount)
        let weightTag = Self.tag("wght")
        var hasWeightAxis = false

        for index in 0..<axisCount {
            let info = axis.advanced(by: index).pointee
            var value = info.def
            if UInt32(info.tag) == weightTag {
                let requested = FT_Fixed(weight << 16)
                value = min(max(requested, info.minimum), info.maximum)
                hasWeightAxis = true
            }
            coords[index] = value
        }
        guard hasWeightAxis else { return }
        coords.withUnsafeMutableBufferPointer { buffer in
            _ = FT_Set_Var_Design_Coordinates(face, FT_UInt(buffer.count), buffer.baseAddress)
        }
    }

    private static func tag(_ string: StaticString) -> UInt32 {
        let bytes = string.withUTF8Buffer { Array($0) }
        precondition(bytes.count == 4)
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    private func face(source: FreeTypeFontSource) throws -> FaceBox {
        let key = FaceKey(resourceName: source.resourceName, faceIndex: source.faceIndex)
        if let cached = faces[key] { return cached }
        guard let url = Bundle.module.url(forResource: source.resourceName, withExtension: nil, subdirectory: "Fonts") else {
            throw FreeTypeTextError.missingResource(source.resourceName)
        }
        guard let library else { throw FreeTypeTextError.initFailed(-1) }

        var face: FT_Face?
        let error = url.path.withCString {
            FT_New_Face(library, $0, FT_Long(source.faceIndex), &face)
        }
        guard error == 0, let face else {
            throw FreeTypeTextError.loadFaceFailed(source.resourceName, error)
        }
        let box = FaceBox(source: source, face: face)
        faces[key] = box
        return box
    }

    private func draw(
        bitmap: FT_Bitmap,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        color: UInt16,
        limitX: Int,
        clip: MK2PixelRect
    ) {
        guard let buffer = bitmap.buffer,
              bitmap.width > 0,
              bitmap.rows > 0 else { return }

        if bitmap.pixel_mode == FT_PIXEL_MODE_MONO.rawValue {
            drawMono(bitmap: bitmap, buffer: buffer, into: &frame, x: x, y: y, color: color, limitX: limitX, clip: clip)
        } else if bitmap.pixel_mode == FT_PIXEL_MODE_GRAY.rawValue {
            drawGray(bitmap: bitmap, buffer: buffer, into: &frame, x: x, y: y, color: color, limitX: limitX, clip: clip)
        }
    }

    private func drawGray(
        bitmap: FT_Bitmap,
        buffer: UnsafeMutablePointer<UInt8>,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        color: UInt16,
        limitX: Int,
        clip: MK2PixelRect
    ) {
        let width = Int(bitmap.width)
        let rows = Int(bitmap.rows)
        let pitch = Int(bitmap.pitch)
        for row in 0..<rows {
            let targetY = y + row
            guard targetY >= clip.y, targetY < clip.maxY else { continue }
            let rowBase = pitch >= 0 ? row * pitch : (rows - 1 - row) * -pitch
            for column in 0..<width {
                let targetX = x + column
                guard targetX >= clip.x, targetX < clip.maxX, targetX < limitX else { continue }
                let alpha = buffer[rowBase + column]
                guard alpha > 0 else { continue }
                frame[targetX, targetY] = Self.blendRGB565(color, over: frame[targetX, targetY], alpha: alpha)
            }
        }
    }

    private func drawMono(
        bitmap: FT_Bitmap,
        buffer: UnsafeMutablePointer<UInt8>,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        color: UInt16,
        limitX: Int,
        clip: MK2PixelRect
    ) {
        let width = Int(bitmap.width)
        let rows = Int(bitmap.rows)
        let pitch = Int(bitmap.pitch)
        for row in 0..<rows {
            let targetY = y + row
            guard targetY >= clip.y, targetY < clip.maxY else { continue }
            let rowBase = pitch >= 0 ? row * pitch : (rows - 1 - row) * -pitch
            for column in 0..<width {
                let targetX = x + column
                guard targetX >= clip.x, targetX < clip.maxX, targetX < limitX else { continue }
                let byte = buffer[rowBase + column / 8]
                let mask = UInt8(0x80 >> (column & 7))
                guard byte & mask != 0 else { continue }
                frame[targetX, targetY] = color
            }
        }
    }

    private static func blendRGB565(_ foreground: UInt16, over background: UInt16, alpha: UInt8) -> UInt16 {
        let a = Int(alpha)
        let inv = 255 - a
        let fr = Int((foreground >> 11) & 0x1f)
        let fg = Int((foreground >> 5) & 0x3f)
        let fb = Int(foreground & 0x1f)
        let br = Int((background >> 11) & 0x1f)
        let bg = Int((background >> 5) & 0x3f)
        let bb = Int(background & 0x1f)
        let r = UInt16((fr * a + br * inv + 127) / 255)
        let g = UInt16((fg * a + bg * inv + 127) / 255)
        let b = UInt16((fb * a + bb * inv + 127) / 255)
        return (r << 11) | (g << 5) | b
    }
}
