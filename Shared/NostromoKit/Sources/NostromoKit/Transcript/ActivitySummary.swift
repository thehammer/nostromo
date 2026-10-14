import Foundation

/// The words on an activity row (PRD "The activity row"; contract §2.1), and the copy texts.
///
/// The title is `N message(s)` first, then TF2's phrases (`ToolGroupSummary`), computed over
/// every call in the row. The messages phrase counts toward the three-phrase cap, and
/// `+N more` counts the hidden *calls*. A row with no messages has no messages phrase.
///
/// `3 messages, ran 9 commands, read 2 files, +4 more · 1 failed · 41 s`
///
/// The time spans the row's tool work only (X1): agent text carries no timestamp.
///
/// Row text is sanitized (`FoldTextSanitizer`); copy text is verbatim.
public enum ActivitySummary {

    /// The count phrases: `3 messages, ran 9 commands, read 2 files, +4 more`. The first
    /// letter is capitalised when the row has no messages phrase (`Ran 9 commands, …`).
    public static func title(for segment: ActivitySegment) -> String {
        phrases(for: segment) { "\($0) message\($0 == 1 ? "" : "s")" }
    }

    /// `N failed`, or nil when nothing failed.
    public static func failureText(for segment: ActivitySegment) -> String? {
        segment.failedCount > 0 ? "\(segment.failedCount) failed" : nil
    }

    /// The first call's start to the latest known call end (X1), or nil when either is unknown.
    /// Never `0 ms`.
    public static func durationText(for segment: ActivitySegment) -> String? {
        guard let start = segment.startedAt, let end = segment.endedAt else { return nil }
        return ToolGroupSummary.durationText(seconds: end.timeIntervalSince(start))
    }

    /// What the row reads: title, failure, time, joined by ` · `. Copy Summary copies this.
    public static func plainText(for segment: ActivitySegment) -> String {
        [title(for: segment), failureText(for: segment), durationText(for: segment)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ToolGroupSummary.separator)
    }

    /// The row's VoiceOver label: `2 earlier messages, ran 9 commands, 1 failed call, 41 s`.
    public static func accessibilityLabel(for segment: ActivitySegment) -> String {
        let failure = segment.failedCount > 0
            ? "\(segment.failedCount) failed call\(segment.failedCount == 1 ? "" : "s")" : nil
        let title = phrases(for: segment) { "\($0) earlier message\($0 == 1 ? "" : "s")" }
        return [title, failure, durationText(for: segment)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    // MARK: Copy

    /// Copy Messages: the folded messages' full text in order, a blank line between messages.
    /// A message's own text blocks are joined the same way. `blockText` maps a block index to
    /// its text (nil for blocks that are not text). Verbatim.
    public static func messagesText(for segment: ActivitySegment, blockText: (Int) -> String?) -> String {
        segment.members
            .compactMap { member -> String? in
                guard case .message(let message) = member else { return nil }
                let texts = message.blockIndices.compactMap(blockText)
                return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
            }
            .joined(separator: "\n\n")
    }

    /// Copy Commands: TF2's `ToolGroupSummary.commandsText` for each group, in order, joined by
    /// a newline. Verbatim.
    public static func commandsText(for segment: ActivitySegment, payloadAvailable: Bool) -> String {
        segment.members
            .compactMap { member -> String? in
                guard case .group(let group) = member else { return nil }
                let text = ToolGroupSummary.commandsText(for: group, payloadAvailable: payloadAvailable)
                return text.isEmpty ? nil : text
            }
            .joined(separator: "\n")
    }

    // MARK: Phrases

    private static func phrases(for segment: ActivitySegment, messages: (Int) -> String) -> String {
        var phrases: [(text: String, calls: Int)] = []
        let messageCount = segment.messageCount
        if messageCount > 0 { phrases.append((messages(messageCount), 0)) }
        phrases += ToolGroupSummary.phrases(for: segment.calls)

        var text = phrases.prefix(3).map(\.text).joined(separator: ", ")
        if phrases.count > 3 {
            let hidden = phrases.dropFirst(3).reduce(0) { $0 + $1.calls }
            text += ", +\(hidden) more"
        }
        if messageCount == 0, let first = text.first {
            text = first.uppercased() + text.dropFirst()
        }
        return FoldTextSanitizer.sanitize(text)
    }
}
