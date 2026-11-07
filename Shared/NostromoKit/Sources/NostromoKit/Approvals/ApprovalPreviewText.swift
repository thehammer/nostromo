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
        /// A path that may be cut in the middle to make the line fit; counts and flags never are.
        public let flexible: Bool

        public init(text: String, style: Style, flexible: Bool = false) {
            self.text = text; self.style = style; self.flexible = flexible
        }
    }

    public struct Line: Equatable {
        public let spans: [Span]
        public var text: String { spans.map(\.text).joined() }
        public var hasWarning: Bool { spans.contains { $0.style == .warning } }
    }

    /// The most lines any preview can have: the targets, a summary line and the relative note.
    public static let worstCaseLineCount = maxTargetLines + 2

    /// The lines of `preview`. `home` shortens a path under it to `~/…`; `cwd` names the session's start folder.
    /// A preview that is `omitted`, or has nothing to say, has no lines.
    ///
    /// Targets that deserve a second look (a critical folder, outside the working folder, can't resolve) come
    /// first, so the cut never hides one behind a calm line. The summary line counts what is left out, and says
    /// how many of those are flagged. A `partial` preview never reads as a smaller one: it says "at least".
    public static func lines(for preview: ApprovalPreview, cwd: String?, home: String? = nil) -> [Line] {
        guard preview.state != .omitted, !preview.targets.isEmpty else { return [] }
        let ordered = preview.targets.filter(isFlagged) + preview.targets.filter { !isFlagged($0) }
        var out = ordered.prefix(maxTargetLines).map { line(for: $0, state: preview.state, home: home) }
        let left = ordered.dropFirst(maxTargetLines)
        let hidden = left.count + preview.more
        let hiddenFlagged = left.filter(isFlagged).count
        let partial = preview.state == .partial
        if hidden > 0 {
            var text = partial ? "and at least \(hidden) more" : "and \(hidden) more"
            if hiddenFlagged > 0 { text += ", \(hiddenFlagged) flagged" }
            out.append(Line(spans: [Span(text: text, style: hiddenFlagged > 0 ? .warning : .muted)]))
        } else if partial {
            out.append(Line(spans: [Span(text: "and possibly more (stopped counting early)", style: .warning)]))
        }
        if preview.targets.contains(where: \.relative) {
            let folder = cwd.map { shorten($0, home: home) } ?? "the session's start folder"
            out.append(Line(spans: [Span(
                text: "(relative to \(folder), where the session started; an earlier cd would change this)",
                style: .warning)]))
        }
        return out
    }

    /// The lines a card reserves, known as soon as the targets are. While the counts are still being taken, or when
    /// a target is a glob, the targets can still grow (a glob expands to many), so the worst case is reserved and a
    /// count arriving later never changes the card's height. Otherwise exactly the lines `lines` returns.
    public static func reservedLineCount(for preview: ApprovalPreview?) -> Int {
        guard let preview, preview.state != .omitted, !preview.targets.isEmpty else { return 0 }
        if preview.state == .counting || preview.targets.contains(where: isGlob) { return worstCaseLineCount }
        return lines(for: preview, cwd: nil).count
    }

    /// Fit `line` to `width`: cut flexible spans (paths) in the middle, longest first, until it fits or each is a
    /// stub. `measure` is the width of a string in the font drawn. Counts and flags are never cut.
    public static func fit(_ line: Line, toWidth width: CGFloat, measure: (String) -> CGFloat) -> Line {
        var spans = line.spans
        func measured(_ spans: [Span]) -> CGFloat { measure(spans.map(\.text).joined()) }
        var keep = spans.map { $0.text.count }
        let originals = spans.map { Array($0.text) }
        while measured(spans) > width {
            guard let i = spans.indices.filter({ spans[$0].flexible && keep[$0] > 3 })
                .max(by: { keep[$0] < keep[$1] }) else { break }
            keep[i] -= 1
            spans[i] = Span(text: middle(originals[i], keep: keep[i]), style: spans[i].style, flexible: true)
        }
        return Line(spans: spans)
    }

    /// `characters` cut to `keep` characters including a middle `…`.
    static func middle(_ characters: [Character], keep: Int) -> String {
        guard characters.count > keep, keep >= 1 else { return String(characters) }
        let tail = (keep - 1) / 2
        let head = keep - 1 - tail
        return String(characters.prefix(head)) + "…" + String(characters.suffix(tail))
    }

    static func isFlagged(_ t: ApprovalPreviewTarget) -> Bool {
        t.cantResolve != nil || t.flags.contains(.homeCritical) || t.flags.contains(.outsideCwd)
    }

    private static func isGlob(_ t: ApprovalPreviewTarget) -> Bool {
        (t.path ?? "").contains(where: { "*?[".contains($0) })
    }

    // MARK: One target

    private static func line(for t: ApprovalPreviewTarget, state: ApprovalPreview.State, home: String?) -> Line {
        var spans: [Span] = []
        if let text = t.cantResolve {
            spans.append(Span(text: "can't resolve: ", style: .warning))
            spans.append(Span(text: text, style: .warning, flexible: true))
            if let why = t.why, !why.isEmpty { spans.append(Span(text: " (\(why))", style: .warning)) }
            return Line(spans: spans + destination(t, home: home))
        }
        let path = t.path.map { shorten($0, home: home) } ?? ""
        spans.append(Span(text: path, style: .normal, flexible: true))
        spans.append(Span(text: " — " + status(t, state: state), style: .normal))
        spans += destination(t, home: home)
        let warnings = t.flags.compactMap(warning)
        if !warnings.isEmpty { spans.append(Span(text: " · " + warnings.joined(separator: ", "), style: .warning)) }
        return Line(spans: spans)
    }

    private static func destination(_ t: ApprovalPreviewTarget, home: String?) -> [Span] {
        guard t.command == "mv", let dest = t.dest else { return [] }
        return [Span(text: " → ", style: .normal), Span(text: shorten(dest, home: home), style: .normal, flexible: true)]
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
