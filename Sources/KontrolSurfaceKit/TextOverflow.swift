import Foundation

/// How a marquee behaves once a string is longer than a display cell.
public enum MarqueeStyle: Sendable, Equatable {
    /// Scroll left, then wrap around through a blank gap and repeat.
    case wrap
    /// Scroll to the end, then reverse back to the start.
    case pingPong
}

/// Policy for text that does not fit the 8-character width of an LCD row.
public enum TextOverflow: Sendable, Equatable {
    /// Hard-truncate to the cell width.
    case clip
    /// Truncate and mark the cut with a trailing dot.
    case ellipsis
    /// Reserved for an abbreviation pass; currently behaves like `clip`.
    case fit
    /// Scroll the text across the cell on the shared surface clock.
    case marquee(speed: Double = 6, gap: Int = 3, style: MarqueeStyle = .wrap, startDelay: Double = 0.8)

    /// Default marquee configuration.
    public static var marquee: TextOverflow { .marquee() }
}
