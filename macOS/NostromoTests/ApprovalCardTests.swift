import XCTest
import AppKit
import Combine
import NostromoKit

// AP2a: the approval card (the first Approve button), its input view, its overlay host and the
// store that owns what has been answered.
//
// These tests pin behaviour from outside: what the card offers, what it shows, what it refuses to
// do, and what it sends. They read views the way a person (or `nostromo-app approvals list`) sees
// them: button titles, label strings, attributed text, frames, accessibility attributes. They
// never read the card's private state.
//
// No wall clock, no real timers (a countdown is ticked by hand), no pasteboard, no network, no
// ~/.nostromo. The store's 2 s outcome timer is an injected closure that a test runs by hand.
//
// Contents:
//   * `ApprovalTestRequests`, `ApprovalRecorder` and `ApprovalTestViews`: shared helpers (the scroll
//     gate tests in `ApprovalScrollSafetyTests` reuse them).
//   * `ApprovalStoreTests`: the store, no AppKit.
//   * `ApprovalCardTests`: the card, its input view and its gestures.
//   * `ApprovalOverlayHostTests`: where the card floats, and how it follows the store.
//   * `ApprovalPaletteContrastTests` and `ApprovalSourceScanTests`.

// MARK: - Requests the daemon would send

/// Builds `ApprovalRequestWire` values the way the daemon sends them: the JSON is assembled here and
/// decoded with the real decoder. The display builders follow `src/approvals/display.rs`
/// (`segments`, `invisible_token`, here-doc lines, separator cuts with `cont`).
enum ApprovalTestRequests {

    typealias Obj = [String: Any]

    static let allOptions = ["allow_once", "deny", "deny_and_stop", "deny_with_note"]

    // MARK: Segments

    static func plain(_ text: String) -> Obj { ["text": text, "kind": "plain"] }

    static func separator(_ text: String) -> Obj { ["text": text, "kind": "separator"] }

    static func invisible(_ scalar: Unicode.Scalar) -> Obj {
        ["text": token(for: scalar), "kind": "invisible", "cp": Int(scalar.value)]
    }

    static func nonAscii(_ scalar: Unicode.Scalar) -> Obj {
        ["text": String(Character(scalar)), "kind": "non_ascii", "cp": Int(scalar.value)]
    }

    private static let tokenNames: [UInt32: String] = [
        0x202A: "LRE", 0x202B: "RLE", 0x202C: "PDF", 0x202D: "LRO", 0x202E: "RLO",
        0x2066: "LRI", 0x2067: "RLI", 0x2068: "FSI", 0x2069: "PDI",
        0x200B: "ZWSP", 0x200C: "ZWNJ", 0x200D: "ZWJ", 0x2060: "WJ", 0xFEFF: "BOM",
        0x00AD: "SHY", 0x061C: "ALM", 0x200E: "LRM", 0x200F: "RLM",
    ]

    /// `⟨tab⟩`, `⟨CR⟩`, `⟨U+202E RLO⟩`, or `⟨U+E0041⟩` where there is no short name.
    static func token(for scalar: Unicode.Scalar) -> String {
        switch scalar.value {
        case 0x09: return "\u{27E8}tab\u{27E9}"
        case 0x0D: return "\u{27E8}CR\u{27E9}"
        default:
            let hex = String(format: "U+%04X", scalar.value)
            if let name = tokenNames[scalar.value] { return "\u{27E8}\(hex) \(name)\u{27E9}" }
            return "\u{27E8}\(hex)\u{27E9}"
        }
    }

    private static let invisibleRanges: [ClosedRange<UInt32>] = [
        0x00AD ... 0x00AD, 0x200B ... 0x200F, 0x2028 ... 0x2029, 0x202A ... 0x202E,
        0x2060 ... 0x2064, 0x2066 ... 0x206F, 0xFEFF ... 0xFEFF, 0xE0000 ... 0xE00FF,
    ]

