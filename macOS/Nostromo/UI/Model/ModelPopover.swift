import AppKit
import NostromoKit

/// One row of the popup: a model or an effort level.
///
/// (Skeleton: filled in by the implementation step of M2.)
final class ModelPopoverRowView: NSView {
    var titleText: String { "" }
    var secondaryText: String { "" }
    var showsCheckmark: Bool { false }
    var isRowEnabled: Bool { true }
    var isHighlighted: Bool { false }
    /// Select this row, as a click does.
    func activate() {}
}

/// The popup's content: a model section and an effort section, driven from the keyboard.
///
/// (Skeleton: filled in by the implementation step of M2.)
final class ModelPopoverViewController: NSViewController {
    enum Section { case model, effort }

    var modelRowViews: [ModelPopoverRowView] { [] }
    var effortRowViews: [ModelPopoverRowView] { [] }
    var focusedSection: Section { .model }
    var focusedRowIndex: Int { 0 }

    /// "Use for new <Agent> focuses" (hidden until M3).
    let useForNewFocusesCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// The posture hint line (hidden until M4).
    let postureHintLabel = NSTextField(labelWithString: "")
    /// "Model list may be out of date".
    let staleNoticeLabel = NSTextField(labelWithString: "")

    init(tag: String, agentName: String?, store: ModelStore, onClose: @escaping () -> Void) {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The `NSPopover` around `ModelPopoverViewController`, anchored to the chip.
final class ModelPopover {
    let viewController: ModelPopoverViewController
    var isShown: Bool { false }

    init(tag: String, agentName: String?, store: ModelStore) {
        viewController = ModelPopoverViewController(tag: tag, agentName: agentName, store: store, onClose: {})
    }

    func show(relativeTo view: NSView) {}
    func close() {}
}
