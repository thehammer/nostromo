import Foundation
import NostromoKit

// What a turn the user did not type shows in the transcript (terminal slice 3e).
//
// The daemon writes terminal output it delivers to a following agent, and its follow notices, as
// user messages, and tags the echoed turn with an `origin` (`TurnOriginWire`, decoded in
// NostromoKit and carried on `ChatTurn.origin`). The transcript shows such a turn as one block per
// item instead of a user bubble. The wording of a block lives in `TerminalDeliveryText`.

extension ChatTurn {

    /// The items of this turn's terminal origin, in the order the message has them. Empty for an
    /// ordinary turn.
    var terminalOriginItems: [TerminalOriginItem] { origin?.items ?? [] }

    /// Whether this turn is a terminal delivery or follow notice (shown as blocks, not a bubble).
    /// Any other origin (a Mother job notice) is not: it has no terminal items to draw.
    var hasTerminalOrigin: Bool {
        switch origin {
        case .terminalDelivery?, .terminalFollowNotice?: return true
        case .motherJobNotice?, .taskWake?, .peerMessage?, .injectedContext?, .localCommand?, nil: return false
        }
    }

    /// Whether this turn is a Mother job notice (shown as one muted marker, not a bubble).
    var hasMotherNoticeOrigin: Bool {
        if case .motherJobNotice? = origin { return true }
        return false
    }

    /// Whether this turn is a background task wake (shown as one muted marker, not a bubble).
    var hasTaskWakeOrigin: Bool {
        if case .taskWake? = origin { return true }
        return false
    }

    /// Whether this turn is text the CLI injected that the user did not type: a message from another
    /// session, a loaded skill, a summary or other context (shown as one muted marker, not a bubble).
    var hasInjectedOrigin: Bool {
        switch origin {
        case .peerMessage?, .injectedContext?: return true
        default: return false
        }
    }

    /// Whether this turn is a local slash command's record (a muted, collapsible output, not a bubble).
    var hasLocalCommandOrigin: Bool {
        if case .localCommand? = origin { return true }
        return false
    }

    /// What a local command's record shows: nil for any other turn.
    var localCommandRecord: (command: String, args: String, output: String, stream: String,
                             compact: CompactInfoWire?)? {
        guard case .localCommand(let command, let args, let output, let stream, _, let compact)? = origin else { return nil }
        return (command, args, output, stream, compact)
    }

    /// Whether the user slot draws a muted marker for this turn: a Mother notice, a task wake or
    /// injected text, or the sent line of a typed command the daemon has not yet answered.
    var hasMarkerOrigin: Bool {
        hasMotherNoticeOrigin || hasTaskWakeOrigin || hasInjectedOrigin || isPendingCommandEcho
    }

    /// The optimistic echo of a typed slash command, not yet adopted by a daemon turn.
    var isPendingCommandEcho: Bool { pendingCommand && daemonId == nil && origin == nil }

    /// The one muted line of a pending command echo: `/context · sent`.
    var pendingCommandMarker: WakeMarkerContent? {
        guard isPendingCommandEcho else { return nil }
        let name = userInput.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? userInput
        return WakeMarkerContent(line: "\(userInput) · sent", tooltipLines: [],
                                 accessibilityLabel: "Command \(name), sent", target: .none)
    }

    /// The marker this turn shows in the user slot; nil for a turn that has none. Only a turn whose
    /// daemon-sent origin says so draws one, never one whose text merely looks like it.
    var markerContent: WakeMarkerContent? {
        switch origin {
        case .motherJobNotice(let items)?: return WakeMarkerText.motherNotice(items)
        case .taskWake(let items, let omitted)?: return WakeMarkerText.taskWake(items, omitted: omitted)
        case .peerMessage(let items, let omitted)?: return WakeMarkerText.peerMessage(items, omitted: omitted)
        case .injectedContext(let kind, let title, let text, let truncated)?:
            return WakeMarkerText.injectedContext(kind: kind, title: title, text: text, truncated: truncated)
        case .localCommand?: return nil
        case .terminalDelivery?, .terminalFollowNotice?, nil: return pendingCommandMarker
        }
    }

    /// What the marker's Copy menu puts on the pasteboard: an injected message's text (a peer's body, never
    /// the raw tag); a Mother notice's raw text (what the agent
    /// received); a task wake's own line, and for several events the tooltip's lines after it (the daemon
    /// never sends the raw event). One event is only its line: its tooltip says the same.
    var markerCopyText: String {
        if hasInjectedOrigin { return markerContent?.copyText ?? userInput }
        if isPendingCommandEcho { return userInput }
        guard hasTaskWakeOrigin, let content = markerContent else { return userInput }
        guard content.tooltipLines.count > 1 else { return content.line }
        return ([content.line] + content.tooltipLines).joined(separator: "\n")
    }

    /// The marker a Mother job notice turn shows in the user slot; nil for any other turn. The raw
    /// element stays in `userInput`, which the marker's Copy Notice Text menu puts on the pasteboard.
    var motherNoticeMarker: WakeMarkerContent? {
        hasMotherNoticeOrigin ? markerContent : nil
    }

    /// The exact text of each item's element in `userInput` (nil for a notice, and for an element
    /// the text no longer holds), parallel to `terminalOriginItems`.
    var terminalOriginTexts: [String?] {
        TerminalDeliveryText.texts(for: terminalOriginItems, in: userInput)
    }

    /// Text the agent received that the blocks do not show (see
    /// `TerminalDeliveryText.unshownText`). Nil for a genuine delivery.
    var terminalOriginExtraText: String? {
        guard hasTerminalOrigin else { return nil }
        return originExtraCache.extra(for: terminalOriginItems, in: userInput)
    }

    /// What the bubble of a terminal-origin turn holds, nil when there is none: the extra text,
    /// or the image-only placeholder for attachments. Never hides what the agent received.
    var terminalOriginBubbleText: String? {
        if let extra = terminalOriginExtraText { return extra }
        return imageURLs.isEmpty ? nil : ChatSession.imageOnlyText
    }
}

/// How a delivery block is addressed inside a turn, apart from the turn's own blocks.
enum TerminalDeliveryBlockKey {

    /// The index under which item `item`'s expansion is kept (`FoldKey.result`), and named in
    /// `onBlockExpansion`. Negative, so it can never be the index of one of the turn's own blocks,
    /// which share that numbering.
    static func blockIndex(item: Int) -> Int { -(item + 1) }

    /// The turn view's column key of item `item` (`b<blockIndex>`, the form `ReplView` hands the
    /// viewport to keep a toggled row where it is).
    static func columnKey(item: Int) -> String { "b\(blockIndex(item: item))" }
}

/// Remembers the last `unshownText` of a turn, keyed by the text it was computed from, so the
/// height estimator and the view do not re-scan (and re-copy) tens of KB for every call. A
/// reference type, so a `ChatTurn` value can fill it through a getter; copies share it, and the
/// key check keeps it honest when `userInput` or the origin changes.
final class TerminalOriginExtraCache {
    private var input: String?
    private var items: [TerminalOriginItem] = []
    private var value: String?

    func extra(for items: [TerminalOriginItem], in text: String) -> String? {
        if let input, input == text, self.items == items { return value }
        let computed = TerminalDeliveryText.unshownText(for: items, in: text)
        input = text
        self.items = items
        value = computed
        return computed
    }
}
