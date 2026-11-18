// NostromoKit — TrackerWire.swift
//
// The agent tracker's frames: `tracker_board` (the whole board the pane shows,
// a REPLACE snapshot; local clients only) and `tracker_summary` (a flag and five
// counts; also sent to network peers for non-sensitive focuses). Mirrors
// `TrackerBoardView` in `src/tracker/view.rs` and the two `ServerMsg` variants
// in `src/ipc/protocol.rs`. The golden JSON lives in `tests/fixtures/tracker/`
// and is decoded by both the Rust round-trip test and `TrackerWireTests`.
//
// Every decoder is lenient on purpose: a newer daemon may add keys or enum
// values. Unknown keys are ignored, unknown enum strings decode to an
// `.unknown(String)` case, an unknown or malformed node decodes to `.unknown`
// (never a throw), and every field that can be absent is optional.

import Foundation

/// The daemon advertises this in `Welcome.features` when it takes `tracker_edit` (the pane edits
/// the board as the user). The pane shows its edit controls only when it is present.
public let trackerEditFeature = "tracker_edit_v1"
/// The daemon advertises this when conflicts carry a stable `conflict_id` and `resolve_conflict` names it.
public let trackerConflictIdsFeature = "tracker_conflict_ids_v1"

/// The pane edits only against a daemon that advertised both features: an older one leaves it read-only.
public func trackerEditSupported(features: [String]?) -> Bool {
    guard let features else { return false }
    return features.contains(trackerEditFeature) && features.contains(trackerConflictIdsFeature)
}

// MARK: - Enums

/// An item's status (`Status`, kebab-case on the wire).
public enum TrackerStatusWire: Hashable {
    case todo
    case inProgress
    case blocked
    case needsYou
    case done
    case unknown(String)

    public init(wire raw: String) {
        switch raw {
        case "todo": self = .todo
        case "in-progress": self = .inProgress
        case "blocked": self = .blocked
        case "needs-you": self = .needsYou
        case "done": self = .done
        default: self = .unknown(raw)
        }
    }
}

/// `item` or `command` (a staged command the user runs).
public enum TrackerItemKindWire: Equatable {
    case item
    case command
    case unknown(String)

    public init(wire raw: String) {
        switch raw {
        case "item": self = .item
        case "command": self = .command
        default: self = .unknown(raw)
        }
    }
}

/// The environment a command or item touches.
public enum TrackerEnvWire: Equatable {
    case prod
    case canada
    case demo
    case staging
    case local
    case unset
    case unknown(String)

    public init(wire raw: String) {
        switch raw {
        case "prod": self = .prod
        case "canada": self = .canada
        case "demo": self = .demo
        case "staging": self = .staging
        case "local": self = .local
        case "unset": self = .unset
        default: self = .unknown(raw)
        }
    }
}

/// How a link was classified by the daemon.
public enum TrackerLinkKindWire: Equatable {
    case pr
    case jira
    case sentry
    case run
    case file
    case url
    case unknown(String)

    public init(wire raw: String) {
        switch raw {
        case "pr": self = .pr
        case "jira": self = .jira
        case "sentry": self = .sentry
        case "run": self = .run
        case "file": self = .file
        case "url": self = .url
        default: self = .unknown(raw)
        }
    }
}

extension TrackerStatusWire: Decodable {
    public init(from decoder: Decoder) throws {
        self.init(wire: (try? decoder.singleValueContainer().decode(String.self)) ?? "")
    }
}

extension TrackerItemKindWire: Decodable {
    public init(from decoder: Decoder) throws {
        self.init(wire: (try? decoder.singleValueContainer().decode(String.self)) ?? "")
    }
}

extension TrackerEnvWire: Decodable {
    public init(from decoder: Decoder) throws {
        self.init(wire: (try? decoder.singleValueContainer().decode(String.self)) ?? "")
    }
}

extension TrackerLinkKindWire: Decodable {
    public init(from decoder: Decoder) throws {
        self.init(wire: (try? decoder.singleValueContainer().decode(String.self)) ?? "")
    }
}

// MARK: - Pieces

/// Item counts per status: exactly the five keys of `tracker_summary.counts`.
public struct TrackerCountsWire: Decodable, Equatable {
    public let todo: Int
    public let inProgress: Int
    public let blocked: Int
    public let needsYou: Int
    public let done: Int

