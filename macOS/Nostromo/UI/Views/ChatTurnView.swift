import AppKit

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
        }

        let label = NSTextField(labelWithString: text)
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
class ChatTurnView: NSView, TurnIsland {

    // MARK: Geometry — each of these was a constraint constant

    /// Gap above the bubble (or above the first block when it is suppressed).
    private static let topPadding: CGFloat = 12
    /// Gap below the last block.
    private static let bottomPadding: CGFloat = 14
    /// Gap between the bubble and the first block.
    private static let bubbleGap: CGFloat = 8
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
    private var bubbleHeight: CGFloat = 0

    /// The frame-positioned column under the bubble: the truncation banner when
    /// there is one, then one view per rendered block. Parallel to
    /// `columnHeights`.
    private var columnViews: [NSView] = []
    private var columnHeights: [CGFloat] = []
    /// Width constraint of each column view, so a pane resize can re-widen them
    /// without rebuilding. Parallel to `columnViews`.
    private var columnWidthConstraints: [NSLayoutConstraint] = []
    private var bubbleWidthConstraint: NSLayoutConstraint?
    /// Index into `columnViews` of the first *block* — 1 when a truncation
    /// banner is present, 0 otherwise. Block index `i` is `columnViews[blockOffset + i]`.
    private var blockOffset = 0
    private var renderedCount = 0

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

    /// Everything the operator has already done to this turn, restored into the
    /// block views as they are built.
    private let interaction: TurnInteractionState

    /// Reply text injected by the confirm card — suppress its bubble so the card
    /// itself serves as the only visible acknowledgement of the user's choice.
    private static let confirmReplySentinel = "(This answers your question:"

    /// Called when the user answers an in-turn `AskUserQuestion` card.
    /// Wired by `ReplView` to `session.send(_:)`.
    var onSend: ((String) -> Void)?

