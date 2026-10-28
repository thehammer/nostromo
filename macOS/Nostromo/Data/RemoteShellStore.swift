import Foundation

// The remote-shell state the Mac keeps, and every string the confirm sheet, the failure sheet and the
// closed toast show. Nothing here imports AppKit: it compiles into the test target too.
//
// What opens a production shell is a person's click on Connect (`RemoteShellConfirmSheet`). This
// store only remembers what the daemon asked, sends the answer exactly once, and words the outcomes.

// MARK: - What the sheets show

/// What the "Connect to PRODUCTION" sheet says.
struct RemoteShellSheetModel: Equatable {
    /// "Connect to PRODUCTION": the environment, uppercased.
    let title: String
    /// "PRODUCTION": the environment on its own (the sheet draws it largest, in red).
    let environment: String
    /// "admin-portal · scheduler · shell": project, service, shell type.
    let subtitle: String
    /// "Requested by cody in Core". Nil for a shell the user opened themselves.
    let requestedBy: String?
    /// The agent's stated reason as plain text (no quote marks added). Nil when there is none.
    let reason: String?
    /// What will run, never shortened: Command, Profile, Cluster, in that order.
    let details: [RemoteShellDetail]
    /// Why Connect is off, when the sheet can't show what would run. Nil when Connect may be offered.
    let connectBlockedReason: String?
    /// The follow checkbox's title ("Let cody follow this shell's output"), only for a shell an agent
    /// (a focus) asked for. Nil for a shell the user opened themselves: nobody to invite.
    let followCheckboxTitle: String?
}

/// One labelled fact about what will run.
struct RemoteShellDetail: Equatable {
    let label: String
    let value: String
}

/// What the failure sheet says when a connection could not be made.
struct RemoteShellFailure: Equatable {
    /// "Couldn't connect to PRODUCTION · admin-portal · scheduler".
    let heading: String
    let reason: String
    /// What to do about it, as the daemon worded it (a command the person can copy).
    let remedy: String?
    /// The first line the AWS CLI printed, for the person at the app.
    let detail: String?
}

/// What the app does when the daemon says a confirm request is over.
enum RemoteShellResolution: Equatable {
    /// Connected, cancelled, dismissed: the sheet closes and nothing else is shown.
    case closeSheet
    /// Nobody answered in time.
    case timedOut
    /// The connection could not be made: no pane, and the failure sheet says why.
    case failed(RemoteShellFailure)
}

// MARK: - Store

/// The remote-shell vocabulary, the one pending confirm request, and the answer-once guard.
///
/// Main thread only (it is fed from `AppStore.handle` and called from AppKit actions).
final class RemoteShellStore {
    static let shared = RemoteShellStore()

    /// The longest reason shown (an agent's text, so bounded and plain).
    static let reasonLimit = 200
    /// The longest agent name shown.
    static let agentNameLimit = 40
    /// The longest focus display name shown.
    static let focusNameLimit = 60
    static let profileMissingText = "(none configured)"
    static let clusterMissingText = "(not provided)"
    static let commandMissingText = "(not provided by the daemon)"
    /// How many finished request ids are remembered, so a late duplicate answer is still refused.
    private static let doneCapacity = 64

    /// Sends one frame to the daemon (`AppStore` points it at the client; dropped when not connected).
    var transport: (RemoteShellClientMessage) -> Void

    private(set) var targets: RemoteShellTargets?
    private(set) var pending: RemoteShellConfirmRequest?

    private var done: Set<String> = []
    private var doneOrder: [String] = []

    init(transport: @escaping (RemoteShellClientMessage) -> Void = { _ in }) {
        self.transport = transport
    }

    // MARK: - Daemon state

    func setTargets(_ targets: RemoteShellTargets) {
        self.targets = targets
    }

    func requestTargets() {
        transport(.targetsRequest)
    }

    /// The daemon wants an answer: this becomes the pending request. A newer one replaces it.
    func present(_ request: RemoteShellConfirmRequest) {
        pending = request
    }

    /// Send `decision` for `requestId`, once. The first call for an id sends the frame and returns
    /// true; any later call for that id (the same decision or another one, such as Connect after
    /// Cancel) and any call for an id the daemon already resolved sends nothing and returns false.
    /// `inviteFollow` is the confirm sheet's follow box; it only means anything with `.connect`.
    @discardableResult
    func answer(requestId: String, decision: RemoteShellDecision, inviteFollow: Bool = false) -> Bool {
        guard !done.contains(requestId) else { return false }
        remember(requestId)
        if pending?.requestId == requestId { pending = nil }
        transport(.answer(requestId: requestId, decision: decision,
                          inviteFollow: inviteFollow && decision == .connect))
        return true
    }

    /// The daemon says the request is over. `target` is the request's target, when the caller still
    /// has it, for the failure heading.
    func resolve(_ resolved: RemoteShellResolved, target: TerminalTarget?) -> RemoteShellResolution {
        if pending?.requestId == resolved.requestId { pending = nil }
        remember(resolved.requestId)
        switch resolved.outcome {
        case "timed_out":
            return .timedOut
        case "connect_failed":
            return .failed(RemoteShellFailure(
                heading: Self.failureHeading(target),
                reason: Self.failureReasonText(resolved.reason),
                remedy: Self.nonEmpty(resolved.remedy),
                detail: Self.nonEmpty(resolved.detail)))
        default:
            return .closeSheet
        }
    }