    enum CodingKeys: String, CodingKey {
        case todo, blocked, done
        case inProgress = "in_progress"
        case needsYou = "needs_you"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        todo = try c.decodeIfPresent(Int.self, forKey: .todo) ?? 0
        inProgress = try c.decodeIfPresent(Int.self, forKey: .inProgress) ?? 0
        blocked = try c.decodeIfPresent(Int.self, forKey: .blocked) ?? 0
        needsYou = try c.decodeIfPresent(Int.self, forKey: .needsYou) ?? 0
        done = try c.decodeIfPresent(Int.self, forKey: .done) ?? 0
    }
}

/// A reference attached to an item.
public struct TrackerLinkWire: Decodable, Equatable {
    public let text: String
    public let url: String?
    public let kind: TrackerLinkKindWire

    enum CodingKeys: String, CodingKey { case text, url, kind }

    public init(text: String, url: String? = nil, kind: TrackerLinkKindWire) {
        self.text = text
        self.url = url
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url)
        kind = try c.decodeIfPresent(TrackerLinkKindWire.self, forKey: .kind) ?? .url
    }
}

/// The live source an item follows (T6): which one and how fresh. Only in `tracker_board`, which a
/// network peer never receives.
public struct TrackerBoundWire: Decodable, Equatable {
    /// `mother.job` or `pr.ci`.
    public let source: String
    /// When the source last reported on the item (absent before its first report).
    public let asOf: Date?
    /// The source has been silent past the badly-stale limit; the item keeps its last value.
    public let badlyStale: Bool

    enum CodingKeys: String, CodingKey {
        case source
        case asOf = "as_of"
        case badlyStale = "badly_stale"
    }

    public init(source: String, asOf: Date? = nil, badlyStale: Bool = false) {
        self.source = source
        self.asOf = asOf
        self.badlyStale = badlyStale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        asOf = try? c.decodeIfPresent(Date.self, forKey: .asOf)
        badlyStale = try c.decodeIfPresent(Bool.self, forKey: .badlyStale) ?? false
    }
}

/// A value that lost to a later write by someone who couldn't have seen it (T3a). Only in
/// `tracker_board`, which a network peer never receives.
public struct TrackerConflictWire: Decodable, Equatable {
    public let field: String
    /// The losing value as text (JSON for a list), raw: it is the user's own.
    public let losing: String
    /// Who wrote it (`agent claudia`, `pane (you)`, `file (unknown editor)`).
    public let losingBy: String
    public let winningBy: String
    public let at: Date?
    /// Position among this item field's losing values, oldest first, as of this view. Informational:
    /// `resolve_conflict` names the conflict by `conflictId`.
    public let index: Int
    /// The conflict's stable id (`resolve_conflict.conflict_id`). Opaque: never parsed. Empty from a
    /// daemon that predates conflict ids.
    public let conflictId: String

    enum CodingKeys: String, CodingKey {
        case field, losing, at, index
        case conflictId = "conflict_id"
        case losingBy = "losing_by"
        case winningBy = "winning_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decodeIfPresent(String.self, forKey: .field) ?? ""
        losing = try c.decodeIfPresent(String.self, forKey: .losing) ?? ""
        losingBy = try c.decodeIfPresent(String.self, forKey: .losingBy) ?? ""
        winningBy = try c.decodeIfPresent(String.self, forKey: .winningBy) ?? ""
        at = try? c.decodeIfPresent(Date.self, forKey: .at)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        conflictId = try c.decodeIfPresent(String.self, forKey: .conflictId) ?? ""
    }
}

/// An item removed over someone's edit. `source` restores it byte for byte (`restore`).
public struct TrackerRemovedConflictWire: Decodable, Equatable {
    public let itemId: String
    /// The removed item's text.
    public let title: String
    public let losingBy: String
    public let winningBy: String
    public let at: Date?
    public let source: String
    /// The conflict's stable id (`resolve_conflict.conflict_id`); opaque. Empty from an older daemon.
    public let conflictId: String

    enum CodingKeys: String, CodingKey {
        case title, at, source
        case conflictId = "conflict_id"
        case itemId = "item_id"
        case losingBy = "losing_by"
        case winningBy = "winning_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try c.decodeIfPresent(String.self, forKey: .itemId) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        losingBy = try c.decodeIfPresent(String.self, forKey: .losingBy) ?? ""
        winningBy = try c.decodeIfPresent(String.self, forKey: .winningBy) ?? ""
        at = try? c.decodeIfPresent(Date.self, forKey: .at)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        conflictId = try c.decodeIfPresent(String.self, forKey: .conflictId) ?? ""
    }
}

