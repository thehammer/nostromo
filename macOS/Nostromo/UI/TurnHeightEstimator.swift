import CoreGraphics
import NostromoKit

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
    /// `ToolGroupRowView`: a fixed 22 pt row, whatever the group holds.
    static let groupRowHeight: CGFloat      = 22
    /// `ActivityRowView.laneInset`: an expanded activity row's members sit this far in.
    static let laneInset: CGFloat           = 14
    /// `ToolResultView` collapsed: the disclosure row plus 8+8 padding.
    static let toolResultCollapsed: CGFloat = 32
    /// `ResultChipView`: a single 10 pt line.
    static let resultSummaryHeight: CGFloat = 14
    /// `ErrorBlockView`: 8+8 padding.
    static let errorChrome: CGFloat         = 16
    /// `NoteBlockView`: 4+4 padding around 11 pt text.
    static let noteChrome: CGFloat          = 8
    static let noteLineHeight: CGFloat      = 14
    /// `AskQuestionView`: header chip, question, divider, and 36 pt per option.
    static let questionChrome: CGFloat      = 46
    static let questionOptionHeight: CGFloat = 36
    /// `TerminalDeliveryBlockView` collapsed: laid out like a collapsed `ToolResultView`. Also
    /// used for a block restored expanded (`TurnInteractionState.expandedBlocks`): harmless, the
    /// measured height replaces the estimate once the row is laid out.
    static let deliveryCollapsed: CGFloat   = 32
    /// `TerminalDeliveryBlockView` as a follow notice: one muted 10 pt line, 4+4 padding.
    static let deliveryNotice: CGFloat      = 22
    /// `ChatTurnView` pins the blocks stack to 82 % of the pane width.
    static let blocksWidthFraction: CGFloat = 0.82
    /// …and the user bubble to 75 %.
    static let bubbleWidthFraction: CGFloat = 0.75
    /// Floor for any non-empty turn. A zero-height turn would collapse the
    /// document and make the scroll position meaningless.
    static let minimumTurnHeight: CGFloat   = 24
    /// Height of a `.gap` / `.historyUnavailable` marker row.
    static let markerHeight: CGFloat        = 44
    /// `WakeMarkerView`: one muted line in the user slot, a fixed height whatever it says (a Mother
    /// job notice turn). Not `markerHeight`, which is the history-gap row.
    static let wakeMarkerHeight: CGFloat    = 22
    /// The gap between the user slot and the blocks under it (`ChatTurnView.bubbleGap`).
    static let userSlotGap: CGFloat         = 8

    // MARK: - Estimation

    /// Estimated rendered height of `turn` at `width` points of pane width.
    ///
    /// `shape`: the turn's fold shape when the caller has it cached (it does not depend on
    /// width); nil plans the turn here.
    static func estimate(_ turn: ChatTurn, width: CGFloat, folds: FoldResolver = FoldResolver(),
                         shape: FoldShape? = nil) -> CGFloat {
        guard turn.marker == nil else { return markerHeight }
        let paneWidth = max(width, 1)

        var height = turnChrome

        let blockWidth = paneWidth * blocksWidthFraction - 14
        var columns = 0
        let bubbleWidth = paneWidth * bubbleWidthFraction - 24
        if turn.hasMotherNoticeOrigin {
            // A Mother job notice is one fixed-height marker in the user slot: the element's length
            // is never measured, because the marker never shows it.
            height += wakeMarkerHeight + userSlotGap
        } else if turn.hasTerminalOrigin {
            // A terminal delivery is blocks, not a bubble: its text length (up to tens of KB) is
            // collapsed away, so only the number of blocks counts. A bubble appears only for
            // attachments or text the blocks do not show.
            if let extra = turn.terminalOriginBubbleText {
                height += CGFloat(turn.imageURLs.count) * (UserBubbleView.imageSize.height + 6)
                if extra != ChatSession.imageOnlyText {
                    height += bubbleChrome
                        + wrappedHeight(characters: extra.count, width: bubbleWidth,
                                        glyphWidth: systemGlyphWidth, lineHeight: bodyLineHeight)
                }
                columns += 1
            }
            for item in turn.terminalOriginItems {
                if columns > 0 { height += blockSpacing }
                height += item.isNotice ? deliveryNotice : deliveryCollapsed
                columns += 1
            }
        } else {
            // User bubble — suppressed for confirm-card replies, but estimating it
            // anyway costs one wrong turn's worth of correction and keeps this
            // function free of `ReplView`'s rendering rules.
            if !turn.imageURLs.isEmpty {
                height += CGFloat(turn.imageURLs.count) * (UserBubbleView.imageSize.height + 6)
            }
            if turn.userInputLength > 0 {
                height += bubbleChrome
                    + wrappedHeight(characters: turn.userInputLength,
                                    width: bubbleWidth,
                                    glyphWidth: systemGlyphWidth,
                                    lineHeight: bodyLineHeight)
            }
        }

        // Estimated item by item through the same Focus layout the view renders.
        for item in (shape ?? FoldShape(turn)).items {
            if columns > 0 { height += blockSpacing }
            columns += 1
            height += estimate(item, of: turn, width: blockWidth, folds: folds)
        }
        return max(height, minimumTurnHeight)
    }

    /// One Focus item at `width` (the block column, or an activity lane).
    private static func estimate(_ item: FoldShape.Item, of turn: ChatTurn, width: CGFloat,
                                 folds: FoldResolver) -> CGFloat {
        switch item {
        case .block(let i):
            return estimate(blockAt: i, of: turn, width: width)
        case .message(let indices):
            var height: CGFloat = 0
            for (n, i) in indices.enumerated() {
                if n > 0 { height += blockSpacing }
                height += estimate(blockAt: i, of: turn, width: width)
            }
            return height
        case .group(let group):
            // A collapsed group is its row, whatever it holds. Expanded, the row plus every
            // member as it rendered before folding, plus a collapsed agent-activity row under
            // each Agent call with subagent blocks.
            var height = groupRowHeight
            guard folds.isExpanded(key: group.key, isStuck: group.isStuck) else { return height }
            for i in group.members {
                height += blockSpacing + estimate(blockAt: i, of: turn, width: width)
            }
            return height + CGFloat(group.agentRows) * (blockSpacing + toolResultCollapsed)
        case .activity(let key, let members):
            // Collapsed, the row alone: what it folds is never laid out. Expanded, the row plus
            // its lane, `laneInset` narrower.
            var height = groupRowHeight
            guard folds.isActivityExpanded(key: key) else { return height }
            let laneWidth = width - laneInset
            for member in members {
                switch member {
                case .message(let indices):
                    for i in indices { height += blockSpacing + estimate(blockAt: i, of: turn, width: laneWidth) }
                default:
                    height += blockSpacing + estimate(member, of: turn, width: laneWidth, folds: folds)
                }
            }
            return height
        }
    }

    private static func estimate(blockAt i: Int, of turn: ChatTurn, width: CGFloat) -> CGFloat {
        let block = turn.blocks[i]
        // Ask for the length only when the answer can change the height —
        // see `TurnBlock.heightDependsOnContentLength`.
        let characters = block.heightDependsOnContentLength ? turn.contentLength(ofBlockAt: i) : 0
        return estimate(block: block, characters: characters, width: width)
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
        case .note:
            return noteChrome + wrappedHeight(characters: characters,
                                              width: width - 2 * NoteBlockView.horizontalInset,
                                              glyphWidth: systemGlyphWidth,
                                              lineHeight: noteLineHeight)
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