    /// The daemon's `is_invisible`, for the characters these fixtures use.
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v < 0x20 || (v >= 0x7F && v <= 0x9F) { return true }
        return invisibleRanges.contains { $0.contains(v) }
    }

    /// `text` as segments: plain runs, invisible characters, non-ASCII characters.
    static func segments(of text: String) -> [Obj] {
        var out: [Obj] = []
        var run = ""
        for scalar in text.unicodeScalars {
            if isInvisible(scalar) {
                if !run.isEmpty { out.append(plain(run)); run = "" }
                out.append(invisible(scalar))
            } else if !scalar.isASCII {
                if !run.isEmpty { out.append(plain(run)); run = "" }
                out.append(nonAscii(scalar))
            } else {
                run.unicodeScalars.append(scalar)
            }
        }
        if !run.isEmpty { out.append(plain(run)) }
        return out
    }

    // MARK: Lines and displays

    /// Numbers lines 1, 2, 3 ... as the daemon does.
    struct Display {
        private(set) var lines: [Obj] = []

        init() {}

        mutating func push(_ kind: String, cont: Bool = false, _ segments: [Obj]) {
            var line: Obj = ["number": lines.count + 1, "kind": kind, "segments": segments]
            if cont { line["cont"] = true }
            lines.append(line)
        }

        mutating func text(_ kind: String, _ content: String) {
            push(kind, ApprovalTestRequests.segments(of: content))
        }
    }

    static func count(_ lines: [Obj], kind: String) -> Int {
        lines.reduce(0) { total, line in
            total + ((line["segments"] as? [Obj]) ?? []).filter { ($0["kind"] as? String) == kind }.count
        }
    }

    static func display(lines: [Obj], commandCount: Int? = nil, unparsed: Bool = false) -> Obj {
        var d: Obj = [
            "lines": lines,
            "invisible_count": count(lines, kind: "invisible"),
            "non_ascii_count": count(lines, kind: "non_ascii"),
            "unparsed": unparsed,
        ]
        if let commandCount = commandCount { d["command_count"] = commandCount }
        return d
    }

    /// A command with no shell operators: one `command` line per original line.
    static func plainBashLines(_ command: String) -> [Obj] {
        var d = Display()
        for content in command.components(separatedBy: "\n") { d.text("command", content) }
        return d.lines
    }

    // MARK: The request

    /// Fifteen minutes from now, on the wall clock the card's countdown reads.
    static func freshDeadlineMs(minutes: Int = 15) -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000) + UInt64(minutes) * 60_000
    }

    static func request(
        id: String = "req-1",
        tag: String = "cody-1",
        toolKind: String = "bash",
        toolName: String = "Bash",
        displayName: String = "Bash",
        agentName: String = "cody",
        subagentType: String? = nil,
        mcp: Obj? = nil,
        input: Obj,
        display: Obj,
        cwd: String? = nil,
        reasonKind: String = "ask_rule",
        reasonText: String = "your rule Bash(rm:*) in ~/.claude/settings.json",
        flags: [String: Bool] = [:],
        options: [String] = ApprovalTestRequests.allOptions,
        description: String? = nil,
        deadlineAtMs: UInt64? = nil
    ) throws -> ApprovalRequestWire {
        var flagValues: [String: Bool] = [
            "default_to_no": false,
            "suppress_always_allow_rule": false,
            "requires_user_interaction": false,
            "classifier_approvable": false,
        ]
        for (key, value) in flags { flagValues[key] = value }
        var agent: Obj = ["name": agentName]
        if let subagentType = subagentType {
            agent["subagent"] = ["agent_id": "agent_abc", "agent_type": subagentType] as Obj
        }
        var root: Obj = [
            "request_id": id,
            "tag": tag,
            "tool_use_id": "toolu_\(id)",
            "agent": agent,
            "tool_name": toolName,
            "display_name": displayName,
            "tool_kind": toolKind,
            "input": input,
            "display": display,
            "reason": ["kind": reasonKind, "text": reasonText] as Obj,
            "flags": flagValues,
            "options": options,
            "session_rule_candidates": [Any](),
            "created_at_ms": 1_760_000_000_000,
            "deadline_at_ms": NSNumber(value: deadlineAtMs ?? freshDeadlineMs()),
        ]
        if let mcp = mcp { root["mcp"] = mcp }
        if let cwd = cwd { root["cwd"] = cwd }
        if let description = description { root["description"] = description }
        let data = try JSONSerialization.data(withJSONObject: root)
        return try JSONDecoder().decode(ApprovalRequestWire.self, from: data)
    }

    /// A Bash request. `lines` default to a faithful no-operator display of `command`.
    static func bash(
        _ command: String,
        lines: [Obj]? = nil,
        commandCount: Int? = 1,
        id: String = "req-1",
        tag: String = "cody-1",
        agentName: String = "cody",
        subagentType: String? = nil,
        cwd: String? = nil,
        reasonKind: String = "ask_rule",
        reasonText: String = "your rule Bash(rm:*) in ~/.claude/settings.json",
        flags: [String: Bool] = [:],
        options: [String] = ApprovalTestRequests.allOptions,
        description: String? = nil,
        deadlineAtMs: UInt64? = nil
    ) throws -> ApprovalRequestWire {
        try request(id: id, tag: tag, agentName: agentName, subagentType: subagentType,
                    input: ["command": command],
                    display: display(lines: lines ?? plainBashLines(command), commandCount: commandCount),
                    cwd: cwd, reasonKind: reasonKind, reasonText: reasonText, flags: flags,
                    options: options, description: description, deadlineAtMs: deadlineAtMs)
    }

    // MARK: Bash fixtures

    static let simpleRmCommand = "rm -rf build/"
    static let compoundCommand = "rm -rf build/ && rm -rf target/debug/incremental"
    static let bidiCommand = "echo \u{202E}txt.exe\u{2069} ok \u{2066}x\u{2067}y\u{2068}z\u{2069}"
    static let cyrillicCommand = "r\u{043C} -rf x"
    static let zeroWidthCommand = "r\u{200B}m -rf\u{200C} \u{200D}x\u{2060}\u{FEFF}"
    static let tabAndCRCommand = "a\tb\rc"
    static let markdownCommand = "echo **bold** [link](http://x)"
    static let heredocSecondCommand = "rm -rf /tmp/notes.txt"

    /// 300 lines: a here-doc opener (line 1), its body (2 to 285), `EOF` (286), the second command on 287, 13 echoes.
    static let heredocCommandLines: [String] = {
        var lines = ["cat > /tmp/notes.txt <<'EOF'"]
        for n in 2 ... 285 { lines.append(String(format: "note line %03d plain text with no operators", n)) }
        lines.append("EOF")
        lines.append(heredocSecondCommand)
        for n in 1 ... 13 { lines.append("echo done \(n)") }
        return lines
    }()

    static var heredoc300Command: String { heredocCommandLines.joined(separator: "\n") }

    static func simpleRm(id: String = "req-1", tag: String = "cody-1", cwd: String? = nil,
                         deadlineAtMs: UInt64? = nil) throws -> ApprovalRequestWire {
        try bash(simpleRmCommand, id: id, tag: tag, cwd: cwd, deadlineAtMs: deadlineAtMs)
    }

    /// `rm -rf build/ && rm -rf target/debug/incremental`: cut after `&&`, the second line continues the first.
    static func compound(id: String = "req-1", tag: String = "cody-1", description: String? = nil) throws -> ApprovalRequestWire {
        var d = Display()
        d.push("command", [plain("rm -rf build/ "), separator("&&")])
        d.push("command", cont: true, [plain(" rm -rf target/debug/incremental")])
        return try bash(compoundCommand, lines: d.lines, commandCount: 2, id: id, tag: tag, description: description)
    }

    static func heredoc300(id: String = "req-1", tag: String = "cody-1") throws -> ApprovalRequestWire {
        var d = Display()
        d.text("command", heredocCommandLines[0])
        for content in heredocCommandLines[1 ..< 285] { d.text("heredoc_body", content) }
        d.text("heredoc_end", heredocCommandLines[285])
        for content in heredocCommandLines[286...] { d.text("command", content) }
        return try bash(heredoc300Command, lines: d.lines, commandCount: 15, id: id, tag: tag)
    }

    static func bidi(id: String = "req-1", tag: String = "cody-1") throws -> ApprovalRequestWire {
        try bash(bidiCommand, id: id, tag: tag)
    }

    static func cyrillic(id: String = "req-1") throws -> ApprovalRequestWire {
        try bash(cyrillicCommand, id: id)
    }

    static func zeroWidth(id: String = "req-1") throws -> ApprovalRequestWire {
        try bash(zeroWidthCommand, id: id)
    }

    static func tabAndCR(id: String = "req-1") throws -> ApprovalRequestWire {
        try bash(tabAndCRCommand, id: id)
    }

    static func markdown(id: String = "req-1") throws -> ApprovalRequestWire {
        try bash(markdownCommand, id: id)
    }

    /// The display drops the trailing `/`: the shown text is not the request's text.
    static func roundTripFailure(id: String = "req-1") throws -> ApprovalRequestWire {
        try bash(simpleRmCommand, lines: plainBashLines("rm -rf build"), id: id)
    }

    // MARK: Other tools

    static let editPath = "/tmp/x/src/main.rs"
    static let editOld = "fn main() {\n    let a = 1;\n    let b = 2;\n    println!(\"{}\", a + b);\n}\n"
    static let editNew = "fn main() {\n    let a = 1;\n    let b = 3;\n    let c = 4;\n    println!(\"{}\", a + b + c);\n}\n"
    static let editDiff: [(kind: String, text: String)] = [
        ("diff_ctx", "fn main() {"),
        ("diff_ctx", "    let a = 1;"),
        ("diff_del", "    let b = 2;"),
        ("diff_del", "    println!(\"{}\", a + b);"),
        ("diff_add", "    let b = 3;"),
        ("diff_add", "    let c = 4;"),
        ("diff_add", "    println!(\"{}\", a + b + c);"),
        ("diff_ctx", "}"),
        ("diff_ctx", ""),
    ]

    static func edit(id: String = "req-1") throws -> ApprovalRequestWire {
        var d = Display()
        d.text("file_header", editPath)
        for item in editDiff { d.text(item.kind, item.text) }
        return try request(id: id, toolKind: "edit", toolName: "Edit", displayName: "Edit",
                           input: ["file_path": editPath, "old_string": editOld, "new_string": editNew],
                           display: display(lines: d.lines))
    }

    static let writePath = "/tmp/x/notes.md"
    static let writeContent = "# Notes\n\nfirst line\nsecond line\nthird line\n"

    static func write(id: String = "req-1") throws -> ApprovalRequestWire {
        var d = Display()
        d.text("file_header", writePath)
        for content in writeContent.components(separatedBy: "\n") { d.text("diff_add", content) }
        return try request(id: id, toolKind: "write", toolName: "Write", displayName: "Write",
                           input: ["file_path": writePath, "content": writeContent],
                           display: display(lines: d.lines))
    }

    static let mcpJSONLines = ["{", "  \"channel\": \"#eng\",", "  \"text\": \"hi\"", "}"]

    static func mcp(id: String = "req-1") throws -> ApprovalRequestWire {
        var d = Display()
        for content in mcpJSONLines { d.text("json", content) }
        return try request(id: id, toolKind: "mcp", toolName: "mcp__slack__post_message", displayName: "Post message",
                           mcp: ["server": "slack", "tool": "post_message"],
                           input: ["channel": "#eng", "text": "hi"], display: display(lines: d.lines),
                           reasonKind: "other", reasonText: "Claude Code asked for approval")
    }

    /// A Bash input with fields besides `command`. The daemon's display shows only the command.
    static func bashWithExtras(_ command: String, extras: Obj, id: String = "req-1") throws -> ApprovalRequestWire {
        var input: Obj = ["command": command]
        for (key, value) in extras { input[key] = value }
        return try request(id: id, input: input, display: display(lines: plainBashLines(command), commandCount: 1))
    }

    static func subagent(id: String = "req-1") throws -> ApprovalRequestWire {
        try bash(simpleRmCommand, id: id, subagentType: "redd")
    }

    // MARK: Kinds with narrower options

    static func safetyCheck(id: String = "req-1") throws -> ApprovalRequestWire {
        try bash(simpleRmCommand, id: id, reasonKind: "safety_check", reasonText: "Dangerous removal of a build directory")
    }

    static func settingsWrite(id: String = "req-1") throws -> ApprovalRequestWire {
        var d = Display()
        for content in ["{", "  \"permissions\": {}", "}"] { d.text("json", content) }
        return try request(id: id, toolKind: "other", toolName: "Config", displayName: "Config",
                           input: ["permissions": [String: Any]()], display: display(lines: d.lines),
                           reasonKind: "settings_write", reasonText: "Changes a Claude settings file")
    }

    static func suppressAlwaysAllowRule(id: String = "req-1") throws -> ApprovalRequestWire {
        try bash(simpleRmCommand, id: id, flags: ["suppress_always_allow_rule": true])
    }

    static func defaultToNo(id: String = "req-1") throws -> ApprovalRequestWire {
        try bash(simpleRmCommand, id: id, flags: ["default_to_no": true])
    }

    /// The daemon may list every option; the card must still offer Deny only.
    static func requiresUserInteraction(id: String = "req-1") throws -> ApprovalRequestWire {
        var d = Display()
        for content in ["{", "  \"question\": \"Which one?\"", "}"] { d.text("json", content) }
        return try request(id: id, toolKind: "other", toolName: "AskUserQuestion", displayName: "AskUserQuestion",
                           input: ["question": "Which one?"], display: display(lines: d.lines),
                           reasonKind: "other", reasonText: "Claude Code asked for approval",
                           flags: ["requires_user_interaction": true])
    }

    // MARK: Frames

    static func resolved(id: String, outcome: String, tag: String = "cody-1",
                         byWindow: String? = "w-other") throws -> ApprovalResolvedFrame {
        var json: Obj = ["tag": tag, "request_id": id, "outcome": outcome, "at_ms": 1_760_000_000_000]
        if let byWindow = byWindow { json["by_window"] = byWindow }
        return try JSONDecoder().decode(ApprovalResolvedFrame.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func refused(id: String, code: String, outcome: String? = nil) throws -> ApprovalAnswerRefusedFrame {
        var json: Obj = ["request_id": id, "code": code]
        if let outcome = outcome { json["outcome"] = outcome }
        return try JSONDecoder().decode(ApprovalAnswerRefusedFrame.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The display with every invisible token put back as its character (the opposite of the card's tokens).
    static func restoringInvisibles(in shown: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\u{27E8}([^\u{27E9}]*)\u{27E9}") else { return shown }
        let ns = shown as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: shown, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let inner = ns.substring(with: match.range(at: 1))
            if inner == "tab" {
                out += "\t"
            } else if inner == "CR" {
                out += "\r"
            } else if inner.hasPrefix("U+") {
                let hex = inner.dropFirst(2).prefix { $0.isHexDigit }
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                    out += String(Character(scalar))
                } else {
                    out += ns.substring(with: match.range)
                }
            } else {
                out += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}

// MARK: - What the store was asked to do

/// The closures an `ApprovalStore` needs, recording what they were called with.
final class ApprovalRecorder {

    struct Sent: Equatable {
        let requestID: String
        let decision: ApprovalDecisionWire
        let windowID: String
    }

    struct Report: Equatable {
        let requestID: String?
        let control: String
        let channel: ApprovalRefusalChannel
    }

    private(set) var sent: [Sent] = []
    private(set) var reports: [Report] = []
    /// The store's outcome-drop timer: `(delay, work)`, run by hand.
    var scheduled: [(delay: TimeInterval, work: () -> Void)] = []

    func makeStore(canSend: @escaping () -> Bool = { true }) -> ApprovalStore {
        ApprovalStore(
            send: { id, decision, windowID in
                self.sent.append(Sent(requestID: id, decision: decision, windowID: windowID))
            },
            report: { id, control, channel in
                self.reports.append(Report(requestID: id, control: control, channel: channel))
            },
            schedule: { delay, work in
                self.scheduled.append((delay: delay, work: work))
            },
            canSend: canSend)
    }

    /// Run every scheduled drop, as if the 2 s had passed.
    func runScheduled() {
        let due = scheduled
        scheduled = []
        for item in due { item.work() }
    }
}

// MARK: - Reading views

enum ApprovalTestViews {

    static func buttons(in view: NSView, visibleOnly: Bool = false) -> [NSButton] {
        rigAllSubviews(of: view).compactMap { $0 as? NSButton }
            .filter { !visibleOnly || !$0.isHiddenOrHasHiddenAncestor }
    }

    static func labels(in view: NSView) -> [NSTextField] {
        rigAllSubviews(of: view).compactMap { $0 as? NSTextField }
            .filter { !$0.isHiddenOrHasHiddenAncestor && !$0.stringValue.isEmpty }
    }

    static func labelTexts(in view: NSView) -> [String] {
        labels(in: view).map(\.stringValue)
    }

    /// The visible label whose text starts with `prefix`.
    static func label(startingWith prefix: String, in view: NSView) -> NSTextField? {
        labels(in: view).first { $0.stringValue.hasPrefix(prefix) }
    }
}

// MARK: - Colours

struct ApprovalTestRGB {
    let r: Double, g: Double, b: Double, a: Double
}

enum ApprovalTestColors {

    static func rgb(_ color: NSColor) -> ApprovalTestRGB {
        let c = color.usingColorSpace(.sRGB) ?? color
        return ApprovalTestRGB(r: Double(c.redComponent), g: Double(c.greenComponent),
                               b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    static func same(_ value: Any?, _ expected: NSColor) -> Bool {
        guard let color = value as? NSColor else { return false }
        let a = rgb(color), b = rgb(expected)
        return abs(a.r - b.r) < 0.003 && abs(a.g - b.g) < 0.003 && abs(a.b - b.b) < 0.003 && abs(a.a - b.a) < 0.003
    }

    /// `fg` (with its alpha) painted over the opaque `bg`.
    static func composite(_ fg: ApprovalTestRGB, over bg: ApprovalTestRGB) -> ApprovalTestRGB {
        ApprovalTestRGB(r: fg.r * fg.a + bg.r * (1 - fg.a), g: fg.g * fg.a + bg.g * (1 - fg.a),
                        b: fg.b * fg.a + bg.b * (1 - fg.a), a: 1)
    }

    /// WCAG relative luminance of an sRGB colour.
    static func luminance(_ c: ApprovalTestRGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    static func contrast(_ a: ApprovalTestRGB, _ b: ApprovalTestRGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

// MARK: - A card in a window

/// One request, one store, one card laid out in an offscreen window. The permit is injected:
/// by default every gesture is a person's.
final class ApprovalCardHarness {

    static let humanPermit: ApprovalCardView.GesturePermit = { _ in .human(sourcePid: nil, sourceState: nil) }

    let recorder: ApprovalRecorder
    let store: ApprovalStore
    let window: NSWindow
    let card: ApprovalCardView

    /// - Parameters:
    ///   - permit: nil uses the card's own, real, `HumanGesture.permit`.
    ///   - isOnScreen: stands in for "the window is visible and not occluded" (the rig window is never ordered in),
    ///     so the input's coverage counts. Pass nil to ask the real window.
    ///   - prepare: runs after the window exists and before the card is added (a composer to hold focus).
    init(_ testCase: XCTestCase, request: ApprovalRequestWire,
         permit: ApprovalCardView.GesturePermit? = ApprovalCardHarness.humanPermit,
         window provided: NSWindow? = nil,
         width: CGFloat = 560, maxHeight: CGFloat = 520, windowID: String = "w-test",
         armDelay: TimeInterval = 0,
         canSend: @escaping () -> Bool = { true },
         isOnScreen: (() -> Bool)? = { true },
         prepare: ((NSWindow) -> Void)? = nil) {
        let window: NSWindow = provided ?? makeRigWindow(testCase, size: NSSize(width: width + 80, height: maxHeight + 80))
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore(canSend: canSend)
        store.handle(.request(request))
        prepare?(window)
        let entry = store.entry(id: request.id)!
        let card = ApprovalCardView(entry: entry, store: store, windowID: { windowID }, permit: permit, armDelay: armDelay,
                                    isOnScreen: isOnScreen)
        let height = card.preferredHeight(forWidth: width, maxHeight: maxHeight)
        card.frame = NSRect(x: 20, y: 20, width: width, height: height)
        window.contentView!.addSubview(card)
        window.contentView!.layoutSubtreeIfNeeded()
        card.layoutSubtreeIfNeeded()
        self.recorder = recorder
        self.store = store
        self.window = window
        self.card = card
    }

    /// Show the card what the store now says (the host does this on every change).
    func sync() {
        if let entry = store.entry(id: card.request.id) { card.update(entry: entry) }
    }

    /// Re-lay the card out at its current size.
    func relayout() {
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()
    }

    /// Every direct subview's top and height (x and width are free to change, y and height are not).
    var rowGeometry: [[CGFloat]] {
        card.subviews.map { [$0.frame.minY, $0.frame.height] }
    }
}

// MARK: - The store

final class ApprovalStoreTests: XCTestCase {

    private var cancellables: [AnyCancellable] = []

    override func tearDown() {
        cancellables = []
        super.tearDown()
    }

    private func make() -> (ApprovalStore, ApprovalRecorder) {
        let recorder = ApprovalRecorder()
        return (recorder.makeStore(), recorder)
    }

    private func watchChanges(_ store: ApprovalStore) -> () -> [String] {
        var tags: [String] = []
        store.changes.sink { tags.append($0) }.store(in: &cancellables)
        return { tags }
    }

    private let allowOnce = ApprovalDecisionWire(kind: .allowOnce)
    private let deny = ApprovalDecisionWire(kind: .deny)

    // MARK: Arrival

    func testARequestAppearsPendingAndFiresAChangeForItsFocus() throws {
        let (store, _) = make()
        let changes = watchChanges(store)
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a", tag: "cody-1")))

        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.pending)
        XCTAssertEqual(store.current(tag: "cody-1")?.request.id, "a")
        XCTAssertEqual(store.visible(tag: "cody-1").map { $0.request.id }, ["a"])
        XCTAssertEqual(store.pendingCount(tag: "cody-1"), 1)
        XCTAssertEqual(store.moreCount(tag: "cody-1"), 0)
        XCTAssertEqual(changes(), ["cody-1"])
    }

    func testAnUnknownFocusHasNothing() throws {
        let (store, _) = make()
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a", tag: "cody-1")))
        XCTAssertNil(store.current(tag: "other"))
        XCTAssertEqual(store.visible(tag: "other").count, 0)
        XCTAssertEqual(store.pendingCount(tag: "other"), 0)
        XCTAssertEqual(store.moreCount(tag: "other"), 0)
    }

    func testRequestsOfAFocusAreListedOldestFirstAndCountedAsMore() throws {
        let (store, _) = make()
        for id in ["a", "b", "c"] { store.handle(.request(try ApprovalTestRequests.simpleRm(id: id))) }
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: "z", tag: "other-1")))

        XCTAssertEqual(store.visible(tag: "cody-1").map { $0.request.id }, ["a", "b", "c"])
        XCTAssertEqual(store.current(tag: "cody-1")?.request.id, "a", "the card shows the oldest")
        XCTAssertEqual(store.pendingCount(tag: "cody-1"), 3)
        XCTAssertEqual(store.moreCount(tag: "cody-1"), 2)
        XCTAssertEqual(store.visible(tag: "other-1").map { $0.request.id }, ["z"], "another focus has its own list")
        XCTAssertEqual(store.moreCount(tag: "other-1"), 0)
    }

    func testTheSameRequestArrivingTwiceIsOneEntry() throws {
        let (store, _) = make()
        let request = try ApprovalTestRequests.simpleRm(id: "a")
        store.handle(.request(request))
        store.handle(.request(request))
        XCTAssertEqual(store.visible(tag: "cody-1").count, 1)
    }

    func testTheStoreFollowsTheSubjectItIsAttachedTo() throws {
        let (store, _) = make()
        let subject = PassthroughSubject<ApprovalEvent, Never>()
        store.attach(to: subject)
        subject.send(.request(try ApprovalTestRequests.simpleRm(id: "a")))
        XCTAssertEqual(store.current(tag: "cody-1")?.request.id, "a")
        subject.send(.resolved(try ApprovalTestRequests.resolved(id: "a", outcome: "denied")))
        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.ended("Denied"))
    }

    // MARK: Answering (T-AP2a-1)

    func testAnAnswerIsSentOnceWithTheDecisionAndTheWindow() throws {
        let (store, recorder) = make()
        let changes = watchChanges(store)
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a")))

        XCTAssertTrue(store.answer("a", allowOnce, windowID: "w1"))

        XCTAssertEqual(recorder.sent, [ApprovalRecorder.Sent(requestID: "a", decision: allowOnce, windowID: "w1")])
        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.inFlight(.allowOnce))
        XCTAssertEqual(changes(), ["cody-1", "cody-1"], "arrival and the answer each tell the focus")
    }

    func testASecondAnswerForTheSameRequestIsRefusedAndSendsNothing() throws {
        let (store, recorder) = make()
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a")))
        XCTAssertTrue(store.answer("a", deny, windowID: "w1"))

        XCTAssertFalse(store.answer("a", allowOnce, windowID: "w2"), "a different decision, a different window: still no")
        XCTAssertFalse(store.answer("a", deny, windowID: "w1"))
        XCTAssertEqual(recorder.sent.count, 1)
        XCTAssertEqual(recorder.sent.first?.decision, deny)
    }

    func testAnAnswerForAnUnknownRequestIsRefused() {
        let (store, recorder) = make()
        XCTAssertFalse(store.answer("nope", allowOnce, windowID: "w1"))
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    func testAnEndedRequestCannotBeAnswered() throws {
        let (store, recorder) = make()
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a")))
        store.handle(.resolved(try ApprovalTestRequests.resolved(id: "a", outcome: "allowed_once")))
        XCTAssertFalse(store.answer("a", allowOnce, windowID: "w1"))
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    func testASnapshotStillHoldingTheRequestDoesNotMakeItAnswerableAgain() throws {
        let (store, recorder) = make()
        let request = try ApprovalTestRequests.simpleRm(id: "a")
        store.handle(.request(request))
        XCTAssertTrue(store.answer("a", deny, windowID: "w1"))

        store.handle(.snapshot([request]))

        XCTAssertNotEqual(store.entry(id: "a")?.state, ApprovalAnswerState.pending, "the daemon's list does not reset what this app did")
        XCTAssertFalse(store.answer("a", deny, windowID: "w1"))
        XCTAssertEqual(recorder.sent.count, 1)
    }

    func testARequestThatArrivesAgainAfterBeingAnsweredNeverComesBackWaiting() throws {
        let (store, recorder) = make()
        let request = try ApprovalTestRequests.simpleRm(id: "a")
        store.handle(.request(request))
        XCTAssertTrue(store.answer("a", deny, windowID: "w1"))

        // The daemon's list no longer holds it (the entry goes), then it is delivered again.
        store.handle(.snapshot([]))
        XCTAssertNil(store.entry(id: "a"))
        store.handle(.request(request))

        XCTAssertNotEqual(store.entry(id: "a")?.state, ApprovalAnswerState.pending)
        XCTAssertFalse(store.answer("a", allowOnce, windowID: "w2"))
        XCTAssertEqual(recorder.sent.count, 1, "one answer per request id for the life of the process")

        store.handle(.snapshot([request]))
        XCTAssertFalse(store.answer("a", allowOnce, windowID: "w2"), "and a later snapshot does not change that")
        XCTAssertEqual(recorder.sent.count, 1)
    }

    // MARK: No connection to answer on

    func testWithNoConnectionAnAnswerIsNotSentAndTheRequestStaysWaiting() throws {
        var online = false
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore(canSend: { online })
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a")))

        XCTAssertFalse(store.answer("a", deny, windowID: "w1"))
        XCTAssertTrue(recorder.sent.isEmpty)
        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.pending)
        XCTAssertFalse(store.answer("a", allowOnce, windowID: "w1"), "still offline")

        online = true
        XCTAssertTrue(store.answer("a", allowOnce, windowID: "w1"), "the same request can be answered once the connection is back")
        XCTAssertEqual(recorder.sent, [ApprovalRecorder.Sent(requestID: "a", decision: allowOnce, windowID: "w1")])
        XCTAssertFalse(store.answer("a", deny, windowID: "w1"), "and then exactly once")
        XCTAssertEqual(recorder.sent.count, 1)
    }

    // MARK: Endings

    func testAResolvedRequestShowsItsOutcomeThenIsDroppedAfterTwoSeconds() throws {
        let (store, recorder) = make()
        let changes = watchChanges(store)
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a")))

        store.handle(.resolved(try ApprovalTestRequests.resolved(id: "a", outcome: "allowed_once")))

        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.ended("Allowed once"))
        XCTAssertEqual(store.current(tag: "cody-1")?.request.id, "a", "the outcome stays where the card is")
        XCTAssertEqual(store.pendingCount(tag: "cody-1"), 0)
        XCTAssertEqual(recorder.scheduled.map { $0.delay }, [2], "the outcome is shown for 2 s")
        let before = changes().count

        recorder.runScheduled()

        XCTAssertNil(store.entry(id: "a"))
        XCTAssertNil(store.current(tag: "cody-1"))
        XCTAssertEqual(store.visible(tag: "cody-1").count, 0)
        XCTAssertGreaterThan(changes().count, before, "dropping the outcome tells the focus")
    }

    func testTheOutcomeTextForEachWayARequestEnds() throws {
        let cases: [(outcome: String, text: String)] = [
            ("allowed_once", "Allowed once"),
            ("denied", "Denied"),
            ("timed_out", "Denied: no answer in 15 min"),
        ]
        for (outcome, text) in cases {
            let (store, _) = make()
            store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a")))
            store.handle(.resolved(try ApprovalTestRequests.resolved(id: "a", outcome: outcome)))
            XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.ended(text), outcome)
        }
    }

    func testAnOutcomeTheStoreDoesNotKnowStillEndsTheRequestWithSomeText() throws {
        let (store, _) = make()
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a")))
        store.handle(.resolved(try ApprovalTestRequests.resolved(id: "a", outcome: "something_new")))
        guard case .ended(let text)? = store.entry(id: "a")?.state else { return XCTFail("the request must end") }
        XCTAssertFalse(text.isEmpty)
    }

    func testARequestAnsweredHereThenResolvedByTheDaemonEnds() throws {
        let (store, recorder) = make()
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a")))
        XCTAssertTrue(store.answer("a", deny, windowID: "w1"))
        store.handle(.resolved(try ApprovalTestRequests.resolved(id: "a", outcome: "denied", byWindow: "w1")))
        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.ended("Denied"))
        XCTAssertEqual(recorder.sent.count, 1)
    }

    func testResolvingTwiceOrResolvingAnUnknownRequestChangesNothing() throws {
        let (store, recorder) = make()
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a")))
        store.handle(.resolved(try ApprovalTestRequests.resolved(id: "a", outcome: "denied")))
        store.handle(.resolved(try ApprovalTestRequests.resolved(id: "a", outcome: "timed_out")))
        store.handle(.resolved(try ApprovalTestRequests.resolved(id: "ghost", outcome: "denied")))

        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.ended("Denied"), "the first ending stands")
        XCTAssertNil(store.entry(id: "ghost"))
        XCTAssertEqual(recorder.scheduled.count, 1, "one drop timer for one ending")
    }

    func testWhenTheOldestEndsTheNextTakesItsPlaceAfterTheDrop() throws {
        let (store, recorder) = make()
        for id in ["a", "b"] { store.handle(.request(try ApprovalTestRequests.simpleRm(id: id))) }
        store.handle(.resolved(try ApprovalTestRequests.resolved(id: "a", outcome: "denied")))

        XCTAssertEqual(store.current(tag: "cody-1")?.request.id, "a", "the ended one still shows its outcome")
        XCTAssertEqual(store.pendingCount(tag: "cody-1"), 1)
        XCTAssertEqual(store.moreCount(tag: "cody-1"), 1)

        recorder.runScheduled()

        XCTAssertEqual(store.current(tag: "cody-1")?.request.id, "b")
        XCTAssertEqual(store.moreCount(tag: "cody-1"), 0)
        XCTAssertEqual(store.pendingCount(tag: "cody-1"), 1)
    }

    // MARK: Refusals

    func testAnAnswerRefusedBecauseTheRequestWasAlreadyResolvedShowsHowItEnded() throws {
        let (store, _) = make()
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a")))
        XCTAssertTrue(store.answer("a", allowOnce, windowID: "w1"))

        store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "a", code: "already_resolved", outcome: "timed_out")))

        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.ended("Already denied (timed out)"))
    }

    func testAnAnswerRefusedAsNotFromTheOperatorAppIsNeverSentAgain() throws {
        let (store, recorder) = make()
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a")))
        XCTAssertTrue(store.answer("a", allowOnce, windowID: "w1"))

        store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "a", code: "not_operator_app")))

        guard case .notSent(let text)? = store.entry(id: "a")?.state else {
            return XCTFail("a refusal that leaves the request pending must read as not sent, got \(String(describing: store.entry(id: "a")?.state))")
        }
        XCTAssertFalse(text.isEmpty, "the card says why")
        XCTAssertEqual(store.pendingCount(tag: "cody-1"), 1, "the request is still waiting (it will time out)")
        XCTAssertFalse(store.answer("a", allowOnce, windowID: "w1"))
        XCTAssertFalse(store.answer("a", deny, windowID: "w1"))
        XCTAssertEqual(recorder.sent.count, 1, "never re-sent")
    }

    func testEveryRefusalThatLeavesTheRequestPendingHoldsItWithoutAResend() throws {
        for code in ["requires_secure_connection", "not_operator_app", "something_new"] {
            let (store, recorder) = make()
            store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a")))
            _ = store.answer("a", deny, windowID: "w1")
            store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "a", code: code)))
            guard let state = store.entry(id: "a")?.state, case .notSent = state else {
                XCTFail("\(code): expected .notSent, got \(String(describing: store.entry(id: "a")?.state))")
                continue
            }
            XCTAssertFalse(store.answer("a", deny, windowID: "w1"), code)
            XCTAssertEqual(recorder.sent.count, 1, code)
        }
    }

    func testARefusalForAnUnknownRequestChangesNothing() throws {
        let (store, _) = make()
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a")))
        store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "ghost", code: "already_resolved", outcome: "denied")))
        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.pending)
        XCTAssertNil(store.entry(id: "ghost"))
    }

    // MARK: Snapshots

    func testASnapshotAddsTheRequestsTheDaemonHoldsThatTheStoreDoesNotKnow() throws {
        let (store, _) = make()
        let changes = watchChanges(store)
        store.handle(.snapshot([try ApprovalTestRequests.simpleRm(id: "a"), try ApprovalTestRequests.simpleRm(id: "b")]))

        XCTAssertEqual(store.visible(tag: "cody-1").map { $0.request.id }, ["a", "b"])
        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.pending)
        XCTAssertFalse(changes().isEmpty, "the focus is told")
    }

    func testASnapshotDropsRequestsTheDaemonNoLongerHolds() throws {
        let (store, _) = make()
        let a = try ApprovalTestRequests.simpleRm(id: "a"), b = try ApprovalTestRequests.simpleRm(id: "b")
        store.handle(.snapshot([a, b]))
        let changes = watchChanges(store)

        store.handle(.snapshot([b]))
        XCTAssertNil(store.entry(id: "a"))
        XCTAssertEqual(store.visible(tag: "cody-1").map { $0.request.id }, ["b"])
        XCTAssertFalse(changes().isEmpty, "the focus is told that a request went")

        store.handle(.snapshot([]))
        XCTAssertEqual(store.visible(tag: "cody-1").count, 0)
        XCTAssertNil(store.current(tag: "cody-1"))
    }

    func testASnapshotKeepsTheOrderOfWhatWasAlreadyHere() throws {
        let (store, _) = make()
        let a = try ApprovalTestRequests.simpleRm(id: "a"), b = try ApprovalTestRequests.simpleRm(id: "b")
        store.handle(.request(a))
        store.handle(.snapshot([b, a]))
        XCTAssertEqual(store.visible(tag: "cody-1").map { $0.request.id }, ["a", "b"], "a was here first")
    }

    // MARK: Announcements and refusal reports

    func testAnArrivalIsAnnouncedToVoiceOverOncePerRequest() {
        let (store, _) = make()
        XCTAssertTrue(store.claimAnnouncement("a"))
        XCTAssertFalse(store.claimAnnouncement("a"))
        XCTAssertFalse(store.claimAnnouncement("a"))
        XCTAssertTrue(store.claimAnnouncement("b"), "another request is announced in its own right")
    }

    func testAReportedRefusalIsForwardedToTheDaemonReport() {
        let (store, recorder) = make()
        store.reportRefusal(requestId: "a", control: "allow_once", channel: .appControl)
        store.reportRefusal(requestId: nil, control: "deny", channel: .accessibility)
        XCTAssertEqual(recorder.reports, [
            ApprovalRecorder.Report(requestID: "a", control: "allow_once", channel: .appControl),
            ApprovalRecorder.Report(requestID: nil, control: "deny", channel: .accessibility),
        ])
        XCTAssertTrue(recorder.sent.isEmpty, "a refusal is a report, never an answer")
    }
}