    init(turn: ChatTurn, contentAvailable: Bool, interaction: TurnInteractionState) {
        self.contentAvailable = contentAvailable
        self.interaction      = interaction
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
        // card's own chosen-state visuals already acknowledge the selection.
        if !turn.userInput.contains(Self.confirmReplySentinel) {
            let bubble = UserBubbleView(text: turn.userInput)
            self.bubble = bubble
            bubbleWidthConstraint = attachIsland(bubble,
                                                 width: Self.bubbleWidth(paneWidth: islandWidth))
        }

        // Every block of an unrecoverable turn is truncated — the user bubble
        // and the assistant's text as much as its tool results — so an answer
        // would otherwise stop mid-sentence with nothing to explain it. One
        // banner at the top of the turn covers all of them; the tool-result
        // disclosure adds its own line because that content is separately
        // expandable.
        if !contentAvailable {
            appendColumnView(Self.makeTruncationBanner())
            blockOffset = 1
        }
        renderNewBlocks(turn.blocks)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func makeTruncationBanner() -> NSView {
        let label = NSTextField(labelWithString:
            "⚠︎  Only the beginning of this turn is still held in this pane. "
            + "The full text remains in the Claude session transcript on disk.")
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
    /// Renders — and measures — only the blocks that are new. Everything already
    /// rendered keeps its cached height, which is sound precisely because each
    /// block is an island at a fixed width: appending one cannot move an
    /// earlier one.
    func update(turn: ChatTurn) {
        let newBlocks = Array(turn.blocks.dropFirst(renderedCount))
        guard !newBlocks.isEmpty else { return }
        renderNewBlocks(newBlocks)
    }

    private func renderNewBlocks(_ blocks: [TurnBlock]) {
        for block in blocks {
            // `renderedCount` is already the index of the block being added, and
            // it keeps counting across streaming `update(turn:)` calls — so it is
            // the block index, and a second counter would only be a second thing
            // to get out of step with it.
            appendColumnView(makeBlockView(block, at: renderedCount))
            renderedCount += 1
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func makeBlockView(_ block: TurnBlock, at index: Int) -> NSView {
        switch block {
        case .text(let t):           return TextBlockView(text: t)
        case .toolCall(let d):       return ToolCallView(data: d)
        case .toolResult(let d):
            let v = ToolResultView(data: d, contentAvailable: contentAvailable,
                                   startExpanded: interaction.expandedBlocks.contains(index))
            v.onExpansionChange = { [weak self] isExpanded in
                guard let self else { return }
                self.onBlockExpansion?(index, isExpanded)
                // Only this block's height changed. Re-measuring the one island
                // and re-summing is what keeps an expand O(1) in turn size — and
                // what stops the cached total drifting from what is on screen.
                self.remeasureColumnView(at: self.blockOffset + index)
                self.onIntrinsicHeightChange?()
            }
            return v
        case .resultSummary(let d):  return ResultChipView(data: d)
        case .errorMessage(let m):   return ErrorBlockView(message: m)
        case .askQuestion(let d):
            let v = AskQuestionView(data: d,
                                    answeredOptionIndex: interaction.answeredOptions[index])
            v.onAnswer = { [weak self] answer, optionIndex in
                guard let self else { return }
                // Record before sending. If the send path ever tears this view
                // down, the answer is already outside it.
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
    private func appendColumnView(_ view: NSView) {
        let width = Self.blockWidth(paneWidth: islandWidth)
        columnWidthConstraints.append(attachIsland(view, width: width))
        columnViews.append(view)
        columnHeights.append(needsFullRemeasure ? 0 : Self.measureIsland(view, width: width))
    }

    /// Give `view` its single width constraint — the only constraint it will
    /// ever hold that is visible from outside itself — and attach it.
    ///
    /// `translatesAutoresizingMaskIntoConstraints = true` is what makes the
    /// frame stick once it is attached. It is also why `measureIsland` has to
    /// detach first; see there.
    @discardableResult
    private func attachIsland(_ view: NSView, width: CGFloat) -> NSLayoutConstraint {
        view.translatesAutoresizingMaskIntoConstraints = true
        let constraint = view.widthAnchor.constraint(equalToConstant: width)
        constraint.isActive = true
        addSubview(view)
        return constraint
    }

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
        let superview = view.superview
        superview.map { _ in view.removeFromSuperview() }

        (view as? WidthPresettable)?.presetLayoutWidth(width)
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height
        view.setFrameSize(NSSize(width: width, height: height))

        superview?.addSubview(view)
        return height
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

        if let bubble {
            let width = Self.bubbleWidth(paneWidth: islandWidth)
            bubbleWidthConstraint?.constant = width
            bubbleHeight = Self.measureIsland(bubble, width: width)
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
        if bubble != nil { height += bubbleHeight + Self.bubbleGap }
        for (i, blockHeight) in columnHeights.enumerated() {
            if i > 0 { height += TurnHeightEstimator.blockSpacing }
            height += blockHeight
        }
        return height + Self.bottomPadding
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    /// Arithmetic over cached block heights — no solve, no matter how many
    /// blocks the turn holds. This is what makes a streaming re-measure cost
    /// the new blocks and nothing else.
    func islandHeight() -> CGFloat {
        remeasureIfNeeded()
        return contentHeight
    }

    override func layout() {
        super.layout()
        remeasureIfNeeded()

        var y = Self.topPadding
        if let bubble {
            let width = Self.bubbleWidth(paneWidth: islandWidth)
            place(bubble, alignmentRect:
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

    private let label: NSTextField

    init(text: String) {
        label = NSTextField(labelWithString: text)
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

        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
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

    init(text: String) {
        super.init(frame: .zero)

        // Route to markdown cards if text has markdown content and no pipe table.
        // (Pipe tables use the existing MarkdownTableView path.)
        if !Self.hasPipeTable(text) && Self.hasMarkdown(text) {
            let segments = Self.markdownSegments(from: text)
            var prevAnchor: NSLayoutYAxisAnchor = topAnchor
            for (i, segment) in segments.enumerated() {
                let card = MarkdownCardView(markdown: segment)
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
                let label = NSTextField(labelWithString: Self.stripMarkdown(txt))
                label.font                 = .systemFont(ofSize: 13)
                label.textColor            = Theme.fg
                label.lineBreakMode        = .byWordWrapping
                label.maximumNumberOfLines = 0
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                view = label
            case .table(let headers, let rows):
                view = MarkdownTableView(headers: headers, rows: rows)
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
        let lines = s.components(separatedBy: "\n")
        let lineMarker = lines.contains { line in
            line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ")
                || line.hasPrefix("- ") || line.hasPrefix("* ")
                || line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
        }
        return lineMarker || s.contains("`") || s.contains("**") || s.contains("\n---")
    }

    /// Splits text on bare `---` separator lines into one or more markdown segments.
    private static func markdownSegments(from text: String) -> [String] {
        var segments: [String] = []
        var current: [String]  = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                let seg = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !seg.isEmpty { segments.append(seg) }
                current = []
            } else {
                current.append(line)
            }
        }
        let tail = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { segments.append(tail) }
        return segments
    }

    /// Returns true when the text contains a markdown pipe table (takes the existing path).
    private static func hasPipeTable(_ s: String) -> Bool {
        let lines = s.components(separatedBy: "\n")
        guard let headerIdx = lines.firstIndex(where: { $0.hasPrefix("|") }) else { return false }
        let nextIdx = lines.index(after: headerIdx)
        guard nextIdx < lines.endIndex else { return false }
        return lines[nextIdx].contains("|") && lines[nextIdx].contains("-")
    }

    // MARK: Segment model & parser

    private enum Segment {
        case paragraph(String)
        case table(headers: [String], rows: [[String]])
    }

    private static func parseSegments(_ text: String) -> [Segment] {
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

// MARK: - ToolCallView

class ToolCallView: NSView {

    init(data: ToolCallData) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
        layer?.cornerRadius    = 6

        let iconLabel = NSTextField(labelWithString: icon(for: data.toolName))
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

        let summaryLabel = NSTextField(labelWithString: data.inputSummary)
        // Literal command text (flags like `--stat`, `->` in scripts, etc.) — disable
        // Fira Code's default ligatures so it renders verbatim. See ToolResultView's
        // buildLabelIfNeeded() for the full explanation of this default-on behavior.
        summaryLabel.attributedStringValue = NSAttributedString(string: data.inputSummary, attributes: [
            .font:            Theme.monoFont,
            .foregroundColor: Theme.fg,
            .ligature:        0,
        ])
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

    private func icon(for name: String) -> String {
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

        let symbol = data.isError ? "✗" : "✓"
        let color  = data.isError ? Theme.redSweater : Theme.sage

        let durationStr = data.durationMs >= 1000
            ? String(format: "%.1fs", Double(data.durationMs) / 1000)
            : "\(data.durationMs)ms"
        let costStr = data.costUSD > 0
            ? String(format: " · $%.4f", data.costUSD)
            : ""
        let labelStr = "\(symbol)  \(durationStr)\(costStr)"

        let label = NSTextField(labelWithString: labelStr)
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

        let label = NSTextField(labelWithString: message)
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
