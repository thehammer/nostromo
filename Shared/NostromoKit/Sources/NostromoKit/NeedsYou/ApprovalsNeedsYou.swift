// NostromoKit — ApprovalsNeedsYou.swift
//
// Permission approvals as a producer into the app-wide "needs you" source (`NeedsYou.swift`).
// One item per pending request, so the aggregator's per-focus counts and total are the
// pending counts the sidebar pill and the Dock badge show, and the notifier posts one
// notification per request id.
//
// Notification text is built here and nowhere else for approvals: the agent, the tool's
// display name and, for Bash, only the FIRST WORD of the first command (never a path, a
// second word, the reason or the input). It carries no action.

import Foundation

public enum ApprovalsNeedsYouProducer {
    public static let name = "approvals"

    /// The id of the item for a request: the id the notification carries.
    public static func itemId(requestId: String) -> String { "\(name):\(requestId)" }

    /// One item per request that is still waiting. Oldest first once aggregated (`since`).
    public static func items(pending: [ApprovalRequestWire]) -> [NeedsYouItem] {
        pending.map { request in
            NeedsYouItem(
                id: itemId(requestId: request.requestId),
                source: .focus(request.tag),
                reason: .approvalPending(1),
                since: Date(timeIntervalSince1970: TimeInterval(request.createdAtMs) / 1000))
        }
    }
}

public struct ApprovalsNeedsYouContentBuilder: NeedsYouContentBuilder {
    public static let maxWordLength = 40

    private let request: (String) -> ApprovalRequestWire?

    /// `request` maps a request id to the request (an item carries no free text).
    public init(request: @escaping (String) -> ApprovalRequestWire?) {
        self.request = request
    }

    public func content(for item: NeedsYouItem) -> NeedsYouNotificationContent? {
        guard case .focus(let tag) = item.source, case .approvalPending = item.reason else { return nil }
        let prefix = ApprovalsNeedsYouProducer.name + ":"
        guard item.id.hasPrefix(prefix),
              let wire = request(String(item.id.dropFirst(prefix.count))) else { return nil }
        return NeedsYouNotificationContent(
            title: Self.title(for: wire),
            body: Self.body(for: wire),
            threadIdentifier: tag,
            userInfo: ["needsYouId": item.id, "producer": ApprovalsNeedsYouProducer.name,
                       "tag": tag, "requestId": wire.requestId])
    }

    /// `Cody needs approval`.
    public static func title(for request: ApprovalRequestWire) -> String {
        "\(ApprovalKinds.capitalized(request.agent.name)) needs approval"
    }

    /// `Bash · rm`; the tool's display name alone for any other tool.
    public static func body(for request: ApprovalRequestWire) -> String {
        guard request.toolKind == .bash, let word = firstWord(of: request) else { return request.displayName }
        return "\(request.displayName) · \(word)"
    }

    /// The first word of the first command, as displayed. A path-shaped word is cut to its last
    /// component, so a path never reaches a lock screen.
    static func firstWord(of request: ApprovalRequestWire) -> String? {
        let first = ApprovalDisplayModel(request: request).summary
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        guard var word = first else { return nil }
        if word.contains("/") { word = word.split(separator: "/").last.map(String.init) ?? "" }
        guard !word.isEmpty else { return nil }
        return word.count > maxWordLength ? String(word.prefix(maxWordLength - 1)) + "…" : word
    }
}
