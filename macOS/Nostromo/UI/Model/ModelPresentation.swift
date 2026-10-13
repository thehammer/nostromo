import Foundation
import NostromoKit

/// Pure text, label and state functions for the model chip and popup: everything the
/// views show, with no AppKit in it, so the exact PRD copy can be unit-tested.
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

    /// The effort levels the CLI is known to offer, cheapest first: the popup's rows when the
    /// catalogue says nothing, and the order the catalogue's own levels are shown in.
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
            if let current, familyName(forModel: pending.model) == current.family {
                return effortOnlyPendingChip(current: current, state: state, pending: pending)
            }
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
        let effort = shownEffort(of: state)
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

    /// A pending change of effort alone. The daemon's `pending` is the whole target, so its model
    /// is the focus's own: showing "Sonnet → Sonnet" would say nothing.
    private static func effortOnlyPendingChip(current: Display, state: SessionModelStateWire,
                                              pending: PendingModelWire) -> Chip {
        let from = explicitEffort(shownEffort(of: state))
        let to = explicitEffort(pending.effort) ?? defaultEffort
        let fromText = current.family + effortSuffix(from)
        let change = "effort from \(from ?? defaultEffort) to \(to)"
        switch state.phase {
        case .applying:
            return chip("Switching\u{2026}", "Switching model", style: .pending, label: "Model: switching \(change)")
        case .waiting, .steady:
            return chip("\(fromText) \u{2192} \(to)", "Switching after this turn", style: .pending,
                        label: "Model: switching \(change) after this turn")
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

    /// The effort the session confirmed (else the recorded one), as the chip and popup show it.
    private static func shownEffort(of state: SessionModelStateWire?) -> String? {
        state?.effectiveEffort ?? state?.recorded?.effort
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

    /// The alias whose row carries the check mark: the model a running session REPORTS (the chip
    /// shows it too), else the recorded model. A pinned full name (`claude-opus-5-5`) resolves to
    /// its catalogue family; a name no family claims checks nothing.
    static func currentAlias(state: SessionModelStateWire?, catalog: ModelCatalogState?) -> String? {
        guard let state, let catalog else { return nil }
        if state.running, let reported = state.reported {
            if let family = reported.family, catalog.families.contains(where: { $0.alias == family }) { return family }
            return resolveAlias(reported.model, in: catalog)
        }
        return state.recorded.flatMap { resolveAlias($0.model, in: catalog) }
    }

    /// The catalogue alias a model name stands for: an alias itself, the name an alias resolves
    /// to, or a name of the family's line (`claude-sonnet-4-6`).
    private static func resolveAlias(_ model: String, in catalog: ModelCatalogState) -> String? {
        if let exact = catalog.families.first(where: { $0.alias == model || $0.resolved == model }) { return exact.alias }
        let family = familyName(forModel: model).lowercased()
        return catalog.families.first { $0.alias == family }?.alias
    }

    /// The current effort as sent on the wire: an explicit level, or `"default"`.
    static func currentEffort(state: SessionModelStateWire?) -> String {
        explicitEffort(shownEffort(of: state)) ?? defaultEffort
    }

    static func modelRows(state: SessionModelStateWire?, catalog: ModelCatalogState?) -> [ModelRow] {
        guard let catalog else { return [] }
        let current = currentAlias(state: state, catalog: catalog)
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
        let family = catalogFamily(of: state, in: catalog)
        let name = family.map { familyName(forModel: $0.alias) }

        var rows = [EffortRow(value: defaultEffort, title: "Default", isCurrent: current == defaultEffort,
                              isEnabled: true, tooltip: nil,
                              accessibilityLabel: label("Default", selected: current == defaultEffort))]
        for level in levels(in: catalog) {
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

    /// Every level any family offers: the known ones in their order, then newer ones as the
    /// catalogue lists them. The standard five when the catalogue offers none.
    private static func levels(in catalog: ModelCatalogState?) -> [String] {
        let offered = (catalog?.families ?? []).flatMap(\.efforts)
        guard !offered.isEmpty else { return effortLevels }
        let unseen = offered.reduce(into: [String]()) { if !effortLevels.contains($1), !$0.contains($1) { $0.append($1) } }
        return effortLevels.filter(offered.contains) + unseen
    }

    /// The catalogue entry whose efforts apply to the current model: the recorded alias, or the
    /// family of a pinned full name (`claude-sonnet-4-6` → `sonnet`), or of what is running.
    private static func catalogFamily(of state: SessionModelStateWire?, in catalog: ModelCatalogState?) -> ModelFamilyWire? {
        guard let catalog, let state else { return nil }
        let candidates = [state.recorded?.model, state.reported?.family, state.reported?.model].compactMap { $0 }
        for model in candidates {
            if let exact = catalog.families.first(where: { $0.alias == model }) { return exact }
            let family = familyName(forModel: model).lowercased()
            if let byFamily = catalog.families.first(where: { $0.alias == family }) { return byFamily }
        }
        return nil
    }

    private static func label(_ name: String, selected: Bool) -> String {
        selected ? "\(name), selected" : name
    }

    // MARK: - Failures

    /// What to tell the user about a request that did not take: "Couldn't switch: <reason>".
    /// `nil` for a request that applied, is waiting, changed nothing or is not one this build knows.
    static func failureMessage(status: ModelRequestStatusWire, code: String?, message: String?) -> String? {
        let reason: String
        switch status {
        case .refused, .failed:
            if status == .refused, let code, let known = refusalReasons[code] {
                reason = known
            } else if let message, let first = message.first {
                reason = first.lowercased() + message.dropFirst()
            } else {
                reason = "something went wrong"
            }
        case .denied:  reason = "the request was declined"
        case .expired: reason = "the request expired"
        case .applied, .pendingTurnEnd, .unchanged, .awaitingUser, .unknown: return nil
        }
        return "Couldn't switch: \(reason)"
    }

    private static let refusalReasons = [
        "unknown_model": "that model isn't available",
        "not_permitted": "this session's model can't be changed",
        "unknown_focus": "this focus no longer exists",
    ]

    /// "Opus was requested, but this session is running Sonnet": for a request the daemon calls
    /// `unchanged` because the model is already the recorded one, while the session runs another.
    /// `nil` when the focus runs what it is recorded to run.
    static func requestedButNotRunning(state: SessionModelStateWire?) -> String? {
        guard let state, state.running, let reported = state.reported, let recorded = state.recorded else { return nil }
        let requested = familyName(forModel: recorded.model)
        let running = reported.family.map { familyName(forModel: $0) } ?? familyName(forModel: reported.model)
        guard requested != running else { return nil }
        return "\(requested) was requested, but this session is running \(running)"
    }

    /// "Use for new Claudia focuses".
    static func footerTitle(agent: String) -> String {
        "Use for new \(agent.prefix(1).uppercased() + agent.dropFirst()) focuses"
    }
}
