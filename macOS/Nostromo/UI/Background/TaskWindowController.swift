import AppKit
import Combine
import NostromoKit

// MARK: - Frames

/// Where a task window goes: the frame remembered for its kind, put back on a screen that exists.
enum TaskWindowFrame {
    static let defaultSize = NSSize(width: 680, height: 480)
    static let minimumSize = NSSize(width: 440, height: 280)

    /// `nostromo.taskWindow.frame.<kind>` (`shell`, `monitor`, `agent`, `workflow`, `other`).
    static func defaultsKey(kind: TaskKindWire) -> String {
        "nostromo.taskWindow.frame.\(BackgroundTaskList.kindLabel(kind).lowercased())"
    }

    /// `frame` moved (and shrunk, if it is bigger than the screen) onto the screen it overlaps most;
    /// nil when it overlaps none of `screens`: a lid sleep or a monitor flap can leave a remembered
    /// frame off every screen, and the window is then placed afresh.
    static func clamp(_ frame: NSRect, to screens: [NSRect]) -> NSRect? {
        let best = screens.max { overlapArea(frame, $0) < overlapArea(frame, $1) }
        guard let screen = best, overlapArea(frame, screen) > 0 else { return nil }
        let width = min(frame.width, screen.width)
        let height = min(frame.height, screen.height)
        let x = min(max(frame.minX, screen.minX), screen.maxX - width)
        let y = min(max(frame.minY, screen.minY), screen.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func overlapArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }
}

// MARK: - The panel

/// A task's window. A panel, **not** a `NostromoWindow`: that class's `windowShouldClose` ends the
/// app. Titled, closable, resizable, miniaturizable, not floating, and not hidden when the app
/// deactivates. It opens over a full-screen main window on that window's display
/// (`.fullScreenAuxiliary`) instead of switching Spaces.
///
/// It is **not** in `AppDelegate.windows` and not a QA extra window, so app-control cannot reach it
/// (`screenshot`, `tree`, `find`, `click`, `ax` address those lists): deliberate, since its text
/// would otherwise bypass the screenshot redaction policy.
///
/// Esc closes it (`SendToAgentWindow`'s pattern: `performKeyEquivalent`, key code 53). ⌘. is taken here
/// and does nothing: the window has no Stop yet, and it must never reach a main window's interrupt.
final class TaskPanel: NSPanel {
    static let escapeKeyCode: UInt16 = 53

