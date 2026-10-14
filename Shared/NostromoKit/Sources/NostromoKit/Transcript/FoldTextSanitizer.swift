import Foundation

/// Makes text safe to draw on one row: no terminal escapes, controls, bidi overrides or
/// tag characters, one line, and at most `maxUTF16` UTF-16 units.
///
/// - Strips ANSI CSI (`ESC [ … final`) and OSC (`ESC ] … BEL|ST`) sequences, the other
///   two-character escapes, their C1 forms, and the string controls (DCS, SOS, PM, APC).
/// - Drops C0 and C1 controls and DEL; newlines, carriage returns, tabs, NEL and the
///   Unicode line/paragraph separators become spaces.
/// - Drops invisible format characters (zero-width space, word joiner and invisible
///   operators, BOM, interlinear annotation). ZWJ/ZWNJ stay: emoji and scripts need them.
/// - Drops bidi embeddings/overrides/isolates and marks (U+202A–202E, U+2066–2069,
///   U+200E/F, U+061C) and tag characters (U+E0000–E007F), which can make a row read differently
///   from what it holds.
/// - Stops at `maxUTF16` units, on a character boundary, so a megabyte of input costs no more
///   to lay out than a line.
///
/// For drawing only. Copy Commands copies the input verbatim.
public enum FoldTextSanitizer {

    public static let maxUTF16 = 512

    /// Longest escape-sequence body skipped. Past it (or with no terminator at all) the
    /// sequence is not one: only its introducer is dropped and the text after it is drawn,
    /// so a stray `ESC ]` or C1 control can never hide the rest of a command.
    public static let maxSequenceLength = 2_048

    public static func sanitize(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var out = String.UnicodeScalarView()
        var units = 0
        var i = scalars.startIndex

        while i < scalars.endIndex {
            let s = scalars[i]
            let after = scalars.index(after: i)
            switch s.value {
            case 0x1B:
                guard after < scalars.endIndex else { i = after; continue }
                let t = scalars[after]
                let body = scalars.index(after: after)
                switch t {
                case "[":
                    i = csiEnd(scalars, from: body) ?? body
                case "]", "P", "X", "^", "_":
                    i = stringEnd(scalars, from: body) ?? body
                case "(", ")", "*", "+", "-", ".", "/", "#", "%", " ":
                    // A designator (`ESC ( B`): three characters, all dropped.
                    i = body < scalars.endIndex ? scalars.index(after: body) : body
                default:
                    i = body   // a two-character escape: both dropped
                }
                continue
            case 0x9B:
                i = csiEnd(scalars, from: after) ?? after
                continue
            case 0x9D, 0x90, 0x98, 0x9E, 0x9F:
                i = stringEnd(scalars, from: after) ?? after
                continue
            case 0x09, 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
                guard units + 1 <= maxUTF16 else { return String(out) }
                out.append(" ")
                units += 1
            case 0x00...0x1F, 0x7F...0x9F,
                 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069,
                 0x200B, 0x2060...0x2064, 0xFEFF, 0xFFF9...0xFFFB,
                 0xE0000...0xE007F:
                break
            default:
                let width = s.utf16.count
                guard units + width <= maxUTF16 else { return cappedCleanly(out, next: s) }
                out.append(s)
                units += width
            }
            i = after
        }
        return String(out)
    }

    /// Where a CSI body (parameters and intermediates, then a final byte) ends, or nil when
    /// what follows is not one.
    private static func csiEnd(_ scalars: String.UnicodeScalarView, from start: String.Index) -> String.Index? {
        var i = start
        var length = 0
        while i < scalars.endIndex, length < maxSequenceLength {
            let v = scalars[i].value
            if (0x40...0x7E).contains(v) { return scalars.index(after: i) }
            guard (0x20...0x3F).contains(v) else { return nil }
            i = scalars.index(after: i)
            length += 1
        }
        return nil
    }

    /// Where an OSC (or other string control) body ends: after BEL, ST (`ESC \`) or C1 ST.
    /// Nil when it is never terminated within `maxSequenceLength`.
    private static func stringEnd(_ scalars: String.UnicodeScalarView, from start: String.Index) -> String.Index? {
        var i = start
        var length = 0
        while i < scalars.endIndex, length < maxSequenceLength {
            let v = scalars[i].value
            let next = scalars.index(after: i)
            if v == 0x07 || v == 0x9C { return next }
            if v == 0x1B, next < scalars.endIndex, scalars[next] == "\\" { return scalars.index(after: next) }
            i = next
            length += 1
        }
        return nil
    }

    /// The capped text, without a last character the cut left incomplete (an emoji ZWJ
    /// sequence, a flag, a letter whose combining mark did not fit).
    private static func cappedCleanly(_ out: String.UnicodeScalarView, next: Unicode.Scalar) -> String {
        var text = String(out)
        guard let last = text.last else { return text }
        if (String(last) + String(next)).count == 1 { text.removeLast() }
        return text
    }
}
