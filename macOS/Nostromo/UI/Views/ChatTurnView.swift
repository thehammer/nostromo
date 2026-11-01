import AppKit
import NostromoKit

// Turn and block views for the transcript, moved out of `ReplView.swift` so
// they can be compiled into the logic test bundle — the same move
// `ToolResultView.swift` and `AskQuestionView.swift` already made, and for the
// same reason. `ReplView` itself pulls in `ChatSession`, `AppStore` and the
// whole daemon client stack, so nothing declared inside it was reachable from a
// test. The constraint-count and height-parity tests in
// `ChatTurnViewLayoutTests` are the point of the move.

// MARK: - TurnIsland

/// A turn view that can be sized and measured before it is inserted anywhere,
/// and re-widened on a pane resize, without ever being constrained to its
/// container.
///
/// Islands report their own height rather than being asked for `fittingSize`.
/// That is not a stylistic preference: `fittingSize` on a `ChatTurnView` means
/// solving every block it holds, which made a steady-state re-measure of a
/// 300-block turn cost 754 ms even when nothing about it had changed — the
/// treadmill that froze the app on 2026-09-09. A turn already knows the height
/// of each of its blocks, so summing them is arithmetic.
protocol TurnIsland: NSView {
    func setIslandWidth(_ width: CGFloat)
    /// Rendered height at the width last given to `setIslandWidth`.
    func islandHeight() -> CGFloat

    // Item-level anchoring (`TranscriptViewportCoordinator`). Island coordinates (flipped),
    // computed from cached heights, so they are right before the island's next `layout()`.
    // Item keys: a tool group's `ToolGroup.key`; a block rendered as itself `b<blockIndex>`.

    /// The first item whose bottom is below `y`, and how far `y` is below its top (negative
    /// when `y` is in the space above it). Nil below the last item.
    func anchorItem(atY y: CGFloat) -> (key: String, offset: CGFloat)?
    /// Top of the item `key`. `b<i>` also finds a call or result inside an expanded group.
    func offset(ofItemKey key: String) -> CGFloat?
    /// The 22 pt row of the tool group `key`.
    func rowRect(forGroupKey key: String) -> NSRect?
}

// MARK: - WidthPresettable

/// A view that can be told the width it is about to be laid out at, *before*
/// anything solves.
///
/// Exists for `MarkdownCardView`, whose height depends on a width it otherwise
/// learns only from `bounds` inside its first `layout()` — so it computes a
/// height against a 400 pt fallback, calls `invalidateIntrinsicContentSize()`,
/// and corrects itself on a second pass. Every measurement therefore paid a
/// `layoutSubtreeIfNeeded()` plus two full solves. Measured on one 200-char
/// text block: `layoutSubtreeIfNeeded()` alone is 1.64 ms where `fittingSize`
/// alone is 0.52 ms, and a turn materializes hundreds of blocks.
///
/// Told the width up front, one `fittingSize` is exact and the loop is gone.
protocol WidthPresettable: NSView {
    func presetLayoutWidth(_ width: CGFloat)
}

// MARK: - ArithmeticIsland

/// A frame-positioned island whose height is a sum it already knows (its members are measured
/// one by one), so measuring it needs neither a solve nor a detach from the window.
protocol ArithmeticIsland: NSView {
    /// Take `width` and report the height at it.
    func arithmeticHeight(atWidth width: CGFloat) -> CGFloat
}

// MARK: - MarkerTurnView

/// Renders the transcript's statements about history it cannot show.
///
/// The PRD is explicit that the one thing worse than losing scrollback is the
/// operator judging what an agent did from a transcript that quietly omitted
/// part of it. So these are plain, unmissable, and rendered in place.
class MarkerTurnView: NSView, TurnIsland {

    private var widthConstraint: NSLayoutConstraint!

    init(marker: ChatTurn.Marker) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true

        let text: String
        switch marker {
        case .gap:
            text = "⋯  Earlier turns may be missing here — this pane was disconnected for longer than the daemon keeps in its attach window."
        case .historyUnavailable:
            text = "⋯  Earlier history is no longer available in this pane. The full record remains on disk in the Claude session transcript."
        case .note(let note):
            text = note
        }

