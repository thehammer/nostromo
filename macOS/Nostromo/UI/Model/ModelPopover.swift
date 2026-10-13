import AppKit
import Combine
import NostromoKit

// MARK: - Colours

/// Explicit colours for everything in the popup. Nothing here uses a system label colour:
/// those follow the Mac's light/dark setting and go dark-on-dark on this UI (#234).
private enum PopoverPalette {
    static let background = NSColor(calibratedWhite: 0.12, alpha: 1)
    static let primary = NSColor.white.withAlphaComponent(ModelChip.normalAlpha)
    static let secondary = NSColor.white.withAlphaComponent(ModelChip.pendingAlpha)
    static let highlight = NSColor.white.withAlphaComponent(0.14)
}

// MARK: - Row

/// One row of the popup: a model or an effort level. Check mark, title, and the resolved
/// full model name as secondary text. A disabled row carries its reason as a tooltip.
final class ModelPopoverRowView: NSView {
    static let height: CGFloat = 26

    private let checkField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let secondaryField = NSTextField(labelWithString: "")
    private let onActivate: () -> Void

    private(set) var isRowEnabled: Bool
    private(set) var isHighlighted = false
    let showsCheckmark: Bool

    var titleText: String { titleField.stringValue }
    var secondaryText: String { secondaryField.stringValue }

    init(title: String, secondary: String, showsCheckmark: Bool, isEnabled: Bool,
         tooltip: String?, accessibilityLabel: String, onActivate: @escaping () -> Void) {
        self.isRowEnabled = isEnabled
        self.showsCheckmark = showsCheckmark
        self.onActivate = onActivate
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        translatesAutoresizingMaskIntoConstraints = false

        let font = NSFont.systemFont(ofSize: 12)
        checkField.stringValue = showsCheckmark ? "\u{2713}" : ""
        checkField.font = font
        titleField.stringValue = title
        titleField.font = font
        secondaryField.stringValue = secondary
        secondaryField.font = NSFont.systemFont(ofSize: 11)
        secondaryField.alignment = .right
        secondaryField.lineBreakMode = .byTruncatingMiddle

        // Disabled rows stay readable (4.5:1): they are dimmed like a pending chip, not greyed out.
        let titleColor = isEnabled ? PopoverPalette.primary : PopoverPalette.secondary
        checkField.textColor = titleColor
        titleField.textColor = titleColor
        secondaryField.textColor = PopoverPalette.secondary
        for field in [checkField, titleField, secondaryField] {
            field.isSelectable = false
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        secondaryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            checkField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            checkField.widthAnchor.constraint(equalToConstant: 14),
            checkField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: checkField.trailingAnchor, constant: 4),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            secondaryField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 12),
            secondaryField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            secondaryField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        toolTip = tooltip
        setAccessibilityElement(true)
        // The row is one element with its own label; its text fields would be read again.
        setAccessibilityChildren([])
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityEnabled(isEnabled)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setHighlighted(_ on: Bool) {
        isHighlighted = on
        layer?.backgroundColor = on ? PopoverPalette.highlight.cgColor : NSColor.clear.cgColor
    }

    /// Select this row, as a click does. A disabled row does nothing.
    func activate() {
        guard isRowEnabled else { return }
        onActivate()
    }

    override func mouseDown(with event: NSEvent) {
        activate()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isRowEnabled else { return false }
        activate()
        return true
    }
}

// MARK: - Content view

/// The popup's content view: takes the keyboard and hands keys to its controller.
private final class ModelPopoverContentView: NSView, ModelShortcutTarget {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onShortcut: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }

    // While the popup is open it is the first responder, so ⇧⌘M reaches it, not the input bar:
    // pressing the shortcut again closes the popup.
    @objc func showModelPopover(_ sender: Any?) { onShortcut?() }
    @objc var canShowModelPopover: Bool { true }
}

// MARK: - View controller

/// The popup's content: a model section and an effort section, driven from the keyboard.
///
/// Arrow keys move within a section, Return selects, Tab (and Shift-Tab) moves between the
/// sections, Escape closes with no change. Selecting a row asks the daemon to apply it
/// at once and closes the popup: `/model` is one action and so is this.
final class ModelPopoverViewController: NSViewController {
    enum Section { case model, effort }

    private let tag: String
    private let agentName: String?
    private let store: ModelStore
    private let onClose: () -> Void
    private var cancellables = Set<AnyCancellable>()

    private(set) var modelRowViews: [ModelPopoverRowView] = []
    private(set) var effortRowViews: [ModelPopoverRowView] = []
    private(set) var focusedSection: Section = .model
    private(set) var focusedRowIndex = 0

    /// "Use for new <Agent> focuses". Present but hidden until M3 wires it.
    let useForNewFocusesCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// The posture hint line. Present but hidden until M4 has a warning to show.
    let postureHintLabel = NSTextField(labelWithString: "")
    /// "Model list may be out of date", shown only for a stale catalogue.
    let staleNoticeLabel = NSTextField(labelWithString: ModelPresentation.staleCatalogNotice)

