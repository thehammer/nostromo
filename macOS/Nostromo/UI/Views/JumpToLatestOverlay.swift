import AppKit

/// Full-area overlay carrying the "Jump to latest" pill, shown only while a
/// transcript pane is *not* following the tail.
///
/// It is laid over the scroll view and must never intercept a click meant for
/// the transcript or the input bar: only the pill itself takes hits, everything
/// else falls through (`OverlayHitTest`; the sidebar "+" bug, #185, is what a
/// naive full-frame overlay does).
///
/// State is per instance, so every pane — in any window — owns its own.
final class JumpToLatestOverlay: NSView {

    /// Fired when the operator clicks the pill. The owner re-pins and scrolls.
    var onJump: (() -> Void)?

    /// The pill. Exposed for hit-testing and the app-control tree dump.
    let button = NSButton()

    private static let trailingInset: CGFloat = 24   // clears the vertical scroller
    private static let bottomInset:   CGFloat = 12
    private static let size = NSSize(width: 132, height: 26)

    /// True while the pane follows the tail; the pill is hidden then.
    private(set) var isFollowingTail = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setFollowingTail(_ following: Bool) {
        isFollowingTail = following
        button.isHidden = !FollowTailPolicy.showsJumpToLatest(isPinned: following)
    }

    /// Only the pill takes clicks. `point` is in the superview's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? {
        OverlayHitTest.hit(in: self, at: point)
    }

    override func layout() {
        super.layout()
        button.frame = NSRect(
            x: bounds.maxX - Self.trailingInset - Self.size.width,
            y: Self.bottomInset,
            width: Self.size.width, height: Self.size.height)
    }

    @objc private func jump() { onJump?() }

    private func configure() {
        button.title = "Jump to latest"
        button.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.isBordered = false
        button.contentTintColor = Theme.fg
        button.wantsLayer = true
        button.layer?.backgroundColor = Theme.bgBarActive.cgColor
        button.layer?.cornerRadius = Self.size.height / 2
        button.layer?.borderWidth = 1
        button.layer?.borderColor = Theme.borderInactive.cgColor
        button.target = self
        button.action = #selector(jump)
        button.setAccessibilityLabel("Jump to latest message")
        button.toolTip = "Scroll to the newest message and keep following"
        addSubview(button)
        setFollowingTail(true)
    }
}
