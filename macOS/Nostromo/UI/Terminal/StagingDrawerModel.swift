import Foundation

/// Why a staged command cannot be placed at the prompt right now. Fixed strings: nothing an agent
/// wrote ever appears in one. Listed in the order they are checked; the first that applies wins.
enum StagingDisabledReason: Equatable {
    case mirror, daemonDisconnected, connecting, ended, notLocal, alternateScreen, sendingPaste
    case justChanged, notInsertable

    var text: String {
        switch self {
        case .mirror:             return "Click the terminal to drive it from this window"
        case .daemonDisconnected: return "Nostromo's daemon is not connected"
        case .connecting:         return "The shell is still connecting"
        case .ended:              return "The shell has ended"
        case .notLocal:           return "Staging into remote shells is not available yet"
        case .alternateScreen:    return "A full-screen program is running"
        case .sendingPaste:       return "A paste is still being sent"
        case .justChanged:        return "Just changed: read it again"
        case .notInsertable:      return "Nostromo will not insert this text"
        }
    }

    /// The reasons that apply to every row of a drawer (as opposed to one entry).
    var appliesToEveryRow: Bool { self != .justChanged && self != .notInsertable }
}

/// What the drawer needs to know about the terminal and this window to decide anything.
struct StagingEnvironment: Equatable {
    /// This window shows the terminal but does not drive it.
    var isMirror: Bool
    var daemonConnected: Bool
    var status: TerminalStatus?
    var kind: TerminalKind?
    var isAlternateScreen: Bool
    /// A large paste is still going out in frames.
    var isSendingInput: Bool
}

/// What a click or Space decided at the moment of the mouse-down or key-down. The exact command is kept,
/// so a replace that lands before the mouse-up changes nothing that is inserted.
struct StagingSnapshot: Equatable {
    let terminalId: String
    let entryId: String
    let command: String
    /// Why nothing may be inserted, decided with the 1.5 s rule at the moment of the snapshot.
    let reason: StagingDisabledReason?
}

/// One row, ready to draw. Pure: no views, no SwiftTerm.
struct StagingRowModel: Equatable {
    enum State: Equatable {
        case ready
        case inserted(ago: String)
        case disabled(StagingDisabledReason)
    }

    let entryId: String
    let number: Int
    /// Exactly what was staged.
    let command: String
    let age: String
    /// Amber: changed more than 30 minutes ago.
    let ageIsStale: Bool
    let state: State
    /// `Claudia's note (unverified): <note>`, the note sanitised; nil when there is none.
    let noteText: String?
    /// The app's own labels (never the agent's). In S1: the placeholder warning.
    let labels: [String]
    let accessibilityLabel: String

    var glyph: String {
        switch state {
        case .ready: return "\u{25B8}"
        case .inserted: return "\u{2713}"
        case .disabled: return "\u{2298}"
        }
    }

    var disabledReason: StagingDisabledReason? {
        if case .disabled(let reason) = state { return reason }
        return nil
    }
}

enum StagingDrawerModel {

    static let agentNameLimit = 40
    static let noteLimit = 240
    /// An entry a person has had under this long to read is not inserted.
    static let readingDelay: TimeInterval = 1.5
    static let staleAfter: TimeInterval = 30 * 60
    static let placeholderLabel = "Contains <\u{2026}>: edit it before pressing Enter"

    // MARK: Texts

    static func agentName(_ list: TerminalStagingList) -> String {
        AgentDisplayText.plain(list.agentName, limit: agentNameLimit) ?? "The agent"
    }

    /// The header as the view lays it out: `lead` truncates (a long agent name goes first), `count`
    /// (`(3)`) never does. The empty state carries the instruction in `lead` and wraps.
    static func headerParts(_ list: TerminalStagingList) -> (lead: String, count: String?) {
        let name = agentName(list)
        if list.state == .frozen { return ("\(name) stopped following; this list won't change", nil) }
        if list.entries.isEmpty {
            return ("Staged by \(name) \u{00B7} nothing yet. Click a staged command to put it at the prompt; you press Enter.", nil)
        }
        return ("Staged by \(name)", "(\(list.entries.count))")
    }

    /// The header's text; `Staged by Claudia (3)`.
    static func headerText(_ list: TerminalStagingList) -> String {
        let parts = headerParts(list)
        return parts.count.map { "\(parts.lead) \($0)" } ?? parts.lead
    }

    /// The one-line collapsed strip: `3 staged by Claudia ▸`.
    static func stripText(_ list: TerminalStagingList) -> String {
        let name = agentName(list)
        let count = list.entries.isEmpty ? "Nothing" : "\(list.entries.count)"
        let stopped = list.state == .frozen ? " (stopped)" : ""
        return "\(count) staged by \(name)\(stopped) \u{25B8}"
    }

