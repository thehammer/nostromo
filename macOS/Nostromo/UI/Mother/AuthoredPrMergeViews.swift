import AppKit
import NostromoKit

// The Merge confirmation: one popover, a plain-text sentence saying what will happen, Cancel and Merge.
//
// The sentence is built by the Kit from the row the person pressed (its title cleaned and capped, its head, its
// base) and is shown verbatim as text: never Markdown, attributed HTML or a link. Cancel is the default button
// (Return cancels); Merge has no key equivalent and can only be pressed; Escape cancels.

// MARK: - Presentation

enum AuthoredPrMergeUI {
    private static var popover: NSPopover?
    private static var popoverDelegate: PopoverCloseDelegate?

    static func show(_ session: AuthoredPrMergeSession, from anchor: NSView) {
        dismiss()
        let pop = NSPopover()
        pop.contentViewController = AuthoredPrMergeViewController(session: session)
        pop.behavior = .transient
        pop.animates = false
        let delegate = PopoverCloseDelegate()
        // Closing the popover any other way (a click elsewhere, the row going away) is a cancel.
        delegate.onClose = { session.cancel() }
        pop.delegate = delegate
        popover = pop
        popoverDelegate = delegate
        // Pointed at the list, at the row's rectangle, rather than at the row's own view: a rebuilt list replaces
        // the row views, and a popover whose view has gone would close, cancelling what the person is reading.
        if let list = anchor.enclosingScrollView?.documentView, anchor !== list {
            pop.show(relativeTo: anchor.convert(anchor.bounds, to: list), of: list, preferredEdge: .minY)
        } else {
            pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    static func dismiss() {
        guard let popover else { return }
        // Cleared first: closing runs the delegate, which must not cancel what is already finished.
        popoverDelegate?.onClose = nil
        self.popover = nil
        popoverDelegate = nil
        if popover.isShown { popover.close() }
    }

    private final class PopoverCloseDelegate: NSObject, NSPopoverDelegate {
        var onClose: (() -> Void)?
        func popoverDidClose(_ notification: Notification) { onClose?() }
    }
}

// MARK: - Content

final class AuthoredPrMergeViewController: NSViewController {
    static let width: CGFloat = 360
    static let padding: CGFloat = 16

    let session: AuthoredPrMergeSession

    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let mergeButton = NSButton(title: "Merge", target: nil, action: nil)

    init(session: AuthoredPrMergeSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))
        let p = Self.padding

        messageLabel.stringValue = session.confirmation.message
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = AuthoredPrsPalette.text
        messageLabel.allowsEditingTextAttributes = false
        messageLabel.isSelectable = false
        messageLabel.maximumNumberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.preferredMaxLayoutWidth = Self.width - 2 * p
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.setAccessibilityLabel(session.confirmation.message)

        cancelButton.title = session.confirmation.cancelTitle
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        // The default button: Return cancels. Merge is reached only by pressing it.
        cancelButton.keyEquivalent = "\r"
        cancelButton.setAccessibilityIdentifier("authored-pr-merge-cancel")

        mergeButton.title = session.confirmation.confirmTitle
        mergeButton.target = self
        mergeButton.action = #selector(mergePressed)
        mergeButton.keyEquivalent = ""
        mergeButton.setAccessibilityLabel("Squash and merge PR \(session.confirmation.number)")
        mergeButton.setAccessibilityIdentifier("authored-pr-merge-confirm")

        for b in [cancelButton, mergeButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        for v in [messageLabel, cancelButton, mergeButton] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            messageLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: p),
            messageLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            messageLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            mergeButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 14),
            mergeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            mergeButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -p),
            cancelButton.centerYAnchor.constraint(equalTo: mergeButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: mergeButton.leadingAnchor, constant: -8),
        ])
        view = root
        root.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.width, height: root.fittingSize.height)
    }

    /// Escape.
    override func cancelOperation(_ sender: Any?) { session.cancel() }

    @objc private func cancelPressed() { session.cancel() }

    @objc private func mergePressed() { session.confirm(event: NSApp.currentEvent, control: mergeButton) }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Return lands on Cancel.
        view.window?.makeFirstResponder(cancelButton)
    }
}