    private let modelStack = NSStackView()
    private let effortStack = NSStackView()
    private let emptyModelsLabel = NSTextField(labelWithString: "Model list unavailable")

    init(tag: String, agentName: String?, store: ModelStore, onClose: @escaping () -> Void) {
        self.tag = tag
        self.agentName = agentName
        self.store = store
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let content = ModelPopoverContentView()
        content.appearance = NSAppearance(named: .darkAqua)
        content.wantsLayer = true
        content.layer?.backgroundColor = PopoverPalette.background.cgColor
        content.onKeyDown = { [weak self] in self?.handleKey($0) ?? false }
        content.onShortcut = { [weak self] in self?.onClose() }
        view = content

        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 2
        outer.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        outer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outer)

        for stack in [modelStack, effortStack] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
        }
        styleNote(emptyModelsLabel)
        styleNote(staleNoticeLabel)
        styleNote(postureHintLabel)
        postureHintLabel.isHidden = true   // M4 shows posture warnings here.

        useForNewFocusesCheckbox.attributedTitle = NSAttributedString(
            string: ModelPresentation.footerTitle(agent: agentName ?? "agent"),
            attributes: [.foregroundColor: PopoverPalette.primary, .font: NSFont.systemFont(ofSize: 11)])
        useForNewFocusesCheckbox.isHidden = true   // M3 wires the per-agent default.

        outer.addArrangedSubview(header("Model"))
        outer.addArrangedSubview(modelStack)
        outer.addArrangedSubview(header("Effort"))
        outer.addArrangedSubview(effortStack)
        outer.addArrangedSubview(staleNoticeLabel)
        outer.addArrangedSubview(postureHintLabel)
        outer.addArrangedSubview(useForNewFocusesCheckbox)

        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 300),
        ])

        reload()
        if let current = currentRowIndex(in: focusedSection) { focus(focusedSection, current) }
        // Follow the daemon while the popup is open (a catalogue refresh, a switch landing).
        store.$states.dropFirst().sink { [weak self] _ in self?.reloadSoon() }.store(in: &cancellables)
        store.$catalog.dropFirst().sink { [weak self] _ in self?.reloadSoon() }.store(in: &cancellables)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
    }

    // MARK: Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: move(by: 1)
        case 126: move(by: -1)
        case 48:  switchSection()
        case 36, 76: selectFocusedRow()
        case 53:  onClose()
        default:  return false
        }
        return true
    }

    private func rows(in section: Section) -> [ModelPopoverRowView] {
        section == .model ? modelRowViews : effortRowViews
    }

    /// Move the highlight to the next enabled row in `direction`; at either end it stays.
    private func move(by direction: Int) {
        let rows = rows(in: focusedSection)
        var index = focusedRowIndex + direction
        while rows.indices.contains(index) {
            if rows[index].isRowEnabled { focus(focusedSection, index); return }
            index += direction
        }
    }

    /// Tab and Shift-Tab: with two sections, "next" and "previous" are the other one.
    private func switchSection() {
        let target: Section = focusedSection == .model ? .effort : .model
        let rows = rows(in: target)
        guard !rows.isEmpty else { return }
        // Land on the current row even when the model no longer offers it (disabled): the
        // highlight shows what is set, and Return on it changes nothing.
        focus(target, currentRowIndex(in: target) ?? rows.firstIndex { $0.isRowEnabled } ?? 0)
    }

    private func focus(_ section: Section, _ index: Int) {
        focusedSection = section
        focusedRowIndex = index
        for (i, row) in modelRowViews.enumerated() { row.setHighlighted(section == .model && i == index) }
        for (i, row) in effortRowViews.enumerated() { row.setHighlighted(section == .effort && i == index) }
    }

    private func selectFocusedRow() {
        let rows = rows(in: focusedSection)
        guard rows.indices.contains(focusedRowIndex) else { return }
        rows[focusedRowIndex].activate()
    }

    // MARK: Choosing

    private func chooseModel(_ row: ModelPresentation.ModelRow) {
        let state = store.state(for: tag)
        // The model already in use does nothing, unless a switch is pending: choosing the
        // current model then cancels it (the daemon reads it as "back to what is running").
        if !(row.isCurrent && state?.pending == nil) {
            store.requestSwitch(tag: tag, model: row.alias, effort: effortAfterSwitching(to: row.alias, state: state))
        }
        onClose()
    }

    /// An explicit effort the new model does not offer would make the daemon refuse the
    /// whole switch, so it goes back to the default alongside the model change.
    private func effortAfterSwitching(to alias: String, state: SessionModelStateWire?) -> String? {
        let effort = ModelPresentation.currentEffort(state: state)
        guard effort != "default",
              let target = store.catalog?.families.first(where: { $0.alias == alias }),
              !target.efforts.contains(effort) else { return nil }
        return "default"
    }

    private func chooseEffort(_ row: ModelPresentation.EffortRow) {
        let state = store.state(for: tag)
        if row.isEnabled, !(row.isCurrent && state?.pending == nil) {
            store.requestSwitch(tag: tag, model: nil, effort: row.value)
        }
        if row.isEnabled { onClose() }
    }

    // MARK: Content

    private func reloadSoon() {
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    /// Rebuild both sections from the store, keeping the highlight on the same row.
    private func reload() {
        let state = store.state(for: tag)
        let catalog = store.catalog

        modelRowViews = ModelPresentation.modelRows(state: state, catalog: catalog).map { row in
            ModelPopoverRowView(title: row.title, secondary: row.secondary, showsCheckmark: row.isCurrent,
                                isEnabled: true, tooltip: row.tooltip, accessibilityLabel: row.accessibilityLabel,
                                onActivate: { [weak self] in self?.chooseModel(row) })
        }
        effortRowViews = ModelPresentation.effortRows(state: state, catalog: catalog).map { row in
            ModelPopoverRowView(title: row.title, secondary: "", showsCheckmark: row.isCurrent,
                                isEnabled: row.isEnabled, tooltip: row.tooltip, accessibilityLabel: row.accessibilityLabel,
                                onActivate: { [weak self] in self?.chooseEffort(row) })
        }
        fill(modelStack, with: modelRowViews)
        fill(effortStack, with: effortRowViews)
        if modelRowViews.isEmpty { modelStack.addArrangedSubview(emptyModelsLabel) }
        staleNoticeLabel.isHidden = !(catalog?.stale ?? false)

        let rows = rows(in: focusedSection)
        if rows.isEmpty {
            focus(.effort, 0)
        } else if rows.indices.contains(focusedRowIndex) {
            focus(focusedSection, focusedRowIndex)
        } else {
            focus(focusedSection, currentRowIndex(in: focusedSection) ?? 0)
        }

        // The popover is as tall as its content: a catalogue that arrives after it opened, or a
        // stale notice that appears, changes the number of rows.
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    /// Index of the row carrying the check mark in `section`, if any.
    private func currentRowIndex(in section: Section) -> Int? {
        let state = store.state(for: tag)
        switch section {
        case .model: return ModelPresentation.modelRows(state: state, catalog: store.catalog).firstIndex { $0.isCurrent }
        case .effort: return ModelPresentation.effortRows(state: state, catalog: store.catalog).firstIndex { $0.isCurrent }
        }
    }

    private func fill(_ stack: NSStackView, with rows: [ModelPopoverRowView]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = PopoverPalette.secondary
        label.setAccessibilityRole(.staticText)
        return label
    }

    private func styleNote(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 11)
        label.textColor = PopoverPalette.secondary
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
    }
}

