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
    /// refuses both over TCP) and the Outlook opener.
    private static func detailActions(_ store: AppStore) -> FredDetailActions {
        FredDetailActions(
            requestDetail: { itemId, completion in
                let requestId = UUID().uuidString
                WorkStore.shared.expect(requestId: requestId) { response in
                    switch response {
                    case .detail(.ok(let detail)): completion(.success(detail))
                    case .detail(.err(let error)), .failed(let error): completion(.failure(error))
                    case .timedOut: completion(.failure(.timedOut))
                    default: completion(.failure(WorkError(code: "unexpected", message: "Unexpected daemon reply")))
                    }
                }
                store.client.send(.detailRequest(requestId: requestId, itemId: itemId))
            },
            seedFred: { text, completion in
                let requestId = UUID().uuidString
                WorkStore.shared.expect(requestId: requestId) { response in
                    switch response {
                    case .sendResult(.ok): completion(nil)
                    case .sendResult(.err(let error)), .failed(let error): completion(error)
                    case .timedOut: completion(.timedOut)
                    default: completion(WorkError(code: "unexpected", message: "Unexpected daemon reply"))
                    }
                }
                store.client.send(.fredSeed(requestId: requestId, text: text))
            },
            open: { NSWorkspace.shared.open($0) })
    }
}