// MARK: - The card

final class ApprovalCardTests: XCTestCase {

    // MARK: Helpers

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 1) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    private func visibleTitles(_ card: ApprovalCardView) -> [String] {
        ApprovalTestViews.buttons(in: card, visibleOnly: true).map(\.title)
    }

    private func press(_ button: NSButton?, file: StaticString = #filePath, line: UInt = #line) {
        guard let button = button else { return XCTFail("no such button", file: file, line: line) }
        button.performClick(nil)
    }

    /// The start (UTF-16 offset) of display line `index` in the input's text.
    private func start(ofLine index: Int, in view: ApprovalInputView) -> Int {
        view.displayedLines.prefix(index).reduce(0) { $0 + $1.utf16.count + 1 }
    }

    private func attribute(_ key: NSAttributedString.Key, at location: Int, in view: ApprovalInputView) -> Any? {
        view.textView.textStorage?.attribute(key, at: location, effectiveRange: nil)
    }

    /// Where `needle` sits in the input's text.
    private func range(of needle: String, in view: ApprovalInputView, file: StaticString = #filePath, line: UInt = #line) -> NSRange {
        let found = (view.textView.string as NSString).range(of: needle)
        XCTAssertNotEqual(found.location, NSNotFound, "`\(needle)` is not in the input view", file: file, line: line)
        return found
    }

    // MARK: Options per kind (28, 29)

    func testANormalRequestOffersDenyANoteMenuDenyAndStopAndAllowOnce() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())

        XCTAssertEqual(h.card.denyButton.title, "Deny")
        XCTAssertEqual(h.card.denyMoreButton?.title, "▾", "Deny's menu: Deny with a note")
        XCTAssertEqual(h.card.denyAndStopButton?.title, "Deny & stop")
        XCTAssertEqual(h.card.allowButton?.title, "Allow once")
        XCTAssertEqual(Set(visibleTitles(h.card)), ["Deny", "▾", "Deny & stop", "Allow once"])
        XCTAssertEqual(h.card.listing.options.map(\.id), ["deny", "deny_with_note", "deny_and_stop", "allow_once"])
    }

    func testSafetyChecksSettingsWritesAndSuppressedRulesOfferTheSameFourControlsAndNothingElse() throws {
        let requests: [(String, ApprovalRequestWire)] = [
            ("safety_check", try ApprovalTestRequests.safetyCheck()),
            ("settings_write", try ApprovalTestRequests.settingsWrite()),
            ("suppress_always_allow_rule", try ApprovalTestRequests.suppressAlwaysAllowRule()),
        ]
        for (name, request) in requests {
            let h = ApprovalCardHarness(self, request: request)
            let buttons = ApprovalTestViews.buttons(in: h.card)

            XCTAssertEqual(Set(buttons.map(\.title)).subtracting(["Send", "Cancel"]),
                           ["Deny", "▾", "Deny & stop", "Allow once"],
                           "\(name): Deny, Deny & stop, Allow once and Deny's menu, plus the hidden note row's Send and Cancel")
            XCTAssertEqual(Set(visibleTitles(h.card)), ["Deny", "▾", "Deny & stop", "Allow once"], "\(name): the visible controls")
            XCTAssertEqual(h.card.listing.options.map(\.id), ["deny", "deny_with_note", "deny_and_stop", "allow_once"], name)
            for button in buttons {
                let words = [button.title, button.accessibilityLabel() ?? "", button.toolTip ?? ""].joined(separator: " ").lowercased()
                for forbidden in ["session", "always", "remember", "persist"] {
                    XCTAssertFalse(words.contains(forbidden), "\(name): no remember option may be rendered (`\(button.title)`)")
                }
            }
            let others = rigAllSubviews(of: h.card).filter { $0 is NSPopUpButton || $0 is NSSegmentedControl || $0 is NSSwitch }
            XCTAssertTrue(others.isEmpty, "\(name): no other kind of control")
        }
    }

    func testARequestThatNeedsClaudeCodesOwnInterfaceOffersDenyOnlyAndSaysWhy() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.requiresUserInteraction())

        XCTAssertNil(h.card.denyMoreButton)
        XCTAssertNil(h.card.denyAndStopButton)
        XCTAssertNil(h.card.allowButton, "the daemon listed Allow once; the card must not offer it")
        XCTAssertEqual(visibleTitles(h.card), ["Deny"])
        XCTAssertEqual(h.card.listing.options.map(\.id), ["deny"])
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: h.card)
                        .contains("This tool needs Claude Code's own interface; Nostromo can't approve it"))
    }

    func testTheExplanationIsOnlyShownWhenAllowIsNotOffered() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        XCTAssertFalse(ApprovalTestViews.labelTexts(in: h.card).contains { $0.contains("Claude Code's own interface") })
    }

    // MARK: No default button (27)

    func testNoButtonInTheCardHasAKeyEquivalentAndTheWindowHasNoDefaultButton() throws {
        for request in [try ApprovalTestRequests.simpleRm(), try ApprovalTestRequests.bidi(),
                        try ApprovalTestRequests.requiresUserInteraction(), try ApprovalTestRequests.defaultToNo()] {
            let h = ApprovalCardHarness(self, request: request)
            for button in ApprovalTestViews.buttons(in: h.card) {
                XCTAssertEqual(button.keyEquivalent, "", "`\(button.title)` must not answer to any key")
            }
            XCTAssertNil(h.window.defaultButtonCell, "no button is the window's default")
        }
    }

    func testAButtonCannotBeMadeTheDefaultByGivingItAKeyEquivalent() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        for button in ApprovalTestViews.buttons(in: h.card) {
            button.keyEquivalent = "\r"
            XCTAssertEqual(button.keyEquivalent, "", "`\(button.title)`")
        }
        h.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNil(h.window.defaultButtonCell)
    }

    private func sendReturnAndSpace(to window: NSWindow) {
        let keys: [(characters: String, code: UInt16)] = [("\r", 36), (" ", 49)]
        for key in keys {
            let down = GestureFixtures.key(.keyDown, in: window, characters: key.characters, keyCode: key.code)
            _ = window.performKeyEquivalent(with: down)
            window.sendEvent(down)
            window.sendEvent(GestureFixtures.key(.keyUp, in: window, characters: key.characters, keyCode: key.code))
        }
    }

    func testReturnAndSpaceWithNothingFocusedAnswerNothingAndMoveNoFocus() throws {
        for request in [try ApprovalTestRequests.simpleRm(), try ApprovalTestRequests.defaultToNo()] {
            let h = ApprovalCardHarness(self, request: request)
            _ = h.window.makeFirstResponder(nil)
            let responder = h.window.firstResponder

            sendReturnAndSpace(to: h.window)

            XCTAssertTrue(h.recorder.sent.isEmpty, "Return and Space with no focused button answer nothing")
            XCTAssertTrue(h.recorder.reports.isEmpty)
            XCTAssertEqual(h.store.entry(id: request.id)?.state, ApprovalAnswerState.pending)
            XCTAssertTrue(h.window.firstResponder === responder, "and nothing moves focus")
        }
    }

    func testReturnAndSpaceInTheFocusedInputAnswerNothing() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        h.card.focusCard()
        XCTAssertTrue(h.window.firstResponder === h.card.inputView.textView, "precondition: the input has focus")

        sendReturnAndSpace(to: h.window)

        XCTAssertTrue(h.recorder.sent.isEmpty)
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.pending)
    }

    // MARK: Keyboard focus (26, 27)

    func testKeyboardFocusStartsInTheInputForAPlainRequest() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        XCTAssertTrue(h.card.initialKeyView === h.card.inputView.textView)
    }

    func testKeyboardFocusStartsOnDenyWhenTheCLISaidDefaultToNo() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.defaultToNo())
        XCTAssertTrue(h.card.initialKeyView === h.card.denyButton)
        XCTAssertTrue(h.card.listing.defaultToNoKind)
    }

    func testKeyboardFocusStartsOnDenyWhenTheInputHasInvisibleCharacters() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.bidi())
        XCTAssertTrue(h.card.initialKeyView === h.card.denyButton)
        XCTAssertTrue(h.card.listing.defaultToNoKind)
    }

    func testFocusCardMovesKeyboardFocusToTheInitialKeyView() throws {
        for request in [try ApprovalTestRequests.simpleRm(), try ApprovalTestRequests.defaultToNo(), try ApprovalTestRequests.bidi()] {
            let h = ApprovalCardHarness(self, request: request)
            h.card.focusCard()
            let expected = h.card.initialKeyView
            XCTAssertNotNil(expected)
            XCTAssertTrue(h.window.firstResponder === expected,
                          "first responder is \(String(describing: h.window.firstResponder)), expected \(String(describing: expected))")
        }
    }

    func testClickingOrTabbingIntoTheCardLandsOnItsInitialKeyView() throws {
        for request in [try ApprovalTestRequests.simpleRm(), try ApprovalTestRequests.bidi()] {
            let h = ApprovalCardHarness(self, request: request)
            XCTAssertTrue(h.window.makeFirstResponder(h.card))
            let landed = pump { h.window.firstResponder === h.card.initialKeyView }
            XCTAssertTrue(landed, "keyboard focus entering the card lands on \(String(describing: h.card.initialKeyView)), not \(String(describing: h.window.firstResponder))")
        }
    }

    func testArrivalLayoutTicksUpdatesAndAnAnswerNeverMoveFocusOrTouchTheComposer() throws {
        var composer: NSTextView!
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.bidi(), prepare: { window in
            composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            window.contentView!.addSubview(composer)
            composer.string = "half a thought"
            _ = window.makeFirstResponder(composer)
            composer.setSelectedRange(NSRange(location: 2, length: 4))
        })
        XCTAssertTrue(h.window.firstResponder === composer, "adding the card to the window leaves the composer focused")

        h.relayout()
        for _ in 0 ..< 3 { h.card.countdown.tick() }
        h.card.setMoreCount(2)
        h.card.inputView.scrollToEnd()
        press(h.card.denyButton)
        h.sync()
        h.store.handle(.resolved(try ApprovalTestRequests.resolved(id: "req-1", outcome: "denied")))
        h.sync()

        XCTAssertTrue(h.window.firstResponder === composer, "nothing the card does on its own takes focus")
        XCTAssertEqual(composer.string, "half a thought")
        XCTAssertEqual(composer.selectedRange(), NSRange(location: 2, length: 4))
    }

    // MARK: Allow gated by scrolling (25)

    func testAllowIsDisabledUntilTheInputHasBeenScrolledToItsEnd() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let allow = try XCTUnwrap(h.card.allowButton)

        XCTAssertFalse(h.card.inputView.hasShownEveryLine, "precondition: 300 lines do not fit")
        XCTAssertFalse(allow.isEnabled)
        XCTAssertEqual(allow.title, "Scroll to the end to allow")
        XCTAssertFalse(h.card.canAllow)

        h.card.inputView.scrollToEnd()

        XCTAssertTrue(h.card.inputView.hasShownEveryLine)
        XCTAssertTrue(allow.isEnabled)
        XCTAssertEqual(allow.title, "Allow once")
        XCTAssertTrue(h.card.canAllow)
    }

    func testScrollingPartwayDoesNotEnableAllow() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let view = h.card.inputView
        let line287 = NSRange(location: start(ofLine: 286, in: view), length: view.displayedLines[286].utf16.count)

        view.textView.scrollRangeToVisible(line287)

        XCTAssertTrue(view.visibleLineNumbers.contains(287), "precondition: line 287 is on screen")
        XCTAssertFalse(view.visibleLineNumbers.contains(300), "precondition: the last line is not")
        XCTAssertFalse(view.hasShownEveryLine)
        XCTAssertEqual(h.card.allowButton?.isEnabled, false)
        XCTAssertEqual(h.card.allowButton?.title, "Scroll to the end to allow")
    }

    func testAllowStaysEnabledAfterScrollingBackUp() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        h.card.inputView.scrollToEnd()
        h.card.inputView.scrollToTop()

        XCTAssertFalse(h.card.inputView.visibleLineNumbers.contains(300), "precondition: back at the top")
        XCTAssertEqual(h.card.allowButton?.isEnabled, true, "every line has been on screen once")
        XCTAssertEqual(h.card.allowButton?.title, "Allow once")
    }

    func testAShortCommandThatFitsEnablesAllowRightAfterLayout() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        XCTAssertTrue(h.card.inputView.hasShownEveryLine)
        XCTAssertEqual(h.card.allowButton?.isEnabled, true)
        XCTAssertEqual(h.card.allowButton?.title, "Allow once")
    }

    func testPressingADisabledAllowNeverAnswers() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let allow = try XCTUnwrap(h.card.allowButton)
        XCTAssertFalse(allow.isEnabled, "precondition")

        allow.performClick(nil)
        XCTAssertTrue(h.recorder.sent.isEmpty)

        // An action delivered to the control anyway (an Accessibility press, a stray `sendAction`).
        let action = try XCTUnwrap(allow.action)
        _ = NSApp.sendAction(action, to: allow.target, from: allow)
        XCTAssertTrue(h.recorder.sent.isEmpty, "the rule is checked where the answer is made, not only by the button's enabled flag")
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.pending)
    }

    // MARK: Arming delay (a card that just appeared cannot be allowed at once)

    private func pump(untilArmed card: ApprovalCardView) -> Bool {
        pump(until: { card.isArmed }, timeout: 2)
    }

    func testAnUnarmedCardRefusesAllowEvenWhenTheWholeInputHasBeenShown() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(), armDelay: 30)
        let allow = try XCTUnwrap(h.card.allowButton)

        XCTAssertFalse(h.card.isArmed)
        XCTAssertTrue(h.card.inputView.hasShownEveryLine, "precondition: nothing but the delay holds Allow back")
        XCTAssertFalse(h.card.canAllow)
        XCTAssertFalse(allow.isEnabled)
        XCTAssertEqual(h.card.listing.options.last?.id, "allow_once")
        XCTAssertEqual(h.card.listing.options.last?.enabled, false)

        allow.performClick(nil)
        let action = try XCTUnwrap(allow.action)
        _ = NSApp.sendAction(action, to: allow.target, from: allow)

        XCTAssertTrue(h.recorder.sent.isEmpty, "a click aimed at what was under the pointer a moment ago must not allow")
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.pending)
    }

    func testDenyWorksWhileTheCardIsUnarmed() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(), armDelay: 30)
        XCTAssertFalse(h.card.isArmed)
        XCTAssertTrue(h.card.denyButton.isEnabled)
        XCTAssertEqual(h.card.denyAndStopButton?.isEnabled, true)

        press(h.card.denyButton)

        XCTAssertEqual(h.recorder.sent.map { $0.decision }, [ApprovalDecisionWire(kind: .deny)])
    }

    func testAllowIsEnabledOnceTheDelayHasPassed() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(), armDelay: 0.05)
        XCTAssertFalse(h.card.isArmed, "precondition: unarmed when it appears")
        XCTAssertEqual(h.card.allowButton?.isEnabled, false)

        XCTAssertTrue(pump(untilArmed: h.card), "the card never armed")

        XCTAssertTrue(h.card.canAllow)
        XCTAssertEqual(h.card.allowButton?.isEnabled, true)
        XCTAssertEqual(h.card.listing.options.last?.enabled, true)
        press(h.card.allowButton)
        XCTAssertEqual(h.recorder.sent.map { $0.decision }, [ApprovalDecisionWire(kind: .allowOnce)])
    }

    func testArmingDoesNotEnableAllowWhileTheInputIsStillUnseen() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300, armDelay: 0.05)
        XCTAssertTrue(pump(untilArmed: h.card), "the card never armed")
        XCTAssertEqual(h.card.allowButton?.isEnabled, false, "armed, but the end of the input has not been shown")
        XCTAssertEqual(h.card.allowButton?.title, "Scroll to the end to allow")
    }

    func testACardWithNoDelayIsArmedAtOnce() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        XCTAssertTrue(h.card.isArmed)
        XCTAssertEqual(h.card.allowButton?.isEnabled, true)
    }

    // MARK: Only a person's scroll counts as having seen the input

    /// Move the input's clip view the way a scroll wheel does (not through `scrollToEnd`, which is the test and script entry).
    private func scrollClip(of view: ApprovalInputView, toBottom: Bool) {
        let target = toBottom ? max(0, view.textView.frame.height - view.contentView.bounds.height) : 0
        view.contentView.scroll(to: NSPoint(x: 0, y: target))
        view.reflectScrolledClipView(view.contentView)
    }

    func testAScrollMadeDuringAnAppControlRequestDoesNotCountAsHavingShownTheInput() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let view = h.card.inputView
        XCTAssertFalse(view.hasShownEveryLine, "precondition")

        SyntheticInputGate.begin()
        scrollClip(of: view, toBottom: true)
        SyntheticInputGate.end()

        XCTAssertTrue(view.visibleLineNumbers.contains(300), "precondition: the clip really is at the end")
        XCTAssertFalse(view.hasShownEveryLine, "a synthetic scroll is not a person looking at the text")
        XCTAssertEqual(h.card.allowButton?.isEnabled, false)
        XCTAssertEqual(h.card.allowButton?.title, "Scroll to the end to allow")
    }

    func testAPersonsScrollToTheEndCountsAfterASyntheticOneDidNot() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let view = h.card.inputView
        view.isPersonEvent = { _ in true }   // the scrolls below stand for a person's wheel

        SyntheticInputGate.begin()
        scrollClip(of: view, toBottom: true)
        SyntheticInputGate.end()
        XCTAssertFalse(view.hasShownEveryLine, "precondition")

        scrollClip(of: view, toBottom: false)
        XCTAssertFalse(view.hasShownEveryLine, "the top is not the end")
        scrollClip(of: view, toBottom: true)

        XCTAssertTrue(view.hasShownEveryLine, "a scroll outside any app-control request counts")
        XCTAssertEqual(h.card.allowButton?.isEnabled, true)
        XCTAssertEqual(h.card.allowButton?.title, "Allow once")
    }

    func testAPersonsScrollToTheEndCountsOnItsOwn() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        scrollClip(of: h.card.inputView, toBottom: true)
        XCTAssertTrue(h.card.inputView.hasShownEveryLine)
        XCTAssertEqual(h.card.allowButton?.isEnabled, true)
    }

    // MARK: Round-trip failure

    func testAllowStaysDisabledWhenTheShownTextIsNotTheRequestsTextEvenAfterScrollingToTheEnd() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.roundTripFailure())
        let allow = try XCTUnwrap(h.card.allowButton)
        let label = "Nostromo couldn't verify this text matches the request"

        XCTAssertFalse(h.card.model.isVerified, "precondition: the display does not match the input")
        XCTAssertTrue(h.card.inputView.hasShownEveryLine, "precondition: the whole text is on screen")
        XCTAssertFalse(allow.isEnabled)
        XCTAssertEqual(allow.title, label)
        XCTAssertFalse(h.card.canAllow)

        h.card.inputView.scrollToEnd()
        XCTAssertFalse(allow.isEnabled, "scrolling does not make unverified text safe")
        XCTAssertEqual(allow.title, label)
        XCTAssertEqual(h.card.listing.options.last?.label, label)
        XCTAssertEqual(h.card.listing.options.last?.enabled, false)

        allow.performClick(nil)
        XCTAssertTrue(h.recorder.sent.isEmpty)
    }

    func testDenyStillWorksWhenTheShownTextCannotBeVerified() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.roundTripFailure())
        XCTAssertTrue(h.card.denyButton.isEnabled)
        XCTAssertEqual(h.card.denyAndStopButton?.isEnabled, true)

        press(h.card.denyButton)

        XCTAssertEqual(h.recorder.sent.map(\.decision), [ApprovalDecisionWire(kind: .deny)])
    }

    // MARK: Answers (28)

    func testAllowOnceSendsAnAllowOnceAnswerForThisWindow() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(), windowID: "w-7")
        press(h.card.allowButton)
        XCTAssertEqual(h.recorder.sent, [ApprovalRecorder.Sent(requestID: "req-1", decision: ApprovalDecisionWire(kind: .allowOnce), windowID: "w-7")])
    }

    func testDenySendsADenyAnswer() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        press(h.card.denyButton)
        XCTAssertEqual(h.recorder.sent, [ApprovalRecorder.Sent(requestID: "req-1", decision: ApprovalDecisionWire(kind: .deny), windowID: "w-test")])
    }

    func testDenyAndStopSendsADenyAndStopAnswer() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        press(h.card.denyAndStopButton)
        XCTAssertEqual(h.recorder.sent.map(\.decision), [ApprovalDecisionWire(kind: .denyAndStop)])
    }

    private func openNoteRow(_ h: ApprovalCardHarness) throws -> (field: NSTextField, send: NSButton) {
        func noteField() -> NSTextField? {
            rigAllSubviews(of: h.card).compactMap { $0 as? NSTextField }.first { $0.isEditable }
        }
        func sendButton() -> NSButton? {
            ApprovalTestViews.buttons(in: h.card).first { $0.title == "Send" && $0.identifier?.rawValue == "deny_with_note" }
        }
        let field = try XCTUnwrap(noteField(), "the card has a one-line note field")
        let send = try XCTUnwrap(sendButton(), "the note row has a Send button")
        XCTAssertTrue(field.isHiddenOrHasHiddenAncestor, "the note row is closed until Deny's menu opens it")

        // What the menu item `Deny with a note…` does.
        let open = NSSelectorFromString("openNoteRow")
        XCTAssertTrue(h.card.responds(to: open), "the menu item's action")
        _ = h.card.perform(open)
        XCTAssertFalse(field.isHiddenOrHasHiddenAncestor, "the note row opens")
        return (field, send)
    }

    func testDenyWithANoteSendsTheTrimmedNote() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        let note = try openNoteRow(h)
        XCTAssertTrue(h.recorder.sent.isEmpty, "opening the row answers nothing")

        note.field.stringValue = "  use trash  "
        note.send.performClick(nil)

        XCTAssertEqual(h.recorder.sent.map(\.decision), [ApprovalDecisionWire(kind: .deny, note: "use trash")])
    }

    func testANoteLongerThanFiveHundredCharactersIsCut() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        let note = try openNoteRow(h)

        note.field.stringValue = String(repeating: "y", count: 600)
        note.send.performClick(nil)

        XCTAssertEqual(h.recorder.sent.first?.decision.note?.count, 500)
        XCTAssertEqual(h.recorder.sent.first?.decision.kind, .deny)
    }

    func testOpeningTheNoteRowAsksTheHostToRemeasureTheCard() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        var asked = 0
        h.card.onNeedsLayout = { asked += 1 }
        _ = try openNoteRow(h)
        XCTAssertGreaterThanOrEqual(asked, 1, "the row adds height, so the host must measure again")
    }

    // The wire shape of what the card sent (the frame the daemon receives).

    private func answerFrame(_ sent: ApprovalRecorder.Sent) throws -> [String: Any] {
        let frame = ClientApprovalAnswer(requestId: sent.requestID, decision: sent.decision,
                                         windowId: sent.windowID, operatorNonce: nil)
        let data = try JSONEncoder().encode(frame)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decisionObject(of frame: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(frame["decision"] as? [String: Any])
    }

    func testAllowOnceGoesOutAsApprovalAnswerAllowOnce() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(), windowID: "w-7")
        press(h.card.allowButton)
        let frame = try answerFrame(try XCTUnwrap(h.recorder.sent.first))
        XCTAssertEqual(frame["type"] as? String, "approval_answer")
        XCTAssertEqual(frame["request_id"] as? String, "req-1")
        XCTAssertEqual(frame["window_id"] as? String, "w-7")
        XCTAssertEqual(Set(try decisionObject(of: frame).keys), ["kind"])
        XCTAssertEqual(try decisionObject(of: frame)["kind"] as? String, "allow_once")
    }

    func testDenyGoesOutAsApprovalAnswerDeny() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        press(h.card.denyButton)
        let decision = try decisionObject(of: try answerFrame(try XCTUnwrap(h.recorder.sent.first)))
        XCTAssertEqual(decision["kind"] as? String, "deny")
        XCTAssertNil(decision["note"], "no note unless one was typed")
    }

    func testDenyAndStopGoesOutAsApprovalAnswerDenyAndStop() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        press(h.card.denyAndStopButton)
        let decision = try decisionObject(of: try answerFrame(try XCTUnwrap(h.recorder.sent.first)))
        XCTAssertEqual(decision["kind"] as? String, "deny_and_stop")
    }

    func testANoteGoesOutAsApprovalAnswerDenyWithTheNote() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        let note = try openNoteRow(h)
        note.field.stringValue = "use trash"
        note.send.performClick(nil)
        let decision = try decisionObject(of: try answerFrame(try XCTUnwrap(h.recorder.sent.first)))
        XCTAssertEqual(decision["kind"] as? String, "deny")
        XCTAssertEqual(decision["note"] as? String, "use trash")
    }

    // MARK: Only a person answers (16, ordering rule, contract §10)

    /// The ordering rule: with app-control running a request (a synthetic click or key), pressing Allow
    /// answers nothing, the card stays as it was, and the refusal is reported to the daemon. This card uses
    /// the real `HumanGesture.permit`: nothing is injected.
    func testSyntheticAllowRefused() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(), permit: nil)
        let allow = try XCTUnwrap(h.card.allowButton)
        XCTAssertTrue(allow.isEnabled, "precondition")

        SyntheticInputGate.begin()
        defer { SyntheticInputGate.end() }
        allow.performClick(nil)

        XCTAssertTrue(h.recorder.sent.isEmpty, "a synthetic Allow must never answer")
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.pending)
        XCTAssertEqual(h.card.listing.state, "pending")
        XCTAssertTrue(h.card.denyButton.isEnabled && allow.isEnabled && (h.card.denyAndStopButton?.isEnabled ?? false),
                      "the card stays as it was: a person can still answer")
        XCTAssertEqual(h.recorder.reports, [ApprovalRecorder.Report(requestID: "req-1", control: "allow_once", channel: .appControl)])
    }

    func testEveryAnswerButtonRefusesASyntheticGestureAndReportsIt() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(), permit: nil)
        SyntheticInputGate.begin()
        defer { SyntheticInputGate.end() }

        press(h.card.denyButton)
        press(h.card.denyAndStopButton)
        press(h.card.allowButton)

        XCTAssertTrue(h.recorder.sent.isEmpty)
        XCTAssertEqual(h.recorder.reports.map(\.control), ["deny", "deny_and_stop", "allow_once"])
        XCTAssertTrue(h.recorder.reports.allSatisfy { $0.channel == .appControl && $0.requestID == "req-1" })
    }

    func testARefusedNoteSendDoesNotAnswerAndIsReported() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(),
                                    permit: { _ in .refused(reason: .appControl) })
        let note = try openNoteRow(h)
        note.field.stringValue = "use trash"
        note.send.performClick(nil)

        XCTAssertTrue(h.recorder.sent.isEmpty)
        XCTAssertEqual(h.recorder.reports.map(\.control), ["deny_with_note"])
        XCTAssertEqual(h.recorder.reports.first?.channel, .appControl)
    }

    func testAnAccessibilityPressWithNoEventAndVoiceOverOffIsRefusedAndReportedAsAccessibility() throws {
        let permit: ApprovalCardView.GesturePermit = { control in
            HumanGesture.permit(nil, control: control, voiceOverEnabled: { false }, allowsSynthetic: { false })
        }
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(), permit: permit)

        press(h.card.allowButton)

        XCTAssertTrue(h.recorder.sent.isEmpty)
        XCTAssertEqual(h.recorder.reports, [ApprovalRecorder.Report(requestID: "req-1", control: "allow_once", channel: .accessibility)])
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.pending)
    }

    func testAnAccessibilityPressWithVoiceOverOnIsAnswered() throws {
        let permit: ApprovalCardView.GesturePermit = { control in
            HumanGesture.permit(nil, control: control, voiceOverEnabled: { true }, allowsSynthetic: { false })
        }
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(), permit: permit)

        press(h.card.allowButton)

        XCTAssertEqual(h.recorder.sent.map(\.decision), [ApprovalDecisionWire(kind: .allowOnce)])
        XCTAssertTrue(h.recorder.reports.isEmpty)
    }

    func testAMarkedEventIsRefusedAndAFreshHumanEventStillAnswersAfterwards() throws {
        let window = GestureFixtures.offscreenWindow(size: NSSize(width: 640, height: 600))
        addTeardownBlock { window.close() }
        final class EventBox { var event: NSEvent? }
        let box = EventBox()
        let permit: ApprovalCardView.GesturePermit = { control in
            HumanGesture.permit(box.event, control: control, voiceOverEnabled: { false }, allowsSynthetic: { false })
        }
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(), permit: permit, window: window)

        box.event = try GestureFixtures.marked(GestureFixtures.key(.keyDown, in: window))
        press(h.card.allowButton)
        XCTAssertTrue(h.recorder.sent.isEmpty, "a marked (app-control) event must not answer")
        XCTAssertEqual(h.recorder.reports.map(\.channel), [.appControl])

        box.event = GestureFixtures.mouse(.leftMouseUp, in: window)
        press(h.card.allowButton)
        XCTAssertEqual(h.recorder.sent.map(\.decision), [ApprovalDecisionWire(kind: .allowOnce)],
                       "the refusal did not poison the card: a person's click answers")
        XCTAssertEqual(h.recorder.reports.count, 1)
    }

    func testAStaleEventDoesNotAnswerAndIsReported() throws {
        let window = GestureFixtures.offscreenWindow(size: NSSize(width: 640, height: 600))
        addTeardownBlock { window.close() }
        let stale = GestureFixtures.mouse(.leftMouseUp, in: window,
                                          timestamp: ProcessInfo.processInfo.systemUptime - 5)
        let permit: ApprovalCardView.GesturePermit = { control in
            HumanGesture.permit(stale, control: control, voiceOverEnabled: { false }, allowsSynthetic: { false })
        }
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(), permit: permit, window: window)

        press(h.card.allowButton)

        XCTAssertTrue(h.recorder.sent.isEmpty, "a left-over click is not the gesture behind this press")
        XCTAssertEqual(h.recorder.reports.count, 1)
        XCTAssertEqual(h.recorder.reports.first?.control, "allow_once")
    }

    // MARK: A rebuilt card never answers twice (T-AP2a-1)

    func testARebuiltCardNeverSendsASecondAnswer() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        press(h.card.denyButton)
        XCTAssertEqual(h.recorder.sent.count, 1, "precondition")

        // A width change or a pane re-materialisation builds a new card for the same entry.
        let entry = try XCTUnwrap(h.store.entry(id: "req-1"))
        let rebuilt = ApprovalCardView(entry: entry, store: h.store, windowID: { "w-test" }, permit: ApprovalCardHarness.humanPermit)
        let height = rebuilt.preferredHeight(forWidth: 400, maxHeight: 400)
        rebuilt.frame = NSRect(x: 20, y: 20, width: 400, height: height)
        h.window.contentView?.addSubview(rebuilt)
        rebuilt.layoutSubtreeIfNeeded()

        // (Not Deny's `▾`: its action opens a menu and would block the test in a tracking loop.)
        for button in ApprovalTestViews.buttons(in: rebuilt) where button !== rebuilt.denyMoreButton {
            button.performClick(nil)
            if let action = button.action { _ = NSApp.sendAction(action, to: button.target, from: button) }
        }

        XCTAssertEqual(h.recorder.sent.count, 1, "one answer for the life of the process, whatever views come and go")
    }

    func testARebuiltCardShowsItsButtonsDisabledAndSaysAnswerIsOnItsWay() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        press(h.card.allowButton)

        let entry = try XCTUnwrap(h.store.entry(id: "req-1"))
        let rebuilt = ApprovalCardView(entry: entry, store: h.store, windowID: { "w-test" }, permit: ApprovalCardHarness.humanPermit)
        h.window.contentView?.addSubview(rebuilt)
        rebuilt.frame = NSRect(x: 20, y: 20, width: 400, height: rebuilt.preferredHeight(forWidth: 400, maxHeight: 400))
        rebuilt.layoutSubtreeIfNeeded()

        XCTAssertFalse(rebuilt.denyButton.isEnabled)
        XCTAssertEqual(rebuilt.denyAndStopButton?.isEnabled, false)
        XCTAssertEqual(rebuilt.allowButton?.isEnabled, false)
        XCTAssertEqual(rebuilt.denyMoreButton?.isEnabled, false)
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: rebuilt).contains { $0.lowercased().contains("allow") },
                      "the card says the answer is on its way: \(ApprovalTestViews.labelTexts(in: rebuilt))")
    }

    func testACardRebuiltFromAStaleWaitingEntryStillCannotAnswerTwice() throws {
        let request = try ApprovalTestRequests.simpleRm()
        let h = ApprovalCardHarness(self, request: request)
        press(h.card.denyButton)
        XCTAssertEqual(h.recorder.sent.count, 1, "precondition")

        // A view built from an old copy of the entry still thinks the request is waiting.
        let stale = ApprovalEntry(request: request, state: .pending)
        let rebuilt = ApprovalCardView(entry: stale, store: h.store, windowID: { "w-test" }, permit: ApprovalCardHarness.humanPermit)
        rebuilt.frame = NSRect(x: 20, y: 20, width: 400, height: rebuilt.preferredHeight(forWidth: 400, maxHeight: 400))
        h.window.contentView?.addSubview(rebuilt)
        rebuilt.layoutSubtreeIfNeeded()
        XCTAssertTrue(rebuilt.denyButton.isEnabled, "precondition: the stale card offers its buttons")

        rebuilt.denyButton.performClick(nil)
        rebuilt.allowButton?.performClick(nil)

        XCTAssertEqual(h.recorder.sent.count, 1, "the store, not the view, decides")
    }

    // MARK: Height stability (T-AP2a-2)

    func testTheCountdownLabelOnlyRewritesItsStringWhenItTicks() {
        var now: UInt64 = 1_000_000
        let countdown = ApprovalCountdownLabel(deadlineAtMs: 1_000_000 + 872_000, nowMs: { now })
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        countdown.label.frame = NSRect(x: 20, y: 10, width: ApprovalCountdownLabel.width, height: 16)
        container.addSubview(countdown.label)
        let frame = countdown.label.frame
        XCTAssertEqual(countdown.label.stringValue, "denies in 14:32")

        let steps: [(elapsedMs: UInt64, text: String)] = [
            (1_000, "denies in 14:31"), (2_000, "denies in 14:30"), (867_000, "denies in 0:05"),
            (872_000, "denies in 0:00"), (900_000, "denies in 0:00"),
        ]
        for step in steps {
            now = 1_000_000 + step.elapsedMs
            countdown.tick()
            XCTAssertEqual(countdown.label.stringValue, step.text)
            XCTAssertEqual(countdown.label.frame, frame, "a tick changes the string and nothing else (\(step.text))")
            XCTAssertTrue(countdown.label.superview === container)
        }
    }

    func testTheCountdownLabelIsWideEnoughForAnHour() throws {
        let countdown = ApprovalCountdownLabel(deadlineAtMs: 1)
        let font = try XCTUnwrap(countdown.label.font)
        let width = NSAttributedString(string: "denies in 60:00", attributes: [.font: font]).size().width
        XCTAssertLessThanOrEqual(width, ApprovalCountdownLabel.width, "the label never needs to grow")
    }

    func testTheCardsHeightAndRowsDoNotChangeAcrossCountdownTicks() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.compound(description: "Clean build outputs"))
        let preferred = h.card.preferredHeight(forWidth: 560, maxHeight: 520)
        let frameHeight = h.card.frame.height
        let rows = h.rowGeometry

        for _ in 0 ..< 3 { h.card.countdown.tick() }
        h.relayout()

        XCTAssertEqual(h.card.preferredHeight(forWidth: 560, maxHeight: 520), preferred)
        XCTAssertEqual(h.card.frame.height, frameHeight)
        XCTAssertEqual(h.rowGeometry, rows)
    }

    func testTheCardsHeightAndRowsDoNotChangeWhenTheRequestMovesFromWaitingToAnsweredToEnded() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.compound(description: "Clean build outputs"))
        let preferred = h.card.preferredHeight(forWidth: 560, maxHeight: 520)
        let rows = h.rowGeometry

        press(h.card.denyButton)
        h.sync()
        h.relayout()
        XCTAssertEqual(h.card.preferredHeight(forWidth: 560, maxHeight: 520), preferred, "waiting to answered")
        XCTAssertEqual(h.rowGeometry, rows, "waiting to answered")

        h.store.handle(.resolved(try ApprovalTestRequests.resolved(id: "req-1", outcome: "timed_out")))
        h.sync()
        h.relayout()
        XCTAssertEqual(h.card.preferredHeight(forWidth: 560, maxHeight: 520), preferred, "answered to ended")
        XCTAssertEqual(h.rowGeometry, rows, "answered to ended")
        XCTAssertEqual(h.card.listing.state, "Denied: no answer in 15 min")
    }

    func testTheCardsHeightAndRowsDoNotChangeWhenAnOutcomeArrivesWithoutAnyAnswer() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        let preferred = h.card.preferredHeight(forWidth: 560, maxHeight: 520)
        let rows = h.rowGeometry

        h.store.handle(.resolved(try ApprovalTestRequests.resolved(id: "req-1", outcome: "allowed_once")))
        h.sync()
        h.relayout()

        XCTAssertEqual(h.card.preferredHeight(forWidth: 560, maxHeight: 520), preferred)
        XCTAssertEqual(h.rowGeometry, rows)
    }

    func testTheCardsHeightAndRowsDoNotChangeWhenAllowChangesItsLabel() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let preferred = h.card.preferredHeight(forWidth: 560, maxHeight: 300)
        let rows = h.rowGeometry
        XCTAssertEqual(h.card.allowButton?.title, "Scroll to the end to allow", "precondition")

        h.card.inputView.scrollToEnd()
        h.relayout()

        XCTAssertEqual(h.card.allowButton?.title, "Allow once")
        XCTAssertEqual(h.card.preferredHeight(forWidth: 560, maxHeight: 300), preferred)
        XCTAssertEqual(h.rowGeometry, rows)
    }

    func testTheCardsHeightAndRowsDoNotChangeWhenAMoreCountAppears() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        let preferred = h.card.preferredHeight(forWidth: 560, maxHeight: 520)
        let rows = h.rowGeometry

        h.card.setMoreCount(2)
        h.relayout()

        XCTAssertTrue(ApprovalTestViews.labelTexts(in: h.card).contains("+2 more"))
        XCTAssertEqual(h.card.preferredHeight(forWidth: 560, maxHeight: 520), preferred)
        XCTAssertEqual(h.rowGeometry, rows)
    }

    func testTheCardIsTallerForALongerInputAndNeverTallerThanItsMaximum() throws {
        let small = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        let big = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        XCTAssertGreaterThan(big.card.frame.height, small.card.frame.height)
        XCTAssertLessThanOrEqual(big.card.frame.height, 300.5)
    }

    // MARK: Content (30, 31)

    func testTheHeadlineNamesTheAgentAndTheTool() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        XCTAssertEqual(h.card.listing.headline, "Cody wants to run Bash")
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: h.card).contains("Cody wants to run Bash"))
    }

    func testASubagentRequestNamesTheSubagentAndItsParent() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.subagent())
        XCTAssertEqual(h.card.listing.agent, "redd (subagent of Cody)")
        XCTAssertTrue(h.card.listing.headline.hasPrefix("redd (subagent of Cody)"), h.card.listing.headline)
    }

    func testTheWorkingDirectoryIsShownWithHomeAsATilde() throws {
        let cwd = NSHomeDirectory() + "/Code/nostromo-wt/ba3"
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(cwd: cwd))
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: h.card).contains("In: ~/Code/nostromo-wt/ba3"),
                      "\(ApprovalTestViews.labelTexts(in: h.card))")
    }

    func testAWorkingDirectoryOutsideHomeIsShownInFull() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(cwd: "/private/var/work/x"))
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: h.card).contains("In: /private/var/work/x"))
    }

    func testTheReasonIsShownAsTheDaemonSentItWithoutEscapeBytes() throws {
        // The daemon strips ANSI from the reason and the description; what the card shows has no escape byte.
        let request = try ApprovalTestRequests.bash(ApprovalTestRequests.simpleRmCommand,
                                                    reasonText: "Dangerous command matched your rule",
                                                    description: "remove build")
        let h = ApprovalCardHarness(self, request: request)
        let texts = ApprovalTestViews.labelTexts(in: h.card)
        XCTAssertTrue(texts.contains("Why: Dangerous command matched your rule"), "\(texts)")
        XCTAssertEqual(h.card.listing.reasonLine, "Dangerous command matched your rule")
        for text in texts {
            XCTAssertFalse(text.unicodeScalars.contains("\u{1B}"), "escape byte in `\(text)`")
        }
        XCTAssertFalse(h.card.inputView.textView.string.unicodeScalars.contains("\u{1B}"))
    }

    func testTheBannerCountsTheInvisibleAndDirectionChangingCharacters() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.bidi())
        XCTAssertEqual(h.card.listing.invisibleCount, 6)
        XCTAssertEqual(h.card.listing.banner, "This command contains 6 invisible or direction-changing characters.")
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: h.card).contains("This command contains 6 invisible or direction-changing characters."))
    }

    func testThereIsNoBannerWhenNothingIsInvisible() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        XCTAssertNil(h.card.listing.banner)
        XCTAssertFalse(ApprovalTestViews.labelTexts(in: h.card).contains { $0.contains("invisible") })
    }

    func testACompoundCommandHasATwoCommandsLine() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.compound())
        XCTAssertEqual(h.card.listing.commandCount, 2)
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: h.card).contains("2 commands"))
    }

    func testASingleCommandHasNoCommandCountLine() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        XCTAssertFalse(ApprovalTestViews.labelTexts(in: h.card).contains { $0.hasSuffix(" commands") || $0 == "1 command" })
    }

    func testAgentSaysIsLabelledMutedAndBelowTheInput() throws {
        let description = "Clean build outputs before the release build"
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.compound(description: description))

        let label = try XCTUnwrap(ApprovalTestViews.label(startingWith: "Agent says:", in: h.card),
                                  "the agent's description is shown, labelled: \(ApprovalTestViews.labelTexts(in: h.card))")
        XCTAssertTrue(label.stringValue.contains(description))
        XCTAssertTrue(ApprovalTestColors.same(label.textColor, ApprovalPalette.mutedText), "muted, not command-coloured")
        XCTAssertTrue(h.card.isFlipped, "precondition: y grows downward in the card")
        XCTAssertGreaterThanOrEqual(label.frame.minY, h.card.inputView.frame.maxY, "below the exact input, never in its place")
        XCTAssertFalse(h.card.inputView.textView.string.contains(description), "the claim is not part of the input")
    }

    func testThereIsNoAgentSaysLabelWithoutADescription() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        XCTAssertNil(ApprovalTestViews.label(startingWith: "Agent says", in: h.card))
    }

    func testMarkdownAndLinksInTheInputAreShownLiterally() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.markdown())
        let view = h.card.inputView
        let storage = try XCTUnwrap(view.textView.textStorage)

        XCTAssertEqual(view.textView.string, ApprovalTestRequests.markdownCommand)
        var links = 0
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { links += 1 }
        }
        XCTAssertEqual(links, 0, "no link attribute: the text is never a link")
        let bold = range(of: "**bold**", in: view)
        let plain = range(of: "echo", in: view)
        let boldFont = try XCTUnwrap(attribute(.font, at: bold.location + 2, in: view) as? NSFont)
        let plainFont = try XCTUnwrap(attribute(.font, at: plain.location, in: view) as? NSFont)
        XCTAssertEqual(boldFont, plainFont, "`**bold**` is not set in bold")
        XCTAssertFalse(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
    }

    func testAnMCPRequestShowsItsToolAndItsFullInputAsJSONLines() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.mcp())
        XCTAssertEqual(h.card.listing.headline, "Cody wants to use mcp__slack__post_message", "server and tool in the name")
        XCTAssertEqual(h.card.inputView.displayedLines, ApprovalTestRequests.mcpJSONLines)
        XCTAssertTrue(h.card.model.isVerified)
    }

    func testAnEditShowsThePathThenTheDiff() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.edit(), maxHeight: 700)
        let view = h.card.inputView
        XCTAssertEqual(h.card.listing.headline, "Cody wants to edit a file")
        XCTAssertEqual(view.displayedLines.first, ApprovalTestRequests.editPath, "the path first")
        XCTAssertEqual(Array(view.displayedLines.dropFirst()), ApprovalTestRequests.editDiff.map { $0.text }, "then every diff line")

        let added = range(of: "    let b = 3;", in: view)
        let deleted = range(of: "    let b = 2;", in: view)
        XCTAssertTrue(ApprovalTestColors.same(attribute(.foregroundColor, at: added.location, in: view), ApprovalPalette.diffAdd), "additions in the add colour")
        XCTAssertTrue(ApprovalTestColors.same(attribute(.foregroundColor, at: deleted.location, in: view), ApprovalPalette.diffDelete), "deletions in the delete colour")
    }

    func testAWriteShowsThePathAndTheFullContent() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.write(), maxHeight: 700)
        let view = h.card.inputView
        XCTAssertEqual(h.card.listing.headline, "Cody wants to write a file")
        XCTAssertEqual(view.displayedLines, [ApprovalTestRequests.writePath] + ApprovalTestRequests.writeContent.components(separatedBy: "\n"))
    }

    // MARK: Invisible and non-ASCII rendering (23, 26)

    func testInvisibleCharactersAreShownAsWarningColouredTokensWhereTheySit() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.bidi())
        let view = h.card.inputView
        let token = ApprovalTestRequests.token(for: "\u{202E}")
        XCTAssertEqual(token, "⟨U+202E RLO⟩", "precondition: the token as the daemon writes it")

        XCTAssertTrue(view.textView.string.hasPrefix("echo \(token)txt.exe"), "the token sits where the character was: \(view.textView.string)")
        let at = range(of: token, in: view)
        for offset in at.location ..< NSMaxRange(at) {
            XCTAssertTrue(ApprovalTestColors.same(attribute(.foregroundColor, at: offset, in: view), ApprovalPalette.warning),
                          "the token is in the warning colour (offset \(offset))")
        }
        let tip = try XCTUnwrap(attribute(.toolTip, at: at.location, in: view) as? String)
        XCTAssertTrue(tip.contains("U+202E"), tip)
        let echo = range(of: "echo", in: view)
        XCTAssertTrue(ApprovalTestColors.same(attribute(.foregroundColor, at: echo.location, in: view), ApprovalPalette.commandText),
                      "ordinary text is in the command colour")
    }

    func testANonASCIILookAlikeIsTintedAndItsTooltipNamesTheCodePoint() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.cyrillic())
        let view = h.card.inputView
        let em = range(of: "\u{043C}", in: view)

        XCTAssertTrue(ApprovalTestColors.same(attribute(.foregroundColor, at: em.location, in: view), ApprovalPalette.nonAscii))
        let tip = try XCTUnwrap(attribute(.toolTip, at: em.location, in: view) as? String)
        XCTAssertTrue(tip.contains("U+043C"), tip)
        XCTAssertEqual(tip, "U+043C CYRILLIC SMALL LETTER EM")
        let r = range(of: "r", in: view)
        XCTAssertTrue(ApprovalTestColors.same(attribute(.foregroundColor, at: r.location, in: view), ApprovalPalette.commandText),
                      "the plain letter next to it is not tinted")
        XCTAssertEqual(h.card.listing.nonAsciiCount, 1)
    }

    func testSeparatorsAreHighlighted() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.compound())
        let view = h.card.inputView
        let amp = range(of: "&&", in: view)
        XCTAssertTrue(ApprovalTestColors.same(attribute(.foregroundColor, at: amp.location, in: view), ApprovalPalette.separator))
        XCTAssertEqual(h.card.listing.lines.first?.separators, ["&&"])
    }

    func testEachPartOfACompoundCommandIsItsOwnNumberedLine() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.compound())
        let view = h.card.inputView
        XCTAssertEqual(view.displayedLines, ["rm -rf build/ &&", " rm -rf target/debug/incremental"])
        XCTAssertEqual(view.lineNumbers, [1, 2])
        XCTAssertEqual(h.card.listing.lines.map(\.number), [1, 2])
    }

    func testAHereDocShowsAllThreeHundredLinesAndLine287AppearsAfterScrolling() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let view = h.card.inputView

        XCTAssertEqual(view.displayedLines.count, 300)
        XCTAssertEqual(view.lineNumbers, Array(1 ... 300))
        XCTAssertEqual(view.displayedLines, ApprovalTestRequests.heredocCommandLines, "every line, none elided")
        XCTAssertEqual(view.displayedLines[286], ApprovalTestRequests.heredocSecondCommand, "the second command is line 287")
        XCTAssertEqual(h.card.listing.commandCount, 15)
        XCTAssertFalse(view.visibleLineNumbers.contains(287), "precondition: it starts scrolled to the top")

        let line = NSRange(location: start(ofLine: 286, in: view), length: view.displayedLines[286].utf16.count)
        view.textView.scrollRangeToVisible(line)
        XCTAssertTrue(view.visibleLineNumbers.contains(287), "line 287 is on screen after scrolling to it: \(view.visibleLineNumbers)")

        view.scrollToEnd()
        XCTAssertTrue(view.visibleLineNumbers.contains(300))
    }

    func testAHereDocBodyAndItsTerminatorAreSetOffFromTheCommand() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let view = h.card.inputView
        let opener = start(ofLine: 0, in: view), body = start(ofLine: 1, in: view), terminator = start(ofLine: 285, in: view)

        XCTAssertNil(attribute(.backgroundColor, at: opener, in: view), "the command line is not set off")
        XCTAssertTrue(ApprovalTestColors.same(attribute(.backgroundColor, at: body, in: view), ApprovalPalette.heredocFill))
        XCTAssertTrue(ApprovalTestColors.same(attribute(.backgroundColor, at: terminator, in: view), ApprovalPalette.heredocFill))
        let style = attribute(.paragraphStyle, at: body, in: view) as? NSParagraphStyle
        XCTAssertGreaterThan(style?.firstLineHeadIndent ?? 0, 0, "the body is indented")
    }

    func testEveryLineLongOrShortIsKeptWhole() throws {
        let long = "echo " + String(repeating: "abcdefghij", count: 60)
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.bash(long))
        XCTAssertEqual(h.card.inputView.displayedLines, [long], "wrapped on screen, never cut")
    }

    // MARK: What the listing reports (22, 23)

    func testTheListingReportsWhatTheViewsHold() throws {
        let description = "Clean build outputs"
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.compound(description: description))
        let listing = h.card.listing

        XCTAssertEqual(listing.requestID, "req-1")
        XCTAssertEqual(listing.focus, "cody-1")
        XCTAssertEqual(listing.agent, "Cody")
        XCTAssertEqual(listing.tool, "Bash")
        XCTAssertEqual(listing.headline, "Cody wants to run Bash")
        XCTAssertEqual(listing.input, ApprovalTestRequests.compoundCommand)
        XCTAssertEqual(listing.lines.map(\.text), h.card.inputView.displayedLines)
        XCTAssertEqual(listing.lines.map(\.number), [1, 2])
        XCTAssertEqual(listing.commandCount, 2)
        XCTAssertEqual(listing.invisibleCount, 0)
        XCTAssertEqual(listing.reasonLine, "your rule Bash(rm:*) in ~/.claude/settings.json")
        XCTAssertFalse(listing.defaultToNoKind)
        XCTAssertEqual(listing.state, "pending")
        XCTAssertNil(listing.banner)
    }

    func testTheListingsOptionsAreTheButtonsWithTheirLabelsAndEnabledFlags() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)

        XCTAssertEqual(h.card.listing.options, [
            ApprovalCardListing.Option(id: "deny", enabled: true, label: "Deny"),
            ApprovalCardListing.Option(id: "deny_with_note", enabled: true, label: "Deny with a note…"),
            ApprovalCardListing.Option(id: "deny_and_stop", enabled: true, label: "Deny & stop"),
            ApprovalCardListing.Option(id: "allow_once", enabled: false, label: "Scroll to the end to allow"),
        ])

        h.card.inputView.scrollToEnd()

        XCTAssertEqual(h.card.listing.options.last, ApprovalCardListing.Option(id: "allow_once", enabled: true, label: "Allow once"))
    }

    func testTheListingsOptionsAreDisabledOnceAnAnswerIsOnItsWay() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        press(h.card.denyButton)
        h.sync()
        XCTAssertTrue(h.card.listing.options.allSatisfy { !$0.enabled }, "\(h.card.listing.options)")
    }

    func testTheListingsSecondsLeftFollowTheDeadline() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        h.card.countdown.tick()
        XCTAssertTrue((890 ... 900).contains(h.card.listing.secondsLeft), "\(h.card.listing.secondsLeft)")
        XCTAssertEqual(h.card.countdown.label.stringValue, ApprovalCountdown.label(seconds: h.card.countdown.secondsLeft))

        let expired = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(deadlineAtMs: 1))
        expired.card.countdown.tick()
        XCTAssertEqual(expired.card.listing.secondsLeft, 0)
        XCTAssertEqual(expired.card.countdown.label.stringValue, "denies in 0:00")
    }

    func testTheListingIsSerialisableAsJSON() throws {
        for request in [try ApprovalTestRequests.compound(description: "d"), try ApprovalTestRequests.bidi(),
                        try ApprovalTestRequests.heredoc300(), try ApprovalTestRequests.simpleRm()] {
            let h = ApprovalCardHarness(self, request: request, maxHeight: 300)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(h.card.listing.jsonObject), "the listing must be serialisable")
            let data = try JSONSerialization.data(withJSONObject: h.card.listing.jsonObject)
            let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(back["request_id"] as? String, "req-1")
            XCTAssertEqual(back["focus"] as? String, "cody-1")
        }
    }

    func testTheDisplayedInputWithItsTokensPutBackIsTheReceivedInputForEveryFixture() throws {
        let fixtures: [(String, ApprovalRequestWire, String)] = [
            ("simple_rm", try ApprovalTestRequests.simpleRm(), ApprovalTestRequests.simpleRmCommand),
            ("compound", try ApprovalTestRequests.compound(), ApprovalTestRequests.compoundCommand),
            ("heredoc_300", try ApprovalTestRequests.heredoc300(), ApprovalTestRequests.heredoc300Command),
            ("bidi", try ApprovalTestRequests.bidi(), ApprovalTestRequests.bidiCommand),
            ("cyrillic", try ApprovalTestRequests.cyrillic(), ApprovalTestRequests.cyrillicCommand),
            ("zero_width", try ApprovalTestRequests.zeroWidth(), ApprovalTestRequests.zeroWidthCommand),
            ("tab_and_cr", try ApprovalTestRequests.tabAndCR(), ApprovalTestRequests.tabAndCRCommand),
            ("markdown", try ApprovalTestRequests.markdown(), ApprovalTestRequests.markdownCommand),
        ]
        for (name, request, command) in fixtures {
            let h = ApprovalCardHarness(self, request: request, maxHeight: 300)
            let listing = h.card.listing

            XCTAssertEqual(ApprovalTestRequests.restoringInvisibles(in: listing.input), command, "\(name): the listing's input")

            // And through the view itself: its lines, joined as the original was, with tokens put back.
            var fromView = ""
            for (i, text) in h.card.inputView.displayedLines.enumerated() {
                if i > 0 && !h.card.model.lines[i].cont { fromView += "\n" }
                fromView += text
            }
            XCTAssertEqual(ApprovalTestRequests.restoringInvisibles(in: fromView), command, "\(name): the text view")
            XCTAssertEqual(listing.invisibleCount, command.unicodeScalars.filter { $0 != "\n" && ApprovalTestRequests.isInvisible($0) }.count, name)
        }
    }

    // MARK: Other fields of a Bash input

    private func commandText(fromViewLinesOf card: ApprovalCardView) -> String {
        var text = ""
        for (i, line) in card.inputView.displayedLines.prefix(card.model.lines.count).enumerated() {
            if i > 0 && !card.model.lines[i].cont { text += "\n" }
            text += line
        }
        return text
    }

    func testAnExtraFieldOfABashInputIsShownAfterTheCommand() throws {
        let request = try ApprovalTestRequests.bashWithExtras(ApprovalTestRequests.simpleRmCommand,
                                                              extras: ["dangerouslyDisableSandbox": true])
        let h = ApprovalCardHarness(self, request: request, maxHeight: 600)
        let view = h.card.inputView

        XCTAssertGreaterThan(h.card.model.allLines.count, h.card.model.lines.count, "precondition: there are extra lines")
        XCTAssertEqual(view.displayedLines.count, h.card.model.allLines.count, "every line the model has is in the view")
        XCTAssertTrue(view.textView.string.contains("dangerouslyDisableSandbox"), view.textView.string)
        XCTAssertTrue(view.textView.string.contains("true"))
        XCTAssertEqual(Array(view.displayedLines.prefix(1)), [ApprovalTestRequests.simpleRmCommand], "the command comes first")
    }

    func testTheListingNumbersTheExtraLinesAfterTheCommandButItsInputIsOnlyTheCommand() throws {
        let request = try ApprovalTestRequests.bashWithExtras(ApprovalTestRequests.compoundCommand,
                                                              extras: ["dangerouslyDisableSandbox": true])
        let h = ApprovalCardHarness(self, request: request, maxHeight: 600)
        let listing = h.card.listing
        let total = h.card.model.allLines.count

        XCTAssertEqual(listing.lines.count, total)
        XCTAssertEqual(listing.lines.map { $0.number }, Array(1 ... total), "the extra lines are numbered after the command lines")
        XCTAssertEqual(listing.lines.map { $0.text }, h.card.inputView.displayedLines)
        XCTAssertTrue(listing.lines.dropFirst(h.card.model.lines.count).contains { $0.text.contains("dangerouslyDisableSandbox") })
        XCTAssertEqual(listing.input, ApprovalTestRequests.compoundCommand, "the input is the command, nothing else")
        XCTAssertEqual(commandText(fromViewLinesOf: h.card), ApprovalTestRequests.compoundCommand)
        XCTAssertTrue(h.card.model.isVerified, "extra fields are not part of the round-trip check of the command")
    }

    func testInvisibleCharactersInAnExtraValueAreCountedAndBannered() throws {
        let request = try ApprovalTestRequests.bashWithExtras(ApprovalTestRequests.simpleRmCommand,
                                                              extras: ["note": "a\u{202E}b"])
        let h = ApprovalCardHarness(self, request: request, maxHeight: 600)

        XCTAssertEqual(h.card.model.invisibleCount, 1)
        XCTAssertEqual(h.card.listing.invisibleCount, 1)
        XCTAssertEqual(h.card.listing.banner, "This command contains 1 invisible or direction-changing character.")
        XCTAssertTrue(h.card.inputView.textView.string.contains("\u{27E8}U+202E RLO\u{27E9}"), "shown as a token, not as the character")
        XCTAssertFalse(h.card.inputView.textView.string.unicodeScalars.contains("\u{202E}"))
    }

    func testAllowWaitsForTheLastExtraLine() throws {
        var extras: [String: Any] = [:]
        for n in 0 ..< 40 { extras["k\(String(format: "%02d", n))"] = n }
        let request = try ApprovalTestRequests.bashWithExtras(ApprovalTestRequests.simpleRmCommand, extras: extras)
        let h = ApprovalCardHarness(self, request: request, maxHeight: 300)
        let view = h.card.inputView
        let last = h.card.model.allLines.count

        XCTAssertGreaterThan(last, 40)
        XCTAssertFalse(view.visibleLineNumbers.contains(last), "precondition: the last extra line is below the fold")
        XCTAssertFalse(view.hasShownEveryLine, "the command alone fitting is not enough")
        XCTAssertEqual(h.card.allowButton?.isEnabled, false)
        XCTAssertEqual(h.card.allowButton?.title, "Scroll to the end to allow")

        view.scrollToEnd()

        XCTAssertTrue(view.visibleLineNumbers.contains(last))
        XCTAssertTrue(view.hasShownEveryLine)
        XCTAssertEqual(h.card.allowButton?.isEnabled, true)
        XCTAssertEqual(view.displayedLines.last, "}")
    }

    // MARK: Left to right, always

    func testEveryRunOfTheInputIsLeftToRightEvenWithRightToLeftLetters() throws {
        let request = try ApprovalTestRequests.bash("cd \u{05D0}/../\u{05D1}\nls \u{05D1}")
        let h = ApprovalCardHarness(self, request: request)
        let view = h.card.inputView
        let storage = try XCTUnwrap(view.textView.textStorage)
        let expected = NSWritingDirection.leftToRight.rawValue | NSWritingDirectionFormatType.override.rawValue
        let text = storage.string as NSString

        XCTAssertGreaterThan(h.card.listing.nonAsciiCount, 0, "precondition: there are right-to-left letters")
        for offset in 0 ..< storage.length where text.character(at: offset) != 0x0A {
            let direction = storage.attribute(.writingDirection, at: offset, effectiveRange: nil) as? [Int]
            XCTAssertEqual(direction, [expected], "writing direction override at offset \(offset)")
            let style = storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(style?.baseWritingDirection, .leftToRight, "paragraph direction at offset \(offset)")
        }
    }

    // MARK: The gutter on a trailing empty line

    func testACommandEndingInANewlineHasAFinalNumberedEmptyLine() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.bash("ls\n"))
        let view = h.card.inputView
        XCTAssertEqual(view.displayedLines, ["ls", ""])
        XCTAssertEqual(view.lineNumbers, [1, 2], "the empty last line has its own number")
        XCTAssertEqual(view.lineNumbers.last, h.card.model.lines.last?.number)
        XCTAssertEqual(h.card.listing.input, "ls\n")
    }

    // MARK: A short pane, and the hard cap

    func testTheCardAlwaysFitsInsideAPaneOnlyTwoHundredAndSixtyPointsTall() throws {
        var lines = (1 ... 30).map { "echo line \($0)" }
        lines[10] = "echo \u{202E}evil"
        let request = try ApprovalTestRequests.bash(lines.joined(separator: "\n"), cwd: NSHomeDirectory() + "/Code/x",
                                                    description: "Print some lines")
        let h = ApprovalOverlayHostTests.hostHarness(self, size: NSSize(width: 700, height: 260))
        h.arrive(request)
        let card = try XCTUnwrap(h.host.card)
        let bottom = ApprovalOverlayHost.bottomInset

        XCTAssertNotNil(card.listing.banner, "precondition: a banner and a description take room")
        XCTAssertGreaterThanOrEqual(card.frame.minY, bottom - 0.5)
        XCTAssertLessThanOrEqual(card.frame.maxY, h.host.bounds.height - bottom + 0.5, "nothing is pushed out of the pane")
        XCTAssertLessThan(card.inputView.frame.height, card.inputView.contentHeight(forWidth: card.inputView.frame.width),
                          "the input gave way")
        XCTAssertEqual(card.denyButton.superview?.isHidden, false)
    }

    func testThePreferredHeightHonoursTheHardMaximumAndDefaultsToNone() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 400)
        let unlimited = h.card.preferredHeight(forWidth: 560, maxHeight: 400)
        XCTAssertEqual(h.card.preferredHeight(forWidth: 560, maxHeight: 400, hardMaxHeight: .infinity), unlimited)
        XCTAssertLessThanOrEqual(h.card.preferredHeight(forWidth: 560, maxHeight: 100, hardMaxHeight: 240), 240.5)
    }

    func testPressingDenyWithNoConnectionSendsNothingAndLeavesTheButtonsEnabled() throws {
        var online = false
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(), canSend: { online })

        press(h.card.denyButton)
        h.sync()

        XCTAssertTrue(h.recorder.sent.isEmpty)
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, ApprovalAnswerState.pending)
        XCTAssertTrue(h.card.denyButton.isEnabled)
        XCTAssertEqual(h.card.denyAndStopButton?.isEnabled, true)
        XCTAssertEqual(h.card.allowButton?.isEnabled, true)

        online = true
        press(h.card.denyButton)
        XCTAssertEqual(h.recorder.sent.map { $0.decision }, [ApprovalDecisionWire(kind: .deny)], "pressing again works once connected")
        press(h.card.denyButton)
        XCTAssertEqual(h.recorder.sent.count, 1)
    }

    // MARK: Only a scroll that moves the clip counts (and only a person's)

    func testALayoutOnlyChangeAfterASyntheticScrollDoesNotEnableAllow() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let view = h.card.inputView

        SyntheticInputGate.begin()
        scrollClip(of: view, toBottom: true)
        SyntheticInputGate.end()
        XCTAssertTrue(view.visibleLineNumbers.contains(300), "precondition: the clip is at the end")
        XCTAssertFalse(view.hasShownEveryLine, "precondition: a synthetic scroll did not count")
        let originY = view.contentView.bounds.origin.y

        view.setFrameSize(NSSize(width: view.frame.width - 24, height: view.frame.height))
        view.layoutSubtreeIfNeeded()
        view.setFrameSize(NSSize(width: view.frame.width + 24, height: view.frame.height))
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.contentView.bounds.origin.y, originY, accuracy: 0.5, "precondition: only the layout changed, not the scroll position")
        XCTAssertFalse(view.hasShownEveryLine, "a resize is not a person looking at the end")
        XCTAssertEqual(h.card.allowButton?.isEnabled, false)
    }

    func testALayoutDrivenClipMoveAfterASyntheticScrollDoesNotCountWhenNoPersonEventIsCurrent() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let view = h.card.inputView
        view.isPersonEvent = { _ in false }

        SyntheticInputGate.begin()
        scrollClip(of: view, toBottom: true)
        SyntheticInputGate.end()
        XCTAssertFalse(view.hasShownEveryLine, "precondition")

        // A clamp after a layout pass moves the clip outside any person's event.
        scrollClip(of: view, toBottom: false)
        scrollClip(of: view, toBottom: true)
        view.setFrameSize(NSSize(width: view.frame.width - 24, height: view.frame.height))
        view.layoutSubtreeIfNeeded()

        XCTAssertFalse(view.hasShownEveryLine, "only a person's event lets the clip count again")
        XCTAssertEqual(h.card.allowButton?.isEnabled, false)
    }

    // MARK: What counts as a person's event (the default)

    func testTheDefaultPersonEventRuleRefusesNoEventAMovedPointerAndSyntheticEvents() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let view = h.card.inputView

        XCTAssertFalse(view.isPersonEvent(nil), "no event: a layout pass")
        XCTAssertFalse(view.isPersonEvent(try GestureFixtures.marked(GestureFixtures.key(.keyDown, in: h.window))),
                       "a key event app-control stamped")
        XCTAssertFalse(view.isPersonEvent(try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseDown, in: h.window))),
                       "a click app-control stamped")
        XCTAssertFalse(view.isPersonEvent(GestureFixtures.mouse(.mouseMoved, in: h.window)), "the pointer moving is not looking")
        SyntheticInputGate.begin()
        defer { SyntheticInputGate.end() }
        XCTAssertFalse(view.isPersonEvent(GestureFixtures.key(.keyDown, in: h.window)), "anything while app-control runs a request")
    }

    func testTheDefaultPersonEventRuleAcceptsAKeyPressAndAClick() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let view = h.card.inputView

        XCTAssertTrue(view.isPersonEvent(GestureFixtures.key(.keyDown, in: h.window, characters: " ", keyCode: 49)))
        XCTAssertTrue(view.isPersonEvent(GestureFixtures.mouse(.leftMouseDown, in: h.window)))
        XCTAssertTrue(view.isPersonEvent(GestureFixtures.mouse(.leftMouseUp, in: h.window)))
    }

    func testAPersonsScrollThatShowsTheEndCountsAfterALayoutOnlyChange() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let view = h.card.inputView

        SyntheticInputGate.begin()
        scrollClip(of: view, toBottom: true)
        SyntheticInputGate.end()
        view.setFrameSize(NSSize(width: view.frame.width - 24, height: view.frame.height))
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.hasShownEveryLine, "precondition")

        view.isPersonEvent = { _ in true }   // the scrolls below stand for a person's wheel
        scrollClip(of: view, toBottom: false)
        scrollClip(of: view, toBottom: true)

        XCTAssertTrue(view.hasShownEveryLine)
        XCTAssertEqual(h.card.allowButton?.isEnabled, true)
    }

    // MARK: Accessibility (T-AP2a-4)

    func testTheCardIsAnAccessibilityGroupAnnouncingWhatIsAsked() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.compound())
        XCTAssertTrue(h.card.isAccessibilityElement())
        XCTAssertEqual(h.card.accessibilityRole(), NSAccessibility.Role.group)
        XCTAssertEqual(h.card.accessibilityLabel(), "Approval needed: Cody wants to run Bash, 2 commands")
    }

    func testAllowOnceIsLabelledInFullForVoiceOver() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.compound())
        XCTAssertEqual(h.card.allowButton?.accessibilityLabel(), "Allow once: rm -rf build/ and 1 more command")
    }

    func testEveryButtonHasAnAccessibilityLabelThatIsNotJustItsGlyph() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        for button in [h.card.denyButton, h.card.denyMoreButton, h.card.denyAndStopButton, h.card.allowButton] {
            let label = try XCTUnwrap(button?.accessibilityLabel(), "a button has no label")
            XCTAssertFalse(label.isEmpty)
            XCTAssertNotEqual(label, "▾", "the menu button says what it does")
        }
        XCTAssertEqual(h.card.allowButton?.accessibilityLabel(), "Allow once: rm -rf build/")
    }

    func testVoiceOverReadsInvisibleCharactersByName() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.bidi())
        let spoken = try XCTUnwrap(h.card.inputView.textView.accessibilityValue() as? String)
        XCTAssertTrue(spoken.contains("RIGHT-TO-LEFT OVERRIDE"), spoken)
        XCTAssertTrue(spoken.contains("U+202E"), spoken)
        XCTAssertFalse(spoken.contains("\u{202E}"), "the character itself is not spoken, its name is")
    }

    func testTheInputIsReadLineByLine() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.compound())
        let spoken = try XCTUnwrap(h.card.inputView.textView.accessibilityValue() as? String)
        XCTAssertEqual(spoken.components(separatedBy: "\n").count, 2)
    }

    // MARK: Appearance and the countdown's timer

    func testTheCardAndItsInputArePinnedToDarkAqua() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        XCTAssertEqual(h.card.appearance?.name, .darkAqua)
        XCTAssertEqual(h.card.inputView.appearance?.name, .darkAqua)
    }

    func testTheCountdownRunsWhileTheCardIsInAWindowAndStopsWhenItLeaves() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm())
        XCTAssertTrue(h.card.countdown.isRunning, "ticking while it is on screen")

        h.card.removeFromSuperview()

        XCTAssertFalse(h.card.countdown.isRunning, "a gone card leaves nothing ticking")
    }
}

