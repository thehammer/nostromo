// Nostromo iOS — TabStripView.swift
//
// A horizontal tab strip over a region's content (W5 — ios-curated-view-
// parity, D1). Replaces the old per-pane `TabView`/`.tabItem`, which nested
// a second bottom tab bar inside the app's own root five-tab bar — this
// renders as a plain view at the TOP of the region's content instead, at
// both compact and (later, W6) regular width.
//
// Parameterised by region (a `[TabPlanEntry]`, a frontmost pane id, an
// unread predicate, a caption, and a selection callback) rather than being a
// singleton, even though `DynamicFocusView` only ever instantiates one of
// these today — W6 (regular width) instantiates one per simultaneously-
// visible region without this view needing to change shape.
//
// Selecting a tab is local client state (`onSelect`), with no daemon round
// trip — see `DaemonStore.selectPane`.
import SwiftUI
import NostromoKit

struct TabStripView: View {
    let entries:         [TabPlanEntry]
    let frontmostPaneId: String
    /// The frontmost tab's `PaneAddress.reason` (D8) — a one-line caption
    /// beneath the strip. `nil`/empty renders nothing.
    let reason:          String?
    let isUnread:        (String) -> Bool
    let onSelect:        (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(entries, id: \.paneId) { entry in
                        tabButton(entry)
                    }
                }
            }

            if let reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .background(.bar)
    }

    // MARK: - Tab button

    private func tabButton(_ entry: TabPlanEntry) -> some View {
        let selected = entry.paneId == frontmostPaneId
        let unread = isUnread(entry.paneId)
        return Button {
            onSelect(entry.paneId)
        } label: {
            HStack(spacing: 4) {
                Text(entry.label)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(selected ? .primary : .secondary)

                // Unread dot: always present, opacity-toggled rather than
                // conditionally inserted — a dot appearing must never
                // reflow the strip under the operator's eyes. Same
                // technique as NostromoKit's `PerriPRRow.markGlyph`.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .opacity(unread ? 1 : 0)
                    .accessibilityHidden(!unread)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}
