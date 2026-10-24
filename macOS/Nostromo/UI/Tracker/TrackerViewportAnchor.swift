import Foundation
import CoreGraphics

/// Keeps the tracker's reading position across an update (design contract §9, PRD criterion 17).
///
/// Before the pane applies a change it captures the first row intersecting the viewport and how far
/// the viewport top is into it, plus the rows after it on screen as fallbacks. After the new layout
/// it computes the scroll position that puts the first surviving one of those rows back at the same
/// offset, so the reader's line moves by less than a point wherever the change happened (above,
/// inside or below the viewport).
///
/// A row held by `TrackerDeferral` keeps its key and place, so a held fold, move or removal never
/// loses the anchor. A moved item's `moving:<id>` row that becomes `item:<id>` on release is
/// followed through `renamed`.
///
/// Pure geometry: row frames are in the flipped document's coordinates (y grows down), the viewport
/// is the clip view's bounds.
struct TrackerViewportAnchor: Equatable {
    struct Entry: Equatable {
        var key: String
        /// Viewport top minus the row's top (≥ 0 for the first row, negative for the rows below it).
        var offset: CGFloat
    }

    /// The first visible row first, then the other visible rows in order.
    var entries: [Entry]

    var first: Entry? { entries.first }

    /// `rows` in display order with their frames; nil when no row intersects the viewport.
    static func capture(rows: [(key: String, frame: CGRect)], viewport: CGRect) -> TrackerViewportAnchor? {
        let top = viewport.minY
        let visible = rows.filter { $0.frame.maxY > top && $0.frame.minY < viewport.maxY && $0.frame.height > 0 }
        guard !visible.isEmpty else { return nil }
        return TrackerViewportAnchor(entries: visible.map { Entry(key: $0.key, offset: top - $0.frame.minY) })
    }

    /// The viewport top that restores the anchor in the new layout, clamped to the scrollable range;
    /// nil when none of the anchored rows survived in place.
    /// - Parameters:
    ///   - skipping: rows that changed their order; anchoring to one would carry the viewport along.
    ///   - shift: how far the viewport's top edge moved down on screen (the banner or the strip
    ///     appeared above it); the content scrolls by as much so the read line stays put.
    func restoredTop(frames: [String: CGRect], renamed: [String: String] = [:], skipping: Set<String> = [],
                     shift: CGFloat = 0, documentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat? {
        for entry in entries where !skipping.contains(entry.key) {
            let key = frames[entry.key] != nil ? entry.key : renamed[entry.key]
            guard let key, !skipping.contains(key), let frame = frames[key] else { continue }
            let maxTop = max(0, documentHeight - viewportHeight)
            return min(max(0, frame.minY + entry.offset + shift), maxTop)
        }
        return nil
    }
}