    override var canBecomeKey: Bool { true }
    /// The main window stays the main window while a task window is key.
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if event.keyCode == Self.escapeKeyCode, flags.isEmpty {
            close()
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "." { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

// MARK: - One window

/// One task's window: the panel, its body view, and what keeps them current. It holds the task's
/// output model while it is open (polling runs for as long) and lets go when it closes.
///
/// Updates change the title and the body's content only: they never order the window front, never
/// make it key and never resize it. Closing it touches no other window's first responder.
final class TaskWindowController: NSObject, NSWindowDelegate {
    let focusTag: String
    let taskId: String
    let panel: TaskPanel
    let body: NSView & TaskWindowBody
    /// The output model this window holds (shell and monitor tasks).
    let model: TaskOutputModel?

    /// Called once when the window has closed.
    var onClose: ((TaskWindowController) -> Void)?

    private let kind: TaskKindWire
    private let defaults: UserDefaults
    private let makeContent: () -> TaskWindowContent?
    private var subscription: AnyCancellable?
    private var isClosed = false
    /// The window is being put in place: the moves that causes are not the user's.
    private var isPlacing = false

    init(focusTag: String, taskId: String, content: TaskWindowContent,
         body: NSView & TaskWindowBody, model: TaskOutputModel?, store: BackgroundTaskStore,
         defaults: UserDefaults, makeContent: @escaping () -> TaskWindowContent?) {
        self.focusTag = focusTag
        self.taskId = taskId
        self.kind = content.kind
        self.body = body
        self.model = model
        self.defaults = defaults
        self.makeContent = makeContent
        self.panel = TaskPanel(contentRect: NSRect(origin: .zero, size: TaskWindowFrame.defaultSize),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = TaskWindowPalette.background
        panel.isRestorable = false
        panel.tabbingMode = .disallowed
        panel.minSize = TaskWindowFrame.minimumSize
        panel.contentView = body
        panel.delegate = self
        panel.title = content.windowTitle
        if let output = body as? TaskOutputView { panel.initialFirstResponder = output.textView }
        body.apply(content: content)
        model?.acquire()
        subscription = store.changes
            .filter { $0 == focusTag }
            .sink { [weak self] _ in self?.refresh() }
    }

    var isOpen: Bool { !isClosed }

    /// Put the window where it was last (clamped to a screen), or place it at `fallbackTopLeft`. With
    /// other windows of the app open, `step` moves it down and to the right so it does not hide them.
    func place(screens: [NSRect], fallbackTopLeft: NSPoint, step: CGFloat) {
        isPlacing = true
        defer { isPlacing = false }
        var saved = defaults.string(forKey: TaskWindowFrame.defaultsKey(kind: kind)).map(NSRectFromString)
        saved?.origin.x += step
        saved?.origin.y -= step
        if let saved, saved.width > 0, saved.height > 0, let clamped = TaskWindowFrame.clamp(saved, to: screens) {
            panel.setFrame(clamped, display: false)
            return
        }
        panel.setContentSize(TaskWindowFrame.defaultSize)
        panel.setFrameTopLeftPoint(fallbackTopLeft)
        if let clamped = TaskWindowFrame.clamp(panel.frame, to: screens) { panel.setFrame(clamped, display: false) }
    }

    /// Show it and bring it to the front (a person opened it).
    func bringForward() {
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.close()
    }

    /// Read the task again and show it. Changes no more than the title and the body's content.
    func refresh() {
        guard !isClosed, let content = makeContent() else { return }
        let title = content.windowTitle
        if panel.title != title { panel.title = title }
        body.apply(content: content)
    }

    // MARK: NSWindowDelegate

    /// Closing a task window never ends the app.
    func windowShouldClose(_ sender: NSWindow) -> Bool { true }

    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        subscription = nil
        model?.release()
        panel.delegate = nil
        onClose?(self)
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    /// The user moved or resized it: that is the frame the next window of this kind opens with.
    private func saveFrame() {
        guard !isPlacing, !isClosed, panel.isVisible else { return }
        defaults.set(NSStringFromRect(panel.frame), forKey: TaskWindowFrame.defaultsKey(kind: kind))
    }
}

// MARK: - The manager

/// Every task window of the app: one per `(tag, taskId)`, reused. Opening a task that has a window
/// brings that window forward; two tasks have two windows. A window stays after its task ends, when
/// the popover closes, and when Clear Context empties the list; it closes with its focus.
final class TaskWindowManager {
    static let shared = TaskWindowManager()

    private struct Key: Hashable {
        let tag: String
        let taskId: String
    }

    private var controllers: [Key: TaskWindowController] = [:]
    private let store: BackgroundTaskStore
    private let registry: TaskOutputRegistry
    private let focusName: (String) -> String
    private let source: (String) -> SubagentTranscriptSource?
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private let visibleScreens: () -> [NSRect]
    private let keyWindow: () -> NSWindow?
    private let now: () -> Date

    /// `focusName` and `source` read the focus's session without creating one.
    init(store: BackgroundTaskStore = .shared,
         registry: TaskOutputRegistry = .shared,
         focusName: @escaping (String) -> String = { AppStore.shared.sessionForHealthView(tag: $0)?.displayName ?? $0 },
         source: @escaping (String) -> SubagentTranscriptSource? = { AppStore.shared.sessionForHealthView(tag: $0) },
         defaults: UserDefaults = .standard,
         pasteboard: NSPasteboard = .general,
         visibleScreens: @escaping () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) },
         keyWindow: @escaping () -> NSWindow? = { NSApp?.keyWindow },
         now: @escaping () -> Date = Date.init) {
        self.store = store
        self.registry = registry
        self.focusName = focusName
        self.source = source
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.visibleScreens = visibleScreens
        self.keyWindow = keyWindow
        self.now = now
    }

    var openCount: Int { controllers.count }

    func isOpen(tag: String, taskId: String) -> Bool {
        controllers[Key(tag: tag, taskId: taskId)] != nil
    }

    func controller(tag: String, taskId: String) -> TaskWindowController? {
        controllers[Key(tag: tag, taskId: taskId)]
    }

    /// The window of this task, made if there is none, and brought forward. Nil when the store has
    /// never heard of the task.
    @discardableResult
    func open(tag: String, taskId: String) -> TaskWindowController? {
        let key = Key(tag: tag, taskId: taskId)
        if let existing = controllers[key] {
            existing.bringForward()
            return existing
        }
        guard let content = content(tag: tag, taskId: taskId) else { return nil }

        let model: TaskOutputModel?
        let body: NSView & TaskWindowBody
        switch content.kind {
        case .shell, .monitor:
            let held = registry.model(tag: tag, taskId: taskId)
            model = held
            body = TaskOutputView(focusTag: tag, taskId: taskId, model: held, pasteboard: pasteboard)
        case .agent:
            model = nil
            body = SubagentTaskView(focusTag: tag, taskId: taskId, source: source(tag))
        case .workflow, .other, .unknown:
            model = nil
            body = TaskNoOutputView(focusTag: tag, taskId: taskId)
        }
        let controller = TaskWindowController(
            focusTag: tag, taskId: taskId, content: content, body: body, model: model, store: store,
            defaults: defaults, makeContent: { [weak self] in self?.content(tag: tag, taskId: taskId) })
        controller.onClose = { [weak self] closed in
            self?.controllers.removeValue(forKey: Key(tag: closed.focusTag, taskId: closed.taskId))
        }
        controller.place(screens: visibleScreens(), fallbackTopLeft: cascadeTopLeft(), step: cascadeStep())
        controllers[key] = controller
        controller.bringForward()
        return controller
    }

    /// The focus is gone: close its task windows and drop its models.
    func closeWindows(forFocus tag: String) {
        for (key, controller) in controllers where key.tag == tag { controller.close() }
        registry.forget(tag: tag)
    }

    func closeAll() {
        for controller in Array(controllers.values) { controller.close() }
    }

    // MARK: Private

    /// How far the next window sits from where a first one would: a step for each window open.
    private func cascadeStep() -> CGFloat {
        CGFloat(28 * (controllers.count % 8))
    }

    /// Where the next window's top-left goes when nothing is remembered: just inside the key window's
    /// top-left corner.
    private func cascadeTopLeft() -> NSPoint {
        let origin = keyWindow().map { NSPoint(x: $0.frame.minX + 40, y: $0.frame.maxY - 40) }
            ?? visibleScreens().first.map { NSPoint(x: $0.minX + 80, y: $0.maxY - 80) }
            ?? NSPoint(x: 80, y: 600)
        let step = cascadeStep()
        return NSPoint(x: origin.x + step, y: origin.y - step)
    }

    private func content(tag: String, taskId: String) -> TaskWindowContent? {
        guard let state = store.state(for: tag), let meta = state.allTasks.last(where: { $0.id == taskId }) else { return nil }
        let row = store.list(for: tag).allRows.first { $0.id == taskId }
        let nowMs = UInt64(max(0, (now().timeIntervalSince1970 * 1000).rounded()))
        return TaskWindowContent.make(tag: tag, focusName: focusName(tag), meta: meta, row: row,
                                      detail: state.details[taskId], nowMs: nowMs)
    }
}

// MARK: - The popover's actions

/// What a Background activity row does when it is opened: show the task's window. (Stop is BA5's, Show
/// in Transcript is BA6's: they extend this object, so until then their items are not offered.)
final class BackgroundTaskWindowActions: BackgroundTaskActions {
    static let shared = BackgroundTaskWindowActions()

    private let manager: TaskWindowManager?

    /// `manager` nil: the app's own (`TaskWindowManager.shared`, read when a row is opened).
    init(manager: TaskWindowManager? = nil) {
        self.manager = manager
    }

    func canOpen(_ row: BackgroundTaskRow, tag: String) -> Bool { true }

    func open(_ row: BackgroundTaskRow, tag: String) {
        (manager ?? TaskWindowManager.shared).open(tag: tag, taskId: row.id)
    }
}