/// Why an item is badged: the classes of sensitive-looking text it holds (`ssn`, `phone`, …),
/// never the text. Agents are not shown such text until the user clears the badge.
public struct TrackerSensitiveWire: Decodable, Equatable {
    public let classes: [String]

    enum CodingKeys: String, CodingKey { case classes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        classes = try c.decodeIfPresent([String].self, forKey: .classes) ?? []
    }
}

/// The banner over a board that isn't current. The view under it is the last
/// good version.
public enum TrackerBannerWire: Equatable {
    /// The file doesn't parse (`line` is 1-based).
    case unreadable(line: Int, reason: String, lastGoodAt: Date?)
    /// The file is gone.
    case missing(lastSeen: Date?)
    case unknown(String)
}

extension TrackerBannerWire: Decodable {
    private enum K: String, CodingKey { case type, line, reason, lastGoodAt = "last_good_at", lastSeen = "last_seen" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "unreadable":
            self = .unreadable(
                line: (try? c.decode(Int.self, forKey: .line)) ?? 0,
                reason: (try? c.decode(String.self, forKey: .reason)) ?? "",
                lastGoodAt: try? c.decodeIfPresent(Date.self, forKey: .lastGoodAt)
            )
        case "missing":
            self = .missing(lastSeen: try? c.decodeIfPresent(Date.self, forKey: .lastSeen))
        default:
            self = .unknown(type)
        }
    }
}

/// The board sits where a commit would pick it up.
public struct TrackerCommittableWire: Decodable, Equatable {
    /// `host/owner/repo`, never credentials.
    public let remote: String?
}

/// One Log line.
public struct TrackerLogLineWire: Decodable, Equatable {
    public let time: String
    public let text: String
}

/// One item with its note and links. `source` is its exact markdown from the
/// file (task line plus indented block, marker included).
public struct TrackerItemWire: Decodable, Equatable {
    public let id: String
    public let section: String
    public let textSpans: [MdSpan]
    /// The task text as stored (raw markdown), to prefill an editor. Empty from an older daemon.
    public let text: String
    /// The note as stored (raw markdown). Nil without a note, and from an older daemon.
    public let note: String?
    public let status: TrackerStatusWire
    public let owner: String?
    public let updatedAt: Date?
    public let noteBlocks: [MdBlock]
    public let links: [TrackerLinkWire]
    public let kind: TrackerItemKindWire
    public let command: String?
    public let env: TrackerEnvWire?
    public let ran: Bool
    /// The live source this item follows and how fresh it is.
    public let bound: TrackerBoundWire?
    /// Overwritten values the user hasn't settled (empty from an older daemon).
    public let conflicts: [TrackerConflictWire]
    /// How many older overwritten values a cap dropped: something was lost that can't be shown.
    public let droppedConflicts: Int
    /// Sensitive-looking text the user hasn't cleared.
    public let sensitive: TrackerSensitiveWire?
    public let source: String

    enum CodingKeys: String, CodingKey {
        case id, section, status, owner, links, kind, command, env, ran, bound, source
        case text, note, conflicts, sensitive
        case droppedConflicts = "dropped_conflicts"
        case textSpans = "text_spans"
        case updatedAt = "updated_at"
        case noteBlocks = "note_blocks"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        section = try c.decodeIfPresent(String.self, forKey: .section) ?? ""
        textSpans = try c.decodeIfPresent([MdSpan].self, forKey: .textSpans) ?? []
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note)
        status = try c.decodeIfPresent(TrackerStatusWire.self, forKey: .status) ?? .unknown("")
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        noteBlocks = try c.decodeIfPresent([MdBlock].self, forKey: .noteBlocks) ?? []
        links = try c.decodeIfPresent([TrackerLinkWire].self, forKey: .links) ?? []
        kind = try c.decodeIfPresent(TrackerItemKindWire.self, forKey: .kind) ?? .item
        command = try c.decodeIfPresent(String.self, forKey: .command)
        env = try c.decodeIfPresent(TrackerEnvWire.self, forKey: .env)
        ran = try c.decodeIfPresent(Bool.self, forKey: .ran) ?? false
        bound = try? c.decodeIfPresent(TrackerBoundWire.self, forKey: .bound)
        conflicts = (try? c.decodeIfPresent([TrackerConflictWire].self, forKey: .conflicts)) ?? []
        droppedConflicts = (try? c.decodeIfPresent(Int.self, forKey: .droppedConflicts)) ?? 0
        sensitive = try? c.decodeIfPresent(TrackerSensitiveWire.self, forKey: .sensitive)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
    }
}

