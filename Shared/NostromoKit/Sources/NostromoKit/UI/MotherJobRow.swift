// NostromoKit — MotherJobRow.swift
//
// Shared SwiftUI row for the Mother job queue.  Used by both iOS (inside a
// NavigationLink) and macOS (inside an NSHostingView-wrapped List).
//
// Swipe actions work via trackpad on macOS 13+ and finger swipe on iOS.
// Terminal-state rows show "Archive"; active rows show "Cancel".

import SwiftUI

/// A single Mother job row with built-in swipe-to-archive / swipe-to-cancel
/// and a state-aware right-click / long-press context menu.
public struct MotherJobRow: View {
    public let model: MotherJobRowModel
    public let onArchive: () -> Void
    public let onCancel: () -> Void
    public let onRetry: () -> Void
    public let onForceStart: () -> Void
    /// Set by the Mac when the origin is a clickable focus. Nil leaves the origin plain text.
    public let onOriginTap: (() -> Void)?

    public init(
        model: MotherJobRowModel,
        onArchive:    @escaping () -> Void = {},
        onCancel:     @escaping () -> Void = {},
        onRetry:      @escaping () -> Void = {},
        onForceStart: @escaping () -> Void = {},
        onOriginTap:  (() -> Void)? = nil
    ) {
        self.model        = model
        self.onArchive    = onArchive
        self.onCancel     = onCancel
        self.onRetry      = onRetry
        self.onForceStart = onForceStart
        self.onOriginTap  = onOriginTap
    }

    public var body: some View {
        rowContent
            .modifier(OriginAccessibility(model: model, onOriginTap: onOriginTap))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if model.isDone {
                    Button(role: .destructive, action: onArchive) {
                        Label("Archive", systemImage: "archivebox")
                    }
                } else {
                    Button(role: .destructive, action: onCancel) {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                }
            }
            .contextMenu { contextMenuItems }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuItems: some View {
        switch model.state {
        case "running":
            Button(action: onCancel) {
                Label("Cancel", systemImage: "xmark.circle")
            }

        case "awaiting":
            if let question = model.question {
                Button(action: {}) {
                    Label("Answer: \(question)", systemImage: "questionmark.bubble")
                }
                .disabled(true)
                Divider()
            }
            Button(action: onCancel) {
                Label("Cancel", systemImage: "xmark.circle")
            }

        case "queued", "ready":
            Button(action: onForceStart) {
                Label("Force Start", systemImage: "play.circle")
            }
            Button(action: onCancel) {
                Label("Cancel", systemImage: "xmark.circle")
            }

        case "failed", "cancelled":
            Button(action: onRetry) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive, action: onArchive) {
                Label("Archive", systemImage: "archivebox")
            }

        case "succeeded":
            Button(role: .destructive, action: onArchive) {
                Label("Archive", systemImage: "archivebox")
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Row layout

    private var rowContent: some View {
        HStack(spacing: 12) {
            stateCircle

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title.isEmpty ? model.id : model.title)
                    .font(.headline)
                    .lineLimit(2)

                if model.origin != nil || repoBranchLabel != nil {
                    detailLine
                }

                if model.reservesProgressLine {
                    progressRow
                }
            }

            Spacer()

            if let ts = model.relativeTimestamp {
                Text(ts)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    /// `origin · repo • branch`. The origin truncates first: the repo keeps its width.
    private var detailLine: some View {
        HStack(spacing: 4) {
            if let origin = model.origin {
                originView(origin)
                if origin.badge != nil, let badge = origin.badge {
                    Text(badge)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(.quaternary))
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                if repoBranchLabel != nil { Text("·").layoutPriority(1) }
            }
            if let repoBranch = repoBranchLabel {
                Text(repoBranch)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func originView(_ origin: MotherOriginDisplay) -> some View {
        let base = Text(origin.text).italic(origin.isItalic)
        if origin.isClickable, let onOriginTap {
            Button(action: onOriginTap) { originText(base.underline(), origin) }
                .buttonStyle(.plain)
                .help(origin.tooltip)
                .accessibilityLabel(origin.accessibilityText)
        } else {
            originText(base, origin)
                .help(origin.tooltip)
                .accessibilityLabel(origin.accessibilityText)
        }
    }

    private func originText(_ text: Text, _ origin: MotherOriginDisplay) -> some View {
        text.lineLimit(1)
            .truncationMode(.tail)
            .opacity(origin.isMuted ? 0.7 : 1)
    }

    /// `≈60% · gates 2/3 · ETA ~25m` and attention badges. The line is always there for
    /// running and awaiting jobs (blank when there is nothing to say), so it never
    /// changes the row's height when progress or a flag first arrives.
    private var progressRow: some View {
        HStack(spacing: 6) {
            Text(model.progressLine ?? " ")
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(model.progressAccessibility ?? model.progressLine ?? "")
                .accessibilityHidden(model.progressLine == nil)
            Spacer(minLength: 0)
            ForEach(model.attentionBadges, id: \.self) { badge in
                Text("⚑ \(badge)")
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.orange)
                    .accessibilityLabel(badge)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var stateCircle: some View {
        Circle()
            .fill(stateColor)
            .frame(width: 10, height: 10)
            .padding(.top, 2)
    }

    private var stateColor: Color {
        switch model.state {
        case "running":          return .blue
        case "awaiting":         return .orange
        case "queued", "ready":  return .gray
        case "succeeded":        return .green
        case "failed":           return .red
        case "cancelled":        return .gray
        default:                 return .gray
        }
    }

    private var repoBranchLabel: String? {
        switch (model.repo, model.branch) {
        case (let r?, let b?): return "\(r) • \(b)"
        case (let r?, nil):    return r
        case (nil, let b?):    return b
        case (nil, nil):       return nil
        }
    }
}


/// What a row says to VoiceOver. Decided here, apart from SwiftUI, so it can be tested: nothing
/// changes for a row without an origin (iOS); with one, the row reads as one element, `<title>.
/// From <origin>.`, and a clickable origin stays reachable as a named action.
public struct OriginAccessibilityDecision: Equatable, Sendable {
    public let label: String
    /// Set only for a clickable origin that has a tap handler.
    public let actionName: String?

    /// Nil when the row has no origin: its accessibility is left alone.
    public static func make(model: MotherJobRowModel, hasOriginTap: Bool) -> OriginAccessibilityDecision? {
        guard let origin = model.origin else { return nil }
        return OriginAccessibilityDecision(
            label: model.accessibilitySummary,
            actionName: origin.isClickable && hasOriginTap ? "Show \(origin.text)" : nil)
    }
}

struct OriginAccessibility: ViewModifier {
    let model: MotherJobRowModel
    let onOriginTap: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let decision = OriginAccessibilityDecision.make(model: model, hasOriginTap: onOriginTap != nil) {
            if let name = decision.actionName, let onOriginTap {
                content
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(decision.label)
                    .accessibilityAction(named: name, onOriginTap)
            } else {
                content
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(decision.label)
            }
        } else {
            content
        }
    }
}
