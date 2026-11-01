import Foundation

/// Why a staged command cannot be placed at the prompt right now. Fixed strings: nothing an agent
/// wrote ever appears in one. Listed in the order they are checked; the first that applies wins.
enum StagingDisabledReason: Equatable, CaseIterable {
    case mirror, daemonDisconnected, connecting, ended, alternateScreen, sendingPaste
    /// Production-treated panes only: what is typed or placed since the last Enter may still be on the line.
    case lineMayHaveText
    case justChanged, notInsertable
    /// A production-treated row that uses shell history (`!!`, `^a^b`, `r`, `fc`): never placed there.
    case historyExpansion
    /// Decided only when a placement was tried: the terminal view did not take the bytes.
    case notSent

    var text: String {
        switch self {
        case .mirror:             return "Click the terminal to drive it from this window"
        case .daemonDisconnected: return "Nostromo's daemon is not connected"
        case .connecting:         return "The shell is still connecting"
        case .ended:              return "The shell has ended"
        case .alternateScreen:    return "A full-screen program is running"
        case .sendingPaste:       return "A paste is still being sent"
        case .lineMayHaveText:    return "Something may already be on the line: press Ctrl-U or Enter in the shell first"
        case .historyExpansion:   return StagingHazards.historyReasonText
        case .justChanged:        return "Just changed: read it again"
        case .notInsertable:      return "Nostromo will not insert this text"
        case .notSent:            return "Nothing was placed: the terminal did not take it"
        }
    }

    /// The reasons that apply to every row of a drawer (as opposed to one entry).
    var appliesToEveryRow: Bool {
        self != .justChanged && self != .notInsertable && self != .notSent && self != .historyExpansion
    }
}

/// How a pane is treated. Decided on the pane's **kind** (an unknown kind, or no information at all, is
/// remote), never on whether a target is present; a Local pane whose foreground is a program other than
/// its shell (`ssh`, `kubectl`) is treated like a remote one. Pure.
enum StagingPaneSafety: Equatable {
    case local
    /// `token`: the environment (`PRODUCTION`), or `REMOTE` when the pane has no target.
    case remote(token: String)
    /// A local terminal where `program` is running in the foreground.
    case localRunning(program: String)

    static let unknownToken = TerminalChromeModel.unknownEnvironment
    static let programLimit = 24

    static func make(kind: TerminalKind?, target: TerminalTarget?, foreground: String?) -> StagingPaneSafety {
        guard kind == .local else {
            let environment = target?.environment ?? ""
            return .remote(token: environment.isEmpty ? unknownToken : environment.uppercased())
        }
        guard let foreground else { return .local }
        return .localRunning(program: AgentDisplayText.plain(foreground, limit: programLimit) ?? "a program")
    }

    /// Whether the production rules apply.
    var isProduction: Bool { self != .local }

    /// The fixed token shown left of the drawer header: `PRODUCTION`, `REMOTE`, `RUNNING`.
    var token: String? {
        switch self {
        case .local: return nil
        case .remote(let token): return token
        case .localRunning: return "RUNNING"
        }
    }
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
    var target: TerminalTarget? = nil
    /// The list's `foreground`: a Local terminal whose shell is running another program.
    var foreground: String? = nil
    /// Something typed or placed since the last Enter may still be on the line (a production pane refuses to
    /// place a command next to it). Unknown counts as true.
    var lineMayHaveText = false

    var safety: StagingPaneSafety { StagingPaneSafety.make(kind: kind, target: target, foreground: foreground) }
}

