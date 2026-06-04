import AppKit

// MARK: - diffLineColor

/// Classify a unified-diff line by its first character for syntax colouring.
/// Free function so it is unit-testable without pulling in PerriView.
func diffLineColor(_ line: String) -> NSColor {
    guard let first = line.first else { return Theme.fg }
    switch first {
    case "+": return Theme.sage
    case "-": return Theme.redSweater
    case "@": return Theme.fgMuted
    default:  return Theme.fg
    }
}
