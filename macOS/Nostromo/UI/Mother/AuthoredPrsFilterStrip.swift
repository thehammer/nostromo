import AppKit
import NostromoKit

// The filter strip above the My open PRs groups: `Repo: [All ▾]  Session: [All ▾]  Clear`.
//
// It looks and reads like the Mother job list's `From:` control (11 pt secondary label, small pop-up, `Show
// all`), but shares no state with it. Repo and session names are Kit-sanitised and capped before they get here;
// a long one truncates in the pop-up and carries its full text as a tooltip.

// MARK: - Remembering the selection

/// The selection, kept in app preferences: one key for the repo, one for the session. Anything stale or
/// malformed reads as `All`.
struct AuthoredPrsFilterStore {
    static let repoKey = "nostromo.authoredPrs.filter.repo"
    static let sessionKey = "nostromo.authoredPrs.filter.session"

    /// Where selections are kept. Tests swap in a throwaway suite.
    static var defaults: UserDefaults = .standard

    let defaults: UserDefaults

    init(defaults: UserDefaults = AuthoredPrsFilterStore.defaults) { self.defaults = defaults }

    func load() -> AuthoredPrsFilterSelection {
        AuthoredPrsFilter.selection(storedRepo: defaults.object(forKey: Self.repoKey),
                                    storedSession: defaults.object(forKey: Self.sessionKey))
    }

    func save(_ selection: AuthoredPrsFilterSelection) {
        let stored = AuthoredPrsFilter.stored(selection)
        for (key, value) in [(Self.repoKey, stored.repo), (Self.sessionKey, stored.session)] {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
}

// MARK: - Strip

final class AuthoredPrsFilterStripView: NSView {
    static let height: CGFloat = 28
    static let repoLabel = "Filter by repository"
    static let sessionLabel = "Filter by session"
    static let clearLabel = "Clear filters"

    let repoPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let sessionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let clearButton = NSButton()
    private let repoCaption = AuthoredPrsFilterStripView.caption("Repo:")
    private let sessionCaption = AuthoredPrsFilterStripView.caption("Session:")

    /// The reader picked something; `selection` is the whole new selection.
    var onChange: ((AuthoredPrsFilterSelection) -> Void)?
    private var selection = AuthoredPrsFilterSelection.all
    private var repoSelections: [AuthoredPrsRepoSelection] = []
    private var sessionSelections: [AuthoredPrsSessionSelection] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        for popUp in [repoPopUp, sessionPopUp] {
            popUp.controlSize = .small
            popUp.font = .systemFont(ofSize: 11)
            popUp.lineBreakMode = .byTruncatingTail
            popUp.translatesAutoresizingMaskIntoConstraints = false
            popUp.target = self
            popUp.setContentCompressionResistancePriority(.init(250), for: .horizontal)
            popUp.setContentHuggingPriority(.init(250), for: .horizontal)
            popUp.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
            popUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        }
        repoPopUp.action = #selector(repoChanged)
        sessionPopUp.action = #selector(sessionChanged)
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
        for caption in [repoCaption, sessionCaption] { caption.setAccessibilityElement(false) }

        let stack = NSStackView(views: [repoCaption, repoPopUp, sessionCaption, sessionPopUp, clearButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.detachesHiddenViews = true
        stack.setCustomSpacing(12, after: repoPopUp)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let widths = repoPopUp.widthAnchor.constraint(equalTo: sessionPopUp.widthAnchor)
        widths.priority = .init(700)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            widths,
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

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
        repoSelections = result.repoEntries.map(\.selection)
        sessionSelections = result.sessionEntries.map(\.selection)
        fill(repoPopUp, titles: result.repoEntries.map(\.menuTitle), selected: repoSelections.firstIndex(of: selection.repo))
        fill(sessionPopUp, titles: result.sessionEntries.map(\.menuTitle), selected: sessionSelections.firstIndex(of: selection.session))
        repoPopUp.toolTip = Self.tooltip(result.repoEntries.first { $0.selection == selection.repo })
        sessionPopUp.toolTip = Self.tooltip(result.sessionEntries.first { $0.selection == selection.session })
        repoPopUp.setAccessibilityValue(repoPopUp.titleOfSelectedItem)
        sessionPopUp.setAccessibilityValue(sessionPopUp.titleOfSelectedItem)
        clearButton.isHidden = !selection.isActive
    }

    private static func tooltip<S>(_ entry: AuthoredPrsFilterEntry<S>?) -> String? { entry?.menuTitle }

    /// Entries have no key equivalents: the job list's `From:` and the main menu own the keys.
    private func fill(_ popUp: NSPopUpButton, titles: [String], selected: Int?) {
        popUp.removeAllItems()
        for title in titles {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.toolTip = title
            popUp.menu?.addItem(item)
        }
        popUp.selectItem(at: selected ?? 0)
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
