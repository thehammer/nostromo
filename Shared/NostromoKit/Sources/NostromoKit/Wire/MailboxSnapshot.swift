// NostromoKit — MailboxSnapshot.swift
//
// Wire types for Fred's mailbox state broadcast.
// Mirrors the Rust structs in `src/data/fred_mailbox.rs` and
// `src/data/graph_client.rs`, using snake_case CodingKeys to match
// the daemon's serde output.

import Foundation

// MARK: - DeviceFlowPrompt

/// Rendered when a Fred source needs sign-in: Microsoft device flow
/// (`kind == "device_code"`: URL + code) or Google loopback (`kind == "browser"`:
/// the URL only works on the daemon's Mac, and there is no code).
/// Mirrors `DeviceFlowPrompt` in `src/data/graph_client.rs`.
public struct DeviceFlowPrompt: Codable, Equatable {
    public let verificationUri: String
    public let userCode:        String
    public let expiresAt:       Date
    /// "device_code" or "browser". Older daemons omit it: decoded as "device_code".
    public let kind:            String
    /// The configured account label, in multi-account mode.
    public let account:         String?
    /// "microsoft" or "google", when the daemon says.
    public let provider:        String?

    public var isBrowserSignIn: Bool { kind == "browser" }

    enum CodingKeys: String, CodingKey {
        case verificationUri = "verification_uri"
        case userCode        = "user_code"
        case expiresAt       = "expires_at"
        case kind
        case account
        case provider
    }

    public init(verificationUri: String, userCode: String, expiresAt: Date,
                kind: String = "device_code", account: String? = nil, provider: String? = nil) {
        self.verificationUri = verificationUri
        self.userCode        = userCode
        self.expiresAt       = expiresAt
        self.kind            = kind
        self.account         = account
        self.provider        = provider
    }

    public init(from decoder: Decoder) throws {
        let c           = try decoder.container(keyedBy: CodingKeys.self)
        verificationUri = try c.decode(String.self, forKey: .verificationUri)
        userCode        = try c.decode(String.self, forKey: .userCode)
        expiresAt       = try c.decode(Date.self,   forKey: .expiresAt)
        kind            = try c.decodeIfPresent(String.self, forKey: .kind) ?? "device_code"
        account         = try c.decodeIfPresent(String.self, forKey: .account)
        provider        = try c.decodeIfPresent(String.self, forKey: .provider)
    }
}

// MARK: - MailboxItem

/// A single email in the inbox snapshot.
/// Mirrors `MailboxItem` in `src/data/fred_mailbox.rs`.
public struct MailboxItem: Codable, Equatable, Identifiable {
    public let from:       String
    public let subject:    String
    public let receivedAt: Date?
    public let vip:        Bool
    public let isInvite:   Bool
    public let isRead:     Bool

    /// Stable derived identifier (no server-side id field).
    public var id: String {
        "\(from)|\(subject)|\(receivedAt?.timeIntervalSince1970 ?? 0)"
    }

    enum CodingKeys: String, CodingKey {
        case from
        case subject
        case receivedAt = "received_at"
        case vip
        case isInvite   = "is_invite"
        case isRead     = "is_read"
    }

    public init(from: String, subject: String, receivedAt: Date?,
                vip: Bool, isInvite: Bool, isRead: Bool) {
        self.from       = from
        self.subject    = subject
        self.receivedAt = receivedAt
        self.vip        = vip
        self.isInvite   = isInvite
        self.isRead     = isRead
    }
}

// MARK: - MailboxSnapshot

/// Full snapshot of the Fred mailbox, including auth-prompt when sign-in is needed.
/// Mirrors `MailboxSnapshot` in `src/data/fred_mailbox.rs`.
public struct MailboxSnapshot: Codable, Equatable {
    public let generatedAt:  Date?
    public let unreadCount:  Int
    public let items:        [MailboxItem]
    public let stale:        Bool
    public let error:        String?
    /// Present when Graph auth is required; `nil` when authenticated.
    public let authPrompt:   DeviceFlowPrompt?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case unreadCount = "unread_count"
        case items
        case stale
        case error
        case authPrompt  = "auth_prompt"
    }

    /// Custom decoder: mirrors the Rust `#[serde(default)]` annotations so that
    /// missing optional fields and missing collection fields all decode cleanly.
    public init(from decoder: Decoder) throws {
        let c       = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decodeIfPresent(Date.self,              forKey: .generatedAt)
        unreadCount = try c.decodeIfPresent(Int.self,               forKey: .unreadCount) ?? 0
        items       = try c.decodeIfPresent([MailboxItem].self,     forKey: .items)       ?? []
        stale       = try c.decodeIfPresent(Bool.self,              forKey: .stale)       ?? false
        error       = try c.decodeIfPresent(String.self,            forKey: .error)
        authPrompt  = try c.decodeIfPresent(DeviceFlowPrompt.self,  forKey: .authPrompt)
    }

    public init(generatedAt: Date?, unreadCount: Int, items: [MailboxItem],
                stale: Bool, error: String?, authPrompt: DeviceFlowPrompt?) {
        self.generatedAt = generatedAt
        self.unreadCount = unreadCount
        self.items       = items
        self.stale       = stale
        self.error       = error
        self.authPrompt  = authPrompt
    }
}
