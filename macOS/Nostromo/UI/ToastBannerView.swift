import AppKit
import Combine

// MARK: - ToastSeverity rendering

extension ToastSeverity {
    var color: NSColor {
        switch self {
        case .info:    return Theme.sage
        case .warning: return Theme.amber
        case .alert:   return Theme.redSweater
        }
    }

    var icon: String {
        switch self {
        case .info:    return "●"
        case .warning: return "▲"
        case .alert:   return "⬟"
        }
    }
}

// MARK: - ToastBannerView

/// Stackable auto-dismissing banner overlay.
///
/// Pin over the content area with `translatesAutoresizingMaskIntoConstraints = false`.
/// Mouse events pass through to underlying views for non-toast areas.
/// Call `showToast(_:)` on the main thread to enqueue a banner.
class ToastBannerView: NSView {

    // MARK: - Constants

    private static let autoDismissInterval: TimeInterval = 6
    /// A toast with a button stays long enough to read it and reach for the button.
    private static let actionDismissInterval: TimeInterval = 15
    private static let animDuration:        TimeInterval = 0.18
    private static let toastWidth:          CGFloat      = 300
    private static let toastHeight:         CGFloat      = 40
    /// A toast with an action is wider and taller: its message wraps to two lines beside the button.
    private static let actionToastWidth:    CGFloat      = 460
    private static let actionToastHeight:   CGFloat      = 52
    private static let toastSpacing:        CGFloat      = 5
    private static let topPad:              CGFloat      = 10
    private static let trailingPad:         CGFloat      = 10

    // MARK: - State

    private struct ActiveToast {
        let view:        NSView
        var dismissWork: DispatchWorkItem
    }
    private var toasts: [ActiveToast] = []

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Fully transparent — only toast subviews are visible.
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    // MARK: - Public API

    func showToast(_ event: PostureThresholdEvent) {
        showToast(message: "\(event.severity.icon) \(event.toastMessage)",
                  severity: event.severity)
    }

    /// Show a toast that has nothing to do with usage posture.
    ///
    /// `MemoryWatchdog` needs to name a condition the operator should know about
    /// — the app holding more memory than is safe — and `PostureThresholdEvent`
    /// is about token budgets. Overloading it with memory semantics would make
    /// both harder to read; this is the neutral surface both go through.
    func showToast(message: String, severity: ToastSeverity) {
        showToast(message: message, severity: severity, action: nil)
    }

