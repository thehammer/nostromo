import Foundation
import NostromoKit

/// Pure text, label and state functions for the model chip and popup: everything the
/// views show, with no AppKit in it, so the exact PRD copy can be unit-tested.
///
/// (Skeleton: filled in by the implementation step of M2.)
enum ModelPresentation {

    enum ChipStyle: Equatable {
        /// A model the session itself reported, or one somebody chose.
        case normal
        /// Dimmed: not yet fact (a start-on model nobody chose, a switch in flight).
        case pending
    }

    /// What the chip shows.
    struct Chip: Equatable {
        var title: String
        var tooltip: String
        var accessibilityLabel: String
        var accessibilityHint: String
        var style: ChipStyle
        var isEnabled: Bool
    }

    struct ModelRow: Equatable {
        /// The alias a selection asks for (`"opus"`).
        var alias: String
        var title: String
        /// The full model name the alias currently resolves to.
        var secondary: String
        var isCurrent: Bool
        var accessibilityLabel: String
        var tooltip: String?
    }

    struct EffortRow: Equatable {
        /// `"default"` or an explicit level, as sent on the wire.
        var value: String
        var title: String
        var isCurrent: Bool
        var isEnabled: Bool
        /// Why the row is disabled.
        var tooltip: String?
        var accessibilityLabel: String
    }

    static let staleCatalogNotice = "Model list may be out of date"
    static let disconnectedTooltip = "Not connected to nostromd"
    /// The chip's accessibility hint: the shortcut that opens the popup.
    static let shortcutHint = "\u{21E7}\u{2318}M"

    /// Effort levels, cheapest first, as the daemon names them.
    static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    private static let separator = " \u{00B7} "
    private static let defaultEffort = "default"

    // MARK: - Chip

    /// What the chip shows for one focus; `nil` hides it (no state: a restricted or hidden
    /// session, or the daemon has said nothing yet).
    static func chip(state: SessionModelStateWire?, isConnected: Bool) -> Chip? {
        guard let state else { return nil }
        var chip = connectedChip(for: state)
        if !isConnected {
            chip.isEnabled = false
            chip.tooltip = disconnectedTooltip
            chip.style = .pending
        }
        return chip
    }

