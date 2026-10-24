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
        let heldKind = Dictionary(held.map { ($0.key, $0.kind.rawValue) }, uniquingKeysWith: { first, _ in first })

        var sections: [[String: Any]] = []
        var current: [String: Any]?
        var items: [[String: Any]] = []
        func flush() {
            guard var section = current else { return }
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
                let state: Any = row.key.hasPrefix(TrackerDeferral.movingPrefix)
                    ? "moving" : (heldKind[row.key].map { $0 as Any } ?? NSNull())
                items.append(itemJSON(item, folded: false, held: state))
            case .stub(let stub):
                items.append(itemJSON(stub.item, folded: false, held: heldKind[row.key].map { $0 as Any } ?? NSNull(), stub: stub.text))
            case .doneGroup(let group):
                current?["done"] = ["count": group.count, "expanded": group.expanded, "title": group.title]
                if !group.expanded {
                    for id in group.itemIds {
                        if let item = p.foldedItems[id] { items.append(itemJSON(item, folded: true, held: NSNull())) }
                    }
                }
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

    static func itemJSON(_ item: TrackerItemRow, folded: Bool, held: Any, stub: String? = nil) -> [String: Any] {
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
            "held": held,
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
