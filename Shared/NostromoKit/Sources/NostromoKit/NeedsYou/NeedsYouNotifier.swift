// NostromoKit — NeedsYouNotifier.swift
//
// Turns the app-wide "needs you" snapshot into macOS (and, later, iOS) notifications:
// one per item id, removed when the item resolves, never posted twice while the item stays.
//
// This file is the ONLY place notification content is built (a policy test scans for
// it). Content is Mother-templated text only: a job's title and a fixed reason label.
// Never a question, a gate name, a repo, an excerpt or a finding. A notification has no
// actions and no category with actions, and is never time-sensitive.
//
// Delivery goes through `NotificationCenterLike`, so tests inject a fake and the real
// `UNUserNotificationCenter` is only ever touched by the app.

import Foundation
import UserNotifications

// MARK: - Center

public enum NeedsYouAuthorization: Equatable {
    case notDetermined
    case denied
    case authorized
}

/// The slice of `UNUserNotificationCenter` the notifier uses. Callbacks may arrive on any
/// thread from the real center, so its conformance hops to the main queue first.
public protocol NotificationCenterLike: AnyObject {
    func authorizationStatus(completion: @escaping (NeedsYouAuthorization) -> Void)
    /// `true` when the operator granted it.
    func requestAuthorization(completion: @escaping (Bool) -> Void)
    func add(request: UNNotificationRequest)
    func removeDelivered(ids: [String])
    func removePending(ids: [String])
}

extension UNUserNotificationCenter: NotificationCenterLike {
    public func authorizationStatus(completion: @escaping (NeedsYouAuthorization) -> Void) {
        getNotificationSettings { settings in
            let status: NeedsYouAuthorization
            switch settings.authorizationStatus {
            case .authorized, .provisional: status = .authorized
            case .denied: status = .denied
            default: status = .notDetermined
            }
            DispatchQueue.main.async { completion(status) }
        }
    }

    public func requestAuthorization(completion: @escaping (Bool) -> Void) {
        requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    public func add(request: UNNotificationRequest) {
        add(request, withCompletionHandler: nil)
    }

    public func removeDelivered(ids: [String]) {
        removeDeliveredNotifications(withIdentifiers: ids)
    }

    public func removePending(ids: [String]) {
        removePendingNotificationRequests(withIdentifiers: ids)
    }
}

// MARK: - Content

public struct NeedsYouNotificationContent: Equatable {
    public var title: String
    public var body: String
    public var threadIdentifier: String
    public var userInfo: [String: String]

    public init(title: String, body: String, threadIdentifier: String, userInfo: [String: String]) {
        self.title = title
        self.body = body
        self.threadIdentifier = threadIdentifier
        self.userInfo = userInfo
    }
}

/// One per producer. Returns nil for an item it does not describe.
public protocol NeedsYouContentBuilder {
    func content(for item: NeedsYouItem) -> NeedsYouNotificationContent?
}

public struct MotherNeedsYouContentBuilder: NeedsYouContentBuilder {
    public static let title = "Mother needs you"
    public static let threadIdentifier = "mother"
    public static let maxTitleLength = 60

    private let jobTitle: (String) -> String?

    /// `jobTitle` maps a job id to its title: an item carries no free text.
    public init(jobTitle: @escaping (String) -> String?) {
        self.jobTitle = jobTitle
    }

    public func content(for item: NeedsYouItem) -> NeedsYouNotificationContent? {
        guard case .motherJob(let jobId) = item.source,
              let label = Self.reasonLabel(item.reason) else { return nil }
        var body = label
        if !item.sensitive, let title = jobTitle(jobId).map(Self.tidy), !title.isEmpty {
            body = "\(title) · \(label)"
        }
        return NeedsYouNotificationContent(
            title: Self.title,
            body: body,
            threadIdentifier: Self.threadIdentifier,
            userInfo: ["needsYouId": item.id, "producer": MotherNeedsYouProducer.name, "jobId": jobId]
        )
    }

    public static func reasonLabel(_ reason: NeedsYouReason) -> String? {
        switch reason {
        case .motherHold(.gatesExhausted): return "Gates exhausted, choose how to proceed"
        case .motherHold(.reviewHold): return "Review hold"
        case .motherHold(.decision), .motherAwaiting: return "Waiting for your answer"
        case .motherAttention(let attention):
            switch attention {
            case .progressStalled: return "Stalled"
            case .burnAhead: return "Burning ahead of progress"
            case .gatesIncomplete: return "Gates incomplete"
            default: return "Needs attention"
            }
        default: return nil
        }
    }

