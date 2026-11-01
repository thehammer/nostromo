// NostromoKit — MotherOriginDisplay.swift
//
// Pure display model for "who queued this Mother job" (Mother focus v2, R3).
// Built from the daemon's `MotherJobAnnotation` and the app's current focus
// names. Every string that came from an agent or a shell (focus names,
// snapshots, tags) goes through `FoldTextSanitizer` and is capped here, so no
// view needs to remember to.

import Foundation

public struct MotherOriginDisplay: Equatable, Sendable {
    public let kind: MotherOriginKind
    /// What the row shows.
    public let text: String
    public let isMuted: Bool
    public let isItalic: Bool
    /// `"unverified"` for a claim the daemon could not vouch for; nil otherwise.
    public let badge: String?
    /// Only an open focus can be jumped to.
    public let isClickable: Bool
    public let focusTag: String?
    public let tooltip: String
    /// `From <origin>`.
    public let accessibilityText: String
    /// The verified focus's name, sanitised and capped, without a `(closed)` suffix. Nil for every
    /// other kind: only a verified focus is ever notified, so only it gets a notified mark.
    public private(set) var name: String? = nil

    public static let rowCap = 40
    public static let tooltipCap = 120

    /// - Parameter currentName: the app's current name for a focus tag, nil when
    ///   the tag is not an open focus.
    public static func make(
        annotation: MotherJobAnnotation?,
        currentName: (String) -> String?
    ) -> MotherOriginDisplay {
        guard let origin = annotation?.origin else { return unknown }
        switch origin.kind {
        case .focus:      return focus(origin, currentName: currentName)
        case .unverified: return unverified(origin)
        case .you:
            return MotherOriginDisplay(
                kind: .you, text: "You", isMuted: false, isItalic: false, badge: nil,
                isClickable: false, focusTag: nil,
                tooltip: "Queued by you in the app.", accessibilityText: "From You")
        case .unknown, .other:
            return unknown
        }
    }

    /// The display for a job with no usable annotation.
    public static let unknown = MotherOriginDisplay(
        kind: .unknown, text: "origin unknown", isMuted: true, isItalic: true, badge: nil,
        isClickable: false, focusTag: nil,
        tooltip: "Queued outside Nostromo (or before origins were recorded).",
        accessibilityText: "From origin unknown")

    /// Sanitised, single-line, capped. Empty when nothing printable is left.
    public static func clean(_ raw: String?, cap: Int) -> String {
        guard let raw else { return "" }
        let s = FoldTextSanitizer.sanitizeInline(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > cap else { return s }
        return String(s.prefix(cap - 1)) + "…"
    }

    // MARK: - Kinds

    private static func focus(_ o: MotherOriginView, currentName: (String) -> String?) -> MotherOriginDisplay {
        let tag = o.focusTag
        let open = tag.flatMap { currentName($0) }
        let isOpen = open != nil
        // Name: the live name, else the daemon's last known, else the snapshot, else the tag.
        let rawName = open ?? o.focusName ?? o.nameSnapshot ?? tag
        let name = firstPrintable([rawName, o.nameSnapshot, tag], cap: rowCap) ?? "focus"
        let text = isOpen ? name : "\(name) (closed)"

        var lines: [String] = []
        if !isOpen { lines.append("This focus is closed.") }
        if let tag { lines.append(clean(tag, cap: tooltipCap)) }
        let snap = clean(o.nameSnapshot, cap: tooltipCap)
        let shown = clean(rawName, cap: tooltipCap)
        if !snap.isEmpty, snap != shown { lines.append("queued as \(snap)") }
        let prefix = clean(o.sessionPrefix, cap: 16)
        if !prefix.isEmpty { lines.append("session \(prefix)") }

        var display = MotherOriginDisplay(
            kind: .focus, text: text, isMuted: !isOpen, isItalic: false, badge: nil,
            isClickable: isOpen, focusTag: tag,
            tooltip: lines.joined(separator: "\n"), accessibilityText: "From \(text)")
        display.name = name
        return display
    }

    private static func unverified(_ o: MotherOriginView) -> MotherOriginDisplay {
        let name = firstPrintable([o.nameSnapshot, o.focusTag], cap: rowCap) ?? "focus"
        let text = "\(name)?"
        return MotherOriginDisplay(
            kind: .unverified, text: text, isMuted: true, isItalic: false, badge: "unverified",
            isClickable: false, focusTag: o.focusTag,
            tooltip: "Claimed by a shell `mother add`; Nostromo could not verify it. Not notified.",
            accessibilityText: "From \(text), unverified")
    }

    private static func firstPrintable(_ candidates: [String?], cap: Int) -> String? {
        for c in candidates {
            let s = clean(c, cap: cap)
            if !s.isEmpty { return s }
        }
        return nil
    }
}
