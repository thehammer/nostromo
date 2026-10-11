import AppKit
import Combine

/// The Fred lane's glue to the app: builds the native surface the daemon's
/// `fred_hud` pane maps to (see `DynamicFocusView.makeLeafView`), bound to the
/// daemon's retained `FredState` (already in `AppStore` after a relaunch or
/// daemon restart) and the connection state.
enum FredBindings {
    static func makeSurface(focus: Focus) -> NSView {
        let store = AppStore.shared
        let surface = FredSurfaceView(model: FredSurfaceModel(
            mailbox: store.fredMailbox,
            calendar: store.fredCalendar,
            isConnected: store.client.connected.value),
            detail: detailActions(store))
        // `@Published` publishes before the property changes, so combine the
        // emitted values rather than re-reading the store.
        Publishers.CombineLatest3(store.$fredMailbox,
                                  store.$fredCalendar,
                                  store.client.connected)
            .receive(on: DispatchQueue.main)
            .sink { [weak surface] mailbox, calendar, connected in
                surface?.model = FredSurfaceModel(mailbox: mailbox, calendar: calendar, isConnected: connected)
            }
            .store(in: &surface.subscriptions)
        return surface
    }

    /// Daemon-backed detail and seed requests (Unix socket only: the daemon
    /// refuses both over TCP) and the Outlook opener. The bridge re-checks every
    /// URL before `NSWorkspace` sees it.
    private static func detailActions(_ store: AppStore) -> FredDetailActions {
        FredDetailBridge.actions(
            workStore: .shared,
            send: { store.client.send($0) },
            open: { NSWorkspace.shared.open($0) })
    }
}
