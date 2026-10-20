// NostromoKit — ApprovalKinds.swift
//
// What the approval card offers for each kind of request, who it says is asking,
// and the words VoiceOver gets (AP2a). Pure functions over `ApprovalRequestWire`:
// the card (macOS) only draws what these return.
//
// Rules, from the PRD's "Kinds of request with narrower options":
//   * Allow once, Deny and Deny & stop are the whole menu. There are no
//     "remember" options yet, and none are ever modelled here.
//   * `requires_user_interaction`: Deny only, plus the explanation.
//   * Deny is offered on every request, whatever the daemon listed, and Allow
//     once only when the daemon listed it. The card can never offer more than the
//     daemon allows.

import Foundation

/// A button (or menu item) the card can show.
public enum ApprovalControl: String, Equatable, CaseIterable {
    case deny
    case denyWithNote = "deny_with_note"
    case denyAndStop = "deny_and_stop"
    case allowOnce = "allow_once"
}

public struct ApprovalCardOptions: Equatable {

    /// The explanation shown with Deny only when the tool needs Claude Code's own interface.
    public static let requiresInteractionNotice =
        "This tool needs Claude Code's own interface; Nostromo can't approve it"

    /// What is offered, in display order: deny, deny_with_note, deny_and_stop, allow_once.
    public let controls: [ApprovalControl]
    /// Set for `requires_user_interaction`.
    public let notice: String?
    /// Keyboard focus starts on Deny: the CLI said `default_to_no`, or anything the card shows
    /// (the input, its extra fields, the text around it) has invisible or direction-changing characters.
    public let defaultsToDeny: Bool

    public var offersAllowOnce: Bool { controls.contains(.allowOnce) }

    public init(request: ApprovalRequestWire) {
        let listed = Set(request.options)
        let interactionOnly = request.flags.requiresUserInteraction
        var controls: [ApprovalControl] = [.deny]
        if !interactionOnly {
            if listed.contains(.denyWithNote) { controls.append(.denyWithNote) }
            if listed.contains(.denyAndStop) { controls.append(.denyAndStop) }
            if listed.contains(.allowOnce) { controls.append(.allowOnce) }
        }
        self.controls = controls
        self.notice = interactionOnly ? Self.requiresInteractionNotice : nil
        // Counted from the segments too: a frame that under-reports must not lose the Deny default.
        // The model's total also covers the Bash extra-field lines and the text around the input.
        let shown = request.display.lines.reduce(0) { $0 + $1.segments.filter { $0.kind == .invisible }.count }
        let modelCount = ApprovalDisplayModel(request: request).invisibleCount
        self.defaultsToDeny = request.flags.defaultToNo || max(request.display.invisibleCount, shown, modelCount) > 0
    }
}

public enum ApprovalKinds {

    /// `Cody wants to run Bash`, `redd (subagent of Cody) wants to edit a file`,
    /// `Cody wants to use mcp__slack__send_message`.
    public static func headline(for request: ApprovalRequestWire) -> String {
        "\(asker(for: request)) wants to \(toolPhrase(for: request))"
    }

    /// Who is asking: the focus's agent, or `redd (subagent of Cody)`.
    public static func asker(for request: ApprovalRequestWire) -> String {
        let agent = capitalized(request.agent.name)
        guard let sub = request.agent.subagent else { return agent }
        let name = sub.agentType.flatMap { $0.isEmpty ? nil : $0 } ?? sub.agentId
        return "\(name) (subagent of \(agent))"
    }

    /// The tool in plain words: `run Bash`, `edit a file`, `write a file`, `edit a notebook`,
    /// `use mcp__slack__send_message`.
    public static func toolPhrase(for request: ApprovalRequestWire) -> String {
        switch request.toolKind {
        case .bash: return "run \(request.displayName.isEmpty ? "Bash" : request.displayName)"
        case .edit: return "edit a file"
        case .write: return "write a file"
        case .notebookEdit: return "edit a notebook"
        case .mcp: return "use \(request.toolName)"
        case .other: return "use \(request.displayName.isEmpty ? request.toolName : request.displayName)"
        }
    }

    /// What VoiceOver announces once on arrival: `Approval needed: Cody wants to run Bash, 2 commands`.
    public static func announcement(for request: ApprovalRequestWire) -> String {
        var text = "Approval needed: \(headline(for: request))"
        if let count = request.display.commandCount, count > 1 { text += ", \(count) commands" }
        return text
    }

    /// `2 commands` above the input; nil for a single command or a tool with no count.
    public static func commandCountLine(for request: ApprovalRequestWire) -> String? {
        guard let count = request.display.commandCount, count > 1 else { return nil }
        return "\(count) commands"
    }

    /// The home directory shown as `~`.
    public static func homeAbbreviated(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The button label VoiceOver reads for Allow once: `Allow once: rm -rf build/ and 1 more command`.
    /// `summary` is the first command (or the first line) as displayed.
    public static func allowOnceAccessibilityLabel(summary: String, commandCount: Int?) -> String {
        var text = "Allow once: \(summary)"
        if let count = commandCount, count > 1 {
            let more = count - 1
            text += " and \(more) more command\(more == 1 ? "" : "s")"
        }
        return text
    }

    private static func capitalized(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
