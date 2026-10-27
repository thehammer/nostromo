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
    var hasTerminalOrigin: Bool { origin != nil }

    /// The exact text of each item's element in `userInput` (nil for a notice, and for an element
    /// the text no longer holds), parallel to `terminalOriginItems`.
    var terminalOriginTexts: [String?] {
        TerminalDeliveryText.texts(for: terminalOriginItems, in: userInput)
    }
}

/// How a delivery block is addressed inside a turn, apart from the turn's own blocks.
enum TerminalDeliveryBlockKey {

    /// The index under which item `item`'s expansion is kept in `TurnInteractionState`
    /// (`expandedBlocks`), and named in `onBlockExpansion`. Negative, so it can never be the
    /// index of one of the turn's own blocks, which share that set.
    static func blockIndex(item: Int) -> Int { -(item + 1) }

    /// The turn view's column key of item `item` (`b<blockIndex>`, the form `ReplView` hands the
    /// viewport to keep a toggled row where it is).
    static func columnKey(item: Int) -> String { "b\(blockIndex(item: item))" }
}