        let label = CopyMenuTextField(labelWithString: text)
        label.isSelectable         = true   // copyable transcript content
        label.font                 = .systemFont(ofSize: 11)
        label.textColor            = Theme.fgMuted
        label.lineBreakMode        = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.alignment            = .center
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.borderInactive.withAlphaComponent(0.6).cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)

        widthConstraint = widthAnchor.constraint(equalToConstant: 400)
        NSLayoutConstraint.activate([
            widthConstraint,
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            rule.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setIslandWidth(_ width: CGFloat) { widthConstraint.constant = width }

    /// Solved rather than cached: a marker is one wrapped label and a rule, so
    /// its whole constraint graph is five constraints deep and costs less to
    /// solve than to bookkeep.
    func islandHeight() -> CGFloat {
        layoutSubtreeIfNeeded()
        return fittingSize.height
    }

    /// A marker holds no items: anchoring falls back to the turn.
    func anchorItem(atY y: CGFloat) -> (key: String, offset: CGFloat)? { nil }
    func offset(ofItemKey key: String) -> CGFloat? { nil }
    func rowRect(forGroupKey key: String) -> NSRect? { nil }
}

// MARK: - ChatTurnView

/// One exchange — the operator's message, then the agent's blocks — rendered as
/// a self-contained Auto Layout island.
///
/// ## Every block is its own island too
///
/// `ReplView`'s header describes why *turns* are frame-positioned islands: Auto
/// Layout's cost scales with the size of one connected constraint graph, so an
/// `NSStackView` chaining N children into one system re-solved the whole session
/// on every pass. This view used to do exactly that *inside* a single turn — an
/// `NSStackView` of blocks plus a `width == stack.width` constraint per block —
/// and so the bug that was fixed between turns was never fixed within one.
///
/// Measured against the real views at a 900 pt pane, before this change:
///
/// | one turn holding | constraints | `measure()` |
/// |---|---|---|
/// | 100 text blocks | 512 | 119 ms |
/// | 400 text blocks | 2 012 | 3 362 ms |
/// | 800 text blocks | 4 012 | 21 825 ms |
/// | 80 tool pairs + a 60×6 table | 2 572 | 9 965 ms |
///
/// …and splitting the *same* 200 table rows across 8 turns instead of 1 took
/// 849 ms instead of 20 147 ms. 24× for identical pixels, which is the result
/// that says the fix is to break the graph up rather than to shrink the content.
///
/// So: the bubble and every block are positioned by `frame` from `layout()`,
/// each holding exactly one constraint of its own — its width — and none
/// linking it to a sibling. Each is measured **detached**, for the same reason
/// `ReplView.measure()` measures a turn detached, and its height is cached
/// here. The turn's own height is those cached heights summed, reported through
/// `intrinsicContentSize`, so `ReplView.measure()`'s contract is unchanged and a
/// turn-level solve is now O(1).
///
/// ## Which makes streaming incremental
///
/// A block's width never depends on its siblings, so appending one cannot
/// change any earlier block's height. `update(turn:)` therefore measures only
/// the blocks it just rendered and adds them to the running sum, where before
/// every appended block re-solved the entire turn: streaming one turn to 300
/// blocks cost 79 750 ms of cumulative main-thread time, spread over 300 solves
/// each redoing work already done. That treadmill is the branch the 2026-09-09
/// stack sample landed in.
///
/// See `.claude/wip/replview-measure-superlinear-autolayout/index.md` for the
/// full measurements and `MarkdownTableView` for the same argument applied
/// inside a single block.
class ChatTurnView: NSView, TurnIsland, ElapsedTicking {

    // MARK: Geometry — each of these was a constraint constant

    /// Gap above the bubble (or above the first block when it is suppressed).
    private static let topPadding: CGFloat = 12
    /// Gap below the last block.
    private static let bottomPadding: CGFloat = 14
    /// Gap between the bubble and the first block.
    private static let bubbleGap: CGFloat = TurnHeightEstimator.userSlotGap
    /// Leading inset of the block column.
    private static let blocksLeadingInset: CGFloat = 14
    /// Trailing inset of the user bubble.
    private static let bubbleTrailingInset: CGFloat = 12

    /// `TurnHeightEstimator` reproduces this layout arithmetically to estimate a
    /// turn's height before it is built, and reads the shared fractions and
    /// spacing from there rather than repeating the literals, so the two cannot
    /// drift apart. `turnChrome` is `topPadding + bottomPadding`; `bubbleChrome`
    /// is `bubbleGap` plus `UserBubbleView`'s own vertical padding.
    static func blockWidth(paneWidth: CGFloat) -> CGFloat {
        paneWidth * TurnHeightEstimator.blocksWidthFraction - blocksLeadingInset
    }

    static func bubbleWidth(paneWidth: CGFloat) -> CGFloat {
        paneWidth * TurnHeightEstimator.bubbleWidthFraction
    }

    /// An image-only message hugs its thumbnail instead of stretching to the
    /// usual fraction of the pane (which left a 1500pt bubble around a 240pt image).
    static func bubbleWidth(paneWidth: CGFloat, imageOnly: Bool) -> CGFloat {
        let full = bubbleWidth(paneWidth: paneWidth)
        return imageOnly ? min(full, UserBubbleView.imageSize.width + 24) : full
    }

    private var bubbleIsImageOnly = false

    // MARK: State

    private var widthConstraint: NSLayoutConstraint!
    /// Pane width the cached heights below were measured at. Starts at the same
    /// 400 pt placeholder the width constraint used to, so a view that is never
    /// given a real width still renders something coherent.
    private var islandWidth: CGFloat = 400
    /// Set when every cached height is stale — at construction, and whenever the
    /// island width actually changes. Cleared by `remeasureIfNeeded`.
    private var needsFullRemeasure = true

    private var bubble: UserBubbleView?
    /// The muted marker a Mother job notice turn shows in the user slot, in place of `bubble`.
    private var wakeMarker: WakeMarkerView?
    /// Height of whichever fills the user slot (the bubble, or the fixed-height marker).
    private var bubbleHeight: CGFloat = 0

    /// The frame-positioned column under the bubble: the truncation banner when
    /// there is one, then the views of each Focus item (`slots`) — a text block of the latest
    /// message, a boundary, a whole tool group (`ToolGroupView`) or a whole activity row
    /// (`ActivityRowView`). Parallel to `columnHeights`.
    private var columnViews: [NSView] = []
    private var columnHeights: [CGFloat] = []
    /// Item key of each column (see `TurnIsland`). Parallel to `columnViews`.
    private var columnKeys: [String] = []
    /// Width constraint of each column view, so a pane resize can re-widen them
    /// without rebuilding. Parallel to `columnViews`.
    private var columnWidthConstraints: [NSLayoutConstraint] = []
    private var bubbleWidthConstraint: NSLayoutConstraint?
    /// Blocks fed to `planner` so far: the index of the next block.
    private var renderedCount = 0

    /// Lays the turn out in the Focus view (`FocusPlanner`, which owns TF2's `ToolFoldPlanner`)
    /// as blocks arrive. Each block is fed once, so streaming costs the new blocks only. The only
    /// classifier: this view renders the items it is given.
    private var planner: FocusPlanner
    private var plannerEnded = false
    /// The planner's items as the ops so far leave them (`FocusPlanner.replay`).
    private var plan: [FocusItem] = []
    /// Messages whose roll-in this pane holds back (FV3): presented through
    /// `FocusPlanner.items(holding:)`, at their place, as conversation. `FocusPlanner.leadingGroups`
    /// stands for the groups before the first message.
    private var held: Set<Int>
    /// The latest message's ordinal, from the planner's `.latestChanged`.
    private var latestOrdinal: Int?

    /// What one rendered item is, for matching it against the next presentation.
    private enum Identity: Equatable {
        case activity(String)
        case message(Int)
        case boundary(Int)
        case group(Int)
    }

    /// One rendered item: its identity and its run of columns.
    private struct Slot {
        let identity: Identity
        let firstColumn: Int
        var columnCount: Int
        /// A message's block indices rendered so far.
        var blockCount: Int

        var columns: Range<Int> { firstColumn ..< firstColumn + columnCount }
    }

    /// The rendered items, in order, each over `columnCount` columns from `firstColumn`.
    private var slots: [Slot] = []
    /// Group id → its view, for the groups rendered as items (not inside a lane).
    private var groupViews: [Int: ToolGroupView] = [:]
    /// How foldables resolve. Kept current: the operator's toggles here and `applyFolds` update
    /// it, so the stuck-turn rule at turn end sees choices made since the view was built.
    private var folds: FoldResolver
    /// The clock the running rows read their elapsed time from.
    private let now: () -> Date
    /// Where tool rows read their permission-request status from (AP2b). Nil: rows show none.
    private let approvals: ApprovalStore?
    /// The last group, while it may still change (no item after it, the turn still open).
    private var openGroupId: Int?
    /// Top-level calls fed unfinished, by `toolUseId`: a quiet completion arrives as an in-place
    /// change to one of these (`ToolCompletionFolding`), not as a new block.
    private var unfinishedCalls: [String: Int] = [:]

    /// False when this turn's payload was dropped past the retention cap. Its
    /// blocks say so rather than rendering as empty.
    private let contentAvailable: Bool

    /// Fired when a block changes its own height (a tool result expanding), so
    /// `ReplView` re-measures rather than leaving the geometry stale.
    var onIntrinsicHeightChange: (() -> Void)?

    /// Fired when the operator answers an `AskUserQuestion` card, so the choice
    /// can be recorded outside this view — which is destroyed on eviction and on
    /// every width change. See `TurnInteractionStore`.
    var onAnsweredOption: ((_ blockIndex: Int, _ optionIndex: Int) -> Void)?

    /// Fired when the operator expands or collapses a tool result. Distinct from
    /// `onIntrinsicHeightChange`, which is about geometry: this one is about
    /// persistence, so the state survives the view.
    var onBlockExpansion: ((_ blockIndex: Int, _ isExpanded: Bool) -> Void)?

    /// Fired when the operator opens or closes a tool group (here or inside an activity lane),
    /// so the choice outlives this view.
    var onGroupToggle: ((_ groupKey: String, _ isExpanded: Bool) -> Void)?

    /// Fired when the operator opens or closes an activity row.
    var onActivityToggle: ((_ key: String, _ isExpanded: Bool) -> Void)?

    /// Asked, during a live update, when a newer message rolls a message into activity (the
    /// latest one, or the groups before the first message): hold the roll-in back, or let it go
    /// through and say how it plays (`RollInHolds.decide`). Held, the outgoing message stays where
    /// it is as conversation (`onHold`) until `releaseHolds`.
    var decideRollIn: (_ ordinal: Int) -> RollInDecision = { _ in .roll(.none) }

    /// A roll-in was held back: the outgoing message's ordinal, so the pane can remember it.
    var onHold: ((_ ordinal: Int) -> Void)?

    /// A hold was dropped to stay under `RollInPolicy.maxHeldPerTurn`: the pane forgets it.
    var onHoldDropped: ((_ ordinal: Int) -> Void)?

    /// Plays the collapse of a message that rolls in on screen. Set by `RollInHolds.wire`.
    var animator: RollInAnimating = SystemRollInAnimator()

    /// The most messages this turn holds back at once. Set by `RollInHolds.wire`.
    var holdLimit: () -> Int = { RollInPolicy.maxHeldPerTurn }

    /// At the limit, which hold to release to make room, given what is held (`RollInPolicy.holdToDrop`
    /// when wired: the oldest the reader is not looking at). Set by `RollInHolds.wire`.
    var holdToDrop: (_ held: Set<Int>) -> Int? = { $0.min() }

    /// Fired when the turn ended in error while streaming and its last group (which has a
    /// failed call) was opened by the stuck-turn rule, so the auto entry can be recorded.
    var onAutoOpen: ((_ groupKey: String) -> Void)?

    /// Fired during live updates when a group can no longer change (something follows it, or
    /// the turn ended), with its final state. Never for groups already settled when built.
    var onGroupSettled: ((ToolGroup) -> Void)?

    /// Fired just before this view changes its own height with nobody having asked (an open
    /// group building its next batch of rows), so the owner can note the reading position.
    var onWillChangeHeight: (() -> Void)?

    /// Everything the operator has already done to this turn, restored into the
    /// block views as they are built. Kept current with what is done here (answers, result
    /// folds), because a roll-in rebuilds items while the view lives: a card answered after the
    /// view was built must come back answered.
    private var interaction: TurnInteractionState

    /// Reply text injected by the confirm card — suppress its bubble so the card
    /// itself serves as the only visible acknowledgement of the user's choice.
    private static let confirmReplySentinel = "(This answers your question:"

    /// Called when the user answers an in-turn `AskUserQuestion` card.
    /// Wired by `ReplView` to `session.send(_:)`.
    var onSend: ((String) -> Void)?

    /// - Parameters:
    ///   - folds: how tool groups and activity rows resolve; nil means the operator's explicit
    ///     choices in `interaction`, else the Focus default (collapsed).
    ///   - heldOrdinals: messages whose roll-in the pane is holding back (`decideRollIn`).
    init(turn: ChatTurn, contentAvailable: Bool, interaction: TurnInteractionState,
         folds: FoldResolver? = nil, heldOrdinals: Set<Int> = [], now: @escaping () -> Date = Date.init,
         approvals: ApprovalStore? = nil) {
        self.approvals        = approvals
        self.contentAvailable = contentAvailable
        self.interaction      = interaction
        self.folds            = folds ?? FoldResolver(turnKey: turn.identityKey)
        self.held             = heldOrdinals
        self.now              = now
        self.planner          = FocusPlanner(turnKey: turn.identityKey)
        super.init(frame: .zero)
        // Positioned by frame inside the document view, with exactly one
        // constraint of its own — its width. Nothing ties it to its container or
        // to its siblings, so the constraint engine holds one independent
        // component per materialized turn instead of one graph spanning the
        // session, and evicting it removes that component entirely.
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true
        widthConstraint = widthAnchor.constraint(equalToConstant: islandWidth)
        widthConstraint.isActive = true

        // Suppress the bubble when the reply was injected by the confirm card — the
        // card's own chosen-state visuals already acknowledge the selection. A turn the daemon
        // wrote for a followed terminal (`origin`) is no bubble either: it is the blocks below.
        // Unless it holds text the blocks do not show, or attachments: then an "also sent" bubble
        // keeps what the agent received visible.
        let bubbleText = turn.hasTerminalOrigin ? turn.terminalOriginBubbleText : turn.userInput
        if let content = turn.motherNoticeMarker {
            // A Mother job notice is one muted marker in the user slot, never the raw element and
            // never a bubble. Its Copy Notice Text menu keeps the agent's text reachable. The confirm
            // sentinel does not apply: this turn is not a confirm-card reply.
            let marker = WakeMarkerView(content: content, noticeText: turn.userInput)
            wakeMarker = marker
            bubbleWidthConstraint = attachIsland(marker, width: slotWidth())
        // The sentinel only ever marks a confirm-card reply, which has no terminal origin: on a
        // terminal-origin turn it is just text, and hiding it would hide what the agent received.
        } else if let bubbleText, turn.hasTerminalOrigin || !turn.userInput.contains(Self.confirmReplySentinel) {
            let bubble = UserBubbleView(text: bubbleText, imageURLs: turn.imageURLs)
            self.bubble = bubble
            bubbleIsImageOnly = bubbleText == ChatSession.imageOnlyText && !turn.imageURLs.isEmpty
            bubbleWidthConstraint = attachIsland(bubble,
                                                 width: Self.bubbleWidth(paneWidth: islandWidth, imageOnly: bubbleIsImageOnly))
        }

        // Every block of an unrecoverable turn is truncated — the user bubble
        // and the assistant's text as much as its tool results — so an answer
        // would otherwise stop mid-sentence with nothing to explain it. One
        // banner at the top of the turn covers all of them; the tool-result
        // disclosure adds its own line because that content is separately
        // expandable.
        if !contentAvailable {
            appendColumnView(Self.makeTruncationBanner(), key: "banner")
        }
        if turn.hasTerminalOrigin { appendDeliveryBlocks(for: turn) }
        render(turn, live: false)
    }

    /// The blocks of a terminal delivery turn: one per item, as the first columns (under the
    /// banner, above the agent's answer), where the user bubble would have been.
    private func appendDeliveryBlocks(for turn: ChatTurn) {
        let texts = turn.terminalOriginTexts
        for (i, item) in turn.terminalOriginItems.enumerated() {
            let index = TerminalDeliveryBlockKey.blockIndex(item: i)
            let view = TerminalDeliveryBlockView(item: item, text: texts[i],
                                                 startExpanded: folds.explicitResult(block: nil, index: index) ?? false)
            view.onExpansionChange = { [weak self, weak view] isExpanded in
                guard let self, let view else { return }
                self.noteBlockExpansion(index, isExpanded)
                self.columnChangedHeight(view)
            }
            appendColumnView(view, key: TerminalDeliveryBlockKey.columnKey(item: i))
        }
    }

    /// The terminal delivery blocks of this turn, in order (empty for an ordinary turn).
    var deliveryBlockViews: [TerminalDeliveryBlockView] {
        columnViews.compactMap { $0 as? TerminalDeliveryBlockView }
    }

    /// Whether the turn shows the user's message as a bubble.
    var hasUserBubble: Bool { bubble != nil }

    /// The marker in the user slot of a Mother job notice turn (nil for any other turn).
    var wakeMarkerView: WakeMarkerView? { wakeMarker }

    /// What fills the user slot: the bubble, or a notice turn's marker.
    private var userSlot: NSView? { bubble ?? wakeMarker }

    /// Width of the user slot: the bubble's fraction of the pane, or the whole row for the marker
    /// (one line, tail-truncated, trailing like the bubble).
    private func slotWidth() -> CGFloat {
        if wakeMarker != nil { return max(islandWidth - Self.blocksLeadingInset - Self.bubbleTrailingInset, 1) }
        return Self.bubbleWidth(paneWidth: islandWidth, imageOnly: bubbleIsImageOnly)
    }

    /// The text and attachment count the user bubble shows (nil without a bubble).
    var userBubbleContent: (text: String, imageCount: Int)? {
        bubble.map { ($0.shownText, $0.imageCount) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func makeTruncationBanner() -> NSView {
        let label = CopyMenuTextField(labelWithString:
            "⚠︎  Only the beginning of this turn is still held in this pane. "
            + "The full text remains in the Claude session transcript on disk.")
        label.isSelectable         = true   // copyable transcript content
        label.font                 = .systemFont(ofSize: 10)
        label.textColor            = Theme.amber
        label.lineBreakMode        = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    // MARK: - TurnIsland

    /// Re-widen the turn, and everything inside it.
    ///
    /// Called by `ReplView.measure()` immediately before it solves, so this is
    /// the deterministic point at which stale heights get refreshed — rather
    /// than relying on `layout()` being reached, which for a detached view is
    /// not something to bet a cached-forever height on. `layout()` calls
    /// `remeasureIfNeeded()` too; both are idempotent.
    func setIslandWidth(_ width: CGFloat) {
        if abs(width - islandWidth) > 0.5 {
            islandWidth = width
            widthConstraint.constant = width
            needsFullRemeasure = true
        }
        remeasureIfNeeded()
    }

    // MARK: - Streaming

    /// Called as the turn's blocks array grows during live streaming.
    ///
    /// Renders — and measures — only the items that changed. Everything already
    /// rendered keeps its cached height, which is sound precisely because each
    /// block is an island at a fixed width: appending one cannot move an
    /// earlier one.
    ///
    /// New blocks go through the Focus planner, whose ops say what changed: an item appended,
    /// the latest message grown, a group or activity segment changed, or a roll-in (a newer
    /// message moved the latest one and the trailing groups into the activity row above). A
    /// changed item is updated in place; a collapsed row or group keeps its fixed-height row,
    /// whose counts change synchronously here. A roll-in rebuilds only this turn's items from
    /// the first one it changed.
    ///
    /// The same block count can still be news: a quiet call that finished has its
    /// empty result folded into the call in place (`ToolCompletionFolding`). When
    /// the turn completes the planner hears how it ended, and a turn that ended
    /// in error opens its last, failed group (`openStuckGroup`).
    func update(turn: ChatTurn) {
        render(turn, live: true)
    }

    /// The tool group view with this key: an item of this turn, or inside a built activity lane
    /// (the load harness's `group-expand`, and tests).
    func groupView(forKey key: String) -> ToolGroupView? {
        if let view = groupViews.values.first(where: { $0.group.key == key }) { return view }
        for row in activityRowViews {
            if let view = row.groupView(forKey: key) { return view }
        }
        return nil
    }

    /// The activity rows of this turn, in order.
    var activityRowViews: [ActivityRowView] { columnViews.compactMap { $0 as? ActivityRowView } }

    /// The activity row with this segment key.
    func activityRowView(forKey key: String) -> ActivityRowView? {
        activityRowViews.first { $0.segment.key == key }
    }

    /// Re-resolve every group and activity row from `folds`: a change made elsewhere (another
    /// window, the mode, the default). Not an operator toggle here, so the toggle callbacks
    /// stay quiet. Those that open or close are re-measured at once. Returns whether any did.
    @discardableResult
    func applyFolds(_ folds: FoldResolver) -> Bool {
        self.folds = folds
        var changed = false
        for (column, view) in columnViews.enumerated() {
            if let group = view as? ToolGroupView {
                let expanded = folds.isExpanded(group.group)
                guard expanded != group.isExpanded else { continue }
                group.setExpanded(expanded)
            } else if let row = view as? ActivityRowView {
                let expanded = folds.isActivityExpanded(key: row.segment.key)
                let opened = expanded != row.isExpanded
                // The lane's groups first, so a lane built by the open is built from `folds`.
                let regrouped = row.applyFolds(folds)
                row.setExpanded(expanded)
                guard regrouped || opened else { continue }
            } else {
                continue
            }
            changed = true
            remeasureColumnIfMeasured(column)
        }
        return changed
    }

    /// Release held roll-ins (all of them, or `ordinals`): the held messages fold into their rows.
    /// `turn` is this turn as it stands (its blocks are read during the call only). The caller
    /// keeps the reading position (`ReplView.applyFoldChange`). `animation`: collapse the
    /// departing messages (an on-screen release in a following pane) or not.
    ///
    /// Returns the open states carried to a row's key: a row the operator opened while a hold
    /// split its segment is keyed by its own first member, and the whole segment, once the hold
    /// is released, is keyed by the segment's first member, so the state moves with it.
    @discardableResult
    func releaseHolds(turn: ChatTurn, ordinals: Set<Int>? = nil,
                      animation: RollInAnimation = .none) -> [String: Bool] {
        let released = ordinals.map { held.intersection($0) } ?? held
        guard !released.isEmpty else { return [:] }
        let ghosts = animation == .none ? [] : ghostViews(forMessages: released)
        let carried = carriedOpenStates(releasing: released)
        held.subtract(released)
        let blocks = turn.blocks
        reconcile(with: held.isEmpty ? plan : planner.items(holding: held),
                  blockAt: { blocks.indices.contains($0) ? blocks[$0] : nil })
        collapse(ghosts, animation: animation)
        invalidateIntrinsicContentSize()
        needsLayout = true
        return carried
    }

    /// Messages whose roll-in this view is holding back.
    var heldOrdinals: Set<Int> { held }

    /// Feed the new blocks to the planner and render what changed.
    ///
    /// The ops of the whole call are applied to `plan` first and the views reconciled once,
    /// so however many times the blocks of this call touched an item (a whole turn being built
    /// touches a 500-call group a thousand times), its view is built or updated once, with its
    /// final state. The turn's block array is only borrowed for the call; holding it would
    /// make every block the session appends to this turn copy the array.
    ///
    /// `live`: a streaming update, as opposed to the build. Only live updates report groups
    /// settling, hold roll-ins and open a stuck group with `onAutoOpen`: what was history when
    /// the view was built already resolves through `folds`.
    private func render(_ turn: ChatTurn, live: Bool) {
        let ending = turn.isComplete && !plannerEnded
        guard turn.blocks.count > renderedCount || ending || !unfinishedCalls.isEmpty else { return }
        let blocks = turn.blocks
        var ops: [FocusOp] = []

        // A quiet call finishing changes a block already fed, in place.
        for (id, index) in unfinishedCalls where index < renderedCount {
            guard case .toolCall(let call) = blocks[index], call.finishedQuietly else { continue }
            unfinishedCalls.removeValue(forKey: id)
            ops += planner.callFinished(toolUseId: id, at: call.finishedAt)
        }
        while renderedCount < blocks.count {
            let index = renderedCount
            renderedCount += 1
            noteCompletion(of: blocks[index], at: index)
            ops += planner.feed(ToolFoldAdapter.foldBlock(blocks[index],
                                                          parentId: turn.subagentTextParents[index]))
        }
        if ending {
            plannerEnded = true
            unfinishedCalls.removeAll()
            ops += planner.turnEnded(outcome: ToolFoldAdapter.outcome(of: turn))
        }

        let settled = trackOpenGroup(through: ops, ending: ending)
        let rolling = live ? decideRollIns(in: ops) : (animation: RollInAnimation.none, ordinals: Set<Int>())
        let ghosts = rolling.animation == .none ? [] : ghostViews(forMessages: rolling.ordinals)
        plan = FocusPlanner.replay(ops, onto: plan)
        reconcile(with: held.isEmpty ? plan : planner.items(holding: held),
                  blockAt: { blocks.indices.contains($0) ? blocks[$0] : nil })
        collapse(ghosts, animation: rolling.animation)

        if ending { openStuckGroup(live: live) }
        if live {
            for group in settled { onGroupSettled?(group) }
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Keep `openGroupId` (the running row's group) current through `ops`; returns the groups
    /// that closed, with their final state.
    private func trackOpenGroup(through ops: [FocusOp], ending: Bool) -> [ToolGroup] {
        var latest: [Int: ToolGroup] = [:]
        var settled: [Int] = []
        func closeOpenGroup() {
            if let id = openGroupId { settled.append(id) }
            openGroupId = nil
        }
        for op in ops {
            switch op {
            case .item(.group(let group)):
                closeOpenGroup()
                latest[group.id] = group
                openGroupId = group.id
            case .item, .rollIn, .latestChanged:
                closeOpenGroup()
            case .groupChanged(let group):
                latest[group.id] = group
            case .segmentChanged:
                break
            }
        }
        if ending { closeOpenGroup() }
        return settled.compactMap { latest[$0] ?? groupViews[$0]?.group }
    }

    /// Roll-ins arrived (a newer message moved the latest one, or the groups before the first
    /// message, into activity): ask the pane about each outgoing message, before anything
    /// changes. A held one stays as it is (`held`, `onHold`); the others go through, and those
    /// the pane says play an animation are returned (the longest wins) with their ordinals.
    ///
    /// The groups before the first message have no outgoing message; `FocusPlanner.leadingGroups`
    /// stands for them, so a reader scrolled up in an open group does not see it fold away.
    private func decideRollIns(in ops: [FocusOp]) -> (animation: RollInAnimation, ordinals: Set<Int>) {
        var latest = latestOrdinal
        var animation = RollInAnimation.none
        var animated: Set<Int> = []
        for op in ops {
            switch op {
            case .rollIn:
                let outgoing = latest ?? FocusPlanner.leadingGroups
                guard !held.contains(outgoing) else { break }
                switch decideRollIn(outgoing) {
                case .hold:
                    if held.count >= holdLimit(), let dropped = holdToDrop(held) {
                        // Folding a message the reader may be looking at: name the reading position
                        // first, as the pane does for every change that moves content.
                        onWillChangeHeight?()
                        held.remove(dropped)
                        onHoldDropped?(dropped)
                    }
                    held.insert(outgoing)
                    onHold?(outgoing)
                case .roll(let played):
                    if played != .none {
                        animation = played
                        animated.insert(outgoing)
                    }
                }
            case .latestChanged(let message):
                latest = message.ordinal
            default:
                break
            }
        }
        latestOrdinal = latest
        return (animation, animated)
    }

    /// Bring the views to `items`: items that match what is rendered (same identity, in the
    /// same place) are updated in place; from the first that does not, the old items' views
    /// go and the new ones are built. Changes only ever happen at a turn's end (a roll-in, a
    /// new item) or in place, so the matching prefix is almost the whole turn.
    private func reconcile(with items: [FocusItem], blockAt: (Int) -> TurnBlock?) {
        latestOrdinal = items.reduce(latestOrdinal) { latest, item in
            if case .message(let m) = item { return max(latest ?? m.ordinal, m.ordinal) } else { return latest }
        }
        var i = 0
        while i < items.count, i < slots.count, slots[i].identity == Self.identity(of: items[i]) {
            guard updateInPlace(slot: i, with: items[i], isLast: i == slots.count - 1, blockAt: blockAt) else { break }
            i += 1
        }
        if i < slots.count { removeSlots(from: i) }
        for item in items[i...] { appendSlot(item, blockAt: blockAt) }
    }

    private static func identity(of item: FocusItem) -> Identity {
        switch item {
        case .activity(let segment): return .activity(segment.key)
        case .message(let message):  return .message(message.ordinal)
        case .boundary(let index):   return .boundary(index)
        case .group(let group):      return .group(group.id)
        }
    }

    /// Update one rendered item to `item` (same identity). False when it cannot be done in place.
    private func updateInPlace(slot i: Int, with item: FocusItem, isLast: Bool,
                               blockAt: (Int) -> TurnBlock?) -> Bool {
        let column = slots[i].firstColumn
        switch item {
        case .activity(let segment):
            guard let row = columnViews[column] as? ActivityRowView else { return false }
            // Members that joined (a trailing group the operator opened, results they expanded)
            // build from the state as it is now, not as it was when the row was made.
            row.updateState(folds: folds)
            if row.segment != segment, row.update(segment: segment, blockAt: blockAt) {
                remeasureColumnIfMeasured(column)
            }
        case .message(let message):
            let rendered = slots[i].blockCount
            guard message.blockIndices.count != rendered else { return true }
            // A message only grows while it is the last item.
            guard isLast, message.blockIndices.count > rendered else { return false }
            for index in message.blockIndices[rendered...] {
                appendColumnView(makeBlockView(blockAt(index), at: index), key: "b\(index)")
            }
            slots[i].columnCount += message.blockIndices.count - rendered
            slots[i].blockCount = message.blockIndices.count
        case .boundary:
            break
        case .group(let group):
            guard let view = groupViews[group.id] else { return false }
            if view.group != group, view.update(group: group, blockAt: blockAt) {
                remeasureColumnIfMeasured(column)
            }
        }
        return true
    }

    /// Render `item` after the last one.
    private func appendSlot(_ item: FocusItem, blockAt: (Int) -> TurnBlock?) {
        let first = columnViews.count
        var blockCount = 0
        switch item {
        case .activity(let segment):
            appendColumnView(makeActivityRow(segment, blockAt: blockAt), key: segment.key)
        case .message(let message):
            for index in message.blockIndices {
                appendColumnView(makeBlockView(blockAt(index), at: index), key: "b\(index)")
            }
            blockCount = message.blockIndices.count
        case .boundary(let index):
            appendColumnView(makeBlockView(blockAt(index), at: index), key: "b\(index)")
        case .group(let group):
            let view = makeGroupView(group, blockAt: blockAt)
            groupViews[group.id] = view
            appendColumnView(view, key: group.key)
        }
        slots.append(Slot(identity: Self.identity(of: item), firstColumn: first,
                          columnCount: columnViews.count - first, blockCount: blockCount))
    }

    /// Drop the views of `slots[from...]`.
    private func removeSlots(from index: Int) {
        let firstColumn = slots[index].firstColumn
        for slot in slots[index...] {
            if case .group(let id) = slot.identity { groupViews.removeValue(forKey: id) }
        }
        slots.removeSubrange(index...)
        for view in columnViews[firstColumn...] { view.removeFromSuperview() }
        columnViews.removeSubrange(firstColumn...)
        columnHeights.removeSubrange(firstColumn...)
        columnKeys.removeSubrange(firstColumn...)
        columnWidthConstraints.removeSubrange(firstColumn...)
    }

    /// Keep `unfinishedCalls` current as blocks are fed.
    private func noteCompletion(of block: TurnBlock, at index: Int) {
        switch block {
        case .toolCall(let call):
            // Subagent calls are not the planner's top-level calls; nothing to finish there.
            if let id = call.toolUseId, call.parentToolUseId == nil, !call.finishedQuietly {
                unfinishedCalls[id] = index
            }
        case .toolResult(let result):
            if let id = result.toolUseId { unfinishedCalls.removeValue(forKey: id) }
        default:
            break
        }
    }

    /// The turn just ended. If it ended in error with a failed call in its last group, and that
    /// group sits after the latest message (the trailing group), it opens, once (contract §2.4):
    /// unless the operator chose a state for it, which wins. A stuck group inside an activity
    /// row opens when the row is opened. Nothing ever closes here.
    private func openStuckGroup(live: Bool) {
        guard let id = groupViews.keys.max(), let view = groupViews[id], view.group.isStuck,
              !view.isExpanded, folds.explicitGroup(view.group.key) == nil
        else { return }
        let key = view.group.key
        folds.groupAuto.insert(key)
        view.setExpanded(true)
        if let column = columnViews.firstIndex(of: view) { remeasureColumnIfMeasured(column) }
        if live { onAutoOpen?(key) }
    }

    private func makeGroupView(_ group: ToolGroup, blockAt: (Int) -> TurnBlock?) -> ToolGroupView {
        let view = ToolGroupView(group: group, blockAt: blockAt,
                                 contentAvailable: contentAvailable, folds: folds,
                                 isExpanded: folds.isExpanded(group), now: now, approvals: approvals)
        view.onToggle = { [weak self, weak view] isExpanded in
            guard let self, let view else { return }
            self.folds.groupStates[view.group.key] = isExpanded
            self.onGroupToggle?(view.group.key, isExpanded)
            self.columnChangedHeight(view)
        }
        view.onBlockExpansion = { [weak self] index, isExpanded in
            self?.noteBlockExpansion(index, isExpanded)
        }
        view.onHeightChange = { [weak self, weak view] in
            guard let self, let view else { return }
            self.columnChangedHeight(view)
        }
        view.onBatchWillBuild = { [weak self] in self?.onWillChangeHeight?() }
        return view
    }

    private func makeActivityRow(_ segment: ActivitySegment, blockAt: (Int) -> TurnBlock?) -> ActivityRowView {
        var blocks: [Int: TurnBlock] = [:]
        ActivityRowView.collectBlocks(of: segment, from: blockAt, into: &blocks)
        let view = ActivityRowView(segment: segment, blocks: blocks, contentAvailable: contentAvailable,
                                   folds: folds,
                                   isExpanded: folds.isActivityExpanded(key: segment.key), now: now,
                                   approvals: approvals)
        view.onToggle = { [weak self, weak view] isExpanded in
            guard let self, let view else { return }
            self.folds.activityStates[view.segment.key] = isExpanded
            self.onActivityToggle?(view.segment.key, isExpanded)
            self.columnChangedHeight(view)
        }
        view.onGroupToggle = { [weak self, weak view] key, isExpanded in
            guard let self, let view else { return }
            self.folds.groupStates[key] = isExpanded
            self.onGroupToggle?(key, isExpanded)
            self.columnChangedHeight(view)
        }
        view.onBlockExpansion = { [weak self] index, isExpanded in
            self?.noteBlockExpansion(index, isExpanded)
        }
        view.onHeightChange = { [weak self, weak view] in
            guard let self, let view else { return }
            self.columnChangedHeight(view)
        }
        view.onBatchWillBuild = { [weak self] in self?.onWillChangeHeight?() }
        return view
    }

    /// A result (or agent activity) fold was toggled somewhere in this turn: remember it here too,
    /// for items a roll-in rebuilds, and tell the owner.
    private func noteBlockExpansion(_ index: Int, _ isExpanded: Bool) {
        folds.resultStates[index] = isExpanded
        onBlockExpansion?(index, isExpanded)
    }

    /// A column's height changed by itself (a toggle, a member fold, a batch of rows): only that
    /// island is re-measured, and the owner is told.
    private func columnChangedHeight(_ view: NSView) {
        guard let column = columnViews.firstIndex(of: view) else { return }
        remeasureColumnView(at: column)
        onIntrinsicHeightChange?()
    }

    private func makeBlockView(_ block: TurnBlock?, at index: Int) -> NSView {
        guard let block else { return NSView() }
        switch block {
        case .text(let t):           return TextBlockView(text: t)
        case .toolCall(let d):       return ToolCallView(data: d)
        case .toolResult(let d):
            let v = ToolResultView(data: d, contentAvailable: contentAvailable,
                                   explicitState: folds.explicitResult(block: block, index: index))
            v.onExpansionChange = { [weak self, weak v] isExpanded in
                guard let self, let v else { return }
                self.noteBlockExpansion(index, isExpanded)
                // Only this block's height changed. Re-measuring the one island
                // and re-summing is what keeps an expand O(1) in turn size — and
                // what stops the cached total drifting from what is on screen.
                self.columnChangedHeight(v)
            }
            return v
        case .resultSummary(let d):  return ResultChipView(data: d)
        case .errorMessage(let m):   return ErrorBlockView(message: m)
        case .note(let text):        return NoteBlockView(text: text)
        case .askQuestion(let d):
            let v = AskQuestionView(data: d,
                                    answeredOptionIndex: interaction.answeredOptions[index])
            v.onAnswer = { [weak self] answer, optionIndex in
                guard let self else { return }
                // Record before sending. If the send path ever tears this view
                // down, the answer is already outside it.
                self.interaction.answeredOptions[index] = optionIndex
                self.onAnsweredOption?(index, optionIndex)
                self.onSend?(answer)
            }
            return v
        }
    }

    // MARK: - Islands

    /// Add one column view — banner or block — and measure it, unless nothing
    /// has been measured at a real width yet.
    ///
    /// Deferring in that case is what stops materialization measuring every
    /// block twice: `init` runs before `ReplView.measure()` has said how wide
    /// the pane is, so the heights it could produce would be thrown away by the
    /// `setIslandWidth` that immediately follows.
    private func appendColumnView(_ view: NSView, key: String) {
        let width = Self.blockWidth(paneWidth: islandWidth)
        columnWidthConstraints.append(constrainIsland(view, width: width))
        // Measured (at its width) before it is attached, so a block streaming into a turn on
        // screen is not detached from the window and attached again just to be asked its height.
        columnHeights.append(needsFullRemeasure ? 0 : Self.measureIsland(view, width: width))
        addSubview(view)
        columnViews.append(view)
        columnKeys.append(key)
    }

    /// Give `view` its single width constraint — the only constraint it will
    /// ever hold that is visible from outside itself — and attach it.
    ///
    /// `translatesAutoresizingMaskIntoConstraints = true` is what makes the
    /// frame stick once it is attached. It is also why `measureIsland` has to
    /// detach first; see there.
    @discardableResult
    private func attachIsland(_ view: NSView, width: CGFloat) -> NSLayoutConstraint {
        let constraint = constrainIsland(view, width: width)
        addSubview(view)
        return constraint
    }

    /// The width constraint half of `attachIsland`.
    private func constrainIsland(_ view: NSView, width: CGFloat) -> NSLayoutConstraint {
        view.translatesAutoresizingMaskIntoConstraints = true
        let constraint = view.widthAnchor.constraint(equalToConstant: width)
        constraint.isActive = true
        return constraint
    }

    #if DEBUG
    /// Every `measureIsland` call, for the layout-cost tests (no wall clock).
    static var measureIslandCount = 0
    #endif

    /// Measure one island at `width`, detached.
    ///
    /// Detached is not optional, and the reason is `ReplView.measure()`'s:
    /// `translatesAutoresizingMaskIntoConstraints = true` makes AppKit pin the
    /// view's size to its frame the moment it has a superview, at which point
    /// `fittingSize` reports the frame it already has rather than the height
    /// its content wants — so a freshly built view measures as zero and a
    /// re-measured one never changes.
    ///
    /// One solve, where `ReplView.measure()`'s loop needed two.
    ///
    /// The loop existed solely so `MarkdownCardView` could discover its own
    /// width during a first, throwaway layout pass; `WidthPresettable` hands it
    /// that width instead — it was always this same `width` argument, knowable
    /// arithmetically before anything was built. `layoutSubtreeIfNeeded()`
    /// still has to run: a wrapping `NSTextField`'s height is only resolved
    /// once the solve has given it a real width, and `fittingSize` alone
    /// reports it as a single line.
    static func measureIsland(_ view: NSView, width: CGFloat) -> CGFloat {
        #if DEBUG
        measureIslandCount += 1
        #endif
        if let island = view as? ArithmeticIsland {
            let height = island.arithmeticHeight(atWidth: width)
            view.setFrameSize(NSSize(width: width, height: height))
            return height
        }
        let superview = view.superview
        let selection = TranscriptSelection.capture(in: view)
        // Put back where it was, not at the end: subview order is the transcript's reading
        // order for VoiceOver (and a column re-measured alone used to move to the end).
        let next = superview.flatMap { siblings -> NSView? in
            guard let i = siblings.subviews.firstIndex(of: view), i + 1 < siblings.subviews.count else { return nil }
            return siblings.subviews[i + 1]
        }
        superview.map { _ in view.removeFromSuperview() }

        (view as? WidthPresettable)?.presetLayoutWidth(width)
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height
        view.setFrameSize(NSSize(width: width, height: height))

        if let next {
            superview?.addSubview(view, positioned: .below, relativeTo: next)
        } else {
            superview?.addSubview(view)
        }
        selection?.restore()
        return height
    }

    /// Re-measure a column now, unless a full re-measure is already pending.
    private func remeasureColumnIfMeasured(_ index: Int) {
        if !needsFullRemeasure { remeasureColumnView(at: index) }
    }

    /// Re-measure one column view in place — a tool result that just expanded.
    private func remeasureColumnView(at index: Int) {
        guard columnViews.indices.contains(index) else { return }
        columnHeights[index] = Self.measureIsland(columnViews[index],
                                                  width: Self.blockWidth(paneWidth: islandWidth))
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Re-measure everything, because the width they were measured at is gone
    /// (or was never real). Idempotent — `needsFullRemeasure` is the latch.
    private func remeasureIfNeeded() {
        guard needsFullRemeasure else { return }
        needsFullRemeasure = false

        if let userSlot {
            let width = slotWidth()
            bubbleWidthConstraint?.constant = width
            bubbleHeight = Self.measureIsland(userSlot, width: width)
        }
        let blocksWidth = Self.blockWidth(paneWidth: islandWidth)
        for (i, view) in columnViews.enumerated() {
            columnWidthConstraints[i].constant = blocksWidth
            columnHeights[i] = Self.measureIsland(view, width: blocksWidth)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // MARK: - Geometry

    /// Content grows downward, so the view's own coordinates do too.
    override var isFlipped: Bool { true }

    /// The same arithmetic `TurnHeightEstimator.estimate` performs, over
    /// measured heights instead of estimated ones — which is what makes the
    /// estimator and the renderer converge rather than drift.
    private var contentHeight: CGFloat {
        var height = Self.topPadding
        if userSlot != nil { height += bubbleHeight + Self.bubbleGap }
        for (i, blockHeight) in columnHeights.enumerated() {
            if i > 0 { height += TurnHeightEstimator.blockSpacing }
            height += blockHeight
        }
        return height + Self.bottomPadding
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    /// Top of the first column (under the bubble).
    private var columnsTop: CGFloat {
        Self.topPadding + (userSlot != nil ? bubbleHeight + Self.bubbleGap : 0)
    }

    /// Calls `body` with each column's index and top, in order, until it returns a value.
    private func firstColumn<T>(where body: (_ column: Int, _ top: CGFloat) -> T?) -> T? {
        remeasureIfNeeded()
        var top = columnsTop
        for i in columnViews.indices {
            if i > 0 { top += TurnHeightEstimator.blockSpacing }
            if let found = body(i, top) { return found }
            top += columnHeights[i]
        }
        return nil
    }

    func anchorItem(atY y: CGFloat) -> (key: String, offset: CGFloat)? {
        firstColumn { i, top in
            guard top + columnHeights[i] > y else { return nil }
            // Inside an activity row: its row, or the lane member under `y`.
            if let row = columnViews[i] as? ActivityRowView, let inside = row.anchorItem(atY: y - top) {
                return inside
            }
            return (columnKeys[i], y - top)
        }
    }

    func offset(ofItemKey key: String) -> CGFloat? {
        // `b<i>` can also name a member of an expanded group; any key can name something in an
        // expanded activity lane.
        let member = key.hasPrefix("b") ? Int(key.dropFirst()) : nil
        return firstColumn { i, top in
            if columnKeys[i] == key { return top }
            if let row = columnViews[i] as? ActivityRowView {
                return row.offset(ofItemKey: key).map { top + $0 }
            }
            guard let member, let group = columnViews[i] as? ToolGroupView,
                  let inside = group.offset(ofMemberBlock: member) else { return nil }
            return top + inside
        }
    }

    func rowRect(forGroupKey key: String) -> NSRect? {
        firstColumn { i, top -> NSRect? in
            if columnKeys[i] == key, columnViews[i] is ToolGroupView {
                return NSRect(x: Self.blocksLeadingInset, y: top,
                              width: Self.blockWidth(paneWidth: islandWidth), height: FoldRowView.height)
            }
            guard let row = columnViews[i] as? ActivityRowView, let rect = row.rowRect(forGroupKey: key) else { return nil }
            return rect.offsetBy(dx: Self.blocksLeadingInset, dy: top)
        }
    }

    // MARK: - Roll-in holds (FV3)

    /// Where a held message (or `FocusPlanner.leadingGroups`) sits in this view's coordinates;
    /// nil when it has no views here (it is folded, or not rendered).
    func rollInRect(ordinal: Int) -> NSRect? {
        let wanted = columns(ofHeld: ordinal)
        guard let last = wanted.last else { return nil }
        var union: NSRect?
        _ = firstColumn { i, top -> Bool? in
            if wanted.contains(i) {
                let rect = columnRect(i, top: top)
                union = union.map { $0.union(rect) } ?? rect
            }
            return i >= last ? true : nil
        }
        return union
    }

    /// The operator holds a text selection inside this message, or is dragging one out in it.
    func hasSelection(inMessage ordinal: Int, isLeftMouseDown: Bool) -> Bool {
        columns(ofHeld: ordinal).contains { Self.holdsSelection(in: columnViews[$0], isLeftMouseDown: isLeftMouseDown) }
    }

    /// The first responder is text inside `view` that has a selection (a label's field editor
    /// included), or the left button is down in it, which is a drag that has selected nothing yet.
    private static func holdsSelection(in view: NSView, isLeftMouseDown: Bool) -> Bool {
        guard let text = view.window?.firstResponder as? NSTextView else { return false }
        let owner: NSView? = text.isFieldEditor ? text.delegate as? NSView : text
        guard let owner, owner.isDescendant(of: view) else { return false }
        return text.selectedRange.length > 0 || isLeftMouseDown
    }

    /// The columns a message (or `FocusPlanner.leadingGroups`: the groups before the first
    /// message) is rendered in. Empty when it is not rendered as an item of its own.
    private func columns(ofHeld ordinal: Int) -> [Int] {
        if ordinal == FocusPlanner.leadingGroups {
            var columns: [Int] = []
            for slot in slots {
                if case .message = slot.identity { break }
                if case .group = slot.identity { columns += slot.columns }
            }
            return columns
        }
        guard let slot = slots.first(where: { $0.identity == .message(ordinal) }) else { return [] }
        return Array(slot.columns)
    }

    private func columnFrame(_ column: Int) -> NSRect? {
        firstColumn { i, top -> NSRect? in i == column ? columnRect(i, top: top) : nil }
    }

    /// Column `i`, whose top is `top`, in this view's coordinates.
    private func columnRect(_ i: Int, top: CGFloat) -> NSRect {
        NSRect(x: Self.blocksLeadingInset, y: top,
               width: Self.blockWidth(paneWidth: islandWidth), height: columnHeights[i])
    }

    /// The views of messages that are about to leave this island, with where they sit in it, so
    /// `collapse` can play them out after the reconcile removed them. The groups before the first
    /// message (`FocusPlanner.leadingGroups`) never animate: they are tool rows, not text.
    private func ghostViews(forMessages ordinals: Set<Int>) -> [(view: NSView, frame: NSRect)] {
        var ghosts: [(view: NSView, frame: NSRect)] = []
        for ordinal in ordinals where ordinal != FocusPlanner.leadingGroups {
            for column in columns(ofHeld: ordinal) {
                if let frame = columnFrame(column) { ghosts.append((columnViews[column], frame)) }
            }
        }
        return ghosts
    }

    /// Play the departing messages' collapse over the island, then drop them. The reconcile has
    /// removed their views and the geometry is already final (the pane's pin re-asserts at the
    /// bottom at once), so this is only what the reader sees for `duration`; a ghost never takes
    /// a click, and is not there for VoiceOver.
    ///
    /// The ghost keeps to the part of the old message's place that no message of the new layout
    /// covers, which is the activity row it folds into: it never draws over a message the reader
    /// is about to read. When the new layout covers all of it there is nothing to play, and the
    /// roll-in is instant. Neither case changes the turn's height: a ghost is only drawn.
    private func collapse(_ ghosts: [(view: NSView, frame: NSRect)], animation: RollInAnimation) {
        guard case .collapse(let duration) = animation else { return }
        let departing = ghosts.filter { ghost in !columnViews.contains { $0 === ghost.view } }
        guard let first = departing.first else { return }
        var region = departing.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        region.size.height = min(region.size.height, firstMessageTop(below: region.minY) - region.minY)
        guard region.size.height >= 1 else { return }
        let container = RollInGhostView(frame: region)
        for ghost in departing {
            Self.hideFromAccessibility(ghost.view)
            container.addSubview(ghost.view)
            ghost.view.frame = ghost.frame.offsetBy(dx: -region.minX, dy: -region.minY)
        }
        addSubview(container)
        animator.collapse(container, duration: duration) { [weak container] in container?.removeFromSuperview() }
    }

    /// Where the first message that reaches below `y` begins, in this view's coordinates; no limit
    /// when none does. At or above `y` when that message covers `y` itself.
    private func firstMessageTop(below y: CGFloat) -> CGFloat {
        var top = CGFloat.greatestFiniteMagnitude
        for slot in slots {
            guard case .message(let ordinal) = slot.identity, let rect = rollInRect(ordinal: ordinal),
                  rect.maxY > y else { continue }
            top = min(top, rect.minY)
        }
        return top
    }

    private static func hideFromAccessibility(_ view: NSView) {
        view.setAccessibilityElement(false)
        view.subviews.forEach(hideFromAccessibility)
    }

    /// Open states to move to the key a released hold gives a row. While a message is held a
    /// segment is split, and the part after the held message is keyed by its own first member;
    /// released, the whole segment is keyed by its first member again, so a choice the operator
    /// made on the split row would be lost. Applied here and returned for the pane to record.
    private func carriedOpenStates(releasing released: Set<Int>) -> [String: Bool] {
        let before = planner.items(holding: held)
        let after = planner.items(holding: held.subtracting(released))
        var carried: [String: Bool] = [:]
        for case .activity(let row) in before {
            guard let state = folds.explicitActivity(row.key), let first = row.members.first else { continue }
            let id = Self.memberID(first)
            for case .activity(let target) in after
            where target.key != row.key && target.members.contains(where: { Self.memberID($0) == id }) {
                guard folds.explicitActivity(target.key) == nil else { continue }
                folds.activityStates[target.key] = state
                carried[target.key] = state
            }
        }
        return carried
    }

    private static func memberID(_ member: ActivityMember) -> String {
        switch member {
        case .message(let message): return "m\(message.ordinal)"
        case .group(let group):     return "g\(group.id)"
        }
    }

    // MARK: - Elapsed time (ElapsedTicking)

    /// The last group's view, while it is running.
    private var runningOpenGroup: ToolGroupView? {
        guard let id = openGroupId, let view = groupViews[id], view.group.state == .running else { return nil }
        return view
    }

    /// When the running row next needs its elapsed time refreshed: 10 s after its call
    /// started, then on each whole second after that. Nil when nothing is running.
    func nextElapsedTick(after now: Date) -> Date? {
        guard let view = runningOpenGroup, let start = view.group.currentCall?.startedAt else { return nil }
        let age = now.timeIntervalSince(start)
        guard age.isFinite else { return nil }
        if age < ToolGroupSummary.elapsedThreshold {
            return start.addingTimeInterval(ToolGroupSummary.elapsedThreshold)
        }
        return start.addingTimeInterval(age.rounded(.down) + 1)
    }

    /// Re-read the clock into the running row. In place: no re-measure.
    func refreshElapsed() {
        runningOpenGroup?.row.refreshElapsed()
    }

    /// Arithmetic over cached block heights — no solve, no matter how many
    /// blocks the turn holds. This is what makes a streaming re-measure cost
    /// the new blocks and nothing else.
    func islandHeight() -> CGFloat {
        remeasureIfNeeded()
        return contentHeight
    }

    /// Columns are positioned in `layout()`, so until the first layout pass they
    /// sit at the origin and a click over a paragraph would land on the wrong
    /// view. A turn attached and clicked before AppKit's layout pass ran (the
    /// same run-loop turn) gets its pass now.
    /// The point goes to `super` untouched (still superview coordinates). Note the
    /// app-control `hittest` reaches this, so it can complete a pending layout pass.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if needsLayout { layoutSubtreeIfNeeded() }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        remeasureIfNeeded()

        var y = Self.topPadding
        if let userSlot {
            let width = slotWidth()
            place(userSlot, alignmentRect:
                    NSRect(x: islandWidth - Self.bubbleTrailingInset - width,
                           y: y, width: width, height: bubbleHeight))
            y += bubbleHeight + Self.bubbleGap
        }
        let blocksWidth = Self.blockWidth(paneWidth: islandWidth)
        for (i, view) in columnViews.enumerated() {
            if i > 0 { y += TurnHeightEstimator.blockSpacing }
            place(view, alignmentRect: NSRect(x: Self.blocksLeadingInset, y: y,
                                              width: blocksWidth, height: columnHeights[i]))
            y += columnHeights[i]
        }
    }

    /// Place one island, from the **alignment** rect the constraints this
    /// replaces would have addressed.
    ///
    /// For every custom view here the alignment rect and the frame are the
    /// same thing, but `NSTextField` insets its text two points on each side —
    /// and the truncation banner is a bare `NSTextField`, so writing these
    /// numbers straight into `frame` would shift it two points against every
    /// other block. Its own width constraint addresses the alignment rect too,
    /// so this keeps the two agreeing.
    ///
    /// Writing an unchanged frame would dirty a block that is already laid
    /// out, and re-solving every block on every pass is precisely the cost
    /// this design exists to avoid.
    private func place(_ view: NSView, alignmentRect: NSRect) {
        let rect = view.frame(forAlignmentRect: alignmentRect)
        guard view.frame != rect else { return }
        view.frame = rect
    }
}

// MARK: - UserBubbleView

/// Right-floating chat bubble for user messages.
///
/// Still constraint-based inside — it is one label in a rounded rect, and its
/// width is a fixed fraction of the pane — but `ChatTurnView` measures and
/// positions it as an island like every block, so it links to nothing.
class UserBubbleView: NSView {

    /// Fixed so the bubble's height is known without waiting on image decode.
    static let imageSize = NSSize(width: 240, height: 150)

    private let label: NSTextField
    private let stack = NSStackView()
    private var imageURLs: [URL]

    var shownText: String { label.stringValue }
    var imageCount: Int { imageURLs.count }

    init(text: String, imageURLs: [URL] = []) {
        self.imageURLs = imageURLs
        label = CopyMenuTextField(labelWithString: text)
        label.isSelectable = true   // copyable: text in the transcript must be selectable
        label.font                 = .systemFont(ofSize: 13)
        label.textColor            = Theme.fg
        label.lineBreakMode        = .byWordWrapping
        label.maximumNumberOfLines = 0
        // Yield horizontally so the label wraps to the available width instead of
        // demanding its full single-line width (which would balloon the scroll view
        // and, ultimately, the whole window past the screen edge).
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.cornflower.withAlphaComponent(0.18).cgColor
        layer?.cornerRadius    = 12
        layer?.borderWidth     = 1
        layer?.borderColor     = Theme.cornflower.withAlphaComponent(0.35).cgColor

        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for url in imageURLs { stack.addArrangedSubview(makeImageView(url)) }
        // An image-only message carries a placeholder the agent needs but the
        // reader does not.
        if !(text == ChatSession.imageOnlyText && !imageURLs.isEmpty) {
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    private func makeImageView(_ url: URL) -> NSImageView {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignLeft
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 6
        iv.layer?.masksToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        let size = Self.imageSize
        iv.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        iv.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        // Decoded to thumbnail size, never source size (see ThumbnailLoader).
        ThumbnailLoader.load(url, size: max(size.width, size.height), scale: 2) { [weak iv] image in
            iv?.image = image
        }
        let click = NSClickGestureRecognizer(target: self, action: #selector(openImage(_:)))
        iv.addGestureRecognizer(click)
        iv.toolTip = "Open \(url.lastPathComponent)"
        return iv
    }

    @objc private func openImage(_ g: NSClickGestureRecognizer) {
        guard let iv = g.view,
              let i = stack.arrangedSubviews.firstIndex(of: iv), i < imageURLs.count
        else { return }
        NSWorkspace.shared.open(imageURLs[i])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - TextBlockView

/// Renders text with markdown table detection. Tables become native grid views;
/// paragraphs stay as labels.
///
/// Uses explicit leading/trailing constraints so `MarkdownTableView` — whose
/// intrinsic size names a height but no width — fills the full block width.
class TextBlockView: NSView, WidthPresettable {

    /// Cards this block rendered, so `presetLayoutWidth` can tell each of them
    /// the width it will be laid out at. Empty for the label/table path, whose
    /// heights do not depend on a width the view has to discover.
    private var cards: [MarkdownCardView] = []

    func presetLayoutWidth(_ width: CGFloat) {
        for card in cards { card.presetWidth = width }
    }

    /// Whose words these are: the conversation (`Theme.fg`), or an agent message folded into an
    /// activity row's lane (`Theme.foldedProse`, PRD "Visual distinction"). Only the text colour
    /// differs; fonts, sizes and so heights are the same.
    enum Tone {
        case conversation
        case folded

        var textColor: NSColor {
            switch self {
            case .conversation: return Theme.fg
            case .folded:       return Theme.foldedProse
            }
        }
    }

    let tone: Tone

    init(text: String, tone: Tone = .conversation) {
        self.tone = tone
        super.init(frame: .zero)
        let textColor = tone.textColor

        // Route to markdown cards if text has markdown content and no pipe table.
        // (Pipe tables use the existing MarkdownTableView path.)
        if !Self.hasPipeTable(text) && Self.hasMarkdown(text) {
            let segments = Self.markdownSegments(from: text)
            var prevAnchor: NSLayoutYAxisAnchor = topAnchor
            for (i, segment) in segments.enumerated() {
                let card = MarkdownCardView(markdown: segment, textColor: textColor)
                card.translatesAutoresizingMaskIntoConstraints = false
                addSubview(card)
                cards.append(card)
                NSLayoutConstraint.activate([
                    card.topAnchor.constraint(equalTo: prevAnchor, constant: i == 0 ? 0 : 8),
                    card.leadingAnchor.constraint(equalTo: leadingAnchor),
                    card.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
                prevAnchor = card.bottomAnchor
            }
            if let last = subviews.last {
                last.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
            }
            return
        }

        let segments = Self.parseSegments(text)
        var prevAnchor: NSLayoutYAxisAnchor? = nil

        for segment in segments {
            let view: NSView
            switch segment {
            case .paragraph(let txt):
                let label = CopyMenuTextField(labelWithString: Self.stripMarkdown(txt))
                label.isSelectable = true   // copyable: text in the transcript must be selectable
                label.font                 = .systemFont(ofSize: 13)
                label.textColor            = textColor
                label.lineBreakMode        = .byWordWrapping
                label.maximumNumberOfLines = 0
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                view = label
            case .table(let headers, let rows):
                view = MarkdownTableView(headers: headers, rows: rows, textColor: textColor)
            case .code(let source):
                // Appended to `cards` so `presetLayoutWidth` reaches it.
                let card = MarkdownCardView(markdown: source, textColor: textColor)
                cards.append(card)
                view = card
            }

            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: prevAnchor ?? topAnchor,
                                          constant: prevAnchor == nil ? 0 : 8),
            ])
            prevAnchor = view.bottomAnchor
        }

        // Close off the view's intrinsic height
        if let last = prevAnchor {
            last.constraint(equalTo: bottomAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Markdown detection & segmentation

    /// Returns true when the text contains enough markdown markers to warrant card rendering.
    private static func hasMarkdown(_ s: String) -> Bool {
        // `~~~` fences contain no backtick, so they need their own check.
        if MarkdownFences.containsFence(s) { return true }
        let lines = s.components(separatedBy: "\n")
        let lineMarker = lines.contains { line in
            line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ")
                || line.hasPrefix("- ") || line.hasPrefix("* ")
                || line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
        }
        return lineMarker || s.contains("`") || s.contains("**") || s.contains("\n---")
    }

    /// Splits text on bare `---` separator lines into one or more markdown segments.
    /// Only prose lines separate: a `---` inside a fenced block is code, and the block's
    /// source (fences included) goes to the card intact so the renderer can see it.
    private static func markdownSegments(from text: String) -> [String] {
        var segments: [String] = []
        var current: [String]  = []
        for segment in MarkdownFences.segments(of: text) {
            switch segment {
            case .code(let block):
                current.append(block.source)
            case .prose(let prose):
                for line in prose.components(separatedBy: "\n") {
                    if line.trimmingCharacters(in: .whitespaces) == "---" {
                        let seg = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !seg.isEmpty { segments.append(seg) }
                        current = []
                    } else {
                        current.append(line)
                    }
                }
            }
        }
        let tail = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { segments.append(tail) }
        return segments
    }

    /// Returns true when the text contains a markdown pipe table (takes the existing path).
    /// Lines inside fenced code never count.
    private static func hasPipeTable(_ s: String) -> Bool {
        MarkdownFences.segments(of: s).contains { segment in
            guard case .prose(let prose) = segment else { return false }
            let lines = prose.components(separatedBy: "\n")
            guard let headerIdx = lines.firstIndex(where: { $0.hasPrefix("|") }) else { return false }
            let nextIdx = lines.index(after: headerIdx)
            guard nextIdx < lines.endIndex else { return false }
            return lines[nextIdx].contains("|") && lines[nextIdx].contains("-")
        }
    }

    // MARK: Segment model & parser

    private enum Segment {
        case paragraph(String)
        case table(headers: [String], rows: [[String]])
        case code(source: String)
    }

    private static func parseSegments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        for fenced in MarkdownFences.segments(of: text) {
            switch fenced {
            case .prose(let prose): segments += parseProse(prose)
            case .code(let block):  segments.append(.code(source: block.source))
            }
        }
        return segments
    }

    /// Paragraphs and tables from a run of prose lines (never code).
    private static func parseProse(_ text: String) -> [Segment] {
        let lines = text.components(separatedBy: "\n")
        var segments: [Segment] = []
        var pending: [String]   = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let next = i + 1 < lines.count ? lines[i + 1] : ""

            // Markdown table: current line starts with |, next line is |---|
            if line.hasPrefix("|"), next.hasPrefix("|"), next.contains("---") {
                // Flush pending paragraph
                let txt = pending.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !txt.isEmpty { segments.append(.paragraph(txt)) }
                pending = []

                let headers = parseCells(line)
                i += 2  // skip header row + separator row
                var rows: [[String]] = []
                while i < lines.count && lines[i].hasPrefix("|") {
                    rows.append(parseCells(lines[i]))
                    i += 1
                }
                if !headers.isEmpty { segments.append(.table(headers: headers, rows: rows)) }
            } else {
                pending.append(line)
                i += 1
            }
        }

        let tail = pending.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { segments.append(.paragraph(tail)) }

        return segments
    }

    private static func parseCells(_ line: String) -> [String] {
        line.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { stripMarkdownLinks($0) }
    }

    /// Converts `[label](url)` → `label` so URLs don't blow up column widths.
    private static let linkRegex = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#)
    private static let boldRegex = try? NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#)
    private static let italRegex = try? NSRegularExpression(pattern: #"\*([^*]+)\*"#)

    private static func stripMarkdownLinks(_ text: String) -> String {
        guard text.contains("](") else { return text }
        let ns    = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return linkRegex?.stringByReplacingMatches(in: text, range: range, withTemplate: "$1") ?? text
    }

    /// Strip `**bold**`, `*italic*`, and `[text](url)` so they don't appear raw in paragraph text.
    static func stripMarkdown(_ text: String) -> String {
        var s = text
        for (regex, template) in [(boldRegex, "$1"), (italRegex, "$1"), (linkRegex, "$1")] {
            guard let rx = regex else { continue }
            let ns = s as NSString
            s = rx.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: template)
        }
        return s
    }
}

// MARK: - CopyMenuTextField

/// A selectable transcript label: selection that stays legible on the dark theme,
/// and a right-click menu that is the owner's, both while idle and while it holds
/// the field editor.
///
/// Once a selectable `NSTextField` is clicked, a field editor (a text view,
/// installed as a subview of the label) becomes the hit view and answers the
/// click with the standard text menu — `NSView.menu` on the label, and the
/// `NSTextViewDelegate` menu hook, do not reach it. So the label brings its own
/// editor (see `CopyMenuTextFieldCell`) and the editor asks the label.
///
/// Every selectable label in the transcript uses this class, menu or not, because
/// the same editor swap is what blackens selected text: see
/// `CopyMenuTextFieldCell.setUpFieldEditorAttributes`.
class CopyMenuTextField: NSTextField {

    override class var cellClass: AnyClass? {
        get { CopyMenuTextFieldCell.self }
        set { _ = newValue }
    }

    /// The menu to show; nil falls back to AppKit's own.
    var menuProvider: (() -> NSMenu)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }
}

final class CopyMenuTextFieldCell: NSTextFieldCell {

    private lazy var editor: CopyMenuFieldEditor = {
        let editor = CopyMenuFieldEditor(frame: .zero)
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.importsGraphics = false
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }

    /// Make the field editor look like the label it replaces.
    ///
    /// These labels carry their colour and font in the attributed string, but the
    /// field editor that takes over on selection reads them from the *cell* — and
    /// finds the system default, which is black on a light Mac. Selected text then
    /// turned black on the selection colour. So the label's own colour and font
    /// (the first run's, else the cell's) are put on the editor, and the selection
    /// uses the theme's highlight rather than the system one.
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        // The editor otherwise takes the label's plain string and hands it back
        // flattened, dropping attributes such as the tool output's `.ligature = 0`.
        allowsEditingTextAttributes = true
        let text = super.setUpFieldEditorAttributes(textObj)
        let runs = attributedStringValue
        let first = runs.length > 0 ? runs.attributes(at: 0, effectiveRange: nil) : [:]
        // Kept on the cell too, so the next selection still knows them should the
        // attributed string have been flattened by the editor handing it back.
        let color = (first[.foregroundColor] as? NSColor) ?? textColor ?? Theme.fg
        let font = (first[.font] as? NSFont) ?? self.font
        textColor = color
        self.font = font
        text.textColor = color
        text.font = font
        if let editor = text as? NSTextView {
            editor.applyTranscriptSelectionTheme()
            // The transcript is dark whatever the Mac's appearance. The unemphasised
            // selection (window or app inactive) is drawn in a system grey that follows
            // the appearance: near-white in aqua, where light text on it is unreadable.
            editor.appearance = NSAppearance(named: .darkAqua)
        }
        return text
    }
}

extension NSTextView {
    /// Selection and caret colours for the dark transcript.
    func applyTranscriptSelectionTheme() {
        selectedTextAttributes = Theme.selectionAttributes
        insertionPointColor = Theme.fg
    }
}

/// Field editor whose context menu is the owning label's, with a plain "Copy" of
/// the selection ahead of the label's own items.
final class CopyMenuFieldEditor: NSTextView {

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let custom = ((delegate as AnyObject?) as? CopyMenuTextField)?.menuProvider?() else { return super.menu(for: event) }
        custom.insertItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: ""), at: 0)
        custom.insertItem(.separator(), at: 1)
        return custom
    }
}

// MARK: - ToolCallView

class ToolCallView: NSView {

    /// Where the context-menu actions copy to. Injectable so tests never touch
    /// the operator's real clipboard.
    var pasteboard: NSPasteboard = .general

    /// Longest command shown in the tooltip; the full text stays copyable.
    static let tooltipLimit = 2000

    private let data: ToolCallData

    init(data: ToolCallData) {
        self.data = data
        super.init(frame: .zero)
        let command = data.fullCommand
        toolTip = command.count > Self.tooltipLimit
            ? String(command.prefix(Self.tooltipLimit)) + "…"
            : command
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
        layer?.cornerRadius    = 6

        let iconLabel = NSTextField(labelWithString: Self.icon(for: data.toolName))
        iconLabel.font      = .systemFont(ofSize: 12)
        iconLabel.textColor = Theme.fgMuted
        iconLabel.setContentHuggingPriority(.required, for: .horizontal)

        let nameLabel = NSTextField(labelWithString: data.toolName)
        nameLabel.font      = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = Theme.fgMuted
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)

        let dotLabel = NSTextField(labelWithString: "·")
        dotLabel.font      = .systemFont(ofSize: 11)
        dotLabel.textColor = Theme.borderInactive
        dotLabel.setContentHuggingPriority(.required, for: .horizontal)

        let summaryLabel = CopyMenuTextField(labelWithString: data.inputSummary)
        // Literal command text (flags like `--stat`, `->` in scripts, etc.) — disable
        // Fira Code's default ligatures so it renders verbatim. See ToolResultView's
        // buildLabelIfNeeded() for the full explanation of this default-on behavior.
        //
        // The wrapping is stated outright, in the string and on the cell. The row has
        // always laid out word-wrapped (an attributed string with no paragraph style
        // wraps, whatever `lineBreakMode` says), but a selectable label that takes
        // the field editor rewrites its string from the cell's mode: with
        // `.byTruncatingMiddle` here, selecting text re-laid the row out as one
        // truncated line and the next measure shrank it. Saying "wrap" in both
        // places keeps the selected and unselected row identical.
        //
        // Font and colour go on the cell as well as in the string, for the same
        // reason: the field editor takes them from the cell, so a string-only font
        // made the text jump to the system font (and the row re-measure shorter)
        // the moment it was selected.
        summaryLabel.font      = Theme.monoFont
        summaryLabel.textColor = Theme.fg
        let wrapping = NSMutableParagraphStyle()
        wrapping.lineBreakMode = .byWordWrapping
        summaryLabel.attributedStringValue = NSAttributedString(string: data.inputSummary, attributes: [
            .font:            Theme.monoFont,
            .foregroundColor: Theme.fg,
            .ligature:        0,
            .paragraphStyle:  wrapping,
        ])
        summaryLabel.isSelectable = true   // copyable transcript content
        summaryLabel.lineBreakMode = .byWordWrapping
        (summaryLabel.cell as? NSTextFieldCell)?.wraps = true
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A selectable label that has been clicked owns the field editor, and a
        // right-click lands on *that* (standard Copy / Look Up menu), never
        // reaching `menu(for:)` below — so the label has to supply the menu itself.
        summaryLabel.menuProvider = { [unowned self] in self.copyMenu() }

        let row = NSStackView(views: [iconLabel, nameLabel, dotLabel, summaryLabel])
        row.orientation = .horizontal
        row.spacing     = 5
        row.alignment   = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Copy menu

    override func menu(for event: NSEvent) -> NSMenu? { copyMenu() }

    func copyMenu() -> NSMenu {
        let menu = NSMenu()
        if data.toolName == "Bash" {
            menu.addItem(withTitle: "Copy command", action: #selector(copyCommand), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Copy full input", action: #selector(copyFullInput), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy summary", action: #selector(copySummary), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyCommand()   { copy(data.fullCommand) }
    @objc private func copyFullInput() { copy(data.inputFull) }
    @objc private func copySummary()   { copy(data.inputSummary) }

    private func copy(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// The glyph a call row leads with. A collapsed group of one shows the same one.
    static func icon(for name: String) -> String {
        switch name {
        case "Read":                         return "📄"
        case "Write":                        return "📝"
        case "Edit", "MultiEdit":            return "✏️"
        case "Bash":                         return "$"
        case "Grep", "Glob":                 return "🔍"
        case "WebFetch", "WebSearch":        return "🌐"
        case "Agent":                        return "🤖"
        case "TodoWrite":                    return "✅"
        case "NotebookRead", "NotebookEdit": return "📓"
        default:                             return "⚙️"
        }
    }
}

// MARK: - ResultChipView

class ResultChipView: NSView {

    init(data: ResultSummaryData) {
        super.init(frame: .zero)

        // An interrupted turn is the operator's own doing, not a failure: neutral, not red.
        let symbol = data.interrupted ? "■" : (data.isError ? "✗" : "✓")
        let color  = data.interrupted ? Theme.fgMuted : (data.isError ? Theme.redSweater : Theme.sage)

        let durationStr = data.durationMs >= 1000
            ? String(format: "%.1fs", Double(data.durationMs) / 1000)
            : "\(data.durationMs)ms"
        let costStr = data.costUSD > 0
            ? String(format: " · $%.4f", data.costUSD)
            : ""
        let labelStr = data.interrupted
            ? "\(symbol)  Interrupted · \(durationStr)\(costStr)"
            : "\(symbol)  \(durationStr)\(costStr)"

        let label = CopyMenuTextField(labelWithString: labelStr)
        label.isSelectable = true   // copyable transcript content
        label.font      = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - ErrorBlockView

class ErrorBlockView: NSView {

    init(message: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.redSweater.withAlphaComponent(0.08).cgColor
        layer?.cornerRadius    = 6
        layer?.borderWidth     = 1
        layer?.borderColor     = Theme.redSweater.withAlphaComponent(0.4).cgColor

        let label = CopyMenuTextField(labelWithString: message)
        label.isSelectable = true   // copyable transcript content
        // Literal error text — disable Fira Code's default ligatures so it renders
        // verbatim. See ToolResultView's buildLabelIfNeeded() for the full explanation.
        label.attributedStringValue = NSAttributedString(string: message, attributes: [
            .font:            Theme.monoFont,
            .foregroundColor: Theme.redSweater,
            .ligature:        0,
        ])
        label.lineBreakMode       = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - NoteBlockView

/// A daemon-authored transcript marker, e.g. "Model changed to Opus (from Sonnet) by you.":
/// one centred line of secondary text, no bubble and no chrome, because it is not a message.
class NoteBlockView: NSView {

    /// Space either side of the text; the height estimator wraps against it.
    static let horizontalInset: CGFloat = 8

    private let label: CopyMenuTextField

    init(text: String) {
        label = CopyMenuTextField(labelWithString: text)
        super.init(frame: .zero)
        label.isSelectable = true   // copyable transcript content
        label.font = .systemFont(ofSize: 11)
        label.textColor = Theme.fgMuted
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        // One element carrying the text; its label field would be read a second time.
        setAccessibilityElement(true)
        setAccessibilityChildren([])
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError() }
}


// MARK: - TranscriptFocusPolicy

/// Whether a pane (re)attach may move focus to the input bar. Stealing focus
/// from a field editor that holds a transcript selection would clear that
/// selection, so a copy in progress survives the re-attach.
///
/// Only a selection inside *this* pane's transcript counts: a selection in a
/// sibling pane (its transcript or its input draft) is none of this pane's
/// business and must not stop it taking focus.
enum TranscriptFocusPolicy {

    /// `transcript` is the pane's transcript scroll view.
    static func shouldFocusInput(currentFirstResponder: NSResponder?, inputTextView: NSTextView?,
                                 transcript: NSView) -> Bool {
        guard let text = currentFirstResponder as? NSTextView,
              text !== inputTextView,
              text.selectedRange().length > 0
        else { return true }
        // A field editor is a transient view the window hands to whichever label
        // is being edited; the label is the thing that lives in the transcript.
        let owner: NSView? = text.isFieldEditor ? text.delegate as? NSView : text
        return !(owner?.isDescendant(of: transcript) ?? false)
    }

    /// Focus `inputTextView` unless that would clear a selection in `transcript`.
    static func focusInputIfAppropriate(in window: NSWindow, inputTextView: NSTextView, transcript: NSView) {
        guard shouldFocusInput(currentFirstResponder: window.firstResponder,
                               inputTextView: inputTextView, transcript: transcript)
        else { return }
        window.makeFirstResponder(inputTextView)
    }
}

// MARK: - TranscriptSelection

/// A transcript selection captured so it can be put back after the view holding
/// it is detached and re-attached.
///
/// Measuring a turn (or one block of it) detaches the view — see
/// `ChatTurnView.measureIsland` — and AppKit drops the first responder when a view
/// holding it leaves the window. Without this a width change, or a block
/// streaming into the turn being read, would silently clear the operator's
/// selection.
///
/// Two kinds of holder: a selectable label's shared *field editor* (the editor is
/// transient — the label is what lives in the transcript), and a plain
/// `NSTextView`, which is how `MarkdownCardView` shows prose. A third, with no
/// text: keyboard focus on a control in the transcript (a tool group row), which a
/// re-measure would otherwise drop the moment the operator toggles it.
struct TranscriptSelection {

    private enum Holder {
        case label(NSTextField)
        case textView(NSTextView)
        case focus(NSView)
    }

    private let holder: Holder
    private let range: NSRange

    /// The selection currently held inside `view`, or nil when the first
    /// responder is not a non-empty selection within it.
    static func capture(in view: NSView) -> TranscriptSelection? {
        if let control = view.window?.firstResponder as? FoldRowView, control.isDescendant(of: view) {
            return TranscriptSelection(holder: .focus(control), range: NSRange(location: 0, length: 0))
        }
        guard let text = view.window?.firstResponder as? NSTextView,
              text.selectedRange.length > 0
        else { return nil }
        if text.isFieldEditor {
            guard let owner = text.delegate as? NSTextField, owner.isDescendant(of: view) else { return nil }
            return TranscriptSelection(holder: .label(owner), range: text.selectedRange)
        }
        guard text.isDescendant(of: view) else { return nil }
        return TranscriptSelection(holder: .textView(text), range: text.selectedRange)
    }

    /// Call once the view is back in its window.
    func restore() {
        switch holder {
        case .label(let owner):
            guard owner.window != nil else { return }
            owner.selectText(nil)
            guard let editor = owner.currentEditor() as? NSTextView else { return }
            apply(range, to: editor)
        case .textView(let text):
            guard let window = text.window else { return }
            // Taking first responder must not scroll the reader to the selection.
            let clip = text.enclosingScrollView?.contentView
            let origin = clip?.bounds.origin
            window.makeFirstResponder(text)
            apply(range, to: text)
            if let clip, let origin, clip.bounds.origin != origin {
                clip.scroll(to: origin)
                clip.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        case .focus(let control):
            guard let window = control.window, window.firstResponder !== control else { return }
            window.makeFirstResponder(control)
        }
    }

    private func apply(_ range: NSRange, to text: NSTextView) {
        let length = (text.string as NSString).length
        guard range.upperBound <= length else { return }
        text.setSelectedRange(range)
    }
}