    /// `10s`, `4m`, `1h`, `2d`.
    static func ageText(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60:    return "\(seconds)s"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default:       return "\(seconds / 86_400)d"
        }
    }

    // MARK: Decisions

    /// The first reason that applies to every row of the drawer, if any (the order is the PRD's).
    static func sharedReason(_ env: StagingEnvironment) -> StagingDisabledReason? {
        if env.isMirror { return .mirror }
        if !env.daemonConnected { return .daemonDisconnected }
        switch env.status {
        case .running?: break
        case .ended?:   return .ended
        default:        return .connecting
        }
        if env.kind != .local { return .notLocal }
        if env.isAlternateScreen { return .alternateScreen }
        if env.isSendingInput { return .sendingPaste }
        return nil
    }

    /// Why `entry` cannot be inserted now. `shownSince` is on the same clock as `now`; an entry with no
    /// known time counts as just changed.
    static func reason(for entry: StagingEntry, env: StagingEnvironment,
                       shownSince: TimeInterval?, now: TimeInterval) -> StagingDisabledReason? {
        if let shared = sharedReason(env) { return shared }
        if let shownSince {
            if now - shownSince < readingDelay { return .justChanged }
        } else {
            return .justChanged
        }
        if !AgentDisplayText.isInsertable(entry.command) { return .notInsertable }
        return nil
    }

    static func snapshot(terminalId: String, entry: StagingEntry, env: StagingEnvironment,
                         shownSince: TimeInterval?, now: TimeInterval) -> StagingSnapshot {
        StagingSnapshot(terminalId: terminalId, entryId: entry.id, command: entry.command,
                        reason: reason(for: entry, env: env, shownSince: shownSince, now: now))
    }

    /// What goes to the shell: the exact UTF-8 of the command, wrapped in the bracketed-paste markers
    /// when the program asked for them. Never a CR, LF or any other added control.
    static func bytes(for command: String, bracketedPaste: Bool) -> [UInt8] {
        let text = Array(command.utf8)
        guard bracketedPaste else { return text }
        return Array("\u{1B}[200~".utf8) + text + Array("\u{1B}[201~".utf8)
    }

    // MARK: Rows

    static func rows(for list: TerminalStagingList, env: StagingEnvironment,
                     shownSince: (String) -> TimeInterval?, now: TimeInterval, date: Date) -> [StagingRowModel] {
        list.entries.enumerated().map { index, entry in
            row(entry, index: index, of: list, env: env, shownSince: shownSince(entry.id), now: now, date: date)
        }
    }

    static func row(_ entry: StagingEntry, index: Int, of list: TerminalStagingList, env: StagingEnvironment,
                    shownSince: TimeInterval?, now: TimeInterval, date: Date) -> StagingRowModel {
        let state: StagingRowModel.State
        if let reason = reason(for: entry, env: env, shownSince: shownSince, now: now) {
            state = .disabled(reason)
        } else if entry.insertedCount > 0, let last = entry.lastInsertedAt {
            state = .inserted(ago: "inserted \(ageText(since: last, now: date)) ago")
        } else {
            state = .ready
        }
        let name = agentName(list)
        let note = AgentDisplayText.plain(entry.note, limit: noteLimit)
        let noteText = note.map { "\(possessive(name)) note (unverified): \($0)" }
        let labels = isPlaceholderCommand(entry.command) ? [placeholderLabel] : []
        var parts = ["Staged command \(index + 1) of \(list.entries.count)", entry.command]
        parts += labels
        if let note { parts += ["\(possessive(name)) note", "unverified", note] }
        switch state {
        case .ready: parts.append("ready to place at the prompt")
        case .inserted(let ago): parts.append(ago)
        case .disabled(let reason): parts.append("unavailable: \(reason.text)")
        }
        let age = ageText(since: entry.changedAt, now: date)
        return StagingRowModel(entryId: entry.id, number: entry.number, command: entry.command, age: age,
                               ageIsStale: date.timeIntervalSince(entry.changedAt) > staleAfter,
                               state: state, noteText: noteText, labels: labels,
                               accessibilityLabel: parts.joined(separator: ", "))
    }

    /// `<name>` placeholders: the command needs editing before it can run as it is.
    static func isPlaceholderCommand(_ command: String) -> Bool {
        command.range(of: #"<[A-Za-z0-9_.:-]{1,40}>"#, options: .regularExpression) != nil
    }

    private static func possessive(_ name: String) -> String {
        "\(name)'s"
    }
}