    /// One line, at most `maxTitleLength` characters, ending in "…" when cut.
    private static func tidy(_ title: String) -> String {
        let oneLine = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard oneLine.count > maxTitleLength else { return oneLine }
        return String(oneLine.prefix(maxTitleLength - 1)) + "…"
    }
}

// MARK: - Notifier

/// Main thread only.
public final class NeedsYouNotifier {
    private let center: NotificationCenterLike
    private let builders: [String: NeedsYouContentBuilder]
    private var current = NeedsYouSnapshot.empty
    /// Ids posted and not yet resolved.
    private var posted = Set<String>()
    /// The first snapshot with anything notifiable is the baseline: those items were already
    /// waiting at launch (or when the operator granted permission), so they count as seen
    /// and never alert. Only items that arrive afterwards do. A delivered notification from a
    /// previous run is cleared when its item resolves, because the baseline sits in `posted`.
    /// Limit: an item that is the first one ever seen after launch is baselined too.
    private var baselined = false
    private let baselineExisting: Bool
    private var authorizationInFlight = false

    /// What the system says; nil until it has been read.
    public private(set) var authorization: NeedsYouAuthorization?

    /// Notifications are allowed. False while denied or not yet determined: the app must
    /// not claim the notify surface then.
    public var isSurfaceAvailable: Bool { authorization == .authorized }

    /// Called when `isSurfaceAvailable` changes.
    public var onSurfaceAvailabilityChange: ((Bool) -> Void)?

    /// `baselineExisting`: the app's setting (see `baselined`). Off, every new item alerts.
    public init(center: NotificationCenterLike, builders: [String: NeedsYouContentBuilder],
                baselineExisting: Bool = false) {
        self.center = center
        self.baselineExisting = baselineExisting
        self.builders = builders
    }

    /// Read the system's setting. Never prompts.
    public func refreshAuthorization() {
        center.authorizationStatus { [weak self] status in
            self?.setAuthorization(status)
        }
    }

    public func apply(_ snapshot: NeedsYouSnapshot) {
        current = snapshot
        reconcile()
    }

    // MARK: - Private

    private func reconcile() {
        let present = Set(current.items.map(\.id))
        let resolved = posted.subtracting(present)
        if !resolved.isEmpty {
            let ids = resolved.sorted()
            center.removeDelivered(ids: ids)
            center.removePending(ids: ids)
            posted.subtract(resolved)
        }

        if baselineExisting, !baselined {
            let notifiable = current.items.filter { builders[$0.producer] != nil }
            if !notifiable.isEmpty {
                posted.formUnion(notifiable.map(\.id))
                baselined = true
                return
            }
        }

        let waiting = current.items.filter { !posted.contains($0.id) && builders[$0.producer] != nil }
        guard !waiting.isEmpty else { return }

        switch authorization {
        case .authorized:
            for item in waiting { post(item) }
        case .denied:
            break
        case nil, .notDetermined:
            requestAuthorizationOnce()
        }
    }

    /// Lazily, on the first item that could be posted.
    private func requestAuthorizationOnce() {
        guard !authorizationInFlight else { return }
        authorizationInFlight = true
        center.authorizationStatus { [weak self] status in
            guard let self else { return }
            guard status == .notDetermined else {
                self.authorizationInFlight = false
                self.setAuthorization(status)
                return
            }
            self.center.requestAuthorization { [weak self] granted in
                guard let self else { return }
                self.authorizationInFlight = false
                self.setAuthorization(granted ? .authorized : .denied)
            }
        }
    }

    private func setAuthorization(_ status: NeedsYouAuthorization) {
        let wasAvailable = isSurfaceAvailable
        authorization = status
        if isSurfaceAvailable != wasAvailable { onSurfaceAvailabilityChange?(isSurfaceAvailable) }
        if status == .authorized { reconcile() }
    }

    private func post(_ item: NeedsYouItem) {
        guard let built = builders[item.producer]?.content(for: item) else { return }
        let content = UNMutableNotificationContent()
        content.title = built.title
        content.body = built.body
        content.threadIdentifier = built.threadIdentifier
        content.userInfo = built.userInfo
        posted.insert(item.id)
        center.add(request: UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
    }
}