// MARK: - Popover

/// The `NSPopover` around `ModelPopoverViewController`, anchored to the chip.
final class ModelPopover: NSObject, NSPopoverDelegate {
    let viewController: ModelPopoverViewController
    private let popover = NSPopover()

    /// Called when the popup has closed, however it closed (a choice, Escape, a click outside).
    var onDidClose: (() -> Void)?

    var isShown: Bool { popover.isShown }

    init(tag: String, agentName: String?, store: ModelStore) {
        let popover = self.popover
        viewController = ModelPopoverViewController(tag: tag, agentName: agentName, store: store) { [weak popover] in
            popover?.performClose(nil)
        }
        super.init()
        popover.contentViewController = viewController
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
    }

    /// Open above `view` (the chip sits at the bottom of the window).
    func show(relativeTo view: NSView) {
        guard !popover.isShown else { return }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    func close() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        onDidClose?()
    }
}

// MARK: - Notice

/// A short message anchored to the chip: "Couldn't switch: …". Shown for a few seconds, then
/// dismissed by whoever opened it; it takes no keyboard focus and has no controls.
final class ModelNoticePopover: NSObject {
    private let popover = NSPopover()
    private let label = NSTextField(wrappingLabelWithString: "")

    var isShown: Bool { popover.isShown }
    var text: String { label.stringValue }

    init(text: String) {
        super.init()
        label.stringValue = text
        label.font = .systemFont(ofSize: 12)
        label.textColor = PopoverPalette.primary
        label.preferredMaxLayoutWidth = 260
        label.setAccessibilityRole(.staticText)

        let content = NSView()
        content.appearance = NSAppearance(named: .darkAqua)
        content.wantsLayer = true
        content.layer?.backgroundColor = PopoverPalette.background.cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .semitransient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
    }

    /// Open above `view`, like the model popup. Needs `view` to be in a window.
    func show(relativeTo view: NSView) {
        guard !popover.isShown, view.window != nil else { return }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    func close() {
        popover.close()
    }
}
