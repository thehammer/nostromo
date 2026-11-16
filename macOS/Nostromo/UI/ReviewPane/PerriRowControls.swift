import SwiftUI
import NostromoKit

/// What a queue row's side-pane controls do. Injected by `DynamicFocusView.makeLeafView` for Perri
/// focuses only; nil elsewhere, so other panes and iOS are unchanged.
struct PerriRowActions {
    var openConversation: (_ repo: String, _ number: Int) -> Void
    var openDiff: (_ repo: String, _ number: Int) -> Void
    /// Opens the Jira ticket `key` for this PR; `order` is its position in the row's keys.
    var openTicket: (_ repo: String, _ number: Int, _ key: String, _ order: Int) -> Void = { _, _, _, _ in }
    /// The Jira site (bare host) ticket controls open on; nil draws none.
    var jiraSite: () -> String? = { AppStore.shared.perriJiraSite }
    /// Draws the controls on this PR's row as if the pointer were over it. For tests only: a real
    /// pointer cannot be delivered to a window parked off screen in CI.
    var hoverOverride: Int? = nil
}

extension PerriRowActions {
    /// Controls that open tabs in `pane`. The ticket control opens `https://<site>/browse/<KEY>` on the
    /// configured Jira site, and nothing when there is no site or the key is malformed.
    static func opening(in pane: ReviewPaneModel,
                        jiraSite: @escaping () -> String? = { AppStore.shared.perriJiraSite }) -> PerriRowActions {
        PerriRowActions(
            openConversation: { repo, number in
                let pr = ReviewPR(repo: repo, number: number)
                if pr.conversationURL != nil { pane.open(pr: pr, target: .conversation) }
            },
            openDiff: { repo, number in
                let pr = ReviewPR(repo: repo, number: number)
                if pr.diffURL != nil { pane.open(pr: pr, target: .diff) }
            },
            openTicket: { repo, number, key, order in
                let pr = ReviewPR(repo: repo, number: number)
                guard pr.conversationURL != nil, let site = jiraSite(),
                      let url = ReviewPR.ticketURL(site: site, key: key) else { return }
                pane.open(pr: pr, target: .ticket(key), url: url, ticketOrder: order)
            },
            jiraSite: jiraSite)
    }
}

/// The PR a focus is reviewing right now when it is not in the queue ("Reviewing #N").
struct ReviewingPR: Equatable {
    let repo: String
    let number: Int
    let title: String
}

/// The ticket keys a row may offer: none unless a Jira site is configured.
func perriTicketKeys(_ tickets: [String], actions: PerriRowActions) -> [String] {
    actions.jiraSite() == nil ? [] : TicketKeys.sanitize(tickets)
}

/// The Conversation and Diff buttons for one PR. Sibling views above the row's own button: pressing one
/// opens a tab and never runs the row's `onLoad`.
struct PerriRowControls: View {
    let repo: String
    let number: Int
    let actions: PerriRowActions
    /// Detected ticket keys; drawn only when a Jira site is configured.
    var tickets: [String] = []
    /// Row-coloured, opaque: the controls sit over the row's second line without moving anything.
    var backing: Color = .black

    static let conversationLabel = "Conversation"
    static let diffLabel = "Diff"

    private var ticketKeys: [String] { perriTicketKeys(tickets, actions: actions) }

