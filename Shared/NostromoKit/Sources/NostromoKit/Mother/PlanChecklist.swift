import Foundation

/// One `- [ ]` / `- [x]` line of a plan.
public struct PlanChecklistItem: Equatable, Sendable {
    public let done: Bool
    public let text: String

    public init(done: Bool, text: String) {
        self.done = done
        self.text = text
    }
}

/// The task items of a plan's markdown, in file order.
///
/// One parser for every place that counts them: the job detail's Overview checklist and the Plan
/// view's `n/m criteria` header, so the two can never disagree. It reads lines, not markdown: an
/// item inside a code fence counts, as it always has.
public enum PlanChecklist {

    public static func parse(_ text: String) -> [PlanChecklistItem] {
        var result: [PlanChecklistItem] = []
        for line in text.components(separatedBy: "\n") {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = itemRegex.firstMatch(in: line, range: range), match.numberOfRanges == 3 else { continue }
            let marker = nsLine.substring(with: match.range(at: 1))
            result.append(PlanChecklistItem(done: marker == "x" || marker == "X",
                                            text: nsLine.substring(with: match.range(at: 2))))
        }
        return result
    }

    /// Optional leading whitespace, `- [`, a space or x/X, `]`, whitespace, then the item's text.
    private static let itemRegex: NSRegularExpression = {
        // A literal pattern: it cannot fail to compile.
        try! NSRegularExpression(pattern: #"^\s*- \[([ xX])\]\s+(.+)$"#)
    }()
}
