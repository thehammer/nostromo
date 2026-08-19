import AppKit

// MARK: - buildDiffAttributedString

/// Build a syntax-coloured attributed string from unified-diff text.
///
/// Pure function — safe to call off the main thread. A free function beside
/// `diffLineColor` for the same reason that one is: it is unit-testable without
/// pulling in a view, and it now has two callers (`CodeContentView`'s live
/// rendering of a `DiffDocument`, and the legacy `PerriView`) rather than being
/// trapped as a private helper inside one of them.
///
/// It reads the marker character back off each line, which is exactly why
/// `DiffDocument` restores those markers when it flattens: the daemon strips
/// them to make lines addressable, and the renderer needs them back to colour.
/// `font` is required rather than defaulted so this never becomes ambiguous
/// with the identically-named private helper still living inside the
/// unreachable `PerriView` (which the PRD keeps for now).
func buildDiffAttributedString(_ diff: String, font: NSFont) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let lines = diff.components(separatedBy: "\n")
    for (i, line) in lines.enumerated() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            font,
            .foregroundColor: diffLineColor(line),
        ]
        result.append(NSAttributedString(string: line, attributes: attrs))
        if i < lines.count - 1 {
            result.append(NSAttributedString(string: "\n", attributes: attrs))
        }
    }
    return result
}
