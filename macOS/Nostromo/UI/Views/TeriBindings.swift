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
        surface.onSendToAgent = { [weak surface] itemId in presentSendToAgent(itemId: itemId, from: surface?.window) }
        surface.onOpenSent = { marker in open(marker) }
        surface.translatesAutoresizingMaskIntoConstraints = false
        return surface
    }

    // MARK: - Send to agent

    /// The sheet on screen, retained while it is. One at a time.
    private static var presentedSheet: SendToAgentSheet?
    private static var isPreviewing = false

    /// Ask the daemon for `itemId`'s defaults and show the confirmation sheet on `window`.
    /// Nothing is created until the user presses Start.
    static func presentSendToAgent(itemId: String, from window: NSWindow?, store: WorkStore = .shared) {
        guard let window, presentedSheet == nil, !isPreviewing else { return }
        isPreviewing = true
        store.requestSendPreview(itemId) { response in
            isPreviewing = false
            switch response {
            case .sendPreview(.ok(let preview)):
                let item = store.allItems.first { $0.id == itemId }
                presentSheet(preview: preview, item: item, store: store, window: window)
            case .sendPreview(.err(let error)), .failed(let error):
                alert("Can't send this item", error.message, on: window)
            case .timedOut:
                alert("Can't send this item", "The daemon did not answer in time.", on: window)
            case .detail, .sendResult:
                break
            }
        }
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
        ) { result in
            switch result {
            case .sent(let outcome) where outcome.kind == "existing":
                if let tag = outcome.focusTag { goToFocus(tag: tag) } else if let job = outcome.jobId { goToJob(job) }
            case .goToExisting(let marker):
                open(marker)
            case .sent, .cancelled:
                break   // a new focus selects itself (`select_for_client`)
            }
        }
        presentedSheet = sheet
        window.beginSheet(sheet.window!) { _ in presentedSheet = nil }
    }

    private static func alert(_ title: String, _ message: String, on window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    // MARK: - Markers

    /// Go to the focus or Mother job a "sent to …" marker names.
    static func open(_ marker: SentMarker) {
        if marker.kind == "mother_job" { goToJob(marker.targetId) } else { goToFocus(tag: marker.targetId) }
    }

    private static func goToFocus(tag: String) {
        guard let focus = FocusStore.shared.focuses.first(where: { $0.sessionTag == tag }) else { return }
        AppStore.shared.focusSelectionRequests.send(focus)
    }

    private static func goToJob(_ jobId: String) {
        guard let mother = FocusStore.shared.focuses.first(where: { $0.id == "mother" }) else { return }
        MotherView.requestedJobId = jobId
        AppStore.shared.focusSelectionRequests.send(mother)
        NotificationCenter.default.post(name: MotherView.openJobNotification, object: nil)
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
