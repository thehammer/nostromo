import AppKit
import Combine
import NostromoKit

/// The Model and Effort pickers of the create-focus sheet, as a controller the sheet owns.
///
/// Both start on what a new focus of the selected agent would get (its per-agent default, else
/// its declared model, else "Default": the CLI's). They follow the agent popup until the user
/// touches either one; from then on the user's choice stays whatever the agent popup does.
///
/// An untouched pair sends nothing (`choice` is nil): the daemon resolves the defaults itself
/// when it starts the session, so a declared or CLI-default focus is recorded as such.
///
/// An effort needs a model to attach to: with no model chosen and none resolved (no default, no
/// declared model), the Effort picker is disabled and shows "Default".
final class CreateFocusModelPickers {
    /// What the sheet hands to the new focus: model alias and effort level, either may be nil.
    struct Choice: Equatable {
        var model: String?
        var effort: String?
    }

    let modelPopup = NSPopUpButton()
    let effortPopup = NSPopUpButton()

    private let store: ModelStore
    private var agent: String?
    private var cancellables = Set<AnyCancellable>()
    private(set) var userTouchedModel = false
    private(set) var userTouchedEffort = false

    init(store: ModelStore = .shared) {
        self.store = store
        for popup in [modelPopup, effortPopup] {
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.autoenablesItems = false
        }
        modelPopup.target = self
        modelPopup.action = #selector(modelPicked)
        effortPopup.target = self
        effortPopup.action = #selector(effortPicked)
        modelPopup.setAccessibilityLabel("Model")
        effortPopup.setAccessibilityLabel("Effort")
        reload()
        // A catalogue or defaults frame that arrives while the sheet is open.
        store.$catalog.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.reload() } }
            .store(in: &cancellables)
        store.$defaults.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.reload() } }
            .store(in: &cancellables)
    }

    /// The agent popup moved. Untouched pickers go to the new agent's start; touched ones stay.
    func agentChanged(to agent: String?) {
        self.agent = agent
        reload()
    }

    /// The choice to create the focus with, or nil when the user touched neither picker.
    var choice: Choice? {
        guard userTouchedModel || userTouchedEffort else { return nil }
        // Effort needs a model to attach to; "Default" falls back to the agent's resolved one.
        return Choice(model: selectedModel ?? resolvedStartModel, effort: selectedEffort)
    }

    /// The alias shown in the Model picker; nil for "Default".
    var selectedModel: String? { modelPopup.selectedItem?.representedObject as? String }
    /// The level shown in the Effort picker; nil for "Default".
    var selectedEffort: String? { effortPopup.selectedItem?.representedObject as? String }

    /// "Choose a model first": the Effort picker's tooltip while no model resolves.
    static let chooseModelFirstTooltip = "Choose a model first"
    /// The Model picker's "Default" title when the agent has no model of its own.
    static let cliDefaultTitle = "CLI default"

    var modelTitles: [String] { modelPopup.itemTitles }
    var effortTitles: [String] { effortPopup.itemTitles }

    /// Pick a model as a click does (nil: "Default").
    func userPickModel(_ alias: String?) {
        guard let index = modelPopup.menu?.items.firstIndex(where: { ($0.representedObject as? String) == alias })
        else { return }
        modelPopup.selectItem(at: index)
        modelPicked()
    }

    /// Pick an effort level as a click does (nil: "Default").
    func userPickEffort(_ level: String?) {
        guard effortPopup.isEnabled, let index = effortPopup.menu?.items.firstIndex(where: { ($0.representedObject as? String) == level })
        else { return }
        effortPopup.selectItem(at: index)
        effortPicked()
    }

    // MARK: - Actions

    @objc private func modelPicked() {
        userTouchedModel = true
        rebuildEffortItems(keeping: selectedEffort)
    }

    @objc private func effortPicked() {
        userTouchedEffort = true
    }

    // MARK: - Content

    /// The model a new focus of the selected agent starts on when the Model picker says "Default":
    /// its per-agent default, else its declared model. nil: the CLI's own default.
    private var resolvedStartModel: String? {
        agent.flatMap { store.resolvedStart(agent: $0).model }
    }

    private func reload() {
        let start = agent.map { store.resolvedStart(agent: $0) } ?? (model: nil, effort: nil)
        let keepModel = userTouchedModel ? selectedModel : start.model
        rebuildModelItems(selecting: keepModel)
        let keepEffort = userTouchedEffort ? selectedEffort : (userTouchedModel ? nil : start.effort)
        rebuildEffortItems(keeping: keepEffort)
    }

    private func rebuildModelItems(selecting alias: String?) {
        modelPopup.removeAllItems()
        add(defaultModelTitle(), value: nil, to: modelPopup)
        for family in (store.catalog?.families ?? []).sorted(by: { $0.rank < $1.rank }) {
            add(family.displayName, value: family.alias, to: modelPopup)
        }
        select(alias.flatMap(familyAlias(for:)), in: modelPopup)
    }

    /// "Agent default (Sonnet)" when the agent starts on a model of its own, else "CLI default".
    private func defaultModelTitle() -> String {
        guard let model = resolvedStartModel else { return Self.cliDefaultTitle }
        let alias = familyAlias(for: model)
        let name = store.catalog?.families.first { $0.alias == alias }?.displayName
            ?? ModelPresentation.familyName(forModel: model)
        return "Agent default (\(name))"
    }

    private func rebuildEffortItems(keeping level: String?) {
        let model = selectedModel ?? resolvedStartModel
        let family = model.flatMap(familyAlias(for:)).flatMap { alias in store.catalog?.families.first { $0.alias == alias } }
        effortPopup.removeAllItems()
        add("Default", value: nil, to: effortPopup)
        for level in ModelPresentation.effortLevels {
            let item = add(level, value: level, to: effortPopup)
            // A known model offers only the levels it lists (none at all: no effort support, as
            // in the model popup); "Default", or a model the catalogue lacks, offers every level.
            if let family { item.isEnabled = family.efforts.contains(level) }
        }
        // No model to attach an effort to: the picker is off, and an effort picked earlier goes.
        effortPopup.isEnabled = model != nil
        effortPopup.toolTip = model == nil ? Self.chooseModelFirstTooltip : nil
        let wanted = level.flatMap { l in effortPopup.menu?.items.first { ($0.representedObject as? String) == l }?.isEnabled == true ? l : nil }
        select(model == nil ? nil : wanted, in: effortPopup)
    }

    /// The alias of the family `model` (an alias or a full name) belongs to, if the catalogue has it.
    private func familyAlias(for model: String) -> String? {
        guard let families = store.catalog?.families else { return nil }
        if families.contains(where: { $0.alias == model }) { return model }
        let family = ModelPresentation.familyName(forModel: model).lowercased()
        return families.first { $0.alias == family }?.alias
    }

    @discardableResult
    private func add(_ title: String, value: String?, to popup: NSPopUpButton) -> NSMenuItem {
        popup.addItem(withTitle: title)
        let item = popup.lastItem!
        item.representedObject = value
        return item
    }

    private func select(_ value: String?, in popup: NSPopUpButton) {
        let index = popup.menu?.items.firstIndex { ($0.representedObject as? String) == value } ?? 0
        popup.selectItem(at: index)
    }
}
