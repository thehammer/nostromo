import AppKit

// FV3: reader-protected roll-in (PRD "Rolling behaviour and scroll safety", contract §2.5).
//
// In the Focus view each agent turn shows only its latest message. When the agent posts a newer
// one the previous message "rolls in" to the activity row above it. That is an automatic change
// on every message, so it must never take a message from under the reader's eyes.
//
// Three parts, in this file because the logic test bundle compiles only the files the project
// lists:
//   - `RollInPolicy`: the pure rules (what to hold, when to release, what to animate);
//   - `RollInAnimating`: the seam that plays the collapse, injected so tests need no timer;
//   - `RollInHolds`: the pane's wiring, which `ReplView` and the scroll-test rig share.
//
// Holds are per pane and transient (contract §2.5): never persisted, never broadcast. They live in
// the pane's `TurnInteractionStore` and nowhere else.

/// What a roll-in plays: nothing, or the outgoing message collapsing.
enum RollInAnimation: Equatable {
    case none
    case collapse(duration: TimeInterval)
}

/// What the pane decides when a newer message is about to roll the latest one into activity.
enum RollInDecision: Equatable {
    /// Keep the outgoing message where it is, as conversation, until the policy releases it.
    case hold
    /// Roll it in now, playing `animation`.
    case roll(RollInAnimation)
}

enum RollInPolicy {

    /// An on-screen roll-in collapses for at most this long (ease-out).
    static let collapseDuration: TimeInterval = 0.15

    /// The most messages one turn holds back at once. Holds are self-limiting (only what is on
    /// screen or selected is held, and a held message that leaves the viewport rolls in), so the
    /// cap is a backstop: past it the oldest (topmost) hold is released to make room.
    static let maxHeldPerTurn = 16

    /// Whether any part of `messageRect` is inside `visibleRect`. Rects that only touch (a zero
    /// height or zero width overlap) are not visible, and neither is an empty message rect.
    static func isVisible(_ messageRect: CGRect, in visibleRect: CGRect) -> Bool {
        let width = min(messageRect.maxX, visibleRect.maxX) - max(messageRect.minX, visibleRect.minX)
        let height = min(messageRect.maxY, visibleRect.maxY) - max(messageRect.minY, visibleRect.minY)
        return width > 0 && height > 0
    }

    /// Whether the outgoing message's roll-in waits.
    ///
    /// - A text selection inside the message always holds it, following the tail or not: the
    ///   roll-in rebuilds the message's views, which would destroy the selection (and a drag in
    ///   progress). Selection inside a message survives any roll-in (PRD).
    /// - Otherwise it holds only while the pane is **not** following the tail and any part of the
    ///   message is on screen. A following pane has the message at the bottom, where the
    ///   roll-in is the expected, animated change.
    static func shouldHold(followingTail: Bool, messageRect: CGRect, visibleRect: CGRect,
                           selectionInMessage: Bool) -> Bool {
        selectionInMessage || (!followingTail && isVisible(messageRect, in: visibleRect))
    }

    /// Whether a message held earlier rolls in now: the hold no longer applies (it left the
    /// viewport, the selection cleared, the pane follows the tail again), or the operator jumped
    /// to latest, which completes every roll-in.
    static func shouldRelease(followingTail: Bool, messageRect: CGRect, visibleRect: CGRect,
                              selectionInMessage: Bool, jumpedToLatest: Bool) -> Bool {
        jumpedToLatest
            || !shouldHold(followingTail: followingTail, messageRect: messageRect,
                           visibleRect: visibleRect, selectionInMessage: selectionInMessage)
    }

    /// What a roll-in that goes through plays. Only a roll-in that is on screen, in a pane that is
    /// following the tail, animates; Reduce Motion makes it instant; an off-screen change is never
    /// animated.
    static func animation(onScreen: Bool, followingTail: Bool, reduceMotion: Bool) -> RollInAnimation {
        guard onScreen, followingTail, !reduceMotion else { return .none }
        return .collapse(duration: collapseDuration)
    }
}

