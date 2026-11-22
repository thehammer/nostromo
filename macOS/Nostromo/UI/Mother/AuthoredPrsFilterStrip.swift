import AppKit
import NostromoKit

// The filter strip above the My open PRs groups: `Org: [All ▾]  Repo: [All ▾]  Session: [All ▾]  Clear`.
//
// It looks and reads like the Mother job list's `From:` control (11 pt secondary label, small pop-up, `Show
// all`), but shares no state with it. Repo and session names are Kit-sanitised and capped before they get here;
// a long one truncates in the pop-up and carries its full text as a tooltip.

// MARK: - Remembering the selection

/// The selection, kept in app preferences: one key for the repo, one for the session. Anything stale or
/// malformed reads as `All`.
struct AuthoredPrsFilterStore {
    static let orgKey = "nostromo.authoredPrs.filter.org"
    static let repoKey = "nostromo.authoredPrs.filter.repo"
    static let sessionKey = "nostromo.authoredPrs.filter.session"

    /// Where selections are kept. Tests swap in a throwaway suite.
    static var defaults: UserDefaults = .standard

    let defaults: UserDefaults

    init(defaults: UserDefaults = AuthoredPrsFilterStore.defaults) { self.defaults = defaults }

    func load() -> AuthoredPrsFilterSelection {
        AuthoredPrsFilter.selection(storedOrg: defaults.object(forKey: Self.orgKey),
                                    storedRepo: defaults.object(forKey: Self.repoKey),
                                    storedSession: defaults.object(forKey: Self.sessionKey))
    }

