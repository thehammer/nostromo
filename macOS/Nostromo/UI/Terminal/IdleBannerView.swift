import AppKit

/// The yellow strip under a remote pane's header: "Closing in 1:59 (no keystrokes for 13 minutes)" and
/// Keep open. It shows from the daemon's idle warning (`idle_closes_at`) until a keystroke or Keep open
/// clears it, and only while the shell is running and the view is in a window. No SwiftTerm.
///
/// A 1 s timer counts it down. It runs in the common run-loop modes (it keeps counting while a menu is
/// open or a divider is being dragged), exists only while the banner shows, and is gone when the banner
/// hides or the view leaves its window. The figure in the text is the daemon's own
/// (`TerminalInfo.idleWarnAfterSecs`), not a constant here.
final class IdleBannerView: NSView {

    static let height: CGFloat = 24

    /// The banner appeared or disappeared (the host lays out again).
    var onVisibilityChange: (() -> Void)?
    /// The Keep open button; the host wires its action.
    let keepOpenButton = NSButton()
    /// The clock, injectable for tests.
    var now: () -> Date = Date.init

    /// Ticks the countdown while the banner shows; nil otherwise.
    private(set) var timer: Timer?

    private let label = NSTextField(labelWithString: "")
    private var info: TerminalInfo?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.idleBannerYellow.cgColor
        isHidden = true
        setAccessibilityIdentifier("terminal-idle-banner")
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .black
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityIdentifier("terminal-idle-label")
        keepOpenButton.isBordered = false
        keepOpenButton.attributedTitle = NSAttributedString(string: "Keep open", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        keepOpenButton.wantsLayer = true
        keepOpenButton.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        keepOpenButton.layer?.cornerRadius = 4
        keepOpenButton.setAccessibilityIdentifier("terminal-keep-open")
        keepOpenButton.setAccessibilityLabel("Keep terminal open")
        addSubview(label)
        addSubview(keepOpenButton)
    }

    required init?(coder: NSCoder) {
        fatalError("IdleBannerView is created in code")
    }

    deinit {
        timer?.invalidate()
    }

    /// The daemon's latest description of the pane.
    func update(info: TerminalInfo?) {
        self.info = info
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let buttonW: CGFloat = 76
        let buttonH: CGFloat = 18
        keepOpenButton.frame = NSRect(x: bounds.width - buttonW - 6, y: (h - buttonH) / 2, width: buttonW, height: buttonH)
        let labelSize = label.intrinsicContentSize
        label.frame = NSRect(x: 10, y: (h - labelSize.height) / 2,
                             width: max(0, bounds.width - buttonW - 22), height: labelSize.height)
    }

    private func refresh() {
        var state = IdleCountdownModel.State.hidden
        if info?.status == .running, window != nil {
            state = IdleCountdownModel.state(idleClosesAt: info?.idleClosesAt, now: now())
        }
        let wasHidden = isHidden
        switch state {
        case .hidden:
            isHidden = true
            timer?.invalidate()
            timer = nil
        case .counting(let secondsLeft):
            label.stringValue = IdleCountdownModel.text(secondsLeft: secondsLeft, warnAfterSecs: info?.idleWarnAfterSecs)
            isHidden = false
            needsLayout = true
            if timer == nil {
                // Common modes: the countdown keeps running while a menu is open or a divider is dragged.
                let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
                RunLoop.main.add(tick, forMode: .common)
                timer = tick
            }
        }
        if wasHidden != isHidden { onVisibilityChange?() }
    }
}