/// What a click or Space decided at the moment of the mouse-down or key-down. The exact command is kept,
/// so a replace that lands before the mouse-up changes nothing that is inserted.
struct StagingSnapshot: Equatable {
    let terminalId: String
    let entryId: String
    let command: String
    /// Why nothing may be inserted, decided with the 1.5 s rule at the moment of the snapshot.
    let reason: StagingDisabledReason?
    /// How the pane was treated when the click began.
    var safety: StagingPaneSafety = .local
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
    /// The destructive patterns the command matches (names), whatever the pane.
    var destructive: [String] = []
    /// False in a production-treated pane: the whole command is shown, wrapped, with no "Show all".
    var collapses = true
    /// Placed at the prompt at least once (and not archived): it can be archived.
    var placed = false
    /// For a row blocked by the reading delay or by a reason shared by every row (which the drawer shows
    /// once, not per row): the line it will show once it can be clicked (`inserted 2m ago`, or why its
    /// text is not insertable), shown now so the row's height does not change at the moment it becomes
    /// clickable. nil for every other row.
    let lineAfterDelay: String?
    let accessibilityLabel: String

    var glyph: String {
        switch state {
        case .ready: return "\u{25B8}"
        case .inserted: return "\u{2713}"
        case .disabled: return "\u{2298}"
        }
    }