/// One node of the board in file order. Joining every node's `source` in order
/// reproduces the file byte for byte. A node kind this client doesn't know
/// (or a malformed one) is `.unknown`; it is skipped, never fatal.
public enum TrackerNodeWire: Equatable {
    case title(text: String, source: String)
    case section(id: String, title: String, source: String)
    /// The `## Log` heading.
    case logHeading(title: String, source: String)
    /// Free prose; `key` is a stable identity for diffing.
    case prose(key: String, blocks: [MdBlock], source: String)
    case item(TrackerItemWire)
    case logLine(time: String, text: String, source: String)
    case unknown
}

extension TrackerNodeWire: Decodable {
    private enum K: String, CodingKey { case type, text, title, source, id, key, blocks, time }

    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: K.self),
              let type = try? c.decode(String.self, forKey: .type)
        else {
            self = .unknown
            return
        }
        let source = (try? c.decode(String.self, forKey: .source)) ?? ""
        switch type {
        case "title":
            self = .title(text: (try? c.decode(String.self, forKey: .text)) ?? "", source: source)
        case "section":
            guard let id = try? c.decode(String.self, forKey: .id) else { self = .unknown; return }
            self = .section(id: id, title: (try? c.decode(String.self, forKey: .title)) ?? "", source: source)
        case "log_heading":
            self = .logHeading(title: (try? c.decode(String.self, forKey: .title)) ?? "", source: source)
        case "prose":
            guard let key = try? c.decode(String.self, forKey: .key) else { self = .unknown; return }
            self = .prose(
                key: key,
                blocks: (try? c.decode([MdBlock].self, forKey: .blocks)) ?? [],
                source: source
            )
        case "item":
            if let item = try? TrackerItemWire(from: decoder) {
                self = .item(item)
            } else {
                self = .unknown
            }
        case "log_line":
            self = .logLine(
                time: (try? c.decode(String.self, forKey: .time)) ?? "",
                text: (try? c.decode(String.self, forKey: .text)) ?? "",
                source: source
            )
        default:
            self = .unknown
        }
    }
}

// MARK: - Frames

/// What the tracker pane shows (`TrackerBoardView`).
public struct TrackerBoardViewWire: Decodable, Equatable {
    public let title: String
    public let path: String
    /// The board's change-log version.
    public let version: UInt64
    public let updatedAt: Date?
    public let nodes: [TrackerNodeWire]
    /// Log lines in file order (oldest first).
    public let log: [TrackerLogLineWire]
    public let banner: TrackerBannerWire?
    public let committable: TrackerCommittableWire?
    public let hiddenByUser: Bool
    /// Items removed over someone's edit (empty from an older daemon).
    public let removedConflicts: [TrackerRemovedConflictWire]
    /// Which run of the board `version` counts in (changes when the daemon's state for the board is lost).
    /// Sent back as `base_epoch`. Empty from an older daemon.
    public let epoch: String

    enum CodingKeys: String, CodingKey {
        case title, path, version, nodes, log, banner, committable, epoch
        case removedConflicts = "removed_conflicts"
        case updatedAt = "updated_at"
        case hiddenByUser = "hidden_by_user"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        version = try c.decodeIfPresent(UInt64.self, forKey: .version) ?? 0
        epoch = (try? c.decodeIfPresent(String.self, forKey: .epoch)) ?? ""
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        nodes = try c.decodeIfPresent([TrackerNodeWire].self, forKey: .nodes) ?? []
        log = try c.decodeIfPresent([TrackerLogLineWire].self, forKey: .log) ?? []
        banner = try c.decodeIfPresent(TrackerBannerWire.self, forKey: .banner)
        committable = try c.decodeIfPresent(TrackerCommittableWire.self, forKey: .committable)
        hiddenByUser = try c.decodeIfPresent(Bool.self, forKey: .hiddenByUser) ?? false
        removedConflicts = (try? c.decodeIfPresent([TrackerRemovedConflictWire].self, forKey: .removedConflicts)) ?? []
    }
}

/// `tracker_board`: the whole board of one focus (REPLACE semantics), or `nil`
/// when the focus has no tracker. Local clients only.
public struct TrackerBoardFrameWire: Decodable, Equatable {
    public let tag: String
    public let board: TrackerBoardViewWire?
}

/// `tracker_summary`: whether a focus has a tracker and its counts. The only
/// tracker frame a network peer may receive.
public struct TrackerSummaryFrameWire: Decodable, Equatable {
    public let tag: String
    public let hasTracker: Bool
    public let counts: TrackerCountsWire

