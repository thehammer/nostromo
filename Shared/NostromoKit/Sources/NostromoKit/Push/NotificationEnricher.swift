// NostromoKit — NotificationEnricher.swift
//
// The Notification Service Extension's whole decision, with the extension host taken out (W16): given
// the push's `userInfo` and the visible contract content, return what to show. Every path that is
// not a successful, permitted fetch returns the contract content **unchanged**:
//
//   - not one of ours, a replacement (`resolved`), a Summary, a work or unknown host, a host the
//     operator switched details off for;
//   - no pairing address or no token (never paired, or before first unlock);
//   - the primary unreachable (VPN down), slow (past the budget), or answering with anything but a
//     `push_detail` for this item; `waiting: false` or a withheld text.
//
// It never throws, never returns placeholder or error text, and never logs the text.

import Foundation

public struct NotificationEnricher: Sendable {
    public typealias TransportFactory = @Sendable (_ address: SharedPushState.Address, _ token: String) -> PushDetailTransport

    private let state: SharedPushState
    private let token: @Sendable () -> String?
    private let transport: TransportFactory
    private let clock: DeadlineClock

    /// `token` reads the device token from the shared Keychain item, on demand.
    public init(state: SharedPushState,
                token: @escaping @Sendable () -> String?,
                transport: @escaping TransportFactory = { WebSocketPushDetailTransport(host: $0.host, port: $0.port, token: $1) },
                clock: DeadlineClock = SystemDeadlineClock()) {
        self.state = state
        self.token = token
        self.transport = transport
        self.clock = clock
    }

    public func enrich(userInfo: [AnyHashable: Any], contract: NotificationContent) async -> NotificationContent {
        guard let payload = PushPayload.parse(userInfo: userInfo),
              EnrichmentPolicy.shouldEnrich(payload: payload, hostClasses: state.hostClasses,
                                            prefs: state.enrichment),
              let address = state.address,
              let token = token(), !token.isEmpty
        else { return contract }
        let fetcher = PushDetailFetcher(transport: transport(address, token), clock: clock)
        let detail = await fetcher.fetch(itemRef: payload.item)
        return NotificationContentComposer.compose(contract: contract, payload: payload, detail: detail)
    }
}
