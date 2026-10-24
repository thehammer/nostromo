import AppKit
import Combine
import NostromoKit

// CL2: floats the sign-in card over the bottom of a transcript pane.
//
// A transparent view pinned to the scroll view's frame (added above it by `ReplView`, like
// `JumpToLatestOverlay` and `ApprovalOverlayHost`). It hit-tests only inside the card, so every
// click elsewhere reaches the transcript and the composer. It shows a card only while the store
// lists this focus's tag.
//
// What it must never do: change the scroll view's or the input bar's frames (the card has a
// frame of its own), or take focus on arrival.

final class ClaudeSignInOverlayHost: NSView {

    static let bottomInset: CGFloat = 8
    /// The transcript column's margins; the right one also clears the vertical scroller.
    static let leadingInset: CGFloat = 12
    static let trailingInset: CGFloat = 24
    static let stackGap: CGFloat = 6

    let focusTag: String
    private(set) var card: ClaudeSignInCardView?

    private let store: ClaudeLoginStore
    private let launcher: LoginTerminalLauncher
    private let permit: ClaudeSignInCardView.GesturePermit?
    /// How far up an overlay of the same pane (the approval card) reaches from the bottom, so this
    /// card stacks above it without moving it. Zero when there is none.
    private let obstructionTop: () -> CGFloat
    private var subscription: AnyCancellable?

    init(tag: String, store: ClaudeLoginStore,
         launcher: LoginTerminalLauncher = LoginTerminalLauncher(),
         permit: ClaudeSignInCardView.GesturePermit? = nil,
         obstructionTop: @escaping () -> CGFloat = { 0 }) {
        focusTag = tag
        self.store = store
        self.launcher = launcher
        self.permit = permit
        self.obstructionTop = obstructionTop
        super.init(frame: .zero)
        subscription = store.changes
            .filter { [tag] in $0.contains(tag) }
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        OverlayHitTest.hit(in: self, at: point)
    }

    func refresh() {
        guard let session = store.session(tag: focusTag) else {
            card?.removeFromSuperview()
            card = nil
            return
        }
        if let card {
            card.update(session: session, claudeBin: store.claudeBin, watch: store.watch)
        } else {
            let new = ClaudeSignInCardView(tag: focusTag, session: session, claudeBin: store.claudeBin,
                                           watch: store.watch, store: store, launcher: launcher, permit: permit)
            addSubview(new)
            card = new
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let card else { return }
        let width = max(0, bounds.width - Self.leadingInset - Self.trailingInset)
        guard width > 0 else { return }
        let obstruction = obstructionTop()
        let y = obstruction > 0 ? obstruction + Self.stackGap : Self.bottomInset
        let height = min(card.preferredHeight(forWidth: width), max(0, bounds.height - y - Self.bottomInset))
        let frame = NSRect(x: Self.leadingInset, y: y, width: width, height: height)
        if card.frame != frame { card.frame = frame }
    }
}