    enum CodingKeys: String, CodingKey {
        case tag, counts
        case hasTracker = "has_tracker"
    }
}

// MARK: - Editing (`tracker_edit`, T3a)

/// Which side of a conflict the user keeps.
public enum TrackerConflictKeepWire: String, Codable, Equatable {
    case current
    case losing
}

/// One edit the user makes in the pane (`TrackerPaneOp` in `src/ipc/protocol.rs`). Encodes as
/// `{"op": "<snake_case name>", …}` and leaves absent optionals out, so `body: ""` (clear the note)
/// is sent and `body: nil` (leave it) is not.
public enum TrackerPaneOpWire: Codable, Equatable {
    /// The tick (`done`) and untick (the previous status, or `todo`).
    case status(id: String, status: String)
    /// At least one of `title` (one line, at most 80 characters), `text` (to undo a restructure)
    /// and `body` (the note; empty clears it).
    case edit(id: String, title: String?, text: String?, body: String?)
    /// The item's text put back exactly as it was (`restore_text`): unlike `edit`'s `text` it is not cut at
    /// 500 characters, so the undo of a long line returns it whole.
    case restoreText(id: String, text: String)
    /// A new item; the daemon names it (`TrackerEditResultWire.created`).
    case add(section: String, title: String, body: String?, before: String?, after: String?)
    case move(id: String, section: String, before: String?, after: String?)
    case remove(id: String)
    /// An item back from its exact markdown (`TrackerItemWire.source`).
    case restore(source: String, section: String, before: String?, after: String?)
    /// Accept the item's current sensitive-looking text.
    case clearBadge(id: String)
    /// Settle a conflict: `field` is `removed` for a removed item; `conflictId` is the opaque id the
    /// board showed (a position no longer names a conflict, so none is sent).
    case resolveConflict(id: String, field: String, keep: TrackerConflictKeepWire, conflictId: String)