    /// Show a toast with an optional button. Clicking the button runs `action.handler` and dismisses
    /// the toast; clicking anywhere else on it only dismisses it. A toast with a button stays for 15
    /// seconds instead of 6.
    func showToast(message: String, severity: ToastSeverity, action: ToastAction?) {
        assert(Thread.isMainThread)
        let size = NSSize(width: action == nil ? Self.toastWidth : Self.actionToastWidth,
                          height: action == nil ? Self.toastHeight : Self.actionToastHeight)
        let view  = makeToastView(message: message, severity: severity, action: action)
        let endX  = bounds.width - size.width - Self.trailingPad
        let yPos  = topYForNextToast(height: size.height)

        // Start off-screen to the right, animate to final position.
        view.frame = NSRect(x: bounds.width, y: yPos, width: size.width, height: size.height)
        addSubview(view)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration        = Self.animDuration
            ctx.timingFunction  = CAMediaTimingFunction(name: .easeOut)
            view.animator().frame.origin.x = endX
        }

        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view else { return }
            self.dismiss(view)
        }
        toasts.append(ActiveToast(view: view, dismissWork: work))
        let interval = action == nil ? Self.autoDismissInterval : Self.actionDismissInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    // MARK: - Hit testing passthrough

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the overlay's own subviews take clicks; everything else falls
        // through to the views underneath. `point` is in the superview's
        // coordinates — see `OverlayHitTest`.
        OverlayHitTest.hit(in: self, at: point)
    }

    // MARK: - Layout helpers

    private func topYForNextToast(height: CGFloat) -> CGFloat {
        // In unflipped NSView coords: Y=0 is bottom, Y=bounds.height is top.
        // First toast appears at the top; subsequent toasts stack downward.
        let topEdge = bounds.height - height - Self.topPad
        guard !toasts.isEmpty else { return topEdge }
        let lowestMinY = toasts.map { $0.view.frame.minY }.min() ?? topEdge
        return lowestMinY - height - Self.toastSpacing
    }

    private func dismiss(_ toastView: NSView) {
        guard let idx = toasts.firstIndex(where: { $0.view === toastView }) else { return }
        toasts[idx].dismissWork.cancel()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.animDuration
            toastView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            toastView.removeFromSuperview()
            self?.toasts.removeAll { $0.view === toastView }
            self?.repositionToasts()
        })
    }

    private func repositionToasts() {
        // Slide remaining toasts up toward the top after a dismissal.
        var top = bounds.height - Self.topPad
        for toast in toasts {   // oldest first → topmost position
            let size = toast.view.frame.size
            let target = NSPoint(x: bounds.width - size.width - Self.trailingPad, y: top - size.height)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.animDuration
                toast.view.animator().frame.origin = target
            }
            top -= size.height + Self.toastSpacing
        }
    }

    // MARK: - Toast view factory

    /// The button on a toast that has an action.
    private final class ToastActionButton: NSButton {
        var toast: NSView?
        var toastAction: ToastAction?
    }

    private func makeToastView(message: String, severity: ToastSeverity, action: ToastAction?) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.bgBar.cgColor
        container.layer?.cornerRadius    = 5
        container.layer?.borderWidth     = 1
        container.layer?.borderColor     = severity.color
            .withAlphaComponent(0.55).cgColor

        // Left severity accent bar
        let accent = NSView()
        accent.wantsLayer = true
        accent.layer?.backgroundColor = severity.color.cgColor
        accent.layer?.cornerRadius    = 1.5
        accent.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(accent)

        // Message label (two lines beside a button, else one)
        let label = action == nil ? NSTextField(labelWithString: message)
                                  : NSTextField(wrappingLabelWithString: message)
        label.font          = Theme.statusFont
        label.textColor     = Theme.fg
        label.lineBreakMode = .byTruncatingTail
        if action != nil { label.maximumNumberOfLines = 2 }
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        // Dismiss button
        let closeLabel = NSTextField(labelWithString: "×")
        closeLabel.font      = Theme.statusFont
        closeLabel.textColor = Theme.fgMuted
        closeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(closeLabel)

        // Action button, between the message and the ×
        var labelTrailing = closeLabel.leadingAnchor
        var labelGap: CGFloat = -4
        if let action {
            let button = ToastActionButton(frame: .zero)
            button.title = action.title
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.toast = container
            button.toastAction = action
            button.target = self
            button.action = #selector(actionClicked(_:))
            button.setAccessibilityIdentifier("toast-action")
            button.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: closeLabel.leadingAnchor, constant: -8),
                button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            labelTrailing = button.leadingAnchor
            labelGap = -8
        }

        NSLayoutConstraint.activate([
            accent.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            accent.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            accent.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7),
            accent.widthAnchor.constraint(equalToConstant: 3),

            label.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: labelTrailing, constant: labelGap),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            closeLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            closeLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(toastClicked(_:)))
        container.addGestureRecognizer(click)

        return container
    }

    /// The toast's button: dismiss the toast, then run what it offers.
    @objc private func actionClicked(_ button: NSButton) {
        guard let sender = button as? ToastActionButton else { return }
        let handler = sender.toastAction?.handler
        if let toast = sender.toast { dismiss(toast) }
        handler?()
    }

    @objc private func toastClicked(_ recognizer: NSClickGestureRecognizer) {
        guard let tapped = recognizer.view else { return }
        dismiss(tapped)
    }
}