// MARK: - Animation seam

/// Plays the collapse of a message that has just rolled in. The turn's geometry is already
/// final when this is called (the pane's pin re-asserts at the bottom at once); the animation
/// is the departing message's frame and opacity, on a ghost over the island.
protocol RollInAnimating: AnyObject {
    /// Collapse `ghost` over `duration`, then call `completion` (once). `ghost` is removed from
    /// its superview by the completion, not by the animator.
    func collapse(_ ghost: NSView, duration: TimeInterval, completion: @escaping () -> Void)
}

/// The shipping animator: ease-out frame height and opacity, through AppKit's animation context.
final class SystemRollInAnimator: RollInAnimating {
    func collapse(_ ghost: NSView, duration: TimeInterval, completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            var collapsed = ghost.frame
            collapsed.size.height = 0
            ghost.animator().frame = collapsed
            ghost.animator().alphaValue = 0
        }, completionHandler: completion)
    }
}

/// The departing message while it collapses. Top-anchored (flipped), clips its children, and
/// never takes a click.
final class RollInGhostView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - The pane's wiring

/// Decides, per pane, which roll-ins wait, and releases them. `ReplView` owns one; so does the
/// scroll-test rig, so the real methods are what the tests drive.
///
/// Evaluation is O(held messages): with nothing held, a scroll, a selection change or a pin
/// change returns at once (`evaluations` counts the messages examined, for the test that says so).
/// A turn with holds that has no view (it was evicted) has nothing on screen and nothing
/// selected, so its holds are dropped.
final class RollInHolds {

    private let scrollView: NSScrollView
    private let store: TurnInteractionStore
    private let viewFor: (UUID) -> ChatTurnView?
    private let turnFor: (UUID) -> ChatTurn?
    private let applyChange: (_ turnIds: Set<UUID>, _ mutation: () -> Void) -> Void

    /// The pane follows the tail (`FollowTailController.isPinned`).
    var isFollowingTail: () -> Bool = { true }
    /// The system's Reduce Motion setting. Injected so a test can flip it.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Plays an on-screen collapse. Injected so a test completes it synchronously.
    var animator: RollInAnimating = SystemRollInAnimator()

    /// Messages examined by `reevaluate`, in the pane's lifetime.
    private(set) var evaluations = 0

    private var releasing = false
    private var observer: NSObjectProtocol?

    /// - Parameters:
    ///   - viewFor: a turn's view, nil when it is not materialized.
    ///   - turnFor: the turn as it stands (hydrated), to re-present it on release.
    ///   - applyChange: re-presents turns while keeping the reading position
    ///     (`TranscriptViewportCoordinator.applyFoldChange`); `mutation` does the work.
    init(scrollView: NSScrollView, store: TurnInteractionStore,
         viewFor: @escaping (UUID) -> ChatTurnView?, turnFor: @escaping (UUID) -> ChatTurn?,
         applyChange: @escaping (_ turnIds: Set<UUID>, _ mutation: () -> Void) -> Void) {
        self.scrollView = scrollView
        self.store = store
        self.viewFor = viewFor
        self.turnFor = turnFor
        self.applyChange = applyChange
        observer = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: nil, queue: nil
        ) { [weak self] note in self?.selectionDidChange(note) }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Wiring a turn view

    /// Give a turn's view its roll-in hooks. Call when the view is built.
    func wire(_ view: ChatTurnView, turn id: UUID) {
        view.animator = animator
        view.decideRollIn = { [weak self, weak view] ordinal in
            guard let self, let view else { return .roll(.none) }
            return self.decide(view, ordinal: ordinal)
        }
        view.onHold = { [weak self] ordinal in self?.store.hold(turn: id, ordinal: ordinal) }
        view.onHoldDropped = { [weak self] ordinal in self?.store.release(turn: id, ordinals: [ordinal]) }
    }

