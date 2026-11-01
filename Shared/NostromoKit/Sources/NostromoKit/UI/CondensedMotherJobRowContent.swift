// NostromoKit — CondensedMotherJobRowContent.swift
//
// The two-line, fixed-height Mother job row (`MotherJobRowStyle.condensed`, Mac list).
// Line 1: state dot · one-line title · age. Line 2: `MotherRowLineTwo` (origin · repo · state
// fact · cost), attention badges and the reserved notified-mark slot. Both lines have fixed
// frames and `lineLimit(1)`, so the row's height never depends on what it says.

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct CondensedMotherJobRowContent: View {
    let model: MotherJobRowModel
    let onOriginTap: (() -> Void)?

    private var title: String {
        FoldTextSanitizer.sanitizeInline(model.title.isEmpty ? model.id : model.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MotherRowMetrics.lineSpacing) {
            lineOne
                .frame(height: MotherRowMetrics.titleLineHeight)
            GeometryReader { geo in
                lineTwo(MotherRowLineTwo.compose(
                    model: model, availableWidth: geo.size.width, measure: MotherRowTextMeasure.width))
            }
            .frame(height: MotherRowMetrics.detailLineHeight)
        }
        .padding(.vertical, MotherRowMetrics.verticalPadding)
        .padding(.horizontal, MotherRowMetrics.horizontalPadding)
        .frame(height: MotherRowMetrics.rowHeight)
        .clipped()
        .help(MotherRowLineTwo.cappedTitle(model))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MotherRowLineTwo.accessibilityLabel(model: model))
        .modifier(OriginTapAction(origin: model.origin, onOriginTap: onOriginTap))
    }

    private var lineOne: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(MotherJobRow.stateColor(for: model.state))
                .frame(width: 8, height: 8)
            Text(title)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(model.relativeTimestamp ?? "")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func lineTwo(_ line: MotherRowLineTwo) -> some View {
        HStack(spacing: 0) {
            originView(line.origin)
                .layoutPriority(1)
            if let repo = line.repo { segment(repo, priority: 0.5) }
            segment(line.stateFact, priority: 0)
            if let cost = line.cost { segment(cost, priority: 0.5) }
            Spacer(minLength: 4)
            ForEach(Array(line.badges.enumerated()), id: \.offset) { _, badge in
                Text(badge)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.orange)
                    .padding(.trailing, line.badgesCollapsed ? 2 : MotherRowLineTwo.badgeSpacing)
                    .help(badgeTooltip)
            }
            notifiedMark(line.notifiedMark)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// The notified mark. App-drawn from the daemon's status; it never contains agent text except a
    /// sanitised, capped name. Empty (but still reserving its slot) when the focus is not notified.
    @ViewBuilder
    private func notifiedMark(_ text: String?) -> some View {
        if let text, let mark = model.noticeMark {
            Text(text)
                .lineLimit(1)
                .fixedSize()
                .help(mark.tooltip)
        } else {
            Color.clear.frame(width: MotherRowLineTwo.notifiedSlotWidth, height: 1)
        }
    }

    private var badgeTooltip: String {
        model.attentionBadges.map { MotherOriginDisplay.clean($0, cap: 60) }.joined(separator: ", ")
    }

    private func segment(_ text: String, priority: Double) -> some View {
        HStack(spacing: 0) {
            Text(MotherRowLineTwo.separator)
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .layoutPriority(priority)
    }

    @ViewBuilder
    private func originView(_ text: String) -> some View {
        if let origin = model.origin {
            let base = Text(text).italic(origin.isItalic)
            if origin.isClickable, let onOriginTap {
                Button(action: onOriginTap) {
                    base.underline().lineLimit(1).truncationMode(.tail).opacity(origin.isMuted ? 0.7 : 1)
                }
                .buttonStyle(.plain)
                .help(origin.tooltip)
            } else {
                base.lineLimit(1).truncationMode(.tail)
                    .opacity(origin.isMuted ? 0.7 : 1)
                    .help(origin.tooltip)
            }
        } else {
            EmptyView()
        }
    }
}

/// A clickable origin stays reachable to VoiceOver as a named action.
private struct OriginTapAction: ViewModifier {
    let origin: MotherOriginDisplay?
    let onOriginTap: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let origin, origin.isClickable, let onOriginTap {
            content.accessibilityAction(named: "Show \(origin.text)", onOriginTap)
        } else {
            content
        }
    }
}

/// Text width at the line-two font (`.caption`).
enum MotherRowTextMeasure {
    #if os(macOS)
    static func width(_ text: String) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    #else
    static func width(_ text: String) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    #endif
}
