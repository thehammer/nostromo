// Nostromo iOS — DecisionSheetView.swift
//
// Renders one `nostromo.ask_decision` request: a prompt, an optional detail,
// the display name of the focus that asked, and one control per choice
// (each showing its own optional detail). Answering takes exactly one tap —
// no confirmation dialog, unlike the queue's swipe-to-approve — because the
// modal itself already interrupted the operator with the full context of
// what they're choosing; the tap IS the confirmation (ios-curated-view-
// parity W3, D6).
//
// Presented from exactly one place — `NostromoApp.swift`'s `ContentView`,
// above the root TabView (D1) — so this view is never inside a lazy
// container and never recycled across different requests, and it holds NO
// answered-state itself: `resolution` is always computed from
// `DaemonStore.decisionStore.resolution(for:)` at the call site and passed
// in with no default value, so a request already answered (by this client
// or another) reconstructs inert rather than armed. See `DecisionStore`
// (NostromoKit) for the actual answer-once gate; this view never touches it
// directly — it only ever routes user interaction through `onClose`.

import SwiftUI
import NostromoKit

/// Why this decision sheet is going away. Only the first two ever produce a
/// wire message (via the caller's `onClose` handling in `NostromoApp.swift`)
/// — `.supersededByDaemon` exists so a system-initiated close (the daemon
/// already reported this request resolved, e.g. answered on another device,
/// timed out, or cancelled) can never be mistaken for an operator dismissal.
/// A spurious dismissal here would read to the calling agent as an explicit
/// Skip that the operator never chose.
enum DecisionCloseReason {
    /// The operator tapped a choice button.
    case operatorChose(String)
    /// The operator tapped Dismiss, or swiped the sheet away.
    case operatorDismissed
    /// This request was already resolved elsewhere by the time this sheet
    /// would otherwise have reacted to it. No code path in this view ever
    /// constructs this case — see the doc comment above.
    case supersededByDaemon
}

struct DecisionSheetView: View {
    let request: PendingDecision
    /// Display name of the focus that asked, resolved by the caller from
    /// `DaemonStore.focuses[request.tag]`. `nil` means the caller couldn't
    /// resolve it — rendered as an explicit fallback, never silently as if
    /// the tag itself were a name.
    let askingFocusName: String?
    /// The resolution already recorded for this request, if any. Non-nil
    /// means this sheet renders the resolved state and is inert: every
    /// control is disabled and no tap can call `onClose`. Deliberately has
    /// no default value, so the compiler is the wiring check for every
    /// construction site — the same trick `AskQuestionView.init` and
    /// macOS's `DecisionSheet.init` use for exactly this bug class.
    let resolution: DecisionResolutionRecord?
    let onClose: (DecisionCloseReason) -> Void

    init(
        request: PendingDecision,
        askingFocusName: String?,
        resolution: DecisionResolutionRecord?,
        onClose: @escaping (DecisionCloseReason) -> Void
    ) {
        self.request = request
        self.askingFocusName = askingFocusName
        self.resolution = resolution
        self.onClose = onClose
    }

    private var isResolved: Bool { resolution != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            focusHeader

            VStack(alignment: .leading, spacing: 6) {
                Text(request.prompt)
                    .font(.headline)
                if let detail = request.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 10) {
                ForEach(request.choices, id: \.id) { choice in
                    choiceButton(choice)
                }
            }

            if isResolved {
                resolvedCaption
            } else {
                Button("Dismiss", role: .cancel) {
                    onClose(.operatorDismissed)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .presentationDetents([.medium, .large])
    }

    // MARK: - Header

    @ViewBuilder
    private var focusHeader: some View {
        // The operator may be nowhere near the focus that asked (D1) — name
        // it explicitly rather than relying on which tab happens to be
        // frontmost. A focus the client doesn't recognize falls back to the
        // raw tag, marked as a fallback rather than presented as a name.
        if let askingFocusName {
            Text(askingFocusName)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("From \(request.tag) (focus name unknown)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Choices

    private func choiceButton(_ choice: DecisionChoice) -> some View {
        Button {
            onClose(.operatorChose(choice.id))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let detail = choice.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(choiceBackground(choice.id))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(isResolved)
    }

    private func choiceBackground(_ choiceId: String) -> Color {
        if isChosen(choiceId) {
            return Color.green.opacity(0.18)
        }
        return Color.accentColor.opacity(isResolved ? 0.05 : 0.12)
    }

    private func isChosen(_ choiceId: String) -> Bool {
        if case .choice(let id) = resolution { return id == choiceId }
        return false
    }

    // MARK: - Resolved state

    @ViewBuilder
    private var resolvedCaption: some View {
        switch resolution {
        case .choice:
            Text("Answered")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .dismissed:
            Text("Dismissed")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .resolvedElsewhere(let reason):
            Text(resolvedElsewhereCaption(reason))
                .font(.caption)
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    private func resolvedElsewhereCaption(_ reason: String) -> String {
        switch reason {
        case "timeout":   return "Timed out"
        case "cancelled": return "Cancelled"
        default:          return "Resolved elsewhere"
        }
    }
}
