// NostromoKit — MotherCrewPanel.swift
//
// SwiftUI rendering of `MotherCrewPanelModel`: the progress line and its breakdown,
// the gate rows, the lens rows, attention badges and a read-only hold banner.
//
// Layout rules (the Mac hosts this in an `NSHostingView` it sizes by hand):
//   - every row is one line of a fixed height, truncated rather than wrapped, so the
//     panel's height is `MotherCrewPanelModel.height` and nothing else;
//   - rows are keyed by their stable ids, glyph columns have a fixed width and digits
//     are monospaced, so a value changing in place moves nothing;
//   - colors come from the host (`MotherCrewPanelColors`); every state is a glyph AND
//     a word, never a color alone, and no text is dimmed below the host's colors;
//   - each row reads as one VoiceOver element, with the model's accessibility string.

import SwiftUI

public struct MotherCrewPanelColors {
    public var text: Color
    public var muted: Color
    public var good: Color
    public var warn: Color
    public var bad: Color

    public init(text: Color, muted: Color, good: Color, warn: Color, bad: Color) {
        self.text = text
        self.muted = muted
        self.good = good
        self.warn = warn
        self.bad = bad
    }

    /// Light-on-dark defaults for a host that has no palette of its own.
    public static let standard = MotherCrewPanelColors(
        text: Color(white: 0.86), muted: Color(white: 0.62),
        good: Color(red: 0.13, green: 0.77, blue: 0.37),
        warn: Color(red: 0.92, green: 0.70, blue: 0.03),
        bad: Color(red: 0.94, green: 0.27, blue: 0.27)
    )
}

public struct MotherCrewPanel: View {
    public let model: MotherCrewPanelModel
    public let colors: MotherCrewPanelColors
    public let breakdownExpanded: Bool
    public let onToggleBreakdown: () -> Void
    /// Nil hides the "Details…" button.
    public let onDetails: (() -> Void)?
    /// Nil hides every Acknowledge button. The host decides whether the click was a person's.
    public let onAcknowledge: ((MotherAttentionReason) -> Void)?

    public init(
        model: MotherCrewPanelModel,
        colors: MotherCrewPanelColors = .standard,
        breakdownExpanded: Bool = false,
        onToggleBreakdown: @escaping () -> Void = {},
        onDetails: (() -> Void)? = nil,
        onAcknowledge: ((MotherAttentionReason) -> Void)? = nil
    ) {
        self.model = model
        self.colors = colors
        self.breakdownExpanded = breakdownExpanded
        self.onToggleBreakdown = onToggleBreakdown
        self.onDetails = onDetails
        self.onAcknowledge = onAcknowledge
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MotherCrewPanelMetrics.gap) {
            if let progress = model.progress {
                progressSection(progress)
            }
            if !model.gates.isEmpty {
                rowsSection(model.gates, detailsButton: true)
            }
            if !model.lenses.isEmpty {
                rowsSection(model.lenses, detailsButton: model.gates.isEmpty)
            }
            if !model.badges.isEmpty {
                badgeRow
            }
            if let hold = model.hold {
                holdSection(hold)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: model.height(breakdownExpanded: breakdownExpanded),
            maxHeight: model.height(breakdownExpanded: breakdownExpanded),
            alignment: .topLeading
        )
        .font(.system(size: 11))
        .monospacedDigit()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Crew")
    }

    // MARK: Sections

    private func progressSection(_ progress: MotherCrewPanelModel.Progress) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(progress.line)
                    .foregroundStyle(colors.text)
                    .lineLimit(1)
                    .accessibilityLabel(progress.accessibility)
                Spacer(minLength: 0)
                if !progress.breakdown.isEmpty {
                    Button(action: onToggleBreakdown) {
                        Text(breakdownExpanded ? "▾ breakdown" : "▸ breakdown")
                            .foregroundStyle(colors.muted)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Progress breakdown")
                    .accessibilityValue(breakdownExpanded ? "expanded" : "collapsed")
                }
            }
            .frame(height: MotherCrewPanelMetrics.row)

            if breakdownExpanded {
                ForEach(progress.breakdown) { row in
                    rowView(row, showDetails: false)
                }
            }
        }
    }

    private func rowsSection(_ rows: [MotherCrewRow], detailsButton: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                rowView(row, showDetails: detailsButton && row.kind == .header)
            }
        }
    }

    @ViewBuilder
    private var detailsControl: some View {
        if model.hasDetails, let onDetails {
            Button("Details…", action: onDetails)
                .buttonStyle(.plain)
                .foregroundStyle(colors.muted)
                .lineLimit(1)
                .accessibilityLabel("Show gate and review details")
        }
    }

    private func rowView(_ row: MotherCrewRow, showDetails: Bool) -> some View {
        HStack(spacing: 6) {
            Text(row.glyph)
                .foregroundStyle(glyphColor(row.glyph))
                .frame(width: 14, alignment: .center)
            Text(row.title)
                .font(.system(size: 11, weight: row.kind == .header ? .semibold : .medium))
                .foregroundStyle(row.kind == .header ? colors.muted : colors.text)
                .lineLimit(1)
                .layoutPriority(1)
            if !row.detail.isEmpty {
                Text(row.detail)
                    .foregroundStyle(colors.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if showDetails { detailsControl }
        }
        .frame(height: MotherCrewPanelMetrics.row)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibility)
    }

    private var badgeRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.badges.enumerated()), id: \.offset) { _, badge in
                HStack(spacing: 4) {
                    Text("⚑ \(badge.label)\(badge.acked ? " · acknowledged" : "")")
                        .foregroundStyle(badgeTint(badge))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(height: MotherCrewPanelMetrics.row - 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(badgeTint(badge), lineWidth: 1)
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(badge.accessibility)
                    if badge.canAcknowledge, let onAcknowledge {
                        Button("Acknowledge") { onAcknowledge(badge.reason) }
                            .buttonStyle(.plain)
                            .foregroundStyle(colors.muted)
                            .underline()
                            .lineLimit(1)
                            .accessibilityLabel(badge.acknowledgeAccessibility)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: MotherCrewPanelMetrics.row)
    }

    private func holdSection(_ hold: MotherHoldSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("⏸").foregroundStyle(colors.warn).frame(width: 14, alignment: .center)
                Text("Held: \(hold.kind)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.warn)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: MotherCrewPanelMetrics.row)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(hold.accessibility)

            ForEach(Array(hold.options.enumerated()), id: \.offset) { _, option in
                VStack(alignment: .leading, spacing: 0) {
                    Text("• \(option.label)\(option.takesText ? " (takes a note)" : "")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(colors.text)
                        .lineLimit(1)
                        .frame(height: MotherCrewPanelMetrics.row, alignment: .leading)
                    if !option.consequence.isEmpty {
                        Text(option.consequence)
                            .foregroundStyle(colors.muted)
                            .lineLimit(2)
                            .padding(.leading, 12)
                            .frame(height: MotherCrewPanelMetrics.consequence, alignment: .topLeading)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(option.accessibility)
            }
        }
    }

    // MARK: Colors

    private func glyphColor(_ glyph: String) -> Color {
        switch glyph {
        case "✓": return colors.good
        case "✗": return colors.bad
        case "?", "…": return colors.warn
        default: return colors.muted
        }
    }

    /// An acknowledged badge is muted; otherwise its reason sets the color.
    private func badgeTint(_ badge: MotherAttentionBadge) -> Color {
        if badge.acked { return colors.muted }
        switch badge.reason {
        case .gatesIncomplete, .decisionAwaiting, .unknown: return colors.warn
        case .progressStalled, .burnAhead: return colors.bad
        }
    }
}