// MARK: - The overlay host

final class ApprovalOverlayHostTests: XCTestCase {

    fileprivate static func hostHarness(_ testCase: XCTestCase, size: NSSize) -> HostHarness {
        HostHarness(testCase, size: size)
    }

    fileprivate final class HostHarness {
        let recorder: ApprovalRecorder
        let store: ApprovalStore
        let window: NSWindow
        let host: ApprovalOverlayHost

        init(_ testCase: XCTestCase, size: NSSize = NSSize(width: 640, height: 500), tag: String = "cody-1",
             store provided: ApprovalStore? = nil, window providedWindow: NSWindow? = nil,
             permit: ApprovalCardView.GesturePermit? = ApprovalCardHarness.humanPermit,
             armDelay: TimeInterval = 0, reduceMotion: Bool = true, windowID: String = "w-test") {
            let recorder = ApprovalRecorder()
            let store = provided ?? recorder.makeStore()
            let window: NSWindow = providedWindow ?? makeRigWindow(testCase, size: size)
            let host = ApprovalOverlayHost(tag: tag, store: store, windowID: { windowID }, permit: permit,
                                           armDelay: armDelay, isOnScreen: { true }, reduceMotion: { reduceMotion })
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView!.addSubview(host)
            self.recorder = recorder
            self.store = store
            self.window = window
            self.host = host
            layout()
        }

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
        }

