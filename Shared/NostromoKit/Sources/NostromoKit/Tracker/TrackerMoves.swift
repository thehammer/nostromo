// NostromoKit — TrackerMoves.swift
//
// Where an item goes when the user moves it (a drag, the Move menu, VoiceOver) and where it goes
// back to on undo. Pure: it reads the rows the pane shows and answers with the `move` op's place.
// "Neighbours" are the open items the view shows (every shown item under the Done filter): never a
// stub, a `moving:` copy, a folded or expanded done item.

import Foundation

/// A place in a section: after `after`, before `before`, or (neither) the end of its open items.
public struct TrackerMoveDestination: Equatable {
    public let section: String
    public let before: String?
    public let after: String?

    public init(section: String, before: String? = nil, after: String? = nil) {
        self.section = section
        self.before = before
        self.after = after
    }

    public func moveOp(_ id: String) -> TrackerPaneOpWire {
        .move(id: id, section: section, before: before, after: after)
    }

    public func restoreOp(source: String) -> TrackerPaneOpWire {
        .restore(source: source, section: section, before: before, after: after)
    }
}

/// Where an item was: its section and the open items on either side of it then. An undo does not replay
/// a place fixed in the past: the neighbours may have moved or gone, so the place is worked out again
/// against the board as it is when the undo runs (`TrackerMoves.place`).
public struct TrackerPlaceHint: Equatable {
    public let section: String
    public let above: String?
    public let below: String?

    public init(section: String, above: String? = nil, below: String? = nil) {
        self.section = section
        self.above = above
        self.below = below
    }

    /// A place that was a move's target: after `after`, before `before`.
    public init(_ destination: TrackerMoveDestination) {
        self.init(section: destination.section, above: destination.after, below: destination.before)
    }
}

/// Where a drop would land and where the pane draws the drop indicator.
public struct TrackerDrop: Equatable {
    public enum Indicator: Equatable {
        /// The line sits on the top edge of this row.
        case above(rowKey: String)
        /// The line sits on the bottom edge of this row.
        case below(rowKey: String)
    }

    public let destination: TrackerMoveDestination
    public let indicator: Indicator
}

public enum TrackerMoves {

    /// One section as the view shows it: its heading and the ids of its movable items, top to bottom.
    struct Group {
        let sectionId: String
        let sectionTitle: String
        var ids: [String]
    }

    static func groups(_ rows: [TrackerRow], filter: TrackerFilter) -> [Group] {
        var groups: [Group] = []
        for row in rows {
            switch row.content {
            case .section(let section):
                groups.append(Group(sectionId: section.id, sectionTitle: section.title, ids: []))
            case .item(let item) where row.key == TrackerRow.itemKey(item.id) && (filter == .done || !item.isDone):
                if !groups.isEmpty { groups[groups.count - 1].ids.append(item.id) }
            default:
                break
            }
        }
        return groups
    }

    private static func position(of id: String, in groups: [Group]) -> (group: Int, index: Int)? {
        for (g, group) in groups.enumerated() {
            if let i = group.ids.firstIndex(of: id) { return (g, i) }
        }
        return nil
    }

    /// Before the item above (nil when it is first).
    public static func up(_ id: String, rows: [TrackerRow], filter: TrackerFilter) -> TrackerMoveDestination? {
        let groups = groups(rows, filter: filter)
        guard let (g, i) = position(of: id, in: groups), i > 0 else { return nil }
        return TrackerMoveDestination(section: groups[g].sectionId, before: groups[g].ids[i - 1])
    }

    /// After the item below (nil when it is last).
    public static func down(_ id: String, rows: [TrackerRow], filter: TrackerFilter) -> TrackerMoveDestination? {
        let groups = groups(rows, filter: filter)
        guard let (g, i) = position(of: id, in: groups), i < groups[g].ids.count - 1 else { return nil }
        return TrackerMoveDestination(section: groups[g].sectionId, after: groups[g].ids[i + 1])
    }

    /// The end of another section's open items.
    public static func toSection(_ sectionId: String) -> TrackerMoveDestination {
        TrackerMoveDestination(section: sectionId)
    }

    /// The sections an item can be moved to: every other section the view shows.
    public static func otherSections(of id: String, rows: [TrackerRow], filter: TrackerFilter) -> [(id: String, title: String)] {
        let groups = groups(rows, filter: filter)
        let own = position(of: id, in: groups).map { groups[$0.group].sectionId }
        return groups.filter { $0.sectionId != own }.map { ($0.sectionId, $0.sectionTitle) }
    }