    func save(_ selection: AuthoredPrsFilterSelection) {
        let stored = AuthoredPrsFilter.stored(selection)
        for (key, value) in [(Self.orgKey, stored.org), (Self.repoKey, stored.repo), (Self.sessionKey, stored.session)] {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
}

// MARK: - Strip

final class AuthoredPrsFilterStripView: NSView {
    static let height: CGFloat = 28
    static let orgLabel = "Filter by organisation"
    static let repoLabel = "Filter by repository"
    static let sessionLabel = "Filter by session"
    static let clearLabel = "Clear filters"

    let orgPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let repoPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let sessionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let clearButton = NSButton()
    private let orgCaption = AuthoredPrsFilterStripView.caption("Org:")
    private let repoCaption = AuthoredPrsFilterStripView.caption("Repo:")
    private let sessionCaption = AuthoredPrsFilterStripView.caption("Session:")

    /// The reader picked something; `selection` is the whole new selection.
    var onChange: ((AuthoredPrsFilterSelection) -> Void)?
    private var selection = AuthoredPrsFilterSelection.all
    private var orgSelections: [AuthoredPrsOrgSelection] = []
    private var repoSelections: [AuthoredPrsRepoSelection] = []
    private var sessionSelections: [AuthoredPrsSessionSelection] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        for popUp in [orgPopUp, repoPopUp, sessionPopUp] {
            popUp.controlSize = .small
            popUp.font = .systemFont(ofSize: 11)
            popUp.lineBreakMode = .byTruncatingTail
            popUp.translatesAutoresizingMaskIntoConstraints = false
            popUp.target = self
            popUp.setContentCompressionResistancePriority(.init(250), for: .horizontal)
            popUp.setContentHuggingPriority(.init(250), for: .horizontal)
            popUp.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
            popUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        }
        orgPopUp.action = #selector(orgChanged)
        repoPopUp.action = #selector(repoChanged)
        sessionPopUp.action = #selector(sessionChanged)
        orgPopUp.setAccessibilityLabel(Self.orgLabel)
        repoPopUp.setAccessibilityLabel(Self.repoLabel)
        sessionPopUp.setAccessibilityLabel(Self.sessionLabel)

        clearButton.isBordered = false
        clearButton.attributedTitle = NSAttributedString(string: "Clear", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: AuthoredPrsPalette.link])
        clearButton.target = self
        clearButton.action = #selector(clearPressed)
        clearButton.setAccessibilityLabel(Self.clearLabel)
        clearButton.toolTip = Self.clearLabel
        clearButton.setContentHuggingPriority(.required, for: .horizontal)
        clearButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        // Captions are named by the pop-ups, not read as separate text.
        for caption in [orgCaption, repoCaption, sessionCaption] { caption.setAccessibilityElement(false) }

        let stack = NSStackView(views: [orgCaption, orgPopUp, repoCaption, repoPopUp, sessionCaption, sessionPopUp, clearButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.detachesHiddenViews = true
        stack.setCustomSpacing(8, after: orgPopUp)
        stack.setCustomSpacing(8, after: repoPopUp)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let widths = [repoPopUp, sessionPopUp].map { $0.widthAnchor.constraint(equalTo: orgPopUp.widthAnchor) }
        widths.forEach { $0.priority = .init(700) }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ] + widths)
        // Tab order is set here, not left to the window's key-view loop (which is geometry-ordered and depends on
        // the system's keyboard-navigation setting): Org, then Repo, then Session, then `viewAfterStrip`.
        orgPopUp.nextKeyView = repoPopUp
        repoPopUp.nextKeyView = sessionPopUp
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Where Tab goes from the Session pop-up: the list below the strip. Set by the owner; named explicitly so
    /// leaving the strip does not depend on the window's key-view loop (a `recalculateKeyViewLoop()` would
    /// otherwise overwrite the links to wherever the geometry sends it).
    weak var viewAfterStrip: NSView? {
        didSet { sessionPopUp.nextKeyView = viewAfterStrip }
    }

    /// Below this width the captions give way to the pop-ups: three pop-ups and their captions do not fit a
    /// narrow pane, and each pop-up is already named by its accessibility label and tooltip.
    static let captionsMinWidth: CGFloat = 420

    override func layout() {
        let showCaptions = bounds.width >= Self.captionsMinWidth
        for caption in [orgCaption, repoCaption, sessionCaption] where caption.isHidden == showCaptions {
            caption.isHidden = !showCaptions
        }
        super.layout()
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = AuthoredPrsPalette.muted
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// Show the entries and the selection the result carries.
    func apply(_ result: AuthoredPrsFilterResult) {
        selection = result.selection
        orgSelections = result.orgEntries.map(\.selection)
        repoSelections = result.repoEntries.map(\.selection)
        sessionSelections = result.sessionEntries.map(\.selection)
        fill(orgPopUp, entries: result.orgEntries, selected: orgSelections.firstIndex(of: selection.org))
        fill(repoPopUp, entries: result.repoEntries, selected: repoSelections.firstIndex(of: selection.repo))
        fill(sessionPopUp, entries: result.sessionEntries, selected: sessionSelections.firstIndex(of: selection.session))
        orgPopUp.toolTip = Self.tooltip(result.orgEntries.first { $0.selection == selection.org })
        repoPopUp.toolTip = Self.tooltip(result.repoEntries.first { $0.selection == selection.repo })
        sessionPopUp.toolTip = Self.tooltip(result.sessionEntries.first { $0.selection == selection.session })
        orgPopUp.setAccessibilityValue(orgPopUp.titleOfSelectedItem)
        repoPopUp.setAccessibilityValue(repoPopUp.titleOfSelectedItem)
        sessionPopUp.setAccessibilityValue(sessionPopUp.titleOfSelectedItem)
        clearButton.isHidden = !selection.isActive
    }

    /// The whole sanitised name, not the capped menu title (which also carries the count).
    private static func tooltip<S>(_ entry: AuthoredPrsFilterEntry<S>?) -> String? { entry?.fullTitle }

    /// Entries have no key equivalents: the job list's `From:` and the main menu own the keys.
    ///
    /// A snapshot can land while the pop-up's menu is open, and `removeAllItems` would close it under the
    /// reader's pointer. So when the entries are the same ones in the same order (only a count moved), the
    /// existing items are updated in place and the menu is left alone; the menu is rebuilt only when the
    /// set of entries itself changes.
    private func fill<S>(_ popUp: NSPopUpButton, entries: [AuthoredPrsFilterEntry<S>], selected: Int?) {
        let titles = entries.map(\.menuTitle)
        if let items = popUp.menu?.items, items.count == entries.count,
           zip(items, entries).allSatisfy({ ($0.representedObject as? AnyHashable) == AnyHashable($1.selection) }) {
            for (item, entry) in zip(items, entries) {
                if item.title != entry.menuTitle { item.title = entry.menuTitle }
                if item.toolTip != entry.fullTitle { item.toolTip = entry.fullTitle }
            }
            let index = selected ?? 0
            if popUp.indexOfSelectedItem != index { popUp.selectItem(at: index) }
            return
        }
        popUp.removeAllItems()
        for (title, entry) in zip(titles, entries) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.toolTip = entry.fullTitle
            item.representedObject = AnyHashable(entry.selection)
            popUp.menu?.addItem(item)
        }
        popUp.selectItem(at: selected ?? 0)
    }

    @objc private func orgChanged() {
        let index = orgPopUp.indexOfSelectedItem
        guard orgSelections.indices.contains(index) else { return }
        selection.org = orgSelections[index]
        onChange?(selection)
    }

    @objc private func repoChanged() {
        let index = repoPopUp.indexOfSelectedItem
        guard repoSelections.indices.contains(index) else { return }
        selection.repo = repoSelections[index]
        onChange?(selection)
    }

    @objc private func sessionChanged() {
        let index = sessionPopUp.indexOfSelectedItem
        guard sessionSelections.indices.contains(index) else { return }
        selection.session = sessionSelections[index]
        onChange?(selection)
    }

    @objc private func clearPressed() {
        onChange?(.all)
    }
}
