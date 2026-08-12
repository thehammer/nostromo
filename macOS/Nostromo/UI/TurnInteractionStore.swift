import Foundation

/// What the operator has done to one turn, held outside the turn's views.
///
/// Turn views are destroyed routinely now — on eviction from the materialized
/// window, and on every width change over 0.5 pt — so any state that lives only
/// in a view is silently reset. For an answered `AskUserQuestion` card that reset
/// is not cosmetic: the rebuilt card is armed again, with full-opacity enabled
/// buttons and a live `onAnswer` → `onSend` → `session.send(_:)` path, and one
/// stray click sends a second message into a live agent session.
///
/// Before virtualization this could not happen, because turn views were never
/// released and the view's own `answered` flag was sufficient.
struct TurnInteractionState: Equatable {

    /// Block index → index of the option the operator chose. Present means the
    /// card is answered: it renders chosen and is inert.
    ///
    /// Keyed by option *index*, not label. Two options can carry the same label,
    /// and `OptionButton` is already constructed with `tag: idx`.
    var answeredOptions: [Int: Int] = [:]

    /// Block indices whose tool result the operator expanded.
    var expandedBlocks: Set<Int> = []

    var isEmpty: Bool { answeredOptions.isEmpty && expandedBlocks.isEmpty }
}

/// Per-turn interaction state for one transcript pane, keyed by `ChatTurn.ID`.
///
/// Owned by `ReplView` and deliberately free of any AppKit dependency, so it
/// compiles into the logic test bundle.
///
/// **Bounded on purpose.** This must not become the leak the virtualization work
/// exists to remove. Two rules, both cheap: `removeAll()` when the transcript is
/// cleared, and `prune(keeping:)` on a splice — the retention cap emits
/// `.spliced(replacedFrom: 0)`, so pruning there also covers dropped history.
/// Between splices, growth is bounded by the number of turns a human has
/// actually interacted with. Pruning on every materialization pass would put an
/// O(turns) walk on the hot path and is not done.
final class TurnInteractionStore {

    private var states: [UUID: TurnInteractionState] = [:]

    /// Interaction state for a turn. An unknown turn has none, which is the
    /// same thing as "nothing has been done to it".
    func state(for turn: UUID) -> TurnInteractionState {
        states[turn] ?? TurnInteractionState()
    }

    func recordAnswer(turn: UUID, block: Int, option: Int) {
        states[turn, default: TurnInteractionState()].answeredOptions[block] = option
    }

    func setExpanded(turn: UUID, block: Int, _ isExpanded: Bool) {
        if isExpanded {
            states[turn, default: TurnInteractionState()].expandedBlocks.insert(block)
        } else {
            states[turn]?.expandedBlocks.remove(block)
            if states[turn]?.isEmpty == true { states.removeValue(forKey: turn) }
        }
    }

    func removeAll() { states.removeAll() }

    /// Forget every turn that is no longer in the transcript.
    func prune(keeping ids: Set<UUID>) {
        states = states.filter { ids.contains($0.key) }
    }

    /// Turns currently carrying state, for tests and diagnostics.
    var trackedTurnCount: Int { states.count }
}
