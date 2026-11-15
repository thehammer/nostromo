import AppKit
import Combine

/// The container a Perri focus is shown in: the focus's `DynamicFocusView`, unchanged, on the left and the
/// review side pane on the right. The pane is Mac-only and outside the daemon's pane tree: nothing here
/// is reported to the daemon, so the tree, the render-state reports and everything peers and agents see
/// are those of `DynamicFocusView` alone.
///
/// With no tabs the pane is removed and the focus fills the container.
final class PerriFocusContainerView: NSView, NSSplitViewDelegate {

    static let minimumFocusWidth: CGFloat = 420
    static let minimumPaneWidth: CGFloat = ReviewSidePaneView.minimumWidth

    let focusView: NSView
    let pane: ReviewSidePaneView
    let model: ReviewPaneModel
    private let split = ReviewSplitView()
    private var cancellables = Set<AnyCancellable>()
    private(set) var isPaneShown = false

    /// Where keyboard focus goes when the pane hides (the queue pane). Default: the focus view.
    var focusQueue: (() -> Void)?

    init(focusView: NSView, model: ReviewPaneModel) {
        self.focusView = focusView
        self.model = model
        pane = ReviewSidePaneView(model: model)
        super.init(frame: .zero)
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        split.container = self
        addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: leadingAnchor), split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: topAnchor), split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        focusView.translatesAutoresizingMaskIntoConstraints = true
        focusView.autoresizingMask = [.width, .height]
        split.addSubview(focusView)
        // `$tabs` delivers before the value is stored: use the delivered value, synchronously.
        model.$tabs
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] visible in self?.setPane(shown: visible) }
            .store(in: &cancellables)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Pane visibility

    private func setPane(shown: Bool) {
        guard shown != isPaneShown else { return }
        isPaneShown = shown
        if shown {
            split.addSubview(pane)
            splitView(split, resizeSubviewsWithOldSize: split.bounds.size)
            announce("Side pane opened")
        } else {
            pane.removeFromSuperview()
            // The focus goes back to the full width; nothing re-applies ratios inside it.
            focusView.frame = split.bounds
            split.adjustSubviews()
            announce("Side pane closed")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let focusQueue = self.focusQueue { focusQueue() } else { self.window?.makeFirstResponder(self.focusView) }
            }
        }
        needsLayout = true
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: pane, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    // MARK: Width

    /// The pane's width for a container of `total`: the saved fraction, kept inside the minimums.
    static func paneWidth(total: CGFloat, fraction: Double, dividerThickness: CGFloat = 1) -> CGFloat {
        let available = total - dividerThickness
        let desired = available * CGFloat(fraction)
        return max(0, min(max(desired, minimumPaneWidth), available - minimumFocusWidth))
    }

    var currentFraction: Double {
        let available = split.bounds.width - split.dividerThickness
        guard available > 0, isPaneShown else { return model.widthFraction }
        return Double(pane.frame.width / available)
    }

    /// Persist after a drag or an accessibility step.
    fileprivate func userResized() {
        guard isPaneShown else { return }
        let fraction = min(0.9, max(0.1, currentFraction))
        if abs(fraction - model.widthFraction) > 0.001 { model.widthFraction = fraction }
    }

    /// Accessibility step: move the divider by 5% of the width.
    fileprivate func nudge(by delta: Double) {
        guard isPaneShown else { return }
        model.widthFraction = min(0.9, max(0.1, model.widthFraction + delta))
        splitView(split, resizeSubviewsWithOldSize: split.bounds.size)
        split.needsLayout = true
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let total = splitView.bounds.width, height = splitView.bounds.height
        guard isPaneShown, pane.superview === splitView else {
            focusView.frame = NSRect(x: 0, y: 0, width: total, height: height)
            return
        }
        let thickness = splitView.dividerThickness
        let paneWidth = Self.paneWidth(total: total, fraction: model.widthFraction, dividerThickness: thickness)
        let focusWidth = total - thickness - paneWidth
        focusView.frame = NSRect(x: 0, y: 0, width: focusWidth, height: height)
        pane.frame = NSRect(x: focusWidth + thickness, y: 0, width: paneWidth, height: height)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        max(proposed, Self.minimumFocusWidth)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        min(proposed, splitView.bounds.width - splitView.dividerThickness - Self.minimumPaneWidth)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}

/// The divider's owner: saves the fraction when a drag ends and exposes increment/decrement.
final class ReviewSplitView: NSSplitView {
    weak var container: PerriFocusContainerView?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)       // tracks the drag until the button goes up
        container?.userResized()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitGroup }
    override func accessibilityLabel() -> String? { "Side pane divider" }
    override func accessibilityValue() -> Any? {
        container.map { "pane \(Int(($0.model.widthFraction * 100).rounded())) percent" }
    }
    override func accessibilityPerformIncrement() -> Bool { container?.nudge(by: 0.05); return true }    // wider pane
    override func accessibilityPerformDecrement() -> Bool { container?.nudge(by: -0.05); return true }
}