    /// The family name of a model: an alias, a pinned full name (`claude-sonnet-5-5`) or
    /// `default`. A name with no recognisable family word is capitalised as it stands.
    static func familyName(forModel model: String) -> String {
        let words = model.split(separator: "-").map(String.init)
        let word: String
        if model.hasPrefix("claude-") {
            // The first word that starts with a letter ("claude-3-5-sonnet" has digits first).
            word = words.dropFirst().first { $0.first?.isLetter == true } ?? model
        } else {
            word = model
        }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    private static func connectedChip(for state: SessionModelStateWire) -> Chip {
        let current = currentDisplay(of: state)

        if let pending = state.pending, state.phase != .steady {
            let from = current?.family ?? "Default"
            let to = familyName(forModel: pending.model)
            switch state.phase {
            case .applying:
                return chip("Switching\u{2026}", "Switching model", style: .pending,
                            label: "Model: switching from \(from) to \(to)")
            case .waiting, .steady:
                return chip("\(from) \u{2192} \(to)\(effortSuffix(pending.effort))", "Switching after this turn",
                            style: .pending, label: "Model: switching from \(from) to \(to) after this turn")
            }
        }

        guard let current else {
            return chip("Default", "Uses the Claude CLI default model", style: .normal,
                        label: steadyLabel(family: "default", effort: nil))
        }
        let effort = explicitEffort(state.recorded?.effort)
        let title = current.family + effortSuffix(effort)
        let label = steadyLabel(family: current.family, effort: effort)
        switch current.origin {
        case .reported(let fullName):
            return chip(title, "Claude \(current.family) (\(fullName)), effort: \(effort ?? defaultEffort)",
                        style: .normal, label: label)
        case .recorded(let chosen):
            return chip(title, "Starts on \(current.family)", style: chosen ? .normal : .pending, label: label)
        }
    }

    private enum Origin {
        /// A running session said so: the full model name it reported.
        case reported(String)
        /// Only the focus's recorded model; `true` when somebody chose it.
        case recorded(chosen: Bool)
    }

    private struct Display {
        let family: String
        let origin: Origin
    }

    /// The model to show as "current": what a running session reports, else what the focus
    /// will start on. Never the requested model as fact while a session is running.
    private static func currentDisplay(of state: SessionModelStateWire) -> Display? {
        if state.running, let reported = state.reported {
            let family = reported.family.map { familyName(forModel: $0) } ?? familyName(forModel: reported.model)
            return Display(family: family, origin: .reported(reported.model))
        }
        if let recorded = state.recorded {
            // A running session that has not reported yet is not fact either.
            let chosen = !state.running && recorded.source.isChosen
            return Display(family: familyName(forModel: recorded.model), origin: .recorded(chosen: chosen))
        }
        return nil
    }

    private static func chip(_ title: String, _ tooltip: String, style: ChipStyle, label: String) -> Chip {
        Chip(title: title, tooltip: tooltip, accessibilityLabel: label,
             accessibilityHint: shortcutHint, style: style, isEnabled: true)
    }

    private static func steadyLabel(family: String, effort: String?) -> String {
        "Model: \(family), effort \(effort ?? defaultEffort). Change model"
    }

    /// The explicit effort level, or `nil` for the model's default.
    private static func explicitEffort(_ effort: String?) -> String? {
        guard let effort, effort != defaultEffort else { return nil }
        return effort
    }

    private static func effortSuffix(_ effort: String?) -> String {
        explicitEffort(effort).map { separator + $0 } ?? ""
    }

    // MARK: - Popup rows

    /// The alias whose row carries the check mark: the recorded model when it is an alias
    /// (a pinned full name matches no row), else what the session reports.
    static func currentAlias(state: SessionModelStateWire?) -> String? {
        guard let state else { return nil }
        if let recorded = state.recorded { return recorded.model }
        return state.reported?.family
    }

    /// The current effort as sent on the wire: an explicit level, or `"default"`.
    static func currentEffort(state: SessionModelStateWire?) -> String {
        explicitEffort(state?.recorded?.effort) ?? defaultEffort
    }

    static func modelRows(state: SessionModelStateWire?, catalog: ModelCatalogState?) -> [ModelRow] {
        guard let catalog else { return [] }
        let current = currentAlias(state: state)
        return catalog.families.sorted { $0.rank < $1.rank }.map { family in
            let title = familyName(forModel: family.alias)
            let isCurrent = family.alias == current
            let label = [title, family.resolved, isCurrent ? "selected" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            return ModelRow(alias: family.alias, title: title, secondary: family.resolved ?? "",
                            isCurrent: isCurrent, accessibilityLabel: label, tooltip: nil)
        }
    }

    static func effortRows(state: SessionModelStateWire?, catalog: ModelCatalogState?) -> [EffortRow] {
        let current = currentEffort(state: state)
        let family = currentAlias(state: state).flatMap { alias in catalog?.families.first { $0.alias == alias } }
        let name = family.map { familyName(forModel: $0.alias) }

        var rows = [EffortRow(value: defaultEffort, title: "Default", isCurrent: current == defaultEffort,
                              isEnabled: true, tooltip: nil,
                              accessibilityLabel: label("Default", selected: current == defaultEffort))]
        for level in effortLevels {
            var tooltip: String?
            if let family, let name, !family.efforts.contains(level) {
                tooltip = family.efforts.isEmpty
                    ? "\(name) doesn't support effort levels"
                    : "\(name) doesn't support \(level) effort"
            }
            let isCurrent = current == level
            let accessibility = tooltip.map { "\(level), unavailable. \($0)" } ?? label(level, selected: isCurrent)
            rows.append(EffortRow(value: level, title: level, isCurrent: isCurrent, isEnabled: tooltip == nil,
                                  tooltip: tooltip, accessibilityLabel: accessibility))
        }
        return rows
    }

    private static func label(_ name: String, selected: Bool) -> String {
        selected ? "\(name), selected" : name
    }

    /// "Use for new Claudia focuses".
    static func footerTitle(agent: String) -> String {
        "Use for new \(agent.prefix(1).uppercased() + agent.dropFirst()) focuses"
    }
}
