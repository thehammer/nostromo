import Foundation
import CoreGraphics
import NostromoKit

/// What `nostromo-app tracker-anchor` reports for a tracker pane: its first visible row and the
/// offset of the viewport top into it, the scroll position, and the changes held back.
struct TrackerAnchorSnapshot: Codable, Equatable {
    struct FirstVisible: Codable, Equatable {
        var rowKey: String
        var offsetPt: Double
    }

    struct Pending: Codable, Equatable {
        var key: String
        /// `done_in_place`, `moved`, `removed` or `selection`.
        var kind: String
    }

    var tag: String
    var window: Int
    /// Nil for an empty pane.
    var firstVisible: FirstVisible?
    /// The viewport top in the document, in points.
    var scrollY: Double
    var documentHeight: Double
    var viewportHeight: Double
    /// True when a deferred fold, move or removal is waiting for its row to leave the viewport.
    var deferredPending: Bool
    var pending: [Pending]

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tag, forKey: .tag)
        try c.encode(window, forKey: .window)
        try c.encode(firstVisible, forKey: .firstVisible)   // null, not absent
        try c.encode(scrollY, forKey: .scrollY)
        try c.encode(documentHeight, forKey: .documentHeight)
        try c.encode(viewportHeight, forKey: .viewportHeight)
        try c.encode(deferredPending, forKey: .deferredPending)
        try c.encode(pending, forKey: .pending)
    }
}

/// Pure geometry behind `tracker-anchor`: no views, no layout, no state. Read-only by construction.
enum TrackerAnchorProbe {

    /// - Parameters:
    ///   - clipBounds: the clip view's bounds (its `origin.y` is the viewport top; the document is flipped).
    ///   - rows: the pane's row views in display order with their frames in the document.
    ///   - held: the changes `TrackerDeferral` is holding back.
    static func snapshot(tag: String, window: Int, clipBounds: CGRect, documentHeight: CGFloat,
                         rows: [(key: String, frame: CGRect)], held: [TrackerHold]) -> TrackerAnchorSnapshot {
        let anchor = TrackerViewportAnchor.capture(rows: rows, viewport: clipBounds)
        let first = anchor?.first.map {
            TrackerAnchorSnapshot.FirstVisible(rowKey: $0.key, offsetPt: Double(max(0, $0.offset)))
        }
        let pending = held.map { TrackerAnchorSnapshot.Pending(key: $0.key, kind: $0.kind.rawValue) }
        return TrackerAnchorSnapshot(
            tag: tag, window: window, firstVisible: first,
            scrollY: Double(clipBounds.minY),
            documentHeight: Double(documentHeight),
            viewportHeight: Double(clipBounds.height),
            deferredPending: held.contains { $0.kind != .selection },
            pending: pending)
    }
}
