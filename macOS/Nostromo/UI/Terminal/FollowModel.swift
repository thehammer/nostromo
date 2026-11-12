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
        /// The follower may stage commands here and receives no output. `by` is the follower focus's label.
        case stagingOnly(by: String)
    }

    /// What the invite popover gives the invited agent.
    enum InviteMode: Equatable {
        /// Today's follow: the terminal's output goes to the agent's model.
        case output
        /// The agent may stage commands for this terminal and receives no output.
        case stagingOnly
    }

    static let notSharedText = "Not shared"
    static let notSharedDescription = "No agent is following this terminal"
    /// The invite popover's checkbox. Off by default (the screen's current contents go out only when ticked).
    static let includeScreenTitle = "Include what's on screen now"
    static let includeScreenDefault = false
    /// The popover's mode group (shown only when the daemon knows the staging-only follow).
    static let modeGroupTitle = "What the agent gets"
    static let outputOptionTitle = "Output: it reads this terminal"
    static let stagingOnlyOptionTitle = "Staging only: it proposes commands and sees no output"
    /// The least width the header gives the badge when there is room: wide enough for "Not shared".
    static let badgeMinWidth: CGFloat = 72

    let info: TerminalInfo
    /// Every focus, in the sidebar's order.
    let focuses: [FollowFocusOption]
    /// The daemon advertised `terminal_staging_only_v1`: the invite popover offers the staging-only mode.
    /// Without it the popover is exactly what it was before the mode existed.
    let offersStagingOnly: Bool

    init(info: TerminalInfo, focuses: [FollowFocusOption], offersStagingOnly: Bool = false) {
        self.info = info
        self.focuses = focuses
        self.offersStagingOnly = offersStagingOnly
    }

    // MARK: - State and badge

    var state: State {
        guard let follower = info.follower else { return .notShared }
        let label = name(forTag: follower.tag)
        if follower.isStagingOnly { return .stagingOnly(by: label) }
        return follower.paused ? .paused(by: label, reason: follower.pauseReason) : .followed(by: label)
    }

    /// "Not shared", "Followed by Claudia", "Paused, too much output".
    var badgeText: String {
        switch state {
        case .notShared:                  return Self.notSharedText
        case .followed(let label):        return "Followed by \(label)"
        case .paused(_, let reason):      return Self.pausedText(reason: reason)
        case .stagingOnly(let label):     return "Staging only: \(label)"
        }
    }

    /// Never red (a red header is how a remote pane says "production"): muted for nobody, blue while
    /// followed (blue means output flows), amber while paused, muted while staging only (no output flows). Drawn as a filled pill with dark text, so it reads on a red header too.
    var badgeColor: NSColor {
        switch state {
        case .notShared: return Theme.fgMuted
        case .followed:  return Theme.followBlue
        case .paused:    return Theme.amber
        case .stagingOnly: return Theme.fgMuted
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
        case .stagingOnly(let label):
            return "\(label) can stage commands for you to place. This terminal's output is not sent to \(label)'s model."
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
        // Revoke is Stop: it ends the follow and freezes the staged list.
        case .stagingOnly: return [.stop, .move]
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

    /// The focuses the picker lists for `mode`. The current follower is left out only when `mode` is what it
    /// already has, so a person can change its mode from here (staging only to full is a person's choice, and
    /// the daemon starts a new follow with an empty list). Without the staging-only mode on offer, as `inviteFocuses`.
    func inviteFocuses(for mode: InviteMode) -> [FollowFocusOption] {
        guard offersStagingOnly, let follower = info.follower, currentMode(of: follower) != mode else {
            return inviteFocuses
        }
        return focuses
    }

    /// The popover's title for the focus `tag` and `mode`: a mode change on the focus that follows already
    /// reads `Change what Claudia gets`; anything else is `inviteHeading`.
    func inviteHeading(forTag tag: String?, mode: InviteMode) -> String {
        if offersStagingOnly, let tag, let follower = info.follower, follower.tag == tag, currentMode(of: follower) != mode {
            return "Change what \(name(forTag: tag)) gets"
        }
        return inviteHeading
    }

    /// The Invite button's spoken label.
    func inviteAccessibilityLabel(mode: InviteMode) -> String {
        switch mode {
        case .output: return "Invite the chosen agent to follow this terminal"
        case .stagingOnly: return "Invite the chosen agent to stage commands only, with no output"
        }
    }

    /// What the invite form has selected when it opens: what the pane's follower already gets, so a Move
    /// never turns a staging-only follow into a full one without a person choosing Output. Output for a
    /// fresh invite (and whenever the staging-only mode is not on offer).
    var defaultInviteMode: InviteMode {
        guard offersStagingOnly, let follower = info.follower else { return .output }
        return currentMode(of: follower)
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
    func warning(forFocusTag tag: String, mode: InviteMode = .output) -> String {
        let agent = name(forTag: tag)
        if mode == .stagingOnly {
            if TerminalChromeModel.isRemote(info) {
                return "Output from \(TerminalChromeModel.environmentToken(for: info)) will NOT be sent to \(agent)'s model. \(agent) can stage commands; you place and run each one."
            }
            return "\(agent) can stage commands for this terminal. Its output will NOT be sent to \(agent)'s model."
        }
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
    /// The most selected text one Send selection carries: the daemon's per-delivery byte cap
    /// (`DeliveryPolicy::CAP_BYTES`). More is refused here, with `selectionTooLargeMessage`.
    static let selectionLimitBytes = 16 * 1024

    /// The menu items' tooltip: what happens to the text on its way.
    static let sendSelectionTooltip = "The daemon redacts secrets from the selection and caps it at 16 KB before the agent's model sees it."

    /// What a person is told when the selection is over the limit.
    static let selectionTooLargeMessage = "That selection is too large to send (the limit is 16 KB). Select less and try again."

    static func selectionIsTooLarge(_ text: String) -> Bool {
        text.utf8.count > selectionLimitBytes
    }

    static func sendSelectionTitle(to option: FollowFocusOption) -> String {
        "Send selection to \(option.name)"
    }

    /// The Send selection menu item for `option`. A focus that follows staging only gets a label and a
    /// warning: sending a selection hands its model text it is otherwise never sent, so a person who
    /// believes that agent is blind is told otherwise here. Every other focus reads as it always did.
    func sendSelectionMenuItem(for option: FollowFocusOption, enabled: Bool, target: AnyObject?, action: Selector) -> NSMenuItem {
        let stagingOnlyTarget = info.follower.map { $0.tag == option.tag && $0.isStagingOnly } ?? false
        var title = Self.sendSelectionTitle(to: option)
        var tooltip = Self.sendSelectionTooltip
        var spoken = title
        if stagingOnlyTarget {
            title += " (staging only: this gives it output)"
            tooltip = "\(option.name) follows this terminal staging only and is not sent its output. "
                + "Sending this selection gives \(option.name)'s model text it would not otherwise see. " + tooltip
            spoken = title + ". " + tooltip
        }
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = target
        entry.representedObject = option.tag
        entry.toolTip = tooltip
        entry.setAccessibilityLabel(spoken)
        entry.isEnabled = enabled
        return entry
    }

    // MARK: - Focus list

    /// The focuses as the popover and the menus offer them: sidebar order, the sidebar's name for each,
    /// the tag the daemon knows each by.
    static func options(from focuses: [Focus]) -> [FollowFocusOption] {
        focuses.map { FollowFocusOption(tag: $0.sessionTag, name: $0.displayName) }
    }

    // MARK: - Private

    private func currentMode(of follower: TerminalFollower) -> InviteMode {
        follower.isStagingOnly ? .stagingOnly : .output
    }

    /// The focus's label for `tag`; the tag itself for a focus that is gone.
    private func name(forTag tag: String) -> String {
        focuses.first { $0.tag == tag }?.name ?? tag
    }
}
