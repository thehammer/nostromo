// NostromoKit — TrackerDeferral.swift
//
// The deferred fold / move / remove rule (design contract §9, PRD "Scroll, layout and focus
// safety"): text never vanishes from under the reader.
//
// - An item the user can see that becomes `done` stays where it is, struck through, and folds
//   into its section's "Done (N)" only once it has left the viewport, the pane is reopened, or the
//   user clicks that Done group.
// - An item the user can see that the agent moves to another section appears in its new section
//   at once (under a temporary `moving:<id>` key) while a muted "moved to <Section>" stub keeps
//   its old key and place until that place leaves the viewport.
// - An item the user can see that is removed leaves a muted "removed" stub in its place until it
//   leaves the viewport.
// - A row holding a text selection keeps its content until the selection is cleared.
//
// Pure and stateless between calls apart from one-shot release requests: every `resolve` works
// out what has to be held from what is on screen now (`displayed`), what the board says
// (`target`), which rows intersect the viewport and which row holds the selection. A hold whose
// row is off screen is simply not renewed, so the display converges on the target.

import Foundation

public struct TrackerHold: Equatable {
    public enum Kind: String, Equatable {
        case doneInPlace = "done_in_place"
        case moved
        case removed
        case selection
    }

    /// The key the held row keeps on screen.
    public let key: String
    public let kind: Kind
    /// What is shown in its place: the struck-through done item, a stub, or (for a selection) the
    /// row as it was.
    public let row: TrackerRow
}

public struct TrackerDeferralResult: Equatable {
    /// What the pane shows now, top to bottom.
    public let rows: [TrackerRow]
    /// The operations that take the previously displayed rows to `rows`.
    public let applyNow: [TrackerDiffOp]
    /// Changes held back, in display order.
    public let held: [TrackerHold]
    /// The rows standing in for a held fold, move or removal.
    public let stubs: [TrackerRow]
    /// Display keys that changed name with no change of place for the reader, old → new: a moved
    /// item's `moving:<id>` row becomes `item:<id>` once its stub is released. The viewport
    /// anchor follows the rename.
    public let renamed: [String: String]
}

public struct TrackerDeferral {
    /// The key prefix of a moved item's row in its new section while its stub holds the old place.
    public static let movingPrefix = "moving:"

    /// The holds of the last `resolve`.
    public private(set) var held: [TrackerHold] = []
    private var releaseEverything = false
    private var releasedSections: Set<String> = []

    public init() {}

    public var hasHeld: Bool { !held.isEmpty }

    /// The pane was reopened (or the user changed the filter): the next `resolve` holds nothing.
    public mutating func releaseAll() {
        releaseEverything = true
    }

    /// The user clicked `section`'s Done group: the next `resolve` folds its done items now.
    public mutating func releaseDone(section: String) {
        releasedSections.insert(section)
    }

    public mutating func resolve(displayed: [TrackerRow],
                                 target: TrackerPresentation,
                                 visibleKeys: Set<String>,
                                 selectedKey: String?) -> TrackerDeferralResult {
        defer {
            releaseEverything = false
            releasedSections = []
        }
        let holds = releaseEverything ? [] : findHolds(displayed: displayed, target: target,
                                                       visibleKeys: visibleKeys, selectedKey: selectedKey)
        let rows = place(holds, displayed: displayed, target: target.rows)

        var renamed: [String: String] = [:]
        let shownKeys = Set(rows.map(\.key))
        for row in displayed where row.key.hasPrefix(Self.movingPrefix) && !shownKeys.contains(row.key) {
            let itemKey = TrackerRow.itemKey(String(row.key.dropFirst(Self.movingPrefix.count)))
            if shownKeys.contains(itemKey) { renamed[row.key] = itemKey }
        }

        held = holds
        return TrackerDeferralResult(
            rows: rows,
            applyNow: TrackerDiff.ops(from: displayed, to: rows),
            held: holds,
            stubs: holds.filter { $0.kind != .selection }.map(\.row),
            renamed: renamed)
    }

    // MARK: - Private

    private func findHolds(displayed: [TrackerRow], target: TrackerPresentation,
                           visibleKeys: Set<String>, selectedKey: String?) -> [TrackerHold] {
        let targetByKey = Dictionary(target.rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var holds: [TrackerHold] = []
        for row in displayed where !row.key.hasPrefix(Self.movingPrefix) {
            let key = row.key
            if key == selectedKey {
                if targetByKey[key] != row {
                    holds.append(TrackerHold(key: key, kind: .selection, row: row))
                }
                continue
            }
            guard let shown = row.item else { continue }   // only items are deferred
            // A selection in the moved item's new copy keeps its stub (and so its key) too.
            let onScreen = visibleKeys.contains(key) || selectedKey == Self.movingPrefix + shown.id
            guard onScreen else { continue }

            if let now = targetByKey[key] {
                if case .item(let item) = now.content, item.sectionId != shown.sectionId {
                    holds.append(TrackerHold(key: key, kind: .moved, row: TrackerRow(
                        key: key, content: .stub(TrackerStubRow(kind: .movedTo(sectionTitle: item.sectionTitle),
                                                               item: shown)))))
                }
                continue
            }
            if let folded = target.foldedItems[shown.id] {
                guard !releasedSections.contains(folded.sectionId) else { continue }
                holds.append(TrackerHold(key: key, kind: .doneInPlace, row: TrackerRow(key: key, content: .item(folded))))
            } else {
                holds.append(TrackerHold(key: key, kind: .removed, row: TrackerRow(
                    key: key, content: .stub(TrackerStubRow(kind: .removed, item: shown)))))
            }
        }
        return holds
    }

    /// The target rows with every hold put back where the reader last saw it.
    private func place(_ holds: [TrackerHold], displayed: [TrackerRow], target: [TrackerRow]) -> [TrackerRow] {
        guard !holds.isEmpty else { return target }
        var rows = target
        var placed = Set<String>()

        for hold in holds {
            guard let index = rows.firstIndex(where: { $0.key == hold.key }) else { continue }
            switch hold.kind {
            case .moved:
                // The live item shows in its new section under its temporary key.
                if let id = rows[index].item?.id {
                    rows[index] = TrackerRow(key: Self.movingPrefix + id, content: rows[index].content)
                }
            case .selection:
                rows[index] = hold.row
                placed.insert(hold.key)
            case .doneInPlace, .removed:
                break
            }
        }

        let byKey = Dictionary(holds.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (i, row) in displayed.enumerated() {
            guard let hold = byKey[row.key], !placed.contains(hold.key) else { continue }
            var insertAt = 0
            for j in stride(from: i - 1, through: 0, by: -1) {
                if let index = rows.firstIndex(where: { $0.key == displayed[j].key }) {
                    insertAt = index + 1
                    break
                }
            }
            rows.insert(hold.row, at: insertAt)
            placed.insert(hold.key)
        }
        return rows
    }
}