    /// Whether `other` shows the same row apart from what the clock moves: the age, its amber, and the
    /// `inserted 2m ago` text (and the spoken label that repeats them). Those update in place, and do not
    /// count as a change (which would re-lay out the rows and clear a refusal's reason every second).
    func matchesApartFromAges(_ other: StagingRowModel) -> Bool {
        guard entryId == other.entryId, number == other.number, command == other.command,
              noteText == other.noteText, labels == other.labels, collapses == other.collapses,
              destructive == other.destructive else { return false }
        switch (state, other.state) {
        case (.ready, .ready), (.inserted, .inserted): return true
        case (.disabled(let a), .disabled(let b)): return a == b
        default: return false
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
    static let placeholderLabel = "Contains <\u{2026}>: edit it before pressing Enter (as written, < and > are redirects)"
    static let youPressEnter = "you press Enter"

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

    /// The header text after the fixed token of a production-treated pane (it truncates; the token never does):
    /// `Staged by Triage (2) \u{00B7} you press Enter`, or `ssh is running \u{00B7} Staged by Triage (2) \u{00B7} you press Enter`.
    /// An empty or stopped list keeps its own text.
    static func productionHeaderText(_ list: TerminalStagingList, safety: StagingPaneSafety) -> String {
        let parts = headerParts(list)
        guard let count = parts.count else { return parts.lead }
        var text = "\(parts.lead) \(count) \u{00B7} \(youPressEnter)"
        if case .localRunning(let program) = safety { text = "\(program) is running \u{00B7} " + text }
        return text
    }

    /// `Insert into PRODUCTION?` (`REMOTE` without a target), or `Insert into a shell running ssh?`.
    static func confirmTitle(_ safety: StagingPaneSafety) -> String {
        switch safety {
        case .remote(let token): return "Insert into \(token)?"
        case .localRunning(let program): return "Insert into a shell running \(program)?"
        case .local: return "Insert into this shell?"
        }
    }

    /// The target line of the confirm sheet: `admin-portal \u{00B7} scheduler \u{00B7} shell`, `REMOTE shell` when the
    /// pane has no target, or what is running in a local terminal.
    static func confirmTargetLine(_ safety: StagingPaneSafety, target: TerminalTarget?) -> String {
        if case .localRunning(let program) = safety { return "A local terminal where \(program) is running" }
        guard let target else { return TerminalChromeModel.unknownTargetText }
        return [target.project, target.service, target.shellType].joined(separator: " \u{00B7} ")
    }

    /// The drawer's spoken label: `Staged by Triage \u{00B7} PRODUCTION \u{00B7} you press Enter`
    /// (`\u{00B7} running ssh \u{00B7}` for a local pane with a program in the foreground).
    static func accessibilityText(_ list: TerminalStagingList, safety: StagingPaneSafety) -> String {
        let name = agentName(list)
        switch safety {
        case .local: return "Staged commands"
        case .remote(let token): return "Staged by \(name) \u{00B7} \(token) \u{00B7} \(youPressEnter)"
        case .localRunning(let program): return "Staged by \(name) \u{00B7} running \(program) \u{00B7} \(youPressEnter)"
        }
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
        if env.isAlternateScreen { return .alternateScreen }
        if env.isSendingInput { return .sendingPaste }
        if env.safety.isProduction && env.lineMayHaveText { return .lineMayHaveText }
        return nil
    }

    /// Why `entry` cannot be inserted now. `shownSince` is on the same clock as `now`; an entry with no
    /// known time counts as just changed.
    static func reason(for entry: StagingEntry, env: StagingEnvironment,
                       shownSince: TimeInterval?, now: TimeInterval) -> StagingDisabledReason? {
        if let shared = sharedReason(env) { return shared }
        if !hasBeenReadable(shownSince: shownSince, now: now) { return .justChanged }
        if !AgentDisplayText.isInsertable(entry.command) { return .notInsertable }
        if env.safety.isProduction && StagingHazards.usesHistoryExpansion(entry.command) { return .historyExpansion }
        return nil
    }

    /// Whether an entry text first shown at `shownSince` has been on screen long enough to be read.
    /// An entry with no known time counts as just changed.
    static func hasBeenReadable(shownSince: TimeInterval?, now: TimeInterval) -> Bool {
        guard let shownSince else { return false }
        return now - shownSince >= readingDelay
    }

    static func snapshot(terminalId: String, entry: StagingEntry, env: StagingEnvironment,
                         shownSince: TimeInterval?, now: TimeInterval) -> StagingSnapshot {
        StagingSnapshot(terminalId: terminalId, entryId: entry.id, command: entry.command,
                        reason: reason(for: entry, env: env, shownSince: shownSince, now: now), safety: env.safety)
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
        var lineAfterDelay: String?
        if case .disabled(let reason) = state, reason == .justChanged || reason.appliesToEveryRow {
            if !AgentDisplayText.isInsertable(entry.command) {
                lineAfterDelay = StagingDisabledReason.notInsertable.text
            } else if entry.insertedCount > 0, let last = entry.lastInsertedAt {
                lineAfterDelay = "inserted \(ageText(since: last, now: date)) ago"
            }
        }
        let name = agentName(list)
        let note = AgentDisplayText.plain(entry.note, limit: noteLimit)
        let noteText = note.map { "\(possessive(name)) note (unverified): \($0)" }
        let destructive = StagingDestructivePatterns.matches(entry.command)
        let production = env.safety.isProduction
        var labels = hazardLabels(for: entry.command, production: production)
        if let label = StagingHazards.destructiveLabel(destructive, production: production) { labels.insert(label, at: 0) }
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
                               state: state, noteText: noteText, labels: labels, destructive: destructive,
                               collapses: !production, placed: entry.insertedCount > 0, lineAfterDelay: lineAfterDelay,
                               accessibilityLabel: parts.joined(separator: ", "))
    }

    /// The labels the app computes about a command's text, in every pane but the destructive-pattern one:
    /// placeholders, look-alike non-ASCII, and (local panes only; a production pane refuses the row) history.
    static func hazardLabels(for command: String, production: Bool) -> [String] {
        var labels: [String] = []
        if isPlaceholderCommand(command) { labels.append(placeholderLabel) }
        if let label = StagingHazards.nonASCIILabel(command) { labels.append(label) }
        if !production && StagingHazards.usesHistoryExpansion(command) { labels.append(StagingHazards.localHistoryLabel) }
        return labels
    }

    /// `<name>` placeholders: the command needs editing before it can run as it is.
    static func isPlaceholderCommand(_ command: String) -> Bool {
        command.range(of: #"<[A-Za-z0-9_.:-]{1,40}>"#, options: .regularExpression) != nil
    }

    private static func possessive(_ name: String) -> String {
        "\(name)'s"
    }
}
