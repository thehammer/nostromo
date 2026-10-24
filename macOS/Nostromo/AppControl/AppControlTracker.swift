import Foundation
import NostromoKit

/// READ-ONLY JSON for `nostromo-app tracker show` and `tracker file` (T1). Pure formatting: it reads
/// what a tracker pane is showing (its presentation and displayed rows, holds included) or, with no
/// pane on screen, what the store's board would show, and changes nothing.
///
/// `conflict` and `badge` are reported as null until the daemon sends them (T3a).
enum AppControlTracker {

    static func show(tag: String,
                     presentation: TrackerPresentation?,
                     displayedRows: [TrackerRow]?,
                     visible: Bool,
                     held: [TrackerHold] = [],
                     renderGeneration: Int = 0,
                     rowsUpdatedLast: Int = 0) -> [String: Any] {
        guard let p = presentation else {
            return ["tag": tag, "waiting": true, "visible": visible, "title": NSNull(), "path": NSNull(),
                    "sections": [Any](), "strip": ["count": 0, "title": "Waiting on you (0)", "items": [Any]()],
                    "banners": [Any](), "filter": TrackerFilter.all.rawValue,
                    "render_generation": renderGeneration, "rows_updated_last": rowsUpdatedLast]
        }
        let heldByKey = Dictionary(held.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let heldByItem = Dictionary(held.compactMap { hold in hold.row.item.map { ($0.id, hold) } },
                                    uniquingKeysWith: { first, _ in first })
        // Where the board itself has each item, whatever the view is still showing.
        var modelSection: [String: String] = [:]
        for row in p.rows { if let item = row.item, case .item = row.content { modelSection[item.id] = item.sectionId } }
        for item in p.foldedItems.values { modelSection[item.id] = item.sectionId }
        for item in p.hiddenItems.values { modelSection[item.id] = item.sectionId }
        func fields(_ item: TrackerItemRow, _ hold: TrackerHold?, moving: Bool = false) -> [String: Any] {
            let section = modelSection[item.id]
            let state: Any = moving ? "moving" : (hold.map { $0.kind.rawValue as Any } ?? NSNull())
            let reason: Any = moving ? "live copy of an item the board moved here; its old place keeps a stub while on screen"
                : (hold.map { heldReason($0, modelSection: section) as Any } ?? NSNull())
            return ["held": state, "held_reason": reason, "model_section": section.map { $0 as Any } ?? NSNull()]
        }

        var sections: [[String: Any]] = []
        var current: [String: Any]?
        var items: [[String: Any]] = []
        // The board's own Done groups: a folded item is listed whether or not the view still holds
        // its row elsewhere (the displayed group leaves held items out of its count and list).
        let modelGroups = Dictionary(p.rows.compactMap { row -> (String, TrackerDoneGroupRow)? in
            if case .doneGroup(let group) = row.content { return (group.sectionId, group) }
            return nil
        }, uniquingKeysWith: { first, _ in first })
        func flush() {
            guard var section = current else { return }
            if let id = section["id"] as? String, let group = modelGroups[id], !group.expanded {
                for itemId in group.itemIds {
                    // A view row for this item may still be held elsewhere: say so here too.
                    if let item = p.foldedItems[itemId] {
                        items.append(itemJSON(item, folded: true, state: fields(item, heldByItem[itemId])))
                    }
                }
            }
            section["items"] = items
            sections.append(section)
            current = nil
            items = []
        }

        var log: Any = NSNull()
        for row in displayedRows ?? p.rows {
            switch row.content {
            case .section(let section):
                flush()
                current = ["id": section.id, "title": section.title, "count": section.count, "done": NSNull()]
            case .item(let item):
                let moving = row.key.hasPrefix(TrackerDeferral.movingPrefix)
                items.append(itemJSON(item, folded: false, state: fields(item, heldByKey[row.key], moving: moving)))
            case .stub(let stub):
                items.append(itemJSON(stub.item, folded: false, state: fields(stub.item, heldByKey[row.key]), stub: stub.text))
            case .doneGroup(let group):
                current?["done"] = ["count": group.count, "expanded": group.expanded, "title": group.title]
            case .log(let row):
                log = ["title": row.title, "count": row.total, "shown": row.lines.count, "expanded": row.expanded]
            case .prose:
                break
            }
        }
        flush()

        var banners: [[String: Any]] = []
        if let banner = p.banner { banners.append(["kind": banner.kind.rawValue, "text": banner.text]) }

        return [
            "tag": tag,
            "waiting": false,
            "title": p.header.title,
            "path": p.header.path,
            "updated": p.header.updatedText,
            "committable": p.header.committableText.map { $0 as Any } ?? NSNull(),
            "visible": visible,
            "hidden_by_user": p.hiddenByUser,
            "filter": p.filter.rawValue,
            "banners": banners,
            "strip": [
                "count": p.strip.count,
                "title": p.strip.title,
                "items": p.strip.entries.map { ["key": $0.key, "text": $0.text, "detail": $0.detail.map { $0 as Any } ?? NSNull()] as [String: Any] },
            ] as [String: Any],
            "sections": sections,
            "log": log,
            "render_generation": renderGeneration,
            "rows_updated_last": rowsUpdatedLast,
        ]
    }

    /// Why the view keeps a row the board has moved, changed or removed, in a sentence.
    static func heldReason(_ hold: TrackerHold, modelSection: String?) -> String {
        let model = modelSection.map { "the board has it in section \($0)" } ?? "the board no longer shows it"
        switch hold.kind {
        case .selection:
            return "text in this row is selected, so its content stays as it was until the selection clears (\(model))"
        case .doneInPlace:
            return "the item is done; its row stays in place while it is on screen (\(model))"
        case .keptInPlace:
            return "the item changed out of this view; its row stays in place while it is on screen (\(model))"
        case .moved:
            return "the board moved the item; a stub keeps its old place while that is on screen (\(model))"
        case .removed:
            return "the board removed the item; a stub keeps its place while it is on screen (\(model))"
        }
    }

    static func itemJSON(_ item: TrackerItemRow, folded: Bool, state: [String: Any], stub: String? = nil) -> [String: Any] {
        [
            "id": item.id,
            "text": item.text,
            "status": item.status.wireName,
            "owner": item.owner.map { $0 as Any } ?? NSNull(),
            "updated": item.relativeTime,
            "updated_at": item.updatedAt.map { iso.string(from: $0) as Any } ?? NSNull(),
            "env": item.envBadge.map { $0 as Any } ?? NSNull(),
            "note": item.noteFirstLine.map { $0 as Any } ?? NSNull(),
            "links": item.linkTexts,
            "folded": folded,
            "held": state["held"] ?? NSNull(),
            "held_reason": state["held_reason"] ?? NSNull(),
            "model_section": state["model_section"] ?? NSNull(),
            "stub": stub.map { $0 as Any } ?? NSNull(),
            "conflict": NSNull(),
            "badge": NSNull(),
        ]
    }

    /// `tracker file`: the board's path, whether a commit would pick it up, and its size on disk.
    static func file(tag: String, board: TrackerBoardViewWire?, fileSize: Int?) -> [String: Any] {
        guard let board else {
            return ["tag": tag, "path": NSNull(), "exists": false, "committable": false, "remote": NSNull(),
                    "size": NSNull(), "banner": NSNull()]
        }
        let banner: Any
        switch board.banner {
        case .unreadable?: banner = "unreadable"
        case .missing?: banner = "missing"
        default: banner = NSNull()
        }
        return [
            "tag": tag,
            "path": board.path,
            "exists": fileSize != nil,
            "committable": board.committable != nil,
            "remote": board.committable?.remote.map { $0 as Any } ?? NSNull(),
            "size": fileSize.map { $0 as Any } ?? NSNull(),
            "banner": banner,
        ]
    }

    /// The file's size in bytes, or nil when it can't be read (gone, or not a file).
    static func fileSize(atPath path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
