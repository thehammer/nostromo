import Foundation

/// Makes text safe to draw on one row: no terminal escapes, controls, bidi overrides or
/// tag characters, one line, and at most `maxUTF16` UTF-16 units.
///
/// - Strips ANSI CSI (`ESC [ … final`) and OSC (`ESC ] … BEL|ST`) sequences, the other
///   two-character escapes, their C1 forms, and the string controls (DCS, SOS, PM, APC).
/// - Drops C0 and C1 controls and DEL; newlines, carriage returns, tabs, NEL and the
///   Unicode line/paragraph separators become spaces.
/// - Drops invisible format characters (zero-width space, word joiner and invisible
///   operators, BOM, interlinear annotation). ZWJ/ZWNJ stay in rows: emoji and scripts need them.
/// - Drops bidi embeddings/overrides/isolates and marks (U+202A–202E, U+2066–2069,
///   U+200E/F, U+061C) and tag characters (U+E0000–E007F), which can make a row read differently
///   from what it holds.
/// - Drops the invisible filler characters that render as blank (Hangul fillers, Braille blank,
///   combining grapheme joiner, Khmer inherent vowels, halfwidth Hangul filler), which can hide
///   in a name or a command.
/// - Stops at `maxUTF16` units, on a character boundary, so a megabyte of input costs no more
///   to lay out than a line.
///
/// Document text (`sanitizeInline`, `sanitizeMultiline`: a plan's paragraphs, code and checklist) is
/// stricter, because there a name or a command can be read as a whole and has no row to stop it:
/// - also drops the soft hyphen (U+00AD), the Mongolian vowel separator (U+180E), variation selectors
///   U+FE00–FE0D and U+E0100–E01EF, which draw nothing;
/// - keeps U+FE0E/FE0F only straight after an emoji (or a keycap base before U+20E3), where they choose
///   how it is drawn;
/// - keeps ZWJ/ZWNJ (U+200D, U+200C) only between two characters that are both outside ASCII and are
///   not joiners themselves: emoji sequences, and the scripts that need them (Persian, Indic). A joiner
///   next to ASCII, at either end of the text, or beside another joiner is dropped, so it cannot hide
///   inside a word, a path or a command.
///
/// For drawing only. Copy Commands copies the input verbatim.
public enum FoldTextSanitizer {

    public static let maxUTF16 = 512

    /// Longest escape-sequence body skipped. Past it (or with no terminator at all) the
    /// sequence is not one: only its introducer is dropped and the text after it is drawn,
    /// so a stray `ESC ]` or C1 control can never hide the rest of a command.
    public static let maxSequenceLength = 2_048

    public static func sanitize(_ text: String) -> String {
        clean(text, mode: .row, cap: maxUTF16)
    }

    /// Document text (a paragraph, a heading, a table cell): the same drops as `sanitize`, line breaks
    /// and tabs become one space, and there is no length cap: a plan is as long as it is.
    public static func sanitizeInline(_ text: String) -> String {
        strict(clean(text, mode: .row, cap: nil))
    }

    /// Preformatted text (a code block, a whole plan file): no length cap, and `\n` and `\t` stay.
    /// `\r\n` becomes `\n`; a lone `\r`, NEL and the Unicode line/paragraph separators become a space.
    /// Everything else `sanitize` drops is dropped here too.
    public static func sanitizeMultiline(_ text: String) -> String {
        strict(clean(text, mode: .multiline, cap: nil))
    }

    private enum Mode { case row, multiline }

    private static func clean(_ text: String, mode: Mode, cap: Int?) -> String {
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
            case 0x0A where mode == .multiline, 0x09 where mode == .multiline:
                out.append(s)
                units += 1
            case 0x0D where mode == .multiline:
                // CRLF is one line break; a lone CR is not one.
                if after < scalars.endIndex, scalars[after] == "\n" {
                    i = after
                    continue
                }
                out.append(" ")
                units += 1
            case 0x09, 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
                if let cap, units + 1 > cap { return String(out) }
                out.append(" ")
                units += 1
            case 0x00...0x1F, 0x7F...0x9F,
                 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069,
                 0x200B, 0x2060...0x2064, 0xFEFF, 0xFFF9...0xFFFB,
                 0xE0000...0xE007F,
                 0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0:
                break
            default:
                let width = s.utf16.count
                if let cap, units + width > cap { return cappedCleanly(out, next: s) }
                out.append(s)
                units += width
            }
            i = after
        }
        return String(out)
    }

    // MARK: Document text

    private static func isStrictInteresting(_ v: UInt32) -> Bool {
        switch v {
        case 0x00AD, 0x180E, 0xFE00...0xFE0F, 0xE0100...0xE01EF, 0x200C, 0x200D: return true
        default: return false
        }
    }

    /// The extra rules of document text (see the type's comment), over text `clean` has already cleaned.
    private static func strict(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { isStrictInteresting($0.value) }) else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var last: Unicode.Scalar?
        /// A joiner waiting to see what follows it.
        var pending: Unicode.Scalar?
        /// Joiners in a row (dropped text between them does not break the row): more than one and none survives.
        var joinersInARow = 0

        for (i, s) in scalars.enumerated() {
            switch s.value {
            case 0x00AD, 0x180E, 0xFE00...0xFE0D, 0xE0100...0xE01EF:
                continue
            case 0xFE0E, 0xFE0F:
                guard pending == nil, let base = last else { continue }
                let next = i + 1 < scalars.count ? scalars[i + 1] : nil
                let keycap = base.value < 0x80 && base.properties.isEmoji && next?.value == 0x20E3 && s.value == 0xFE0F
                guard keycap || (base.value > 0x7F && base.properties.isEmoji) else { continue }
                out.append(s)
                last = s
                joinersInARow = 0
            case 0x200C, 0x200D:
                joinersInARow += 1
                if joinersInARow == 1, let before = last, before.value > 0x7F {
                    pending = s
                } else {
                    pending = nil   // next to ASCII, at the start, or beside another joiner: dropped
                }
            default:
                if let joiner = pending, joinersInARow == 1, s.value > 0x7F { out.append(joiner) }
                pending = nil
                joinersInARow = 0
                out.append(s)
                last = s
            }
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