    /// Ask the daemon for a remote shell in `tag`'s focus. It answers with the same confirm request
    /// an agent's would produce, minus the requester.
    func open(tag: String, target: TerminalTarget) {
        transport(.open(tag: tag, target: target))
    }

    // MARK: - Words

    /// The confirm sheet's text. `focusLabel` names a focus by its tag (the sidebar's name).
    static func sheetModel(for request: RemoteShellConfirmRequest,
                           focusLabel: (String) -> String?) -> RemoteShellSheetModel {
        let environment = request.target.environment.uppercased()
        let subtitle = [request.target.project, request.target.service, request.target.shellType]
            .joined(separator: " \u{00B7} ")
        let isAgent = request.requestedBy.kind != "user"
        let command = nonBlank(request.shellCommand)
        return RemoteShellSheetModel(
            title: "Connect to \(environment)", environment: environment, subtitle: subtitle,
            requestedBy: isAgent ? requestedByLine(for: request, focusLabel: focusLabel) : nil,
            reason: isAgent ? plainText(request.reason, limit: reasonLimit) : nil,
            details: [
                RemoteShellDetail(label: "Command", value: command ?? commandMissingText),
                RemoteShellDetail(label: "Profile", value: nonEmpty(request.profile) ?? profileMissingText),
                RemoteShellDetail(label: "Cluster", value: nonEmpty(request.cluster) ?? clusterMissingText),
            ],
            connectBlockedReason: command == nil
                ? "The daemon did not say which command would run, so this shell can't be authorised. Cancel and try again."
                : nil,
            followCheckboxTitle: request.requestedBy.kind == "focus" ? followCheckboxTitle(for: request) : nil)
    }

    /// "Let cody follow this shell's output". The agent's name is the agent's text: plain, bounded.
    static func followCheckboxTitle(for request: RemoteShellConfirmRequest) -> String {
        let agent = plainText(request.requestedBy.agent, limit: agentNameLimit) ?? "the agent"
        return "Let \(agent) follow this shell's output"
    }

    /// The reason a connection failed, in words. `code` is the daemon's failure code.
    static func failureReasonText(_ code: String?) -> String {
        switch code {
        case "sso_expired":                    return "AWS SSO session expired"
        case "session_manager_plugin_missing": return "The Session Manager plugin is not installed"
        case "profile_not_configured":         return "No AWS profile is set up for this environment"
        case "no_running_task":                return "No task is running for this service"
        case "exec_not_enabled":               return "ECS Exec is not enabled for this service"
        case "access_denied":                  return "AWS denied access to this task"
        case "target_not_connected":           return "The task is not ready for exec"
        case "connect_timeout":                return "The session did not start in time"
        case "aws_cli_missing":                return "The AWS CLI is not installed"
        case "aws_error":                      return "The AWS CLI reported an error"
        default:                               return "The connection could not be made"
        }
    }

    /// Why a connected remote session ended, as the closed toast words it.
    static func closePhrase(_ reason: String?) -> String {
        switch reason {
        case "remote_exit":    return "remote session ended"
        case "idle_timeout":   return "idle for 15 minutes"
        case "user_closed":    return "closed"
        case "network":        return "connection lost"
        case "sso_expired":    return "AWS SSO session expired"
        case "daemon_stopped": return "Nostromo daemon restarted"
        default:               return "ended"
        }
    }

    /// What a remote pane shows until its session begins: "Connecting to production · admin-portal · scheduler…".
    static func connectingMessage(for target: TerminalTarget) -> String {
        "Connecting to \(target.environment) \u{00B7} \(target.project) \u{00B7} \(target.service)\u{2026}"
    }

    /// The toast for a remote shell that closed, or nil for a local terminal (or one with no target).
    /// "production · admin-portal · scheduler shell closed: remote session ended, exit 0".
    static func closedToastMessage(for closed: TerminalClosedInfo) -> String? {
        guard closed.kind == .ecs, let target = closed.target else { return nil }
        var message = "\(target.environment) \u{00B7} \(target.project) \u{00B7} \(target.service) "
            + "\(target.shellType) closed: \(closePhrase(closed.reason))"
        if let code = closed.exitCode { message += ", exit \(code)" }
        return message
    }

    // MARK: - Private

    private func remember(_ requestId: String) {
        guard done.insert(requestId).inserted else { return }
        doneOrder.append(requestId)
        if doneOrder.count > Self.doneCapacity {
            done.remove(doneOrder.removeFirst())
        }
    }

    private static func failureHeading(_ target: TerminalTarget?) -> String {
        guard let target else { return "Couldn't connect" }
        return "Couldn't connect to \(target.environment.uppercased()) \u{00B7} \(target.project) \u{00B7} \(target.service)"
    }

