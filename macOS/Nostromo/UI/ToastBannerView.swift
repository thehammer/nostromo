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
    private static let animDuration:        TimeInterval = 0.18
    private static let toastWidth:          CGFloat      = 300
    private static let toastHeight:         CGFloat      = 40
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
        assert(Thread.isMainThread)
        let view  = makeToastView(event)
        let endX  = bounds.width - Self.toastWidth - Self.trailingPad
        let yPos  = topYForNextToast()

        // Start off-screen to the right, animate to final position.
        view.frame = NSRect(x: bounds.width, y: yPos,
                            width: Self.toastWidth, height: Self.toastHeight)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoDismissInterval, execute: work)
    }

    // MARK: - Hit testing passthrough

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let all non-toast-subview clicks fall through to views underneath.
        for sub in subviews {
            let converted = sub.convert(point, from: self)
            if sub.bounds.contains(converted) {
                return sub.hitTest(converted)
            }
        }
        return nil
    }

    // MARK: - Layout helpers

    private func topYForNextToast() -> CGFloat {
        // In unflipped NSView coords: Y=0 is bottom, Y=bounds.height is top.
        // First toast appears at the top; subsequent toasts stack downward.
        let topEdge = bounds.height - Self.toastHeight - Self.topPad
        guard !toasts.isEmpty else { return topEdge }
        let lowestMinY = toasts.map { $0.view.frame.minY }.min() ?? topEdge
        return lowestMinY - Self.toastHeight - Self.toastSpacing
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
        let endX = bounds.width - Self.toastWidth - Self.trailingPad
        var y = bounds.height - Self.toastHeight - Self.topPad
        for toast in toasts {   // oldest first → topmost position
            let target = NSPoint(x: endX, y: y)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.animDuration
                toast.view.animator().frame.origin = target
            }
            y -= Self.toastHeight + Self.toastSpacing
        }
    }

    // MARK: - Toast view factory

    private func makeToastView(_ event: PostureThresholdEvent) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.bgBar.cgColor
        container.layer?.cornerRadius    = 5
        container.layer?.borderWidth     = 1
        container.layer?.borderColor     = event.severity.color
            .withAlphaComponent(0.55).cgColor

        // Left severity accent bar
        let accent = NSView()
        accent.wantsLayer = true
        accent.layer?.backgroundColor = event.severity.color.cgColor
        accent.layer?.cornerRadius    = 1.5
        accent.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(accent)

        // Message label
        let label = NSTextField(labelWithString: "\(event.severity.icon) \(event.toastMessage)")
        label.font          = Theme.statusFont
        label.textColor     = Theme.fg
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        // Dismiss button
        let closeLabel = NSTextField(labelWithString: "×")
        closeLabel.font      = Theme.statusFont
        closeLabel.textColor = Theme.fgMuted
        closeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(closeLabel)

        NSLayoutConstraint.activate([
            accent.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            accent.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            accent.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7),
            accent.widthAnchor.constraint(equalToConstant: 3),

            label.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: closeLabel.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            closeLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            closeLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(toastClicked(_:)))
        container.addGestureRecognizer(click)

        return container
    }

    @objc private func toastClicked(_ recognizer: NSClickGestureRecognizer) {
        guard let tapped = recognizer.view else { return }
        dismiss(tapped)
    }
}
