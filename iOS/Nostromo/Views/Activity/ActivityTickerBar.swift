// Nostromo iOS — ActivityTickerBar.swift
//
// The always-present ambient-activity line (ios-curated-view-parity W4) —
// the iOS analogue of macOS's window-level `ActivityTickerView` overlay,
// reshaped for a phone: a fixed-height single-line bar composed above the
// input bar inside `TranscriptView`'s bottom safe-area inset (see
// `DynamicFocusView`, which owns and injects it), or as a plain bottom inset
// directly on a non-repl surface that has no input bar of its own.
//
// D4 (the inviolable property): an activity event arriving while the
// operator is reading must never move what they're looking at. The
// transcript's autoscroll is keyed only on `store.turns.count`
// (`TranscriptView`), so an activity event cannot trigger it directly — but
// a `safeAreaInset` whose HEIGHT changes shifts the scroll view's content
// inset with no scroll call ever being made. So this bar is exactly one
// line, at a fixed height, always — `lineLimit(1)`, `.truncationMode(.tail)`,
// and an explicit `.frame(height:)` — regardless of whether it's showing a
// (pre-truncated) event summary or a longer not-ingesting health message.
//
// D6: renders nothing but the text `displayText(health:)` already computed
// — never `toolInput`, `cwd`, or `toolUseId`. D7: no enable/disable control
// of any kind lives here or anywhere in this wedge.

import SwiftUI

struct ActivityTickerBar: View {
    /// Precomputed by the caller via `ActivityStreamModel.displayText(health:)`
    /// — health always wins over a cached last event when not ingesting.
    let text: String
    let onTap: () -> Void

    private static let barHeight: CGFloat = 28

    var body: some View {
        Button(action: onTap) {
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
        .buttonStyle(.plain)
    }
}
