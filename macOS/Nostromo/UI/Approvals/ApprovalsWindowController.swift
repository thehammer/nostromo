import AppKit
import NostromoKit

// AP5: the Approvals window. One reusable panel, opened from Window ▸ Approvals, from the production-shell guard
// bar's `View in log`, and from a click on a tool row's approval status. Read-only: nothing in it edits,
// deletes or clears an entry.
//
// A panel, **not** a `NostromoWindow` (that class's `windowShouldClose` ends the app), following the task window
// (BA4): its frame is remembered and put back on a screen that exists. It is shown with `orderFront`: it never
// makes itself key, so opening it from a link takes keyboard focus from nothing (the composer keeps its first
// responder), and a click in it makes it key like any window. It is not in `AppDelegate.windows`, so app-control's
// `screenshot`, `tree`, `find` and `click` cannot reach it (its text would otherwise bypass the screenshot policy).

/// The panel. Esc closes it.
final class ApprovalsPanel: NSPanel {
    static let escapeKeyCode: UInt16 = 53

    override var canBecomeKey: Bool { true }
    /// The main window stays the main window while this one is key.
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if event.keyCode == Self.escapeKeyCode, flags.isEmpty {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { close() }
}

final class ApprovalsWindowManager: NSObject, NSWindowDelegate {

    static let shared = ApprovalsWindowManager()

    static let defaultSize = NSSize(width: 980, height: 560)
    static let minimumSize = NSSize(width: 700, height: 320)
    static let defaultsKey = "nostromo.approvalsWindow.frame"

    private(set) var panel: ApprovalsPanel?
    private(set) var logView: ApprovalsLogView?

    private let defaults: UserDefaults
    private let store: ApprovalsLogStore
    private let revealer: ApprovalsTranscriptRevealing
    private let visibleScreens: () -> [NSRect]
    private var isPlacing = false

    init(defaults: UserDefaults = .standard,
         store: ApprovalsLogStore = .shared,
         revealer: ApprovalsTranscriptRevealing = LiveApprovalsTranscriptReveal(),
         visibleScreens: @escaping () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }) {
        self.defaults = defaults
        self.store = store
        self.revealer = revealer
        self.visibleScreens = visibleScreens
        super.init()
    }

    var isOpen: Bool { panel?.isVisible ?? false }

    /// Open the window (or bring it forward), showing every row, or only those `link` names. It reads the log
    /// afresh. It never makes the window key and never touches another window.
    func show(link: ApprovalsLogLink? = nil) {
        let (panel, view) = ensureWindow()
        view.apply(link: link)
        if !panel.isVisible { place(panel) }
        panel.orderFront(nil)
    }

    func close() { panel?.close() }

    // MARK: - Window

    private func ensureWindow() -> (ApprovalsPanel, ApprovalsLogView) {
        if let panel, let logView { return (panel, logView) }
        let panel = ApprovalsPanel(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                   backing: .buffered, defer: true)
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = ApprovalPalette.cardBackground
        panel.isRestorable = false
        panel.tabbingMode = .disallowed
        panel.minSize = Self.minimumSize
        panel.title = "Approvals"
        let view = ApprovalsLogView(store: store, revealer: revealer)
        panel.contentView = view
        panel.delegate = self
        self.panel = panel
        logView = view
        return (panel, view)
    }

    /// Where it was last (clamped to a screen), else near the top-left of the main screen.
    private func place(_ panel: ApprovalsPanel) {
        isPlacing = true
        defer { isPlacing = false }
        let screens = visibleScreens()
        if let saved = defaults.string(forKey: Self.defaultsKey).map(NSRectFromString), saved.width > 0, saved.height > 0,
           let clamped = TaskWindowFrame.clamp(saved, to: screens) {
            panel.setFrame(clamped, display: false)
            return
        }
        panel.setContentSize(Self.defaultSize)
        if let screen = screens.first {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.minX + 80, y: screen.maxY - 80))
            if let clamped = TaskWindowFrame.clamp(panel.frame, to: screens) { panel.setFrame(clamped, display: false) }
        }
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    /// The user moved or resized it: that is where it opens next time.
    private func saveFrame() {
        guard !isPlacing, let panel else { return }
        defaults.set(NSStringFromRect(panel.frame), forKey: Self.defaultsKey)
    }
}