    /// A newer message is about to roll `ordinal` into activity: hold it, or roll it in (animated
    /// or not). Called by the view during a live update, before it changes anything.
    func decide(_ view: ChatTurnView, ordinal: Int) -> RollInDecision {
        guard let (rect, visible) = geometry(of: view, ordinal: ordinal) else { return .roll(.none) }
        let following = isFollowingTail()
        if RollInPolicy.shouldHold(followingTail: following, messageRect: rect, visibleRect: visible,
                                   selectionInMessage: view.hasSelection(inMessage: ordinal)) {
            return .hold
        }
        return .roll(RollInPolicy.animation(onScreen: RollInPolicy.isVisible(rect, in: visible),
                                            followingTail: following, reduceMotion: reduceMotion()))
    }

    // MARK: Triggers

    /// The viewport moved (`FollowTailController.onScroll`).
    func scrolled() { reevaluate() }

    /// The pane became pinned (it follows the tail again). `jumpedToLatest`: the operator pressed
    /// Jump to latest or sent a message, which completes every roll-in; scrolling back down to
    /// the tail releases only the holds the policy no longer wants (a selection still holds).
    func pinned(jumpedToLatest: Bool) { reevaluate(jumpedToLatest: jumpedToLatest) }

    /// Release what the policy no longer holds. O(held messages).
    func reevaluate(jumpedToLatest: Bool = false) {
        guard !releasing, store.hasHolds else { return }
        let following = isFollowingTail()
        let viewport = scrollView.contentView.bounds
        var due: [UUID: Set<Int>] = [:]
        var animation: [UUID: RollInAnimation] = [:]

        for id in store.heldTurns {
            let held = store.state(for: id).heldOrdinals
            guard let view = viewFor(id) else {
                due[id] = held
                continue
            }
            var onScreen = false
            for ordinal in held {
                evaluations += 1
                let measured = geometry(of: view, ordinal: ordinal)
                let visible = measured.map { RollInPolicy.isVisible($0.rect, in: $0.visible) } ?? false
                let shouldRelease = RollInPolicy.shouldRelease(
                    followingTail: following, messageRect: measured?.rect ?? .zero,
                    visibleRect: measured?.visible ?? viewport,
                    selectionInMessage: view.hasSelection(inMessage: ordinal), jumpedToLatest: jumpedToLatest)
                guard shouldRelease else { continue }
                due[id, default: []].insert(ordinal)
                onScreen = onScreen || (visible && !jumpedToLatest)
            }
            animation[id] = RollInPolicy.animation(onScreen: onScreen, followingTail: following,
                                                   reduceMotion: reduceMotion())
        }
        guard !due.isEmpty else { return }
        release(due, animation: animation)
    }

    // MARK: Release

    private func release(_ ordinals: [UUID: Set<Int>], animation: [UUID: RollInAnimation]) {
        releasing = true
        defer { releasing = false }
        for (id, set) in ordinals { store.release(turn: id, ordinals: set) }
        applyChange(Set(ordinals.keys)) {
            for (id, set) in ordinals {
                guard let view = viewFor(id), let turn = turnFor(id) else { continue }
                let carried = view.releaseHolds(turn: turn, ordinals: set, animation: animation[id] ?? .none)
                for (key, isExpanded) in carried { store.setActivity(turn: id, key: key, isExpanded) }
            }
        }
    }

    // MARK: Geometry

    /// The outgoing message's rect in the document's coordinates, and the viewport (also in the
    /// document's). Nil when the message has no views to measure (not rendered, or the view is
    /// not in the document).
    private func geometry(of view: ChatTurnView, ordinal: Int) -> (rect: CGRect, visible: CGRect)? {
        guard let document = scrollView.documentView, view.isDescendant(of: document),
              let rect = view.rollInRect(ordinal: ordinal) else { return nil }
        return (view.convert(rect, to: document), scrollView.contentView.bounds)
    }

    private func selectionDidChange(_ note: Notification) {
        guard store.hasHolds, let text = note.object as? NSTextView else { return }
        let owner: NSView? = text.isFieldEditor ? text.delegate as? NSView : text
        guard let owner, owner.isDescendant(of: scrollView) else { return }
        reevaluate()
    }
}