        func arrive(_ request: ApprovalRequestWire) {
            store.handle(.request(request))
            layout()
        }
    }

    // MARK: Arrival (22)

    func testAnArrivingRequestShowsACardAndItsListingInTheSameRunLoopTurn() throws {
        let h = HostHarness(self)
        XCTAssertNil(h.host.card)
        XCTAssertTrue(h.host.listings.isEmpty)

        h.store.handle(.request(try ApprovalTestRequests.compound()))

        XCTAssertNotNil(h.host.card, "the card is there synchronously: no timer, no later turn")
        XCTAssertEqual(h.host.listings.count, 1)
        XCTAssertEqual(h.host.listings.first?.requestID, "req-1")
        XCTAssertEqual(h.host.listings.first?.input, ApprovalTestRequests.compoundCommand)
        XCTAssertTrue(h.host.card?.superview === h.host)
    }

    func testTheListingMatchesTheCardOnScreen() throws {
        let h = HostHarness(self)
        h.arrive(try ApprovalTestRequests.compound(description: "d"))
        let card = try XCTUnwrap(h.host.card)
        XCTAssertEqual(h.host.listings, [card.listing])
        XCTAssertEqual(h.host.listings.first?.lines.map(\.text), card.inputView.displayedLines)
    }

    func testARequestForAnotherFocusDoesNotShowACard() throws {
        let h = HostHarness(self)
        h.arrive(try ApprovalTestRequests.simpleRm(tag: "someone-else"))
        XCTAssertNil(h.host.card)
        XCTAssertTrue(h.host.listings.isEmpty)
    }

    func testARequestAlreadyInTheStoreShowsWhenTheHostIsBuilt() throws {
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore()
        store.handle(.request(try ApprovalTestRequests.simpleRm()))
        let h = HostHarness(self, store: store)
        XCTAssertEqual(h.host.listings.first?.requestID, "req-1", "a pane built after the request arrived still shows it")
    }

    // MARK: Geometry

    func testTheHostOnlyTakesClicksInsideTheCard() throws {
        let h = HostHarness(self)
        XCTAssertNil(h.host.hitTest(NSPoint(x: 100, y: 100)), "no card, no hit: every click goes to the transcript")

        h.arrive(try ApprovalTestRequests.simpleRm())
        let card = try XCTUnwrap(h.host.card)

        let inside = NSPoint(x: card.frame.midX, y: card.frame.minY + 4)
        let hit = try XCTUnwrap(h.host.hitTest(inside), "a point inside the card hits the card or one of its views")
        XCTAssertTrue(hit.isDescendant(of: card))
        XCTAssertNil(h.host.hitTest(NSPoint(x: card.frame.midX, y: card.frame.minY - 4)), "the gap under the card")
        XCTAssertNil(h.host.hitTest(NSPoint(x: card.frame.minX - 6, y: card.frame.midY)), "the margin beside the card")
        XCTAssertNil(h.host.hitTest(NSPoint(x: card.frame.midX, y: h.host.bounds.maxY - 4)), "the transcript above it")
    }

    func testTheCardIsBottomAnchoredAndSpansTheTranscriptColumn() throws {
        let h = HostHarness(self, size: NSSize(width: 700, height: 500))
        h.arrive(try ApprovalTestRequests.simpleRm())
        let frame = try XCTUnwrap(h.host.card).frame

        XCTAssertEqual(frame.minY, ApprovalOverlayHost.bottomInset, accuracy: 0.5, "8 pt above the bottom")
        XCTAssertEqual(ApprovalOverlayHost.bottomInset, 8)
        XCTAssertEqual(frame.minX, 12, accuracy: 0.5, "the transcript column's leading margin")
        XCTAssertEqual(h.host.bounds.maxX - frame.maxX, 24, accuracy: 0.5, "a trailing margin that clears the scroller")
        XCTAssertEqual(frame.width, 700 - 12 - 24, accuracy: 0.5)
    }

    func testTheCardIsNeverTallerThanSixtyPercentOfThePaneEvenForAThreeHundredLineInput() throws {
        let h = HostHarness(self, size: NSSize(width: 700, height: 500))
        h.arrive(try ApprovalTestRequests.heredoc300())
        let card = try XCTUnwrap(h.host.card)

        XCTAssertLessThanOrEqual(card.frame.height, 500 * 0.6 + 0.5)
        XCTAssertGreaterThan(card.frame.height, 150, "and it uses most of that room rather than collapsing")
        XCTAssertFalse(card.inputView.hasShownEveryLine, "the rest is reached by scrolling inside the card")
    }

    func testTheCardKeepsItsRoomWhenThePaneIsResized() throws {
        let h = HostHarness(self, size: NSSize(width: 700, height: 500))
        h.arrive(try ApprovalTestRequests.heredoc300())
        h.host.setFrameSize(NSSize(width: 500, height: 400))
        h.layout()
        let card = try XCTUnwrap(h.host.card)
        XCTAssertEqual(card.frame.width, 500 - 12 - 24, accuracy: 0.5)
        XCTAssertLessThanOrEqual(card.frame.height, 400 * 0.6 + 0.5)
        XCTAssertEqual(card.frame.minY, 8, accuracy: 0.5)
    }

    // MARK: One card for a focus

    func testOnlyTheOldestRequestIsShownAndTheOthersAreCountedAsMore() throws {
        let h = HostHarness(self)
        h.arrive(try ApprovalTestRequests.simpleRm(id: "a"))
        h.arrive(try ApprovalTestRequests.simpleRm(id: "b"))
        let card = try XCTUnwrap(h.host.card)

        XCTAssertEqual(card.request.id, "a", "the oldest")
        XCTAssertEqual(h.host.subviews.count, 1, "one card for the focus")
        XCTAssertEqual(h.host.listings.map(\.requestID), ["a"])
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: card).contains("+1 more"), "\(ApprovalTestViews.labelTexts(in: card))")
    }

    func testTheNextRequestTakesTheCardWhenTheFirstHasEndedAndLeft() throws {
        let h = HostHarness(self)
        h.arrive(try ApprovalTestRequests.simpleRm(id: "a"))
        h.arrive(try ApprovalTestRequests.simpleRm(id: "b"))

        h.store.handle(.resolved(try ApprovalTestRequests.resolved(id: "a", outcome: "denied")))
        XCTAssertEqual(h.host.card?.request.id, "a", "the outcome stays for its two seconds")
        h.recorder.runScheduled()
        h.layout()

        let card = try XCTUnwrap(h.host.card)
        XCTAssertEqual(card.request.id, "b")
        XCTAssertFalse(ApprovalTestViews.labelTexts(in: card).contains { $0.hasSuffix(" more") }, "nothing else is waiting")
        XCTAssertEqual(h.host.subviews.count, 1)
        XCTAssertEqual(card.denyButton.isEnabled, true, "the new card is waiting for an answer")
    }

    // MARK: A short pane

    func testTheCardInANormalPaneStillCapsAtSixtyPercent() throws {
        var lines = (1 ... 30).map { "echo line \($0)" }
        lines[10] = "echo \u{202E}evil"
        let request = try ApprovalTestRequests.bash(lines.joined(separator: "\n"), cwd: NSHomeDirectory() + "/Code/x",
                                                    description: "Print some lines")
        let h = HostHarness(self, size: NSSize(width: 700, height: 600))
        h.arrive(request)
        let card = try XCTUnwrap(h.host.card)
        XCTAssertLessThanOrEqual(card.frame.height, 600 * 0.6 + 0.5)
        XCTAssertGreaterThan(card.frame.height, 600 * 0.6 - 40, "and it uses that room")
    }

    // MARK: Arming delay

    func testACardSwappedInForTheNextRequestIsUnarmedAgain() throws {
        let h = HostHarness(self, armDelay: 0.05)
        h.arrive(try ApprovalTestRequests.simpleRm(id: "a"))
        h.arrive(try ApprovalTestRequests.simpleRm(id: "b"))
        let first = try XCTUnwrap(h.host.card)
        XCTAssertFalse(first.isArmed, "a new card starts unarmed")
        XCTAssertEqual(first.allowButton?.isEnabled, false)
        XCTAssertTrue(waitUntilArmed(first), "the first card never armed")
        XCTAssertEqual(first.allowButton?.isEnabled, true)

        h.store.handle(.resolved(try ApprovalTestRequests.resolved(id: "a", outcome: "denied")))
        h.recorder.runScheduled()
        h.layout()

        let second = try XCTUnwrap(h.host.card)
        XCTAssertEqual(second.request.id, "b")
        XCTAssertFalse(second.isArmed, "the next request's card is unarmed again")
        XCTAssertFalse(second.canAllow)
        XCTAssertEqual(second.allowButton?.isEnabled, false)
        second.allowButton?.performClick(nil)
        XCTAssertTrue(h.recorder.sent.isEmpty)
        XCTAssertTrue(waitUntilArmed(second), "the second card never armed")
        XCTAssertEqual(second.allowButton?.isEnabled, true)
    }

    func testTheHostsDefaultDelayKeepsANewCardUnarmed() throws {
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore()
        let window = makeRigWindow(self, size: NSSize(width: 640, height: 500))
        let host = ApprovalOverlayHost(tag: "cody-1", store: store, windowID: { "w" }, permit: ApprovalCardHarness.humanPermit,
                                       reduceMotion: { true })
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 500)
        window.contentView!.addSubview(host)
        store.handle(.request(try ApprovalTestRequests.simpleRm()))
        window.contentView?.layoutSubtreeIfNeeded()

        let card = try XCTUnwrap(host.card)
        XCTAssertGreaterThan(ApprovalOverlayHost.armDelay, 0)
        XCTAssertFalse(card.isArmed)
        card.allowButton?.performClick(nil)
        XCTAssertTrue(recorder.sent.isEmpty)
        XCTAssertEqual(host.focusTag, "cody-1")
    }

    private func waitUntilArmed(_ card: ApprovalCardView) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !card.isArmed && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return card.isArmed
    }

    // MARK: Answers and endings through the host

    func testAnAnswerPressedInTheHostsCardCarriesTheWindowIDAndAsksTheCardToWait() throws {
        let h = HostHarness(self, windowID: "w-42")
        h.arrive(try ApprovalTestRequests.simpleRm())
        let card = try XCTUnwrap(h.host.card)

        card.denyButton.performClick(nil)

        XCTAssertEqual(h.recorder.sent, [ApprovalRecorder.Sent(requestID: "req-1", decision: ApprovalDecisionWire(kind: .deny), windowID: "w-42")])
        XCTAssertFalse(card.denyButton.isEnabled, "the host showed the card the in-flight state")
        XCTAssertEqual(card.allowButton?.isEnabled, false)
        card.denyButton.performClick(nil)
        XCTAssertEqual(h.recorder.sent.count, 1)
    }

    func testAResolvedRequestShowsItsOutcomeOnTheCardThenTheCardLeavesAfterTheDrop() throws {
        let h = HostHarness(self)
        h.arrive(try ApprovalTestRequests.simpleRm())
        let card = try XCTUnwrap(h.host.card)

        h.store.handle(.resolved(try ApprovalTestRequests.resolved(id: "req-1", outcome: "allowed_once")))

        XCTAssertTrue(h.host.card === card, "the same card shows the outcome in place")
        XCTAssertEqual(h.host.listings.first?.state, "Allowed once")
        XCTAssertTrue(ApprovalTestViews.labelTexts(in: card).contains("Allowed once"))
        XCTAssertFalse(card.denyButton.isEnabled)
        XCTAssertEqual(h.recorder.scheduled.map { $0.delay }, [2])

        h.recorder.runScheduled()

        XCTAssertNil(h.host.card, "with Reduce Motion the card is removed with no animation")
        XCTAssertTrue(h.host.subviews.isEmpty)
        XCTAssertTrue(h.host.listings.isEmpty)
        XCTAssertNil(card.superview)
        XCTAssertFalse(card.countdown.isRunning)
    }

    func testAnotherWindowsAnswerShowsTheOutcomeHereWithoutSendingAnything() throws {
        let h = HostHarness(self)
        h.arrive(try ApprovalTestRequests.simpleRm())
        let card = try XCTUnwrap(h.host.card)

        h.store.handle(.resolved(try ApprovalTestRequests.resolved(id: "req-1", outcome: "denied", byWindow: "w-other")))

        XCTAssertTrue(ApprovalTestViews.labelTexts(in: card).contains("Denied"))
        XCTAssertFalse(card.denyButton.isEnabled)
        XCTAssertEqual(card.allowButton?.isEnabled, false)
        XCTAssertTrue(h.recorder.sent.isEmpty, "this window answered nothing")
        XCTAssertTrue(h.recorder.reports.isEmpty)
    }

    func testAnAnswerRefusedBecauseItArrivedAfterTheTimeoutShowsAlreadyDenied() throws {
        let h = HostHarness(self)
        h.arrive(try ApprovalTestRequests.simpleRm())
        let card = try XCTUnwrap(h.host.card)
        card.denyButton.performClick(nil)

        h.store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "req-1", code: "already_resolved", outcome: "timed_out")))

        XCTAssertTrue(ApprovalTestViews.labelTexts(in: card).contains("Already denied (timed out)"), "\(ApprovalTestViews.labelTexts(in: card))")
        XCTAssertEqual(h.recorder.sent.count, 1)
    }

    func testAnAnswerTheDaemonRefusedAsNotFromTheOperatorAppSaysSoAndLeavesTheCardDisabled() throws {
        let h = HostHarness(self)
        h.arrive(try ApprovalTestRequests.simpleRm())
        let card = try XCTUnwrap(h.host.card)
        card.allowButton?.performClick(nil)

        h.store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "req-1", code: "not_operator_app")))

        XCTAssertNotNil(h.host.card, "the request is still pending: the card stays")
        let state = try XCTUnwrap(h.host.listings.first?.state)
        XCTAssertNotEqual(state, "pending", "the card says the answer was not sent")
        XCTAssertFalse(state.isEmpty)
        XCTAssertFalse(card.denyButton.isEnabled, "nothing is re-sent")
        card.allowButton?.performClick(nil)
        card.denyButton.performClick(nil)
        XCTAssertEqual(h.recorder.sent.count, 1)
    }

    // MARK: Announcement (T-AP2a-4)

    func testTheArrivalIsAnnouncedOnceNoMatterHowOftenTheCardIsBuilt() throws {
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore()
        let first = HostHarness(self, store: store)
        first.arrive(try ApprovalTestRequests.simpleRm())
        XCTAssertFalse(store.claimAnnouncement("req-1"), "the host already claimed the one announcement")

        // The same request in a second window, and the card rebuilt: still nothing left to claim.
        let second = HostHarness(self, store: store)
        XCTAssertNotNil(second.host.card)
        XCTAssertFalse(store.claimAnnouncement("req-1"))
    }

    // MARK: Two windows, one store (T-AP2a-1)

    func testAnAnswerInOneWindowDisablesTheOthersCardAndIsNeverSentTwice() throws {
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore()
        let first = HostHarness(self, store: store, windowID: "w-1")
        let second = HostHarness(self, store: store, windowID: "w-2")
        store.handle(.request(try ApprovalTestRequests.simpleRm()))
        first.layout()
        second.layout()
        let a = try XCTUnwrap(first.host.card), b = try XCTUnwrap(second.host.card)
        XCTAssertFalse(a === b, "each window has its own card")

        a.denyButton.performClick(nil)

        XCTAssertFalse(b.denyButton.isEnabled, "the other window's card sees the answer")
        b.denyButton.performClick(nil)
        b.allowButton?.performClick(nil)
        XCTAssertEqual(recorder.sent.map(\.windowID), ["w-1"], "one answer, from the window that gave it")
    }
}