    /// The label on the first ticket's button.
    static func ticketLabel(_ key: String) -> String { "Ticket \(key)" }
    /// The disclosure's label for `count` further tickets.
    static func moreLabel(_ count: Int) -> String { "\(count) more ticket\(count == 1 ? "" : "s")" }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            labelled
            iconOnly
        }
        .padding(.trailing, 4)
        .padding(.bottom, 3)
    }

    private var labelled: some View {
        HStack(spacing: 4) {
            button(Self.conversationLabel, symbol: "bubble.left", showsText: true) { actions.openConversation(repo, number) }
            button(Self.diffLabel, symbol: "doc.plaintext", showsText: true) { actions.openDiff(repo, number) }
            ticketControls(showsText: true)
        }
        .padding(3)
        .background(backing)
        // Needs room: below ~290 pt of row (more with a ticket) the icon buttons are used instead.
        .frame(minWidth: 290 + (ticketKeys.isEmpty ? 0 : 130) + (ticketKeys.count > 1 ? 36 : 0),
               alignment: .trailing)
    }

    private var iconOnly: some View {
        HStack(spacing: 4) {
            button(Self.conversationLabel, symbol: "bubble.left", showsText: false) { actions.openConversation(repo, number) }
            button(Self.diffLabel, symbol: "doc.plaintext", showsText: false) { actions.openDiff(repo, number) }
            ticketControls(showsText: false)
        }
        .padding(3)
        .background(backing)
    }

    /// **Ticket KEY** for the first key, and a `+N` menu for the rest.
    @ViewBuilder
    private func ticketControls(showsText: Bool) -> some View {
        if let first = ticketKeys.first {
            button(Self.ticketLabel(first), symbol: "ticket", showsText: showsText,
                   help: "Ticket \(first) in the side pane",
                   accessibility: "Open ticket \(first)") { actions.openTicket(repo, number, first, 0) }
            let rest = Array(ticketKeys.dropFirst())
            if !rest.isEmpty {
                // The chip is drawn here (a menu style may restyle its label); an invisible menu sits over it.
                Text("+\(rest.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(white: 0.92))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.24)))
                    .accessibilityHidden(true)
                    .overlay {
                        Menu {
                            ForEach(Array(rest.enumerated()), id: \.element) { offset, key in
                                Button("Open ticket \(key)") { actions.openTicket(repo, number, key, offset + 1) }
                            }
                        } label: {
                            Color.clear
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .accessibilityLabel(Self.moreLabel(rest.count))
                    }
                    .help(Self.moreLabel(rest.count))
            }
        }
    }

    private func button(_ title: String, symbol: String, showsText: Bool,
                        help: String? = nil, accessibility: String? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 10))
                if showsText { Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize() }
            }
            .foregroundColor(Color(white: 0.92))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.24)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "\(title == Self.diffLabel ? "Diff" : "Conversation") for #\(number) in the side pane")
        .accessibilityLabel(accessibility ?? (title == Self.diffLabel ? "Open diff for pull request \(number)"
                                                    : "Open conversation for pull request \(number) in side pane"))
    }
}

/// A queue row with the side-pane controls drawn over it on the marked and hovered row. The controls
/// are an overlay: no row's height or position changes. Every row exposes both as accessibility actions
/// whether drawn or not.
struct PerriQueueRow: View {
    let model: PerriPRRowModel
    let repo: String
    let number: Int
    let actions: PerriRowActions
    var tickets: [String] = []
    let onLoad: () -> Void
    @State private var hovered = false

    var body: some View {
        NostromoKit.PerriPRRow(model: model, onLoad: onLoad, onClear: {})
            .overlay(alignment: .bottomTrailing) {
                if model.marked || hovered || actions.hoverOverride == number {
                    PerriRowControls(repo: repo, number: number, actions: actions, tickets: tickets,
                                     backing: model.marked ? Color(red: 0.07, green: 0.12, blue: 0.2) : .black)
                }
            }
            .onHover { hovered = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: Text("Open conversation for pull request \(number) in side pane")) {
                actions.openConversation(repo, number)
            }
            .accessibilityAction(named: Text("Open diff for pull request \(number)")) {
                actions.openDiff(repo, number)
            }
            .accessibilityActions {
                ForEach(Array(perriTicketKeys(tickets, actions: actions).enumerated()), id: \.element) { offset, key in
                    Button("Open ticket \(key)") { actions.openTicket(repo, number, key, offset) }
                }
            }
    }
}

/// The "Reviewing #N" row at the top of the queue when the pin is not in it.
struct PerriReviewingRow: View {
    let reviewing: ReviewingPR
    let actions: PerriRowActions
    /// From the matching queue item when there is one, else none.
    var tickets: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reviewing #\(reviewing.number)")
                    .font(.headline)
                Text("\(reviewing.repo) • \(reviewing.title)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4).padding(.leading, 4)
        .background(Color.accentColor.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .bottomTrailing) {
            PerriRowControls(repo: reviewing.repo, number: reviewing.number, actions: actions,
                             tickets: tickets, backing: Color(red: 0.07, green: 0.12, blue: 0.2))
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            ForEach(Array(perriTicketKeys(tickets, actions: actions).enumerated()), id: \.element) { offset, key in
                Button("Open ticket \(key)") { actions.openTicket(reviewing.repo, reviewing.number, key, offset) }
            }
        }
    }
}