    private static func requestedByLine(for request: RemoteShellConfirmRequest,
                                         focusLabel: (String) -> String?) -> String {
        let agent = plainText(request.requestedBy.agent, limit: agentNameLimit) ?? "an agent"
        let tag = request.tag ?? request.requestedBy.tag
        let focus = tag.flatMap { plainText(focusLabel($0), limit: focusNameLimit) ?? plainText($0, limit: focusNameLimit) }
            ?? "a focus"
        return "Requested by \(agent) in \(focus)"
    }

    /// Agent-supplied text as plain text: format characters (bidi overrides, zero-width, BOM) are
    /// dropped, control characters and newlines become spaces, runs of spaces collapse, and anything
    /// past `limit` is cut (the last character is "…"). Nil when nothing is left.
    private static func plainText(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let spaced = String(String.UnicodeScalarView(text.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if scalar.properties.generalCategory == .format || invisibleFillers.contains(scalar.value) { return nil }
            return CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                ? " " : scalar
        }))
        let collapsed = spaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "\u{2026}"
    }

    /// Not format characters (so `generalCategory == .format` misses them) but they draw nothing: Hangul
    /// filler (U+3164, U+115F, U+1160, U+FFA0), the combining grapheme joiner (U+034F) and braille blank (U+2800).
    private static let invisibleFillers: Set<UInt32> = [0x3164, 0x115F, 0x1160, 0xFFA0, 0x034F, 0x2800]

    /// Text with something visible in it: whitespace, format characters and the fillers do not count.
    private static func nonBlank(_ text: String?) -> String? {
        guard let text else { return nil }
        let visible = text.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && scalar.properties.generalCategory != .format
                && !invisibleFillers.contains(scalar.value)
        }
        return visible ? text : nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - Which project is this focus?

/// The project a directory belongs to, from each project's `repo_paths`, as `ecs_detect_project`
/// reads them: inside the repository, or a worktree sibling named `<repo>-<branch>`.
enum ProjectDetection {

    static func detect(path: String?, repoPaths: [String: [String]], home: String) -> String? {
        guard let path = path.map(trimmed), !path.isEmpty else { return nil }
        for project in repoPaths.keys.sorted() {
            for raw in repoPaths[project] ?? [] {
                let repo = trimmed(expandHome(raw, home: home))
                guard !repo.isEmpty else { continue }
                if path == repo || path.hasPrefix(repo + "/") || path.hasPrefix(repo + "-") {
                    return project
                }
            }
        }
        return nil
    }

    private static func expandHome(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    private static func trimmed(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

// MARK: - The New Remote Shell picker

/// The picker's four cascading choices. Starts from the project the focus's directory belongs to,
/// then `production`, then that project's default service, then `shell`.
struct RemoteShellPickerModel: Equatable {
    private let targets: RemoteShellTargets

    private(set) var project: String
    private(set) var environment: String
    private(set) var service: String
    private(set) var shellType: String

    /// Nil when the vocabulary has no project to choose.
    init?(targets: RemoteShellTargets, projectPath: String?, home: String) {
        guard let first = targets.projects.first else { return nil }
        self.targets = targets
        let detected = ProjectDetection.detect(path: projectPath, repoPaths: targets.repoPaths, home: home)
        project = targets.projects.contains { $0.name == detected } ? (detected ?? first.name) : first.name
        environment = ""
        service = ""
        shellType = Self.preferred("shell", in: targets.shellTypes)
        redefaultEnvironment()
    }

    var projects: [String] { targets.projects.map(\.name) }
    var environments: [String] { currentProject?.environments.map(\.name) ?? [] }
    var services: [String] { currentEnvironment?.services ?? [] }
    var shellTypes: [String] { targets.shellTypes }

    var selection: TerminalTarget {
        TerminalTarget(project: project, environment: environment, service: service, shellType: shellType)
    }

    mutating func selectProject(_ name: String) {
        guard projects.contains(name) else { return }
        project = name
        redefaultEnvironment()
    }

    mutating func selectEnvironment(_ name: String) {
        guard environments.contains(name) else { return }
        environment = name
        if !services.contains(service) { redefaultService() }
    }

    mutating func selectService(_ name: String) {
        guard services.contains(name) else { return }
        service = name
    }

    mutating func selectShellType(_ name: String) {
        guard shellTypes.contains(name) else { return }
        shellType = name
    }

    // MARK: - Private

    private var currentProject: RemoteShellProject? { targets.projects.first { $0.name == project } }
    private var currentEnvironment: RemoteShellEnvironment? {
        currentProject?.environments.first { $0.name == environment }
    }

    private mutating func redefaultEnvironment() {
        environment = Self.preferred("production", in: environments)
        redefaultService()
    }

    private mutating func redefaultService() {
        let offered = services
        if let preferred = currentProject?.defaultService, offered.contains(preferred) {
            service = preferred
        } else {
            service = offered.first ?? ""
        }
    }

    private static func preferred(_ name: String, in names: [String]) -> String {
        names.contains(name) ? name : (names.first ?? "")
    }
}
