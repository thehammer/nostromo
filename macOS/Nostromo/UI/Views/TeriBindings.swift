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
        surface.translatesAutoresizingMaskIntoConstraints = false
        return surface
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
