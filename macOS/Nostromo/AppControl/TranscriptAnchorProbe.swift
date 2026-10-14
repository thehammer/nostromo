import Foundation
import CoreGraphics

/// Where a transcript pane's viewport sits, in content terms: the first visible block, how far the
/// viewport top is into it, how far the viewport bottom is above the document bottom, and whether
/// the pane follows the tail. The scroll-safety gate (`nostromo-app transcript-anchor`, and
/// `ScrollSafetyGate` in the tests) compares two of these around an event: nothing may move
/// by more than 1 pt.
struct TranscriptAnchorSnapshot: Codable, Equatable {
    struct FirstVisible: Codable, Equatable {
        /// The turn's content key (`TurnListVirtualizer.Anchor.key`).
        var turnKey: String
        /// The block or tool group inside the turn (`TurnIsland.anchorItem`), nil when the turn
        /// is not materialized.
        var itemKey: String?
        /// Viewport top minus the top of the item (or of the turn, with no item), in points, ≥ 0.
        var offsetPt: Double

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(turnKey, forKey: .turnKey)
            try c.encode(itemKey, forKey: .itemKey)   // null, not absent
            try c.encode(offsetPt, forKey: .offsetPt)
        }
    }

    var tag: String
    var window: Int
    /// Nil for an empty transcript.
    var firstVisible: FirstVisible?
    /// Document bottom minus viewport bottom, in points; 0 when scrolled to the bottom.
    var bottomOffsetPt: Double
    var following: Bool

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tag, forKey: .tag)
        try c.encode(window, forKey: .window)
        try c.encode(firstVisible, forKey: .firstVisible)   // null, not absent
        try c.encode(bottomOffsetPt, forKey: .bottomOffsetPt)
        try c.encode(following, forKey: .following)
    }
}

/// Pure geometry behind `transcript-anchor`: no views, no layout, no state.
enum TranscriptAnchorProbe {

    /// - Parameters:
    ///   - clipBounds: the clip view's bounds (its `origin.y` is the viewport top).
    ///   - documentHeight: the larger of the document view's height and the virtualizer's.
    ///   - anchor: `TurnListVirtualizer.captureAnchor(viewportTop:item:)` at the viewport top.
    static func snapshot(tag: String, window: Int, clipBounds: CGRect, documentHeight: CGFloat,
                         anchor: TurnListVirtualizer.Anchor?, following: Bool) -> TranscriptAnchorSnapshot {
        let first = anchor.map { a -> TranscriptAnchorSnapshot.FirstVisible in
            let offset = a.itemKey == nil ? a.offsetWithinTurn : a.offsetInItem
            return .init(turnKey: a.key, itemKey: a.itemKey, offsetPt: Double(max(0, offset)))
        }
        return TranscriptAnchorSnapshot(tag: tag, window: window, firstVisible: first,
                                        bottomOffsetPt: Double(max(0, documentHeight - clipBounds.maxY)),
                                        following: following)
    }
}
