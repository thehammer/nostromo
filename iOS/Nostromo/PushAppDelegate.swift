// Nostromo iOS — PushAppDelegate.swift
//
// Push notifications on the phone (W13). iOS needs an app delegate to hand over the Apple push token,
// and a notification-center delegate to route a tap, so this is the one place the app touches them:
//
//   - the operator enables notifications on the settings screen (`requestAuthorization`), which registers for remote notifications;
//   - the token (hex) goes to `PushModel`, which sends `register_push` whenever the link is up;
//   - on every foreground connect the model reconciles: delivered notifications whose item no longer
//     waits are removed (the replace-in-place withdrawal of S1 covers the rest while the app is closed)
//     and the badge is set to the waiting count;
//   - tapping a notification records which one, and the root view opens a read-only screen for it.
//
// No code here answers anything: a decision notification's only action is Open (S7).

import UIKit
import UserNotifications
import Combine
import NostromoKit

/// Holds the model the delegate reports to. `AppSession` sets `model` when the phone is paired and
/// clears it when it is not.
@MainActor
final class PushCoordinator {
    static let shared = PushCoordinator()

    weak var model: PushModel? {
        didSet { attach() }
    }
    /// The token iOS issued, kept so a model created later still gets it.
    private(set) var token: String?
    private var bag = Set<AnyCancellable>()

    /// Read from the signing (the embedded profile's `aps-environment`), not from the build
    /// configuration, so a Release build signed with a development profile still reaches the sandbox.
    var environment: PushEnvironmentWire {
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        return .signed(provisioning: profile, simulator: simulator)
    }

    func didRegister(deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        model?.apnsToken = token
    }

    /// Ask for permission (alert, badge, sound), then register for remote notifications. Time-sensitive
    /// delivery needs no request option: the entitlement is what allows it. Called from the settings screen when the operator turns notifications on.
    func enable() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        return granted
    }

    /// Whether iOS lets Nostromo notify, for the settings screen.
    func authorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// At launch, if the operator already allowed notifications, ask iOS for a (possibly new) token.
    func registerIfAuthorized() async {
        let status = await authorization()
        if status == .authorized || status == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// This phone is no longer paired (revoked, un-paired, or the transport changed): drop what the
    /// pairing put on the phone. Delivered notifications and the badge go, iOS is told to stop pushing
    /// to this install, and the token is forgotten. (The primary deletes the device's push record when
    /// it is revoked or unpaired, so it sends nothing more.)
    func reset() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        Task { try? await center.setBadgeCount(0) }
        UIApplication.shared.unregisterForRemoteNotifications()
        token = nil
        model = nil
    }

    private func attach() {
        bag.removeAll()
        guard let model else { return }
        model.environment = environment
        model.apnsToken = token
        // A fresh pairing after a reset has no token yet: ask iOS for one again.
        if token == nil { Task { await registerIfAuthorized() } }
        // Every answer to `push_waiting`: remove what no longer waits, and set the badge.
        model.$waiting
            .combineLatest(model.$badge)
            .dropFirst()
            .sink { [weak self] waiting, badge in
                Task { await self?.reconcile(waiting: waiting, badge: badge) }
            }
            .store(in: &bag)
    }

    private func reconcile(waiting: [PushWaitingItemWire], badge: Int) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let payloads: [(identifier: String, payload: PushPayload)] = delivered.compactMap { note in
            guard let payload = PushPayload.parse(userInfo: note.request.content.userInfo) else { return nil }
            return (note.request.identifier, payload)
        }
        let staleItems = Set(PushModel.staleItems(delivered: payloads.map(\.payload), waiting: waiting))
        let identifiers = payloads.filter { staleItems.contains($0.payload.item) }.map(\.identifier)
        if !identifiers.isEmpty { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
        try? await center.setBadgeCount(badge)
    }
}

final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in await PushCoordinator.shared.registerIfAuthorized() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushCoordinator.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No token means no push; the settings screen keeps saying so. Nothing else to do.
    }

    /// A notification arriving while the app is open is shown as a banner like any other.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    /// A tap opens the screen for that item.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let payload = PushPayload.parse(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { PushCoordinator.shared.model?.tapped = payload }
    }
}
