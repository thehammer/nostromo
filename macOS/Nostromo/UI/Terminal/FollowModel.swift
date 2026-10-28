import AppKit

// What the Follow control of a terminal pane says and offers, derived from the daemon's `TerminalInfo`
// and the focus list alone: no view state, no SwiftTerm. Every string, colour and choice the header
// badge, the invite popover and the context menu show comes from here, so the views only draw it.
//
// Following is invitation-only. Nothing here starts it: the model only says what a person may choose.

/// A focus the invite popover or the Send selection menu offers: its daemon tag and the name the
/// sidebar shows for it (the focus's label, never the bare tag unless the focus is gone).
struct FollowFocusOption: Equatable {
    let tag: String
    let name: String
}

/// What a person can do about a pane's sharing, as buttons.
enum FollowAction: Equatable {
    /// Open the invite popover on a pane nobody follows.
    case invite
    /// Stop following at once.
    case stop
    /// Open the invite popover to hand the following to another focus.
    case move
    /// Resume a following that paused itself.
    case resume
}

struct FollowModel: Equatable {

    enum State: Equatable {
        case notShared
        /// `by` is the follower focus's label.
        case followed(by: String)
        /// `reason` is the daemon's pause code (`too_much_output`, `too_many_deliveries`), if any.
        case paused(by: String, reason: String?)
    }

    static let notSharedText = "Not shared"
    static let notSharedDescription = "No agent is following this terminal"
    /// The invite popover's checkbox. Off by default (the screen's current contents go out only when ticked).
    static let includeScreenTitle = "Include what's on screen now"
    static let includeScreenDefault = false
    /// The least width the header gives the badge when there is room: wide enough for "Not shared".
    static let badgeMinWidth: CGFloat = 72

    let info: TerminalInfo
    /// Every focus, in the sidebar's order.
    let focuses: [FollowFocusOption]

    init(info: TerminalInfo, focuses: [FollowFocusOption]) {
        self.info = info
        self.focuses = focuses
    }

    // MARK: - State and badge

    var state: State {
        guard let follower = info.follower else { return .notShared }
        let label = name(forTag: follower.tag)
        return follower.paused ? .paused(by: label, reason: follower.pauseReason) : .followed(by: label)
    }

    /// "Not shared", "Followed by Claudia", "Paused, too much output".
    var badgeText: String {
        switch state {
        case .notShared:                  return Self.notSharedText
        case .followed(let label):        return "Followed by \(label)"
        case .paused(_, let reason):      return Self.pausedText(reason: reason)
        }
    }

    /// Never red (a red header is how a remote pane says "production"): muted for nobody, blue while
    /// followed, amber while paused. Drawn as a filled pill with dark text, so it reads on a red header too.
    var badgeColor: NSColor {
        switch state {
        case .notShared: return Theme.fgMuted
        case .followed:  return Theme.followBlue
        case .paused:    return Theme.amber
        }
    }

    /// The badge's tooltip and accessibility text: the whole sentence, never cut.
    var badgeDescription: String {
        switch state {
        case .notShared:
            return Self.notSharedDescription
        case .followed(let label):
            return "Output from this terminal is being sent to \(label)'s model"
        case .paused(let label, let reason):
            return "\(Self.pausedText(reason: reason)). \(label) is not receiving this terminal's output until you resume"
        }
    }

    static func pausedText(reason: String?) -> String {
        switch reason {
        case "too_much_output":      return "Paused, too much output"
        case "too_many_deliveries":  return "Paused, too many deliveries"
        default:                     return "Paused"
        }
    }

    // MARK: - Actions

    /// What the popover or header offers now. A pane that is not running cannot be invited to; one that
    /// is followed can always be stopped.
    var actions: [FollowAction] {
        switch state {
        case .notShared: return info.status == .running ? [.invite] : []
        case .followed:  return [.stop, .move]
        case .paused:    return [.resume, .stop]
        }
    }

    // MARK: - Invite

    /// The invite popover's title: an invite on a pane nobody follows, a Move on one that is followed.
    var inviteHeading: String {
        state == .notShared ? "Let an agent follow this terminal" : "Move this terminal to another agent"
    }

    /// The focuses the picker lists. A Move is to another focus: the one that follows already is not offered.
    var inviteFocuses: [FollowFocusOption] {
        focuses.filter { $0.tag != info.follower?.tag }
    }

    /// The focus the invite popover starts on: the one that owns the pane, or, for a remote pane an
    /// agent asked for, the agent that asked. When that focus already follows (a Move), the next
    /// candidate, so the popover never starts on the focus that has it. Nil when there are no focuses.
    var defaultInviteTag: String? {
        var candidates: [String] = []
        if info.kind == .ecs, info.requestedBy.kind == "focus", let requester = info.requestedBy.tag {
            candidates.append(requester)
        }
        candidates.append(info.tag)
        candidates.append(contentsOf: focuses.map(\.tag))
        let offered = candidates.filter { tag in focuses.contains { $0.tag == tag } }
        return offered.first { $0 != info.follower?.tag } ?? offered.first
    }

    /// The line under the picker: where this pane's output would go. A remote pane names its environment
    /// in capitals ("Output from PRODUCTION will be sent to Claudia's model."); a local one does not.
    func warning(forFocusTag tag: String) -> String {
        let agent = name(forTag: tag)
        if TerminalChromeModel.isRemote(info) {
            return "Output from \(TerminalChromeModel.environmentToken(for: info)) will be sent to \(agent)'s model."
        }
        return "Output will be sent to \(agent)'s model."
    }

    // MARK: - Send selection

    /// The focus Send selection offers first: the pane's owner (its daemon tag), else the first focus.
    var defaultSelectionTag: String? {
        focuses.contains(where: { $0.tag == info.tag }) ? info.tag : focuses.first?.tag
    }

    /// Every other focus, for the Send selection submenu.
    var otherSelectionFocuses: [FollowFocusOption] {
        let first = defaultSelectionTag
        return focuses.filter { $0.tag != first }
    }

    /// "Send selection to Claudia".
    static func sendSelectionTitle(to option: FollowFocusOption) -> String {
        "Send selection to \(option.name)"
    }

    // MARK: - Focus list

    /// The focuses as the popover and the menus offer them: sidebar order, the sidebar's name for each,
    /// the tag the daemon knows each by.
    static func options(from focuses: [Focus]) -> [FollowFocusOption] {
        focuses.map { FollowFocusOption(tag: $0.sessionTag, name: $0.displayName) }
    }

    // MARK: - Private

    /// The focus's label for `tag`; the tag itself for a focus that is gone.
    private func name(forTag tag: String) -> String {
        focuses.first { $0.tag == tag }?.name ?? tag
    }
}
