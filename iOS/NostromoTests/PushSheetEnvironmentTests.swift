// L5: a sheet's environment comes from the app's real view tree: SwiftUI hands a `.sheet` only the
// environment objects injected on the view that presents it, so a sheet that needs one the app never
// gave it traps (fatal "No ObservableObject of type ... found") the first time it is shown, which a
// pure Kit test cannot see. This presents the real `PushGate`'s tap sheet in a real window; a
// missing injection crashes the hosted run, which fails the test.

import XCTest
import SwiftUI
import Combine
import NostromoKit
@testable import Nostromo

@MainActor
private final class StillTransport: DaemonTransport {
    let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    let frames = PassthroughSubject<HostedServerMsg, Never>()
    var connected: Bool { connectedSubject.value }
    var connectedPublisher: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var framePublisher: AnyPublisher<HostedServerMsg, Never> { frames.eraseToAnyPublisher() }
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        Just(ConnectionState.connecting).eraseToAnyPublisher()
    }
    func start() {}
    func stop() {}
    func send(_ msg: some Encodable) {}
}

@MainActor
final class PushSheetEnvironmentTests: XCTestCase {

    private func spin(seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    func testTappingANotificationPresentsTheItemSheetWithoutTrapping() async throws {
        let transport = StillTransport()
        let push = PushModel(transport: transport)
        let store = DaemonStore(client: transport)

        let host = UIHostingController(rootView: PushGate(push: push, store: store) { Text("app content") })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        await spin(seconds: 0.2)

        push.tapped = PushPayload(item: "it-1", kind: .review, host: "sendai", ref: "PR #4821")

        // Presenting the sheet evaluates `PushItemView`, which reads `DaemonStore` and `PushModel`
        // from its environment: without the store injected on the sheet this process traps here.
        for _ in 0..<60 where host.presentedViewController == nil { await spin(seconds: 0.05) }
        XCTAssertNotNil(host.presentedViewController, "the tapped notification opens its screen")
        await spin(seconds: 0.5)
        XCTAssertNotNil(host.presentedViewController, "and it stays up")

        push.tapped = nil
        window.isHidden = true
    }
}
