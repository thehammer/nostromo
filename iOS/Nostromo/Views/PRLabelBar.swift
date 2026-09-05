// Nostromo iOS — PRLabelBar.swift
//
// The per-focus "which PR am I in" label (W8 — per-focus-pr-indicator),
// answering the PRD's operator-visibility requirement
// (docs: .claude/prds/pr-review-concurrency-model.md): "a focus that has a
// PR under review says so, on screen, without anyone calling a tool. Repo
// and number, plainly, in that focus. A focus with none says it has none."
//
// A fixed-height top `safeAreaInset`, mirroring `ActivityTickerBar`'s bottom
// one (`Views/Activity/ActivityTickerBar.swift`) — same recipe, same reason:
// D4 there (and here) is that a height which changes when content loads
// shifts the transcript's scroll content inset out from under the operator.
// So this bar is exactly one line, at a fixed height, always — `lineLimit(1)`,
// `.truncationMode(.tail)`, an explicit `.frame(height:)` — regardless of
// whether it's showing a real PR or the explicit "no PR" string
// (`FocusPRLabel.noPR`, never empty, never absent).
//
// `text` is precomputed by the caller via `FocusPRLabel.secondary(repo:
// number:fallback:)` — this view renders whatever string it's handed and
// does not derive PR identity itself, the same "one shared derivation, view
// never inlines `payload.repo`" rule `FocusPRLabel`'s own doc comment states.

import SwiftUI

struct PRLabelBar: View {
    let text: String

    private static let barHeight: CGFloat = 28

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