    /// Where the item is now, as a place to move (or restore) it back to: after the item above it,
    /// else before the item below, else its section's end. `fallbackSection` is for an item the view
    /// does not list (a done item).
    public static func origin(of id: String, rows: [TrackerRow], filter: TrackerFilter,
                              fallbackSection: String) -> TrackerMoveDestination {
        let groups = groups(rows, filter: filter)
        guard let (g, i) = position(of: id, in: groups) else { return TrackerMoveDestination(section: fallbackSection) }
        let group = groups[g]
        if i > 0 { return TrackerMoveDestination(section: group.sectionId, after: group.ids[i - 1]) }
        if group.ids.count > 1 { return TrackerMoveDestination(section: group.sectionId, before: group.ids[1]) }
        return TrackerMoveDestination(section: group.sectionId)
    }

    /// Both neighbours of the item now (for an item the view does not list: just the section).
    public static func hint(of id: String, rows: [TrackerRow], filter: TrackerFilter,
                            fallbackSection: String) -> TrackerPlaceHint {
        let groups = groups(rows, filter: filter)
        guard let (g, i) = position(of: id, in: groups) else { return TrackerPlaceHint(section: fallbackSection) }
        let ids = groups[g].ids
        return TrackerPlaceHint(section: groups[g].sectionId, above: i > 0 ? ids[i - 1] : nil,
                                below: i + 1 < ids.count ? ids[i + 1] : nil)
    }

    /// The place `hint` means on the board as it is now: after the item that was above (when it is still in
    /// the section), else before the one that was below, else the end of the section's open items.
    /// `isInSection` says whether the daemon's newest board still has an item in a section (a row the view
    /// holds back may already be gone from it).
    public static func place(_ hint: TrackerPlaceHint, rows: [TrackerRow], filter: TrackerFilter,
                             isInSection: (_ id: String, _ section: String) -> Bool = { _, _ in true }) -> TrackerMoveDestination {
        let shown = groups(rows, filter: filter).first { $0.sectionId == hint.section }?.ids ?? []
        func usable(_ id: String?) -> String? {
            guard let id, shown.contains(id), isInSection(id, hint.section) else { return nil }
            return id
        }
        if let above = usable(hint.above) { return TrackerMoveDestination(section: hint.section, after: above) }
        if let below = usable(hint.below) { return TrackerMoveDestination(section: hint.section, before: below) }
        return TrackerMoveDestination(section: hint.section)
    }

    /// The last open item the view shows in the section (what a new item goes after).
    public static func lastItem(in sectionId: String, rows: [TrackerRow], filter: TrackerFilter) -> String? {
        groups(rows, filter: filter).first { $0.sectionId == sectionId }?.ids.last
    }

    /// Dropping item `id` on the row with key `key`; `lowerHalf` says which half of that row the pointer is
    /// in. Nil when nothing would change or the row is not a place to drop (the Done group, prose, the Log,
    /// a stub, the item itself).
    public static func drop(_ id: String, over key: String, lowerHalf: Bool,
                            rows: [TrackerRow], filter: TrackerFilter) -> TrackerDrop? {
        guard let row = rows.first(where: { $0.key == key }) else { return nil }
        let groups = groups(rows, filter: filter)
        switch row.content {
        case .item(let item) where key == TrackerRow.itemKey(item.id):
            guard item.id != id, let (g, i) = position(of: item.id, in: groups) else { return nil }
            let ids = groups[g].ids
            let section = groups[g].sectionId
            if lowerHalf {
                if i + 1 < ids.count, ids[i + 1] == id { return nil }
                return TrackerDrop(destination: TrackerMoveDestination(section: section, after: item.id),
                                   indicator: .below(rowKey: key))
            }
            if i > 0, ids[i - 1] == id { return nil }
            let destination = i > 0 ? TrackerMoveDestination(section: section, after: ids[i - 1])
                                    : TrackerMoveDestination(section: section, before: item.id)
            return TrackerDrop(destination: destination, indicator: .above(rowKey: key))
        case .section(let section):
            return endOfSection(section.id, moving: id, rows: rows, groups: groups)
        case .addItem(let add):
            return endOfSection(add.sectionId, moving: id, rows: rows, groups: groups)
        default:
            return nil
        }
    }

    /// The end of a section's open items: the line goes above its add row, else under its last item (or heading).
    private static func endOfSection(_ sectionId: String, moving id: String, rows: [TrackerRow], groups: [Group]) -> TrackerDrop? {
        guard let group = groups.first(where: { $0.sectionId == sectionId }) else { return nil }
        if group.ids.last == id { return nil }
        let indicator: TrackerDrop.Indicator
        if rows.contains(where: { $0.key == TrackerRow.addKey(sectionId) }) {
            indicator = .above(rowKey: TrackerRow.addKey(sectionId))
        } else if let last = group.ids.last {
            indicator = .below(rowKey: TrackerRow.itemKey(last))
        } else {
            indicator = .below(rowKey: TrackerRow.sectionKey(sectionId))
        }
        return TrackerDrop(destination: TrackerMoveDestination(section: sectionId), indicator: indicator)
    }
}
