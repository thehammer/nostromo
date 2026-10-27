import AppKit
import Combine

/// The single app-wide owner of the remote-shell sheets: the "Connect to PRODUCTION" confirmation
/// and, when a connection could not be made, the failure sheet.
///
/// - A `remote_shell_confirm_request` becomes a `RemoteShellConfirmSheet` on the key window (the main
///   window, then any window, when none is key). The daemon holds one request at a time, so a newer
///   one replaces the sheet on screen without answering for it.
/// - The asking focus is flagged in the sidebar (`raiseAttention`), as `DecisionPresenter` does for an
///   agent's question; this never switches a window's focus or activates the app.
/// - A `remote_shell_resolved` closes the sheet (sending nothing), then shows what the outcome needs:
///   the failure sheet for `connect_failed`, a toast when nobody answered in time.
///
/// Like `DecisionPresenter` it is the only subscriber to the app's remote-shell events and the only
/// place a confirm sheet is built; `MainLayout` is built once per window and must not know about
/// them. Started once from `AppDelegate.applicationDidFinishLaunching`, beside
/// `DecisionPresenter.shared.start()`.
final class RemoteShellPresenter {

    static let shared = RemoteShellPresenter()

    private var cancellables = Set<AnyCancellable>()
    /// The confirm sheet on screen, if any.
    private var sheet: RemoteShellConfirmSheet?
    /// The request the daemon is waiting on, kept until it resolves (the sheet is gone after Connect,
    /// but a failed connection still names its target).
    private var request: RemoteShellConfirmRequest?
    /// Kept alive while it is on screen.
    private var failureSheet: RemoteShellFailureSheet?

    private let store: RemoteShellStore
    private let terminals: TerminalSessionStore

    private init(store: RemoteShellStore = .shared, terminals: TerminalSessionStore = .shared) {
        self.store = store
        self.terminals = terminals
    }

    func start() {
        AppStore.shared.remoteShellRequests
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in self?.present(request) }
            .store(in: &cancellables)

        AppStore.shared.remoteShellResolutions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] resolved in self?.handleResolved(resolved) }
            .store(in: &cancellables)
    }

    // MARK: - Presenting

    private func present(_ newRequest: RemoteShellConfirmRequest) {
        store.present(newRequest)
        // The daemon holds one request at a time: whatever was on screen is over.
        sheet?.closeWithoutAnswering()
        sheet = nil
        request = newRequest
        guard let host = Self.hostWindow() else { return }

        let model = RemoteShellStore.sheetModel(for: newRequest) { tag in
            FocusStore.shared.focuses.first { $0.sessionTag == tag }?.displayName
        }
        let confirm = RemoteShellConfirmSheet(request: newRequest, model: model)
        guard let sheetWindow = confirm.window else { return }
        sheet = confirm
        let key = Self.attentionKey(newRequest.requestId)
        if newRequest.requestedBy.kind != "user", let tag = newRequest.tag ?? newRequest.requestedBy.tag {
            AppStore.shared.raiseAttention(tag: tag, key: key)
        }
        host.beginSheet(sheetWindow) { [weak self] _ in
            AppStore.shared.clearAttention(key: key)
            if self?.sheet === confirm { self?.sheet = nil }
        }
    }

    /// The daemon says a request is over.
    private func handleResolved(_ resolved: RemoteShellResolved) {
        let known = request?.requestId == resolved.requestId ? request : nil
        if known != nil { request = nil }
        let outcome = store.resolve(resolved, target: known?.target)
        let onScreen = sheet?.requestId == resolved.requestId ? sheet : nil
        let host = onScreen?.window?.sheetParent
        let show = { [weak self] in
            DispatchQueue.main.async {
                self?.showOutcome(outcome, request: known, on: host)
            }
        }
        if let onScreen {
            sheet = nil
            onScreen.closeWithoutAnswering(completion: show)
        } else {
            show()
        }
    }

    private func showOutcome(_ outcome: RemoteShellResolution, request: RemoteShellConfirmRequest?, on host: NSWindow?) {
        switch outcome {
        case .closeSheet:
            break
        case .timedOut:
            guard let tag = request?.tag ?? request?.requestedBy.tag else { return }
            terminals.toasts.send(TerminalToast(tag: tag, message: "Remote shell request timed out; nothing connected",
                                                severity: .info, action: nil))
        case .failed(let failure):
            guard let host = host ?? Self.hostWindow() else { return }
            let sheet = RemoteShellFailureSheet(failure: failure)
            guard let sheetWindow = sheet.window else { return }
            failureSheet = sheet
            host.beginSheet(sheetWindow) { [weak self] _ in self?.failureSheet = nil }
        }
    }

    // MARK: - Windows

    /// The key window, else the main window, else the first one.
    static func hostWindow() -> NSWindow? {
        (NSApp.keyWindow as? NostromoWindow)
            ?? (NSApp.mainWindow as? NostromoWindow)
            ?? NSApp.windows.compactMap { $0 as? NostromoWindow }.first
    }

    private static func attentionKey(_ requestId: String) -> String { "remote-shell-\(requestId)" }
}

extension NSWindow {
    /// Size the window's content to what its Auto Layout constraints need at `width` (a sheet built
    /// from a fixed rect would otherwise clip text that wraps onto more lines).
    func fitContent(toWidth width: CGFloat) {
        guard let contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        setContentSize(NSSize(width: width, height: max(contentView.fittingSize.height, 1)))
    }
}