// MARK: - Contrast (T-AP2a-3)

final class ApprovalPaletteContrastTests: XCTestCase {

    private func ratio(_ fg: NSColor, _ bg: NSColor) -> Double {
        ApprovalTestColors.contrast(ApprovalTestColors.rgb(fg), ApprovalTestColors.rgb(bg))
    }

    /// The ratio of `fg` (with its alpha) painted over `bg`, against `bg`.
    private func ratioOverFill(_ fg: NSColor, fill: NSColor, over bg: NSColor) -> Double {
        let ground = ApprovalTestColors.composite(ApprovalTestColors.rgb(fill), over: ApprovalTestColors.rgb(bg))
        return ApprovalTestColors.contrast(ApprovalTestColors.rgb(fg), ground)
    }

    private func inDarkAqua(_ body: () -> Void) {
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance(body)
    }

    func testCommandTextIsAtLeastSevenToOneOnTheCardAndOnTheInput() {
        inDarkAqua {
            XCTAssertGreaterThanOrEqual(ratio(ApprovalPalette.commandText, ApprovalPalette.cardBackground), 7)
            XCTAssertGreaterThanOrEqual(ratio(ApprovalPalette.commandText, ApprovalPalette.inputBackground), 7)
        }
    }

    func testWarningTokensAreAtLeastFourPointFiveToOneOnTheCardAndOnTheInput() {
        inDarkAqua {
            XCTAssertGreaterThanOrEqual(ratio(ApprovalPalette.warning, ApprovalPalette.cardBackground), 4.5)
            XCTAssertGreaterThanOrEqual(ratio(ApprovalPalette.warning, ApprovalPalette.inputBackground), 4.5)
        }
    }

