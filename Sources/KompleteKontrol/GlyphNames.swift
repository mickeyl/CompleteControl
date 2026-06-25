import Foundation

// Glyph names transcribed verbatim from shaduzlabs/cabl FONT_16-seg.h
// (MIT). Index, mask, and name align 1:1 with `font16Segment`; original
// spellings are preserved.
public extension KKDisplayFrame {
    static let glyphNames: [String] = [
        "' '", "smiley (transparent)", "smiley (matte)", "heart",
        "diamond", "club", "spade", "bullet (filled)",
        "negative bullet (filled)", "bullet", "negative bullet", "male",
        "female", "eigth note", "beamed eighth notes", "sun with rays",
        "right-pointing pointer (filled)", "left-pointing pointer (filled)", "up-down arrow", "double exlamation mark",
        "paragraph", "section", "filled rectangle", "up-down arrow with base",
        "up arrow", "down arrow", "right arrow", "left arrow",
        "right angle", "left-right arrow", "up-pointing pointer (filled)", "down-pointing pointer (filled)",
        "' '", "'!'", "'\"'", "'#'",
        "'$'", "'%'", "'&'", "'''",
        "'('", "')'", "'*'", "'+'",
        "','", "'-'", "'.'", "'/'",
        "'0'", "'1'", "'2'", "'3'",
        "'4'", "'5'", "'6'", "'7'",
        "'8'", "'9'", "':'", "';'",
        "'<'", "'='", "'>'", "'?'",
        "'@'", "'A'", "'B'", "'C'",
        "'D'", "'E'", "'F'", "'G'",
        "'H'", "'I'", "'J'", "'K'",
        "'L'", "'M'", "'N'", "'O'",
        "'P'", "'Q'", "'R'", "'S'",
        "'T'", "'U'", "'V'", "'W'",
        "'X'", "'Y'", "'Z'", "'['",
        "'\\'", "']'", "'^'", "'_'",
        "'`'", "'a'", "'b'", "'c'",
        "'d'", "'e'", "'f'", "'g'",
        "'h'", "'i'", "'j'", "'k'",
        "'l'", "'m'", "'n'", "'o'",
        "'p'", "'q'", "'r'", "'s'",
        "'t'", "'u'", "'v'", "'w'",
        "'x'", "'y'", "'z'", "'{'",
        "'|'", "'}'", "'~'", "home",
        "shaduzLABS",
    ]

    /// The cabl name for a glyph index, or `nil` if out of range.
    static func glyphName(at index: Int) -> String? {
        glyphNames.indices.contains(index) ? glyphNames[index] : nil
    }
}
