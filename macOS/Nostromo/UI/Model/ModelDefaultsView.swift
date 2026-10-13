import AppKit
import Combine
import NostromoKit

/// One agent's line in the defaults list.
struct ModelDefaultRow: Equatable {
    let agent: String
    /// What new focuses of the agent start on: `"Haiku · high"`, or the declared model when
    /// the user set no default, or `"CLI default"`.
    let summary: String
    /// The user set a default (so it can be cleared); false for an agent that only declares one.
    let hasDefault: Bool
}

/// The per-agent defaults list: every agent that has a default or declares a model, what its
/// new focuses start on, and a Clear button for the defaults the user set. Existing focuses
/// are never affected: they keep the model they have.
final class ModelDefaultsView: NSView {
    private let store: ModelStore
    private let stack = NSStackView()
    private var cancellables = Set<AnyCancellable>()
    private(set) var rows: [ModelDefaultRow] = []
    private(set) var clearButtons: [NSButton] = []

    private static let primary = NSColor.white.withAlphaComponent(ModelChip.normalAlpha)
    private static let secondary = NSColor.white.withAlphaComponent(ModelChip.pendingAlpha)

    init(store: ModelStore) {
        self.store = store
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 320),
        ])

        reload()
        store.$defaults.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }.store(in: &cancellables)
        store.$catalog.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The rows for `defaults`: agents sorted by name, those with a default and those that
    /// declare a model.
    static func rows(defaults: ModelDefaultsState?, catalog: ModelCatalogState?) -> [ModelDefaultRow] {
        guard let defaults else { return [] }
        let agents = Set(defaults.defaults.keys).union(defaults.declared.keys).sorted()
        return agents.map { agent in
            if let d = defaults.defaults[agent] {
                return ModelDefaultRow(agent: agent, summary: describe(model: d.model, effort: d.effort, catalog: catalog),
                                       hasDefault: true)
            }
            let declared = defaults.declared[agent].map { describe(model: $0, effort: nil, catalog: catalog) }
            return ModelDefaultRow(agent: agent, summary: declared.map { "\($0) (agent's own)" } ?? "CLI default",
                                   hasDefault: false)
        }
    }

    private static func describe(model: String, effort: String?, catalog: ModelCatalogState?) -> String {
        let family = catalog?.families.first { $0.alias == model }?.displayName
            ?? ModelPresentation.familyName(forModel: model)
        guard let effort, effort != "default" else { return family }
        return "\(family) \u{00B7} \(effort)"
    }

    /// Press Clear on `agent`'s row, as a click does.
    func clear(agent: String) {
        store.clearDefault(agent: agent)
    }

    private func reload() {
        rows = Self.rows(defaults: store.defaults, catalog: store.catalog)
        clearButtons = []
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let title = NSTextField(labelWithString: "AGENT DEFAULTS")
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = Self.secondary
        stack.addArrangedSubview(title)

        if rows.isEmpty {
            let empty = NSTextField(labelWithString: "No agent defaults yet")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = Self.secondary
            stack.addArrangedSubview(empty)
        }
        for row in rows {
            let line = NSStackView()
            line.orientation = .horizontal
            line.spacing = 8
            let name = NSTextField(labelWithString: row.agent.prefix(1).uppercased() + row.agent.dropFirst())
            name.font = .systemFont(ofSize: 12)
            name.textColor = Self.primary
            name.widthAnchor.constraint(equalToConstant: 80).isActive = true
            let summary = NSTextField(labelWithString: row.summary)
            summary.font = .systemFont(ofSize: 12)
            summary.textColor = row.hasDefault ? Self.primary : Self.secondary
            summary.lineBreakMode = .byTruncatingTail
            summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            line.addArrangedSubview(name)
            line.addArrangedSubview(summary)
            if row.hasDefault {
                let button = NSButton(title: "", target: self, action: #selector(clearTapped(_:)))
                button.attributedTitle = NSAttributedString(
                    string: "Clear", attributes: [.foregroundColor: Self.primary, .font: NSFont.systemFont(ofSize: 11)])
                button.bezelStyle = .inline
                button.identifier = NSUserInterfaceItemIdentifier(row.agent)
                button.setAccessibilityLabel("Clear default for \(row.agent)")
                clearButtons.append(button)
                line.addArrangedSubview(button)
            }
            stack.addArrangedSubview(line)
        }
        layoutSubtreeIfNeeded()
    }

    @objc private func clearTapped(_ sender: NSButton) {
        guard let agent = sender.identifier?.rawValue else { return }
        clear(agent: agent)
    }
}

/// The `NSPopover` around `ModelDefaultsView`, anchored to the chip.
final class ModelDefaultsPopover: NSObject {
    let view: ModelDefaultsView
    private let popover = NSPopover()

    var isShown: Bool { popover.isShown }

    init(store: ModelStore) {
        view = ModelDefaultsView(store: store)
        super.init()
        let controller = NSViewController()
        controller.view = view
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
    }

    func show(relativeTo anchor: NSView) {
        guard !popover.isShown, anchor.window != nil else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    func close() { popover.performClose(nil) }
}