    func testMutedTextIsAtLeastFourPointFiveToOneOnTheCardAndOnTheInput() {
        inDarkAqua {
            XCTAssertGreaterThanOrEqual(ratio(ApprovalPalette.mutedText, ApprovalPalette.cardBackground), 4.5, "Agent says, the countdown and context lines")
            XCTAssertGreaterThanOrEqual(ratio(ApprovalPalette.mutedText, ApprovalPalette.inputBackground), 4.5)
        }
    }

    func testTheTintedAndHighlightedRunsAreAtLeastFourPointFiveToOneOnTheInput() {
        inDarkAqua {
            XCTAssertGreaterThanOrEqual(ratio(ApprovalPalette.nonAscii, ApprovalPalette.inputBackground), 4.5, "non-ASCII look-alikes")
            XCTAssertGreaterThanOrEqual(ratio(ApprovalPalette.separator, ApprovalPalette.inputBackground), 4.5, "separators")
            XCTAssertGreaterThanOrEqual(ratio(ApprovalPalette.diffAdd, ApprovalPalette.inputBackground), 4.5, "diff additions")
            XCTAssertGreaterThanOrEqual(ratio(ApprovalPalette.diffDelete, ApprovalPalette.inputBackground), 4.5, "diff deletions")
        }
    }

