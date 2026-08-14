import CoreGraphics

/// Estimates how tall a turn will render, from arithmetic alone.
///
/// Deliberately touches no `NSView`, no CoreText, and no Auto Layout. The
/// transcript needs a height for every turn in the session — five thousand of
/// them — to know where the scrollbar sits and which turns intersect the
/// viewport, and it needs them again on every window resize. Measuring that
/// honestly would mean building five thousand view subtrees, which is the
/// problem this whole change exists to remove.
///
/// So estimates are cheap and approximate, and the virtualizer corrects each one
/// to the real measured height the moment its turn materializes (and keeps the
/// scroll anchor pinned while it does). Estimates only have to be close enough
/// that the scrollbar is believable and the correction is small.
enum TurnHeightEstimator {

    // MARK: - Calibration
    //
    // Constants below are derived from the block views in `ReplView.swift`:
    // fonts, padding, stack spacing, and fixed row heights. Where a view's
    // height is fixed by a constraint the number is exact; where it wraps text
    // the average-glyph-width figure is what makes it an estimate.
    //
    // Three of them — `blockSpacing`, `blocksWidthFraction`, `bubbleWidthFraction`
    // — are the *same* number as a constraint in `ChatTurnView`, and that view now
    // reads them from here rather than repeating the literal, so the two cannot
    // drift apart. The rest cannot be consolidated the same way: each is a **sum**
    // of several separate constraint constants (top padding plus bottom padding
    // plus an inter-view gap), and giving them a single home means restructuring
    // those views. Until that happens the prose above each constant naming its
    // origin is the link, and a change to a block view means checking here.

    /// Average advance width as a fraction of point size, for the system font at
    /// 13 pt over English prose. Used to turn a character count into a line count.
    static let systemGlyphWidth: CGFloat = 6.6
    /// Same, for the monospaced font used by tool output.
    static let monoGlyphWidth: CGFloat = 6.0

    static let bodyLineHeight: CGFloat      = 16
    static let monoLineHeight: CGFloat      = 14
    /// `ChatTurnView`: 12 pt above the bubble, 14 pt below the blocks stack.
    static let turnChrome: CGFloat          = 26
    /// `blocksStack.spacing`.
    static let blockSpacing: CGFloat        = 6
    /// `UserBubbleView`: 8 pt top + 8 pt bottom padding, plus the 8 pt gap to
    /// the blocks stack.
    static let bubbleChrome: CGFloat        = 24
    /// `MarkdownCardView`: 12 pt padding on all sides.
    static let cardChrome: CGFloat          = 24
    /// `ToolCallView`: one 7+7-padded row of 11 pt text.
    static let toolCallHeight: CGFloat      = 30
    /// `ToolResultView` collapsed: the disclosure row plus 8+8 padding.
    static let toolResultCollapsed: CGFloat = 32
    /// `ResultChipView`: a single 10 pt line.
    static let resultSummaryHeight: CGFloat = 14
    /// `ErrorBlockView`: 8+8 padding.
    static let errorChrome: CGFloat         = 16
    /// `AskQuestionView`: header chip, question, divider, and 36 pt per option.
    static let questionChrome: CGFloat      = 46
    static let questionOptionHeight: CGFloat = 36
    /// `ChatTurnView` pins the blocks stack to 82 % of the pane width.
    static let blocksWidthFraction: CGFloat = 0.82
    /// …and the user bubble to 75 %.
    static let bubbleWidthFraction: CGFloat = 0.75
    /// Floor for any non-empty turn. A zero-height turn would collapse the
    /// document and make the scroll position meaningless.
    static let minimumTurnHeight: CGFloat   = 24
    /// Height of a `.gap` / `.historyUnavailable` marker row.
    static let markerHeight: CGFloat        = 44

    // MARK: - Estimation

    /// Estimated rendered height of `turn` at `width` points of pane width.
    static func estimate(_ turn: ChatTurn, width: CGFloat) -> CGFloat {
        guard turn.marker == nil else { return markerHeight }
        let paneWidth = max(width, 1)

        var height = turnChrome

        // User bubble — suppressed for confirm-card replies, but estimating it
        // anyway costs one wrong turn's worth of correction and keeps this
        // function free of `ReplView`'s rendering rules.
        let bubbleWidth = paneWidth * bubbleWidthFraction - 24
        if turn.userInputLength > 0 {
            height += bubbleChrome
                + wrappedHeight(characters: turn.userInputLength,
                                width: bubbleWidth,
                                glyphWidth: systemGlyphWidth,
                                lineHeight: bodyLineHeight)
        }

        let blockWidth = paneWidth * blocksWidthFraction - 14
        for (i, block) in turn.blocks.enumerated() {
            // Ask for the length only when the answer can change the height —
            // see `TurnBlock.heightDependsOnContentLength`.
            let characters = block.heightDependsOnContentLength
                ? turn.contentLength(ofBlockAt: i) : 0
            height += estimate(block: block, characters: characters, width: blockWidth)
            if i > 0 { height += blockSpacing }
        }

        return max(height, minimumTurnHeight)
    }

    static func estimate(block: TurnBlock, characters: Int, width: CGFloat) -> CGFloat {
        switch block {
        case .text:
            // Markdown text routes to one card per `---`-separated segment; the
            // single-card case is the overwhelming majority and the difference
            // is one chrome's worth per extra segment.
            return cardChrome + wrappedHeight(characters: characters,
                                              width: width - cardChrome,
                                              glyphWidth: systemGlyphWidth,
                                              lineHeight: bodyLineHeight)
        case .toolCall:
            return toolCallHeight

        case .toolResult(let d):
            // Non-error results stay collapsed and cost one disclosure row
            // regardless of how large the payload is. Errors open by default.
            guard d.isError else { return toolResultCollapsed }
            return toolResultCollapsed + wrappedHeight(characters: characters,
                                                       width: width,
                                                       glyphWidth: monoGlyphWidth,
                                                       lineHeight: monoLineHeight)
        case .resultSummary:
            return resultSummaryHeight

        case .errorMessage:
            return errorChrome + wrappedHeight(characters: characters,
                                               width: width - 20,
                                               glyphWidth: monoGlyphWidth,
                                               lineHeight: monoLineHeight)
        case .askQuestion(let d):
            return questionChrome
                + CGFloat(d.options.count) * questionOptionHeight
                + wrappedHeight(characters: d.question.count,
                                width: width - 28,
                                glyphWidth: systemGlyphWidth,
                                lineHeight: bodyLineHeight)
        }
    }

    /// Height of `characters` characters of text wrapped to `width` points.
    static func wrappedHeight(characters: Int, width: CGFloat,
                              glyphWidth: CGFloat, lineHeight: CGFloat) -> CGFloat {
        guard characters > 0 else { return 0 }
        let charsPerLine = max(1.0, (max(width, 1) / glyphWidth).rounded(.down))
        let lines = max(1.0, (CGFloat(characters) / charsPerLine).rounded(.up))
        return lines * lineHeight
    }
}
