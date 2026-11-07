// NostromoKit — ApprovalPreviewText.swift
//
// The words of the consequence preview (AP7): one line per target under the command on the
// approval card. Pure: no views, no file system. The daemon already did the reading; this only
// says it. Which spans take the warning colour is part of the answer, so a card and a test agree.

import Foundation

public enum ApprovalPreviewText {

    /// How many target lines the card reserves room for, however many arrive.
    public static let maxTargetLines = 6

    public enum Style: Equatable {
        case normal
        /// Flags: outside the working folder, a critical folder, a symlink, ….
        case warning
        case muted
    }

    public struct Span: Equatable {
        public let text: String
        public let style: Style
    }

    public struct Line: Equatable {
        public let spans: [Span]
        public var text: String { spans.map(\.text).joined() }
        public var hasWarning: Bool { spans.contains { $0.style == .warning } }
    }

    /// The lines of `preview`. `home` shortens a path under it to `~/…`; `cwd` names the session's start folder.
    /// A preview that is `omitted`, or has nothing to say, has no lines.
    public static func lines(for preview: ApprovalPreview, cwd: String?, home: String? = nil) -> [Line] {
        guard preview.state != .omitted, !preview.targets.isEmpty else { return [] }
        var out = preview.targets.prefix(maxTargetLines).map { line(for: $0, state: preview.state, home: home) }
        let hidden = max(0, preview.targets.count - maxTargetLines) + preview.more
        if hidden > 0 { out.append(Line(spans: [Span(text: "and \(hidden) more", style: .muted)])) }
        if preview.targets.contains(where: \.relative) {
            let folder = cwd.map { shorten($0, home: home) } ?? "the session's start folder"
            out.append(Line(spans: [Span(text: "(relative to \(folder), where the session started)", style: .muted)]))
        }
        return out
    }

    /// The lines a card reserves, known as soon as the targets are: the same count `lines` returns,
    /// whatever the counts say, so a count arriving later never changes the card's height.
    public static func reservedLineCount(for preview: ApprovalPreview?) -> Int {
        guard let preview, preview.state != .omitted, !preview.targets.isEmpty else { return 0 }
        let hidden = preview.targets.count > maxTargetLines || preview.more > 0
        return min(preview.targets.count, maxTargetLines) + (hidden ? 1 : 0)
            + (preview.targets.contains(where: \.relative) ? 1 : 0)
    }

    // MARK: One target

    private static func line(for t: ApprovalPreviewTarget, state: ApprovalPreview.State, home: String?) -> Line {
        var spans: [Span] = []
        if let text = t.cantResolve {
            var shown = "can't resolve: \(text)"
            if let why = t.why, !why.isEmpty { shown += " (\(why))" }
            spans.append(Span(text: shown, style: .warning))
            return Line(spans: spans + destination(t, home: home))
        }
        let path = t.path.map { shorten($0, home: home) } ?? ""
        spans.append(Span(text: path, style: .normal))
        spans.append(Span(text: " — " + status(t, state: state), style: .normal))
        spans += destination(t, home: home)
        let warnings = t.flags.compactMap(warning)
        if !warnings.isEmpty { spans.append(Span(text: " · " + warnings.joined(separator: ", "), style: .warning)) }
        return Line(spans: spans)
    }

    private static func destination(_ t: ApprovalPreviewTarget, home: String?) -> [Span] {
        guard t.command == "mv", let dest = t.dest else { return [] }
        return [Span(text: " → " + shorten(dest, home: home), style: .normal)]
    }

    private static func status(_ t: ApprovalPreviewTarget, state: ApprovalPreview.State) -> String {
        if t.flags.contains(.busy) { return "not counted (busy)" }
        if t.flags.contains(.network) { return "not counted: network or external volume" }
        if t.exists == false { return "does not exist" }
        if t.flags.contains(.unreadable), t.exists == nil { return "can't read it" }
        if t.flags.contains(.notCounted) { return "not counted" }
        guard t.exists == true else { return state == .counting ? "counting…" : "not counted" }
        var parts: [String]
        switch t.kind {
        case "dir":
            if t.files == nil && t.dirs == nil { return state == .counting ? "counting…" : "directory" }
            parts = [count(t.dirs ?? 0, "directory", "directories"), count(t.files ?? 0, "file", "files")]
            if let bytes = t.bytes { parts.append(size(bytes)) }
        case "symlink": return "symlink"
        case "file":
            parts = ["file"]
            if let bytes = t.bytes { parts.append(size(bytes)) }
        default: return "special file"
        }
        let joined = parts.joined(separator: " · ")
        return t.atLeast ? "at least " + joined : joined
    }

    private static func warning(_ flag: ApprovalPreviewFlag) -> String? {
        switch flag {
        case .outsideCwd: return "outside the working folder"
        case .homeCritical: return "critical folder"
        case .symlink: return "symlink, not followed"
        case .otherVolume: return "stops at another volume"
        case .unreadable: return "some entries unreadable"
        case .notCounted, .network, .busy: return nil
        }
    }

    // MARK: Numbers and paths

    static func count(_ n: UInt64, _ one: String, _ many: String) -> String {
        "\(grouped(n)) \(n == 1 ? one : many)"
    }

    /// `41208` as `41,208`.
    static func grouped(_ n: UInt64) -> String {
        let digits = Array(String(n))
        var out = ""
        for (i, d) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out += "," }
            out.append(d)
        }
        return out
    }

    /// Decimal units, one decimal place: `1.2 GB`, `41.2 KB`, `7 bytes`.
    static func size(_ bytes: UInt64) -> String {
        if bytes < 1000 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        var value = Double(bytes)
        var unit = ""
        for u in ["KB", "MB", "GB", "TB", "PB"] {
            value /= 1000
            unit = u
            if value < 1000 { break }
        }
        return String(format: "%.1f %@", value, unit)
    }

    static func shorten(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