    func testRunsOnTheirOwnHighlightFillAreAtLeastFourPointFiveToOne() {
        inDarkAqua {
            XCTAssertGreaterThanOrEqual(ratioOverFill(ApprovalPalette.warning, fill: ApprovalPalette.warningFill, over: ApprovalPalette.inputBackground), 4.5,
                                        "an invisible token on its fill")
            XCTAssertGreaterThanOrEqual(ratioOverFill(ApprovalPalette.separator, fill: ApprovalPalette.separatorFill, over: ApprovalPalette.inputBackground), 4.5,
                                        "a separator on its fill")
        }
    }

    func testTheColoursDoNotDependOnTheAppearanceSoKeyAndNonKeyWindowsAgree() {
        let pairs: [(NSColor, NSColor)] = [
            (ApprovalPalette.commandText, ApprovalPalette.cardBackground),
            (ApprovalPalette.warning, ApprovalPalette.cardBackground),
            (ApprovalPalette.mutedText, ApprovalPalette.cardBackground),
            (ApprovalPalette.nonAscii, ApprovalPalette.inputBackground),
            (ApprovalPalette.separator, ApprovalPalette.inputBackground),
        ]
        for (fg, bg) in pairs {
            var dark = 0.0
            var light = 0.0
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = ratio(fg, bg) }
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = ratio(fg, bg) }
            XCTAssertEqual(dark, light, accuracy: 0.0001, "the card pins its own colours: they cannot flip with the system")
        }
    }
}

// MARK: - Source scan (33)

final class ApprovalSourceScanTests: XCTestCase {

    private func approvalSources() throws -> [String] {
        let dir = URL(fileURLWithPath: #filePath)        // …/macOS/NostromoTests/ApprovalCardTests.swift
            .deletingLastPathComponent()                  // …/macOS/NostromoTests
            .deletingLastPathComponent()                  // …/macOS
            .appendingPathComponent("Nostromo/UI/Approvals")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
    }

    private func code(of file: String) throws -> [String] {
        try DecisionCoordinatorTests.codeLines(ofSourceAt: "UI/Approvals/\(file)")
    }

    func testTheScanSeesTheCardCodeItGuards() throws {
        let files = try approvalSources()
        for expected in ["ApprovalStore.swift", "ApprovalCardView.swift", "ApprovalInputView.swift",
                         "ApprovalOverlayHost.swift", "ApprovalCountdown.swift"] {
            XCTAssertTrue(files.contains(expected), "\(expected) is missing from UI/Approvals: \(files)")
        }
    }

    func testNothingInTheApprovalUINeverStealsForegroundOrSwitchesFocus() throws {
        for file in try approvalSources() {
            let lines = try code(of: file)
            for needle in DecisionCoordinatorTests.forbiddenForegroundAndFocusCalls {
                let hits = lines.filter { $0.contains(needle) }
                XCTAssertTrue(hits.isEmpty, "UI/Approvals/\(file) must not call `\(needle)`: an approval never steals foreground or focus on arrival: \(hits)")
            }
        }
    }

    func testTheArrivalPathNeverTouchesTheFirstResponder() throws {
        for file in ["ApprovalOverlayHost.swift", "ApprovalStore.swift", "ApprovalCountdown.swift"] {
            let joined = try code(of: file).joined(separator: "\n")
            XCTAssertFalse(joined.contains("makeFirstResponder"), "\(file) is on the arrival path and must not move focus")
            XCTAssertFalse(joined.contains("becomeFirstResponder"), file)
        }
    }

    func testNoButtonIsGivenAKeyEquivalentOrMadeTheDefault() throws {
        let literal = try NSRegularExpression(pattern: "keyEquivalent\\s*(=|:)\\s*\"[^\"]")
        for file in try approvalSources() {
            for line in try code(of: file) {
                let range = NSRange(location: 0, length: (line as NSString).length)
                XCTAssertNil(literal.firstMatch(in: line, range: range), "UI/Approvals/\(file) gives a control a key equivalent: \(line)")
                XCTAssertFalse(line.contains("isDefault"), "UI/Approvals/\(file): \(line)")
                XCTAssertFalse(line.contains("defaultButtonCell"), "UI/Approvals/\(file): \(line)")
            }
        }
    }
}
