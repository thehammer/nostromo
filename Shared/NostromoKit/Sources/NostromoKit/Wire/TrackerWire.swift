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

// MARK: - Enums

/// An item's status (`Status`, kebab-case on the wire).
public enum TrackerStatusWire: Equatable {
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url)
        kind = try c.decodeIfPresent(TrackerLinkKindWire.self, forKey: .kind) ?? .url
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
    public let status: TrackerStatusWire
    public let owner: String?
    public let updatedAt: Date?
    public let noteBlocks: [MdBlock]
    public let links: [TrackerLinkWire]
    public let kind: TrackerItemKindWire
    public let command: String?
    public let env: TrackerEnvWire?
    public let ran: Bool
    /// `<source>/<key>` of a live binding.
    public let bound: String?
    public let source: String

    enum CodingKeys: String, CodingKey {
        case id, section, status, owner, links, kind, command, env, ran, bound, source
        case textSpans = "text_spans"
        case updatedAt = "updated_at"
        case noteBlocks = "note_blocks"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        section = try c.decodeIfPresent(String.self, forKey: .section) ?? ""
        textSpans = try c.decodeIfPresent([MdSpan].self, forKey: .textSpans) ?? []
        status = try c.decodeIfPresent(TrackerStatusWire.self, forKey: .status) ?? .unknown("")
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        noteBlocks = try c.decodeIfPresent([MdBlock].self, forKey: .noteBlocks) ?? []
        links = try c.decodeIfPresent([TrackerLinkWire].self, forKey: .links) ?? []
        kind = try c.decodeIfPresent(TrackerItemKindWire.self, forKey: .kind) ?? .item
        command = try c.decodeIfPresent(String.self, forKey: .command)
        env = try c.decodeIfPresent(TrackerEnvWire.self, forKey: .env)
        ran = try c.decodeIfPresent(Bool.self, forKey: .ran) ?? false
        bound = try c.decodeIfPresent(String.self, forKey: .bound)
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

    enum CodingKeys: String, CodingKey {
        case title, path, version, nodes, log, banner, committable
        case updatedAt = "updated_at"
        case hiddenByUser = "hidden_by_user"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        version = try c.decodeIfPresent(UInt64.self, forKey: .version) ?? 0
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        nodes = try c.decodeIfPresent([TrackerNodeWire].self, forKey: .nodes) ?? []
        log = try c.decodeIfPresent([TrackerLogLineWire].self, forKey: .log) ?? []
        banner = try c.decodeIfPresent(TrackerBannerWire.self, forKey: .banner)
        committable = try c.decodeIfPresent(TrackerCommittableWire.self, forKey: .committable)
        hiddenByUser = try c.decodeIfPresent(Bool.self, forKey: .hiddenByUser) ?? false
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
