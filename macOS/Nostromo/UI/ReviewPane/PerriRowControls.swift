import SwiftUI
import NostromoKit

/// What a queue row's side-pane controls do. Injected by `DynamicFocusView.makeLeafView` for Perri
/// focuses only; nil elsewhere, so other panes and iOS are unchanged.
struct PerriRowActions {
    var openConversation: (_ repo: String, _ number: Int) -> Void
    var openDiff: (_ repo: String, _ number: Int) -> Void
    /// Draws the controls on this PR's row as if the pointer were over it. For tests only: a real
    /// pointer cannot be delivered to a window parked off screen in CI.
    var hoverOverride: Int? = nil
}

/// The PR a focus is reviewing right now when it is not in the queue ("Reviewing #N").
struct ReviewingPR: Equatable {
    let repo: String
    let number: Int
    let title: String
}

/// The Conversation and Diff buttons for one PR. Sibling views above the row's own button: pressing one
/// opens a tab and never runs the row's `onLoad`.
struct PerriRowControls: View {
    let repo: String
    let number: Int
    let actions: PerriRowActions
    /// Row-coloured, opaque: the controls sit over the row's second line without moving anything.
    var backing: Color = .black

    static let conversationLabel = "Conversation"
    static let diffLabel = "Diff"

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
        }
        .padding(3)
        .background(backing)
        // Needs room: below ~290 pt of row the icon buttons are used instead.
        .frame(minWidth: 290, alignment: .trailing)
    }

    private var iconOnly: some View {
        HStack(spacing: 4) {
            button(Self.conversationLabel, symbol: "bubble.left", showsText: false) { actions.openConversation(repo, number) }
            button(Self.diffLabel, symbol: "doc.plaintext", showsText: false) { actions.openDiff(repo, number) }
        }
        .padding(3)
        .background(backing)
    }

    private func button(_ title: String, symbol: String, showsText: Bool, action: @escaping () -> Void) -> some View {
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
        .help("\(title == Self.diffLabel ? "Diff" : "Conversation") for #\(number) in the side pane")
        .accessibilityLabel(title == Self.diffLabel ? "Open diff for pull request \(number)"
                                                    : "Open conversation for pull request \(number) in side pane")
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
    let onLoad: () -> Void
    @State private var hovered = false

    var body: some View {
        NostromoKit.PerriPRRow(model: model, onLoad: onLoad, onClear: {})
            .overlay(alignment: .bottomTrailing) {
                if model.marked || hovered || actions.hoverOverride == number {
                    PerriRowControls(repo: repo, number: number, actions: actions,
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
    }
}

/// The "Reviewing #N" row at the top of the queue when the pin is not in it.
struct PerriReviewingRow: View {
    let reviewing: ReviewingPR
    let actions: PerriRowActions

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
                             backing: Color(red: 0.07, green: 0.12, blue: 0.2))
        }
        .accessibilityElement(children: .contain)
    }
}
