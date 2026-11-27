// Nostromo iOS — NotificationService.swift
//
// The Notification Service Extension (W16). iOS runs it for every alert push that carries
// `mutable-content` (the primary sets that for a device registered with `capabilities.nse`), before
// the notification is shown, even after the app was force-quit.
//
// All it may do is ENRICH: when the operator allows it and the primary answers in time, the body
// becomes the first line of the item's question, PR title or decision prompt (a decision's body ends
// " · answer on your Mac"; there are no choice actions). It cannot hide or remove a notification (that
// needs Apple's filtering entitlement, which is not requested), so every other outcome delivers the
// contract content EXACTLY as the push carried it: no pairing, no token (before first unlock), the VPN
// down, a slow or hostile answer, a replacement, a work host. The fetch has a hard 4 s budget, well
// under iOS's ~30 s; `serviceExtensionTimeWillExpire` delivers the original too.
//
// The decision lives in `NostromoKit.NotificationEnricher`, which the Kit tests cover. This file
// is only the glue to UserNotifications. It never logs notification text and never sends a verb that
// answers anything (a source-policy test pins that).

import UserNotifications
import NostromoKit

final class NotificationService: UNNotificationServiceExtension {

    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let original = request.content
        lock.lock()
        self.contentHandler = contentHandler
        self.original = original
        lock.unlock()

        let contract = NotificationContent(title: original.title, subtitle: original.subtitle, body: original.body)
        let userInfo = original.userInfo
        let enricher = Self.makeEnricher()
        work = Task { [weak self] in
            let composed = await enricher.enrich(userInfo: userInfo, contract: contract)
            // Unchanged means unchanged: hand back the very content the push carried.
            guard composed != contract, let mutable = original.mutableCopy() as? UNMutableNotificationContent else {
                self?.deliver(original)
                return
            }
            mutable.subtitle = composed.subtitle
            mutable.body = composed.body
            self?.deliver(mutable)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        lock.lock()
        let original = self.original
        lock.unlock()
        if let original { deliver(original) }
    }

    /// Hands iOS the notification once; the first caller wins.
    private func deliver(_ content: UNNotificationContent) {
        lock.lock()
        let handler = contentHandler
        contentHandler = nil
        lock.unlock()
        handler?(content)
    }

    private static func makeEnricher() -> NotificationEnricher {
        let defaults = UserDefaults(suiteName: SharedPushState.defaultAppGroup) ?? .standard
        return NotificationEnricher(
            state: SharedPushState(defaults: defaults),
            // The token comes from the shared Keychain item; before the first unlock it is not
            // readable and the notification is delivered as it came.
            token: { KeychainDeviceCredentialStore().load()?.token })
    }
}
