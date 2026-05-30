import AppKit
import Combine

/// Vertical navigation sidebar — focus names stacked top-to-bottom, full window height.
///
/// Built-in focuses appear first, then a 1px separator, then dynamic focuses.
/// A "+" button pinned to the sidebar bottom creates new dynamic focuses.
/// Active focus: 3px cornflower left-accent + subtle bg highlight + bold label.
/// Sweater indicator: small colored dot to the right of the Mother label.
/// Right border separates sidebar from content area.
class TabBarView: NSView {

    // MARK: - State

    private var cancellables = Set<AnyCancellable>()
    private var items: [String: NavTabItem] = [:]   // keyed by focus.id

    /// Set by MainLayout when the active focus changes. Drives highlight state.
    var activeFocus: Focus? { didSet { updateStates() } }

    /// Called when the user taps a focus item.
    var onSwitch: ((Focus) -> Void)?

    /// Called when the user taps the "+" button.
    var onAdd: (() -> Void)?

    /// Called when the user selects "Remove Focus" from a dynamic item's context menu.
    var onRemove: ((Focus) -> Void)?

    // Layout anchors we manage across reloads
    private var dynamicSeparator: NSView?
    private var addButton: NSView?

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bgBar.cgColor

        // Right border
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = Theme.borderInactive.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: topAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.widthAnchor.constraint(equalToConstant: 1),
        ])

        // Add-focus button pinned to bottom
        let btn = makeAddButton()
        addSubview(btn)
        NSLayoutConstraint.activate([
            btn.leadingAnchor.constraint(equalTo: leadingAnchor),
            btn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            btn.bottomAnchor.constraint(equalTo: bottomAnchor),
            btn.heightAnchor.constraint(equalToConstant: 32),
        ])
        addButton = btn

        // Mother sweater dots — global state, same on all windows
        AppStore.shared.$motherJobs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSweaters() }
            .store(in: &cancellables)
    }

    // MARK: - Focus list management

    /// Tears down and rebuilds the item list from a new focuses array.
    func setFocuses(_ focuses: [Focus]) {
        // Remove old items
        items.values.forEach { $0.removeFromSuperview() }
        items = [:]
        dynamicSeparator?.removeFromSuperview()
        dynamicSeparator = nil

        let builtIns  = focuses.filter { $0.isBuiltIn }
        let dynamics  = focuses.filter { !$0.isBuiltIn }

        var prev: NSView? = nil

        // Built-in items
        for focus in builtIns {
            let item = NavTabItem(focus: focus)
            item.onTap = { [weak self] in self?.onSwitch?(focus) }
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
            NSLayoutConstraint.activate([
                item.leadingAnchor.constraint(equalTo: leadingAnchor),
                item.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
                item.heightAnchor.constraint(equalToConstant: 40),
            ])
            if let p = prev {
                item.topAnchor.constraint(equalTo: p.bottomAnchor).isActive = true
            } else {
                item.topAnchor.constraint(equalTo: topAnchor, constant: 8).isActive = true
            }
            items[focus.id] = item
            prev = item
        }

        // Separator between built-ins and dynamic focuses
        if !dynamics.isEmpty {
            let sep = NSView()
            sep.wantsLayer = true
            sep.layer?.backgroundColor = Theme.borderInactive.cgColor
            sep.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sep)
            NSLayoutConstraint.activate([
                sep.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                sep.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
                sep.heightAnchor.constraint(equalToConstant: 1),
                sep.topAnchor.constraint(equalTo: prev?.bottomAnchor ?? topAnchor, constant: 4),
            ])
            dynamicSeparator = sep
            prev = sep
        }

        // Dynamic items with context menu
        for focus in dynamics {
            let item = NavTabItem(focus: focus)
            item.onTap = { [weak self] in self?.onSwitch?(focus) }
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
            NSLayoutConstraint.activate([
                item.leadingAnchor.constraint(equalTo: leadingAnchor),
                item.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
                item.heightAnchor.constraint(equalToConstant: 40),
            ])
            if let p = prev {
                item.topAnchor.constraint(equalTo: p.bottomAnchor).isActive = true
            } else {
                item.topAnchor.constraint(equalTo: topAnchor, constant: 8).isActive = true
            }

            // Right-click context menu: "Remove Focus"
            let menu = NSMenu()
            let removeItem = NSMenuItem(title: "Remove Focus", action: #selector(removeFocusTapped(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = focus
            menu.addItem(removeItem)
            item.menu = menu

            items[focus.id] = item
            prev = item
        }

        updateStates()
        updateSweaters()
    }

    @objc private func removeFocusTapped(_ sender: NSMenuItem) {
        guard let focus = sender.representedObject as? Focus else { return }
        onRemove?(focus)
    }

    // MARK: - Add button

    private func makeAddButton() -> NSView {
        let btn = NSView()
        btn.wantsLayer = true
        btn.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "+")
        label.font      = NSFont.systemFont(ofSize: 18, weight: .thin)
        label.textColor = Theme.fgMuted
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        btn.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(addTapped))
        btn.addGestureRecognizer(click)

        return btn
    }

    @objc private func addTapped() { onAdd?() }

    // MARK: - State updates

    private func updateStates() {
        items.forEach { id, item in item.isActive = (id == activeFocus?.id) }
    }

    private func updateSweaters() {
        let jobs = AppStore.shared.motherJobs
        let threshold: TimeInterval = 15 * 60
        let now = Date()
        let anyLong = jobs.contains {
            $0.state == "running" && $0.startedAt.map { now.timeIntervalSince($0) > threshold } == true
        }
        items["mother"]?.sweaterColor = anyLong ? Theme.amber : nil
    }
}

// MARK: - NavTabItem

private class NavTabItem: NSView {

    let focus: Focus
    var onTap: (() -> Void)?

    var isActive: Bool = false {
        didSet { updateAppearance() }
    }

    var sweaterColor: NSColor? = nil {
        didSet { updateAppearance() }
    }

    private let accentBar = NSView()
    private let label     = NSTextField(labelWithString: "")
    private let dot       = NSView()

    init(focus: Focus) {
        self.focus = focus
        super.init(frame: .zero)
        wantsLayer = true

        // Left accent bar — 3px, full height
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = Theme.cornflower.cgColor
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentBar)
        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 3),
        ])

        // Label — centered in item
        label.stringValue  = focus.displayName
        label.font         = Theme.tabFont
        label.textColor    = Theme.fgMuted
        label.alignment    = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])

        // Sweater dot — 6px circle, right-aligned, hidden by default
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapped)))

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }

    private func updateAppearance() {
        accentBar.isHidden = !isActive
        layer?.backgroundColor = isActive
            ? Theme.cornflower.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor

        let displayName = focus.displayName
        if isActive {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.tabFontBold, .foregroundColor: NSColor.white,
            ]
            label.attributedStringValue = NSAttributedString(string: displayName, attributes: attrs)
        } else {
            let color = sweaterColor ?? Theme.fgMuted
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.tabFont, .foregroundColor: color,
            ]
            label.attributedStringValue = NSAttributedString(string: displayName, attributes: attrs)
        }

        if let sc = sweaterColor {
            dot.isHidden = false
            dot.layer?.backgroundColor = sc.cgColor
        } else {
            dot.isHidden = true
        }
    }
}