    private enum K: String, CodingKey {
        case op, id, status, title, text, body, section, before, after, source, field, keep
        case conflictId = "conflict_id"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .status(let id, let status):
            try c.encode("status", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(status, forKey: .status)
        case .edit(let id, let title, let text, let body):
            try c.encode("edit", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encodeIfPresent(text, forKey: .text)
            try c.encodeIfPresent(body, forKey: .body)
        case .restoreText(let id, let text):
            try c.encode("restore_text", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
        case .add(let section, let title, let body, let before, let after):
            try c.encode("add", forKey: .op)
            try c.encode(section, forKey: .section)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(body, forKey: .body)
            try c.encodeIfPresent(before, forKey: .before)
            try c.encodeIfPresent(after, forKey: .after)
        case .move(let id, let section, let before, let after):
            try c.encode("move", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(section, forKey: .section)
            try c.encodeIfPresent(before, forKey: .before)
            try c.encodeIfPresent(after, forKey: .after)
        case .remove(let id):
            try c.encode("remove", forKey: .op)
            try c.encode(id, forKey: .id)
        case .restore(let source, let section, let before, let after):
            try c.encode("restore", forKey: .op)
            try c.encode(source, forKey: .source)
            try c.encode(section, forKey: .section)
            try c.encodeIfPresent(before, forKey: .before)
            try c.encodeIfPresent(after, forKey: .after)
        case .clearBadge(let id):
            try c.encode("clear_badge", forKey: .op)
            try c.encode(id, forKey: .id)
        case .resolveConflict(let id, let field, let keep, let conflictId):
            try c.encode("resolve_conflict", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(field, forKey: .field)
            try c.encode(keep, forKey: .keep)
            try c.encode(conflictId, forKey: .conflictId)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "status":
            self = .status(id: try c.decode(String.self, forKey: .id), status: try c.decode(String.self, forKey: .status))
        case "edit":
            self = .edit(id: try c.decode(String.self, forKey: .id),
                         title: try c.decodeIfPresent(String.self, forKey: .title),
                         text: try c.decodeIfPresent(String.self, forKey: .text),
                         body: try c.decodeIfPresent(String.self, forKey: .body))
        case "restore_text":
            self = .restoreText(id: try c.decode(String.self, forKey: .id), text: try c.decode(String.self, forKey: .text))
        case "add":
            self = .add(section: try c.decode(String.self, forKey: .section),
                        title: try c.decode(String.self, forKey: .title),
                        body: try c.decodeIfPresent(String.self, forKey: .body),
                        before: try c.decodeIfPresent(String.self, forKey: .before),
                        after: try c.decodeIfPresent(String.self, forKey: .after))
        case "move":
            self = .move(id: try c.decode(String.self, forKey: .id),
                         section: try c.decode(String.self, forKey: .section),
                         before: try c.decodeIfPresent(String.self, forKey: .before),
                         after: try c.decodeIfPresent(String.self, forKey: .after))
        case "remove":
            self = .remove(id: try c.decode(String.self, forKey: .id))
        case "restore":
            self = .restore(source: try c.decode(String.self, forKey: .source),
                            section: try c.decode(String.self, forKey: .section),
                            before: try c.decodeIfPresent(String.self, forKey: .before),
                            after: try c.decodeIfPresent(String.self, forKey: .after))
        case "clear_badge":
            self = .clearBadge(id: try c.decode(String.self, forKey: .id))
        case "resolve_conflict":
            self = .resolveConflict(id: try c.decode(String.self, forKey: .id),
                                    field: try c.decode(String.self, forKey: .field),
                                    keep: try c.decode(TrackerConflictKeepWire.self, forKey: .keep),
                                    conflictId: try c.decode(String.self, forKey: .conflictId))
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown tracker op \(op)")
        }
    }
}

/// The `tracker_edit` frame. Applied only from the verified Mac app, with the connection's
/// `operator_nonce`; refused for every other peer.
public struct TrackerEditRequestWire: Encodable, Equatable {
    public let tag: String
    public let requestId: String
    /// The board version the edit was made against (`TrackerBoardViewWire.version`).
    public let baseVersion: UInt64
    /// The `epoch` of the board view `baseVersion` is from; nil when the board showed none (an older daemon).
    public let baseEpoch: String?
    public let operatorNonce: String?
    public let ops: [TrackerPaneOpWire]

    public init(tag: String, requestId: String, baseVersion: UInt64, baseEpoch: String? = nil,
                operatorNonce: String?, ops: [TrackerPaneOpWire]) {
        self.tag = tag
        self.requestId = requestId
        self.baseVersion = baseVersion
        self.baseEpoch = baseEpoch
        self.operatorNonce = operatorNonce
        self.ops = ops
    }

    enum CodingKeys: String, CodingKey {
        case type, tag, ops
        case requestId = "request_id"
        case baseVersion = "base_version"
        case baseEpoch = "base_epoch"
        case operatorNonce = "operator_nonce"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("tracker_edit", forKey: .type)
        try c.encode(tag, forKey: .tag)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(baseVersion, forKey: .baseVersion)
        try c.encodeIfPresent(baseEpoch, forKey: .baseEpoch)
        try c.encodeIfPresent(operatorNonce, forKey: .operatorNonce)
        try c.encode(ops, forKey: .ops)
    }
}

/// Why a `tracker_edit` changed nothing.
public struct TrackerEditErrorWire: Decodable, Equatable {
    /// `invalid_args`, `unknown_item`, `invalid_status`, `board_too_large`, `no_tracker`,
    /// `not_operator_app`, … (a code this client doesn't know is still shown as is).
    public let code: String
    public let reason: String?
    /// The failing op's position, when the failure is one op's.
    public let index: Int?
    /// The pane's view is out of date: look again (the daemon sets it with `invalid_args`). False when absent.
    public let stale: Bool

    enum CodingKeys: String, CodingKey { case code, reason, index, stale }

    public init(code: String, reason: String? = nil, index: Int? = nil, stale: Bool = false) {
        self.code = code
        self.reason = reason
        self.index = index
        self.stale = stale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        index = try c.decodeIfPresent(Int.self, forKey: .index)
        stale = (try? c.decodeIfPresent(Bool.self, forKey: .stale)) ?? false
    }
}

/// `tracker_edit_result`: the answer to this connection's `tracker_edit`. Local only.
public struct TrackerEditResultWire: Decodable, Equatable {
    public let tag: String
    public let requestId: String
    public let ok: Bool
    public let error: TrackerEditErrorWire?
    /// The board version after the edit (0 on a refusal).
    public let version: UInt64
    /// The ids `add` generated, in op order.
    public let created: [String]

    enum CodingKeys: String, CodingKey {
        case tag, ok, error, version, created
        case requestId = "request_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId) ?? ""
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        error = try? c.decodeIfPresent(TrackerEditErrorWire.self, forKey: .error)
        version = try c.decodeIfPresent(UInt64.self, forKey: .version) ?? 0
        created = try c.decodeIfPresent([String].self, forKey: .created) ?? []
    }
}
