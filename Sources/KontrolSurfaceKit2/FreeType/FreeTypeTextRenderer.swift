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

    private enum RunLayout: Hashable {
        case proportional
        case monospaced(advance: Int)
    }

    private struct TextRunKey: Hashable {
        var familyID: String
        var weight: FreeTypeFontWeight
        var pixelSize: Int
        var rasterMode: FreeTypeRasterMode
        var layout: RunLayout
        var text: String
    }

    private struct GlyphKey: Hashable {
        var familyID: String
        var weight: FreeTypeFontWeight
        var pixelSize: Int
        var rasterMode: FreeTypeRasterMode
        var glyphIndex: FT_UInt
    }

    private struct CachedGlyph {
        var advanceX: Int = 0
        var bitmapLeft: Int = 0
        var bitmapTop: Int = 0
        var width: Int = 0
        var height: Int = 0
        var alpha: [UInt8] = []
        var lastUsed: UInt64 = 0
    }

    private struct GlyphPlacement {
        var glyph: CachedGlyph
        var x: Int
        var y: Int
    }

    private struct CachedTextRun {
        var advanceWidth: Int = 0
        var boundsX: Int = 0
        var boundsY: Int = 0
        var width: Int = 0
        var height: Int = 0
        var alpha: [UInt8] = []
        var lastUsed: UInt64 = 0
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
    private var glyphs: [GlyphKey: CachedGlyph] = [:]
    private var textRuns: [TextRunKey: CachedTextRun] = [:]
    private var runClock: UInt64 = 0
    private let renderLock = NSLock()
    private static let maxCachedGlyphs = 2048
    private static let maxCachedTextRuns = 1024

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
        renderLock.lock()
        defer { renderLock.unlock() }

        let face = try configuredFace(style: style).face
        return metrics(for: face, pixelSize: style.pixelSize)
    }

    public func measure(_ text: String, style: FreeTypeTextStyle) throws -> Int {
        renderLock.lock()
        defer { renderLock.unlock() }

        return try cachedRun(text, style: style, layout: .proportional).advanceWidth
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
        renderLock.lock()
        defer { renderLock.unlock() }

        let face = try configuredFace(style: style).face
        let metrics = metrics(for: face, pixelSize: style.pixelSize)
        let run = try cachedRun(text, style: style, layout: .proportional)
        let bounds = clip.flatMap { $0.clipped(to: MK2PixelFrame.bounds) } ?? MK2PixelFrame.bounds
        let widthLimit = maxWidth.map { min(x + max(0, $0), MK2PixelFrame.width) } ?? MK2PixelFrame.width
        let baselineY = y + metrics.ascender
        draw(run: run, into: &frame, x: x, baselineY: baselineY, color: style.color, limitX: widthLimit, clip: bounds)
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

        let bounds = clip.flatMap { $0.clipped(to: MK2PixelFrame.bounds) } ?? MK2PixelFrame.bounds
        let scalars = Array(text.unicodeScalars)
        let widthLimit = maxWidth.map { min(x + max(0, $0), MK2PixelFrame.width) } ?? MK2PixelFrame.width

        if let background {
            let bgRect = MK2PixelRect(x: x, y: y, width: scalars.count * advance, height: cellHeight)
            if let filled = bgRect.clipped(to: bounds) { frame.fill(filled, background) }
        }

        let baselineY = y + ascent
        let run = try cachedRun(text, style: style, layout: .monospaced(advance: advance))
        draw(run: run, into: &frame, x: x, baselineY: baselineY, color: style.color, limitX: widthLimit, clip: bounds)
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

    private func cachedRun(_ text: String, style: FreeTypeTextStyle, layout: RunLayout) throws -> CachedTextRun {
        let key = TextRunKey(
            familyID: style.familyID,
            weight: style.weight,
            pixelSize: style.pixelSize,
            rasterMode: style.rasterMode,
            layout: layout,
            text: text
        )
        runClock &+= 1
        if var cached = textRuns[key] {
            cached.lastUsed = runClock
            textRuns[key] = cached
            return cached
        }

        let face = try configuredFace(style: style).face
        var run = buildRun(text, face: face, style: style, layout: layout)
        run.lastUsed = runClock
        if textRuns.count >= Self.maxCachedTextRuns {
            evictOldestTextRun()
        }
        textRuns[key] = run
        return run
    }

    private func buildRun(_ text: String, face: FT_Face, style: FreeTypeTextStyle, layout: RunLayout) -> CachedTextRun {
        let loadFlags = Self.loadFlags(for: style.rasterMode, render: true)
        var placements: [GlyphPlacement] = []
        placements.reserveCapacity(text.unicodeScalars.count)

        var penX = 0
        var previousGlyph: FT_UInt = 0
        var hasPixels = false
        var minX = 0
        var minY = 0
        var maxX = 0
        var maxY = 0

        for scalar in text.unicodeScalars {
            let glyphIndex = FT_Get_Char_Index(face, FT_ULong(scalar.value))
            if case .proportional = layout,
               previousGlyph != 0,
               glyphIndex != 0 {
                var delta = FT_Vector()
                if FT_Get_Kerning(face, previousGlyph, glyphIndex, FT_UInt(FT_KERNING_DEFAULT.rawValue), &delta) == 0 {
                    penX += Int((delta.x + 32) >> 6)
                }
            }

            if let glyph = cachedGlyph(glyphIndex: glyphIndex, face: face, style: style, loadFlags: loadFlags) {
                let glyphX = penX + glyph.bitmapLeft
                let glyphY = -glyph.bitmapTop
                if glyph.width > 0, glyph.height > 0 {
                    placements.append(GlyphPlacement(
                        glyph: glyph,
                        x: glyphX,
                        y: glyphY
                    ))
                    if hasPixels {
                        minX = min(minX, glyphX)
                        minY = min(minY, glyphY)
                        maxX = max(maxX, glyphX + glyph.width)
                        maxY = max(maxY, glyphY + glyph.height)
                    } else {
                        minX = glyphX
                        minY = glyphY
                        maxX = glyphX + glyph.width
                        maxY = glyphY + glyph.height
                        hasPixels = true
                    }
                }

                switch layout {
                    case .proportional:
                        penX += glyph.advanceX
                    case let .monospaced(advance):
                        penX += advance
                }
            } else if case let .monospaced(advance) = layout {
                penX += advance
            }
            previousGlyph = glyphIndex
        }

        var run = CachedTextRun()
        run.advanceWidth = penX
        guard hasPixels else { return run }

        run.boundsX = minX
        run.boundsY = minY
        run.width = maxX - minX
        run.height = maxY - minY
        run.alpha = Array(repeating: 0, count: run.width * run.height)

        for placement in placements {
            for row in 0..<placement.glyph.height {
                for column in 0..<placement.glyph.width {
                    let sourceAlpha = placement.glyph.alpha[row * placement.glyph.width + column]
                    guard sourceAlpha > 0 else { continue }
                    let targetX = placement.x - run.boundsX + column
                    let targetY = placement.y - run.boundsY + row
                    let targetIndex = targetY * run.width + targetX
                    let targetAlpha = run.alpha[targetIndex]
                    run.alpha[targetIndex] = UInt8(Int(sourceAlpha) + (Int(targetAlpha) * (255 - Int(sourceAlpha)) + 127) / 255)
                }
            }
        }
        return run
    }

    private func cachedGlyph(glyphIndex: FT_UInt, face: FT_Face, style: FreeTypeTextStyle, loadFlags: FT_Int32) -> CachedGlyph? {
        let key = GlyphKey(
            familyID: style.familyID,
            weight: style.weight,
            pixelSize: style.pixelSize,
            rasterMode: style.rasterMode,
            glyphIndex: glyphIndex
        )
        runClock &+= 1
        if var cached = glyphs[key] {
            cached.lastUsed = runClock
            glyphs[key] = cached
            return cached
        }

        guard FT_Load_Glyph(face, glyphIndex, loadFlags) == 0, let glyph = face.pointee.glyph else {
            return nil
        }
        let slot = glyph.pointee
        let copied = copyAlpha(bitmap: slot.bitmap)
        let cached = CachedGlyph(
            advanceX: Int((slot.advance.x + 32) >> 6),
            bitmapLeft: Int(slot.bitmap_left),
            bitmapTop: Int(slot.bitmap_top),
            width: copied.width,
            height: copied.height,
            alpha: copied.alpha,
            lastUsed: runClock
        )
        if glyphs.count >= Self.maxCachedGlyphs {
            evictOldestGlyph()
        }
        glyphs[key] = cached
        return cached
    }

    private func copyAlpha(bitmap: FT_Bitmap) -> (width: Int, height: Int, alpha: [UInt8]) {
        guard let buffer = bitmap.buffer,
              bitmap.width > 0,
              bitmap.rows > 0 else {
            return (0, 0, [])
        }

        let width = Int(bitmap.width)
        let height = Int(bitmap.rows)
        let pitch = Int(bitmap.pitch)
        let absolutePitch = abs(pitch)
        var alpha = Array(repeating: UInt8(0), count: width * height)
        for row in 0..<height {
            let sourceRow = pitch >= 0 ? row : height - 1 - row
            let source = buffer.advanced(by: sourceRow * absolutePitch)
            for column in 0..<width {
                if bitmap.pixel_mode == FT_PIXEL_MODE_MONO.rawValue {
                    let byte = source[column / 8]
                    let mask = UInt8(0x80 >> (column & 7))
                    alpha[row * width + column] = byte & mask == 0 ? 0 : 255
                } else if bitmap.pixel_mode == FT_PIXEL_MODE_GRAY.rawValue {
                    alpha[row * width + column] = source[column]
                }
            }
        }
        return (width, height, alpha)
    }

    private func evictOldestTextRun() {
        guard let oldest = textRuns.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { return }
        textRuns.removeValue(forKey: oldest)
    }

    private func evictOldestGlyph() {
        guard let oldest = glyphs.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { return }
        glyphs.removeValue(forKey: oldest)
    }

    private func metrics(for face: FT_Face, pixelSize: Int) -> FreeTypeTextMetrics {
        guard let size = face.pointee.size else {
            return FreeTypeTextMetrics(ascender: pixelSize, descender: 0, lineHeight: pixelSize)
        }
        let metrics = size.pointee.metrics
        return FreeTypeTextMetrics(
            ascender: Int(metrics.ascender >> 6),
            descender: Int(metrics.descender >> 6),
            lineHeight: Int(metrics.height >> 6)
        )
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
        run: CachedTextRun,
        into frame: inout MK2PixelFrame,
        x: Int,
        baselineY: Int,
        color: UInt16,
        limitX: Int,
        clip: MK2PixelRect
    ) {
        guard !run.alpha.isEmpty, run.width > 0, run.height > 0 else { return }
        let drawX = x + run.boundsX
        let drawY = baselineY + run.boundsY
        for row in 0..<run.height {
            let targetY = drawY + row
            guard targetY >= clip.y, targetY < clip.maxY else { continue }
            for column in 0..<run.width {
                let targetX = drawX + column
                guard targetX >= clip.x, targetX < clip.maxX, targetX < limitX else { continue }
                let alpha = run.alpha[row * run.width + column]
                guard alpha > 0 else { continue }
                frame[targetX, targetY] = Self.blendRGB565(color, over: frame[targetX, targetY], alpha: alpha)
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
