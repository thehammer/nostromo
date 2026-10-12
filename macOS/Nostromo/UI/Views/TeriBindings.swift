import AppKit
import Combine

/// The Teri lane's glue to the app: builds the native surface the daemon's
/// `teri_surface` pane maps to (see `DynamicFocusView.makeLeafView`). The only
/// place the Teri views touch `AppStore`; everything else takes a `WorkStore`.
enum TeriBindings {
    private static var cancellables = Set<AnyCancellable>()
    private static var isWired = false

    static func makeSurface(focus: Focus) -> NSView {
        wireStoreToDaemon()
        let surface = TeriSurfaceView(store: WorkStore.shared)
        surface.onSendToAgent = { [weak surface] itemId in presentSendToAgent(itemId: itemId, from: surface) }
        surface.onOpenSent = { [weak surface] marker in open(marker, window: surface?.window) }
        surface.translatesAutoresizingMaskIntoConstraints = false
        flow.onPreparingChanged = { [weak surface] preparing in surface?.setSendPreparing(preparing) }
        return surface
    }

    // MARK: - Send to agent

    /// The sheet on screen, retained while it is. One at a time.
    private static var presentedSheet: SendToAgentSheet?
    /// The preview request in flight and the sheet: what a second press is told.
    private static let flow = SendToAgentFlow()
    private static let navigator = Navigator()

    /// Ask the daemon for `itemId`'s defaults and show the confirmation sheet on the surface's
    /// window. Nothing is created until the user confirms. The surface shows progress while the
    /// daemon is asked, and a press made meanwhile (or with a sheet up) gets a notice.
    static func presentSendToAgent(itemId: String, from surface: TeriSurfaceView?, store: WorkStore = .shared) {
        let window = surface?.window
        flow.begin(
            itemId: itemId, window: window, previewer: store,
            presentSheet: { preview, window in
                let item = store.allItems.first { $0.id == itemId }
                presentSheet(preview: preview, item: item, store: store, window: window)
                return true
            },
            showError: { message, window in alert("Can't send this item", message, on: window) })
    }

    private static func presentSheet(preview: SendPreview, item: WorkItem?, store: WorkStore, window: NSWindow) {
        var projects = CreateFocusSheet.discoverProjects()
        for path in FocusStore.shared.focuses.compactMap(\.projectPath) where !projects.contains(path) {
            projects.append(path)
        }
        let sheet = SendToAgentSheet(
            itemId: preview.itemId,
            mruKey: item.flatMap { TeriProjectMRU.key(for: $0) },
            preview: preview,
            agents: CreateFocusSheet.discoverAgents(),
            projects: projects,
            orgResolver: RepoOrgResolver(),
            mru: TeriProjectMRU(),
            sender: store
        ) { [weak window] result in
            flow.handle(result, window: window, navigator: navigator)
        }
        presentedSheet = sheet
        window.beginSheet(sheet.window!) { _ in
            presentedSheet = nil
            flow.sheetDismissed()
        }
    }

    private static func alert(_ title: String, _ message: String, on window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    // MARK: - Markers

    /// Go to the focus or Mother job a "sent to …" marker names; say so when it is not there yet.
    static func open(_ marker: SentMarker, window: NSWindow? = nil) {
        flow.handle(.goToExisting(marker), window: window, navigator: navigator)
    }

    private final class Navigator: SendNavigating {
        func goToFocus(tag: String) -> Bool {
            guard let focus = FocusStore.shared.focuses.first(where: { $0.sessionTag == tag }) else { return false }
            AppStore.shared.focusSelectionRequests.send(focus)
            return true
        }

        func goToJob(_ jobId: String) -> Bool {
            guard let mother = FocusStore.shared.focuses.first(where: { $0.id == "mother" }) else { return false }
            MotherView.requestedJobId = jobId
            AppStore.shared.focusSelectionRequests.send(mother)
            NotificationCenter.default.post(name: MotherView.openJobNotification, object: nil)
            return true
        }
    }

    /// Point the shared store at the daemon connection: outgoing frames go to
    /// its client, and its connected flag follows the client's.
    private static func wireStoreToDaemon() {
        guard !isWired else { return }
        isWired = true
        let client = AppStore.shared.client
        WorkStore.shared.sendFrame = { client.send($0) }
        client.connected
            .receive(on: DispatchQueue.main)
            .sink { WorkStore.shared.setConnected($0) }
            .store(in: &cancellables)
    }
}
