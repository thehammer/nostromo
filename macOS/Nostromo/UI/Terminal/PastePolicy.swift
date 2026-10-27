import Foundation

/// Whether a paste goes straight to the shell or asks first.
enum PasteDecision: Equatable {
    case send
    /// Ask first: the text is `lines` lines, and each may run as a command.
    case confirm(lines: Int)
}

enum PastePolicy {

    /// Only a remote (`ecs`) shell asks, and only for more than one line. `\r\n` and `\r` count as
    /// one line break each, and one trailing newline (a copied line) does not make a second line.
    static func decide(kind: TerminalKind, text: String) -> PasteDecision {
        guard kind == .ecs else { return .send }
        let lines = lineCount(text)
        return lines > 1 ? .confirm(lines: lines) : .send
    }

    static func lineCount(_ text: String) -> Int {
        var normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalised.hasSuffix("\n") { normalised.removeLast() }
        return normalised.components(separatedBy: "\n").count
    }
}
