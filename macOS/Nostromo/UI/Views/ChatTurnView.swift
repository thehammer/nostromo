import AppKit

// Turn and block views for the transcript, moved out of `ReplView.swift` so
// they can be compiled into the logic test bundle — the same move
// `ToolResultView.swift` and `AskQuestionView.swift` already made, and for the
// same reason. `ReplView` itself pulls in `ChatSession`, `AppStore` and the
// whole daemon client stack, so nothing declared inside it was reachable from a
// test. The constraint-count and height-parity tests in
// `ChatTurnViewLayoutTests` are the point of the move.

// MARK: - TurnIsland

/// A turn view that owns exactly one constraint of its own — its width — so it
/// can be measured with `fittingSize` before it is inserted anywhere, and can be
/// re-widened on a pane resize without ever being constrained to its container.
protocol TurnIsland: NSView {
    func setIslandWidth(_ width: CGFloat)
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
}

// MARK: - ChatTurnView

class ChatTurnView: NSView, TurnIsland {

    private let blocksStack   = NSStackView()
    private var renderedCount = 0
    private var widthConstraint: NSLayoutConstraint!
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

    func setIslandWidth(_ width: CGFloat) { widthConstraint.constant = width }

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
        widthConstraint = widthAnchor.constraint(equalToConstant: 400)
        widthConstraint.isActive = true

        // Blocks container — AI response, left-aligned at 82% width.
        //
        // The width fractions and the stack spacing here are read back by
        // `TurnHeightEstimator`, which has to reproduce this layout arithmetically
        // to estimate a turn's height before it is built. They are referenced from
        // there rather than repeated, so a change to the layout cannot silently
        // desynchronise the estimator. The remaining calibration constants in that
        // file are *sums* of several constraint constants below (chrome, padding);
        // folding those together needs a real refactor of these views and is
        // deliberately not part of this change.
        blocksStack.orientation = .vertical
        blocksStack.spacing     = TurnHeightEstimator.blockSpacing
        blocksStack.alignment   = .width
        blocksStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(blocksStack)

        // Suppress the bubble when the reply was injected by the confirm card — the
        // card's own chosen-state visuals already acknowledge the selection.
        let suppressBubble = turn.userInput.contains(Self.confirmReplySentinel)

        if suppressBubble {
            // Pin blocksStack directly to the top so there is no gap where the bubble
            // would have been.
            NSLayoutConstraint.activate([
                blocksStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                blocksStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                blocksStack.widthAnchor.constraint(equalTo: widthAnchor,
                                                   multiplier: TurnHeightEstimator.blocksWidthFraction,
                                                   constant: -14),
                blocksStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            ])
        } else {
            // User bubble — trailing-pinned, width driven by intrinsicContentSize capped at 75%.
            // No spacer/NSStackView needed: trailing anchor right-aligns it, intrinsicContentSize
            // gives AutoLayout the natural width, and the ≤ constraint caps long messages.
            let bubble = UserBubbleView(text: turn.userInput)
            bubble.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bubble)

            NSLayoutConstraint.activate([
                bubble.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                bubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                // Fixed 75 % width so AutoLayout never needs intrinsicContentSize — the
                // unconstrained single-line NSTextField width overflowed the right edge.
                bubble.widthAnchor.constraint(equalTo: widthAnchor,
                                              multiplier: TurnHeightEstimator.bubbleWidthFraction),

                blocksStack.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 8),
                blocksStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                blocksStack.widthAnchor.constraint(equalTo: widthAnchor,
                                                   multiplier: TurnHeightEstimator.blocksWidthFraction,
                                                   constant: -14),
                blocksStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            ])
        }

        // Every block of an unrecoverable turn is truncated — the user bubble
        // and the assistant's text as much as its tool results — so an answer
        // would otherwise stop mid-sentence with nothing to explain it. One
        // banner at the top of the turn covers all of them; the tool-result
        // disclosure adds its own line because that content is separately
        // expandable.
        if !contentAvailable {
            blocksStack.addArrangedSubview(Self.makeTruncationBanner())
        }
        renderNewBlocks(turn.blocks)
    }

    private static func makeTruncationBanner() -> NSView {
        let label = NSTextField(labelWithString:
            "⚠︎  Only the beginning of this turn is still held in this pane. "
            + "The full text remains in the Claude session transcript on disk.")
        label.font                 = .systemFont(ofSize: 10)
        label.textColor            = Theme.amber
        label.lineBreakMode        = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Called as the turn's blocks array grows during live streaming.
    func update(turn: ChatTurn) {
        let newBlocks = Array(turn.blocks.dropFirst(renderedCount))
        renderNewBlocks(newBlocks)
    }

    private func renderNewBlocks(_ blocks: [TurnBlock]) {
        for block in blocks {
            // `renderedCount` is already the index of the block being added, and
            // it keeps counting across streaming `update(turn:)` calls — so it is
            // the block index, and a second counter would only be a second thing
            // to get out of step with it.
            let v = makeBlockView(block, at: renderedCount)
            v.translatesAutoresizingMaskIntoConstraints = false
            blocksStack.addArrangedSubview(v)
            // Explicitly match width — NSStackView alignment=.width doesn't reliably
            // propagate width to custom views with no intrinsic size (e.g. TextBlockView)
            v.widthAnchor.constraint(equalTo: blocksStack.widthAnchor).isActive = true
            renderedCount += 1
        }
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
}

// MARK: - UserBubbleView

/// Right-floating chat bubble for user messages.
/// Overrides intrinsicContentSize so NSStackView (bubbleRow) can determine height.
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
/// Uses explicit leading/trailing constraints (not NSStackView alignment) so
/// MarkdownTableView — which has no intrinsic content size — fills the full width.
class TextBlockView: NSView {

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
