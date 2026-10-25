// NostromoKit — FredWireTests.swift
//
// Wire JSON assertions for Fred mailbox + calendar types.
// Verifies MailboxSnapshot / CalendarSnapshot decoding and
// ServerMsg.fredState round-trip match the Rust daemon's protocol format.

import XCTest
@testable import NostromoKit

final class FredWireTests: XCTestCase {

    // MARK: - Helpers

    private func decode(_ json: String) throws -> Data {
        try XCTUnwrap(json.data(using: .utf8))
    }

    private var nostromo: JSONDecoder { .nostromo }

    // MARK: - fred_state: populated mailbox + calendar

    func testFredStateDecodesPopulatedMailboxAndCalendar() throws {
        let json = """
        {
            "type": "fred_state",
            "mailbox": {
                "generated_at": "2026-06-08T09:00:00Z",
                "unread_count": 2,
                "items": [
                    {
                        "from": "Alice <alice@example.com>",
                        "subject": "Invitation: Weekly sync",
                        "received_at": "2026-06-08T08:55:00Z",
                        "vip": true,
                        "is_invite": true,
                        "is_read": false
                    },
                    {
                        "from": "Bob <bob@example.com>",
                        "subject": "Re: Project update",
                        "received_at": "2026-06-08T07:30:00Z",
                        "vip": false,
                        "is_invite": false,
                        "is_read": true
                    }
                ],
                "stale": false,
                "error": null
            },
            "calendar": {
                "events": [
                    {
                        "start": "2026-06-08T09:30:00Z",
                        "end": "2026-06-08T10:00:00Z",
                        "title": "Daily standup",
                        "status": "accepted",
                        "is_now": true
                    },
                    {
                        "start": "2026-06-08T08:00:00Z",
                        "end": "2026-06-08T09:00:00Z",
                        "title": "Past event",
                        "status": "accepted",
                        "is_now": false
                    }
                ],
                "next": {
                    "title": "Lunch",
                    "in_minutes": 45
                },
                "sweater": "amber",
                "stale": false
            }
        }
        """.data(using: .utf8)!

        let msg = ServerMsg.decode(from: json)
        guard case .fredState(let mailbox, let calendar) = msg else {
            XCTFail("Expected .fredState, got \(msg)")
            return
        }

        // Mailbox assertions
        XCTAssertEqual(mailbox.unreadCount, 2)
        XCTAssertEqual(mailbox.items.count, 2)
        XCTAssertNotNil(mailbox.generatedAt)
        XCTAssertFalse(mailbox.stale)
        XCTAssertNil(mailbox.error)
        XCTAssertNil(mailbox.authPrompt)

        let firstItem = mailbox.items[0]
        XCTAssertEqual(firstItem.from, "Alice <alice@example.com>")
        XCTAssertEqual(firstItem.subject, "Invitation: Weekly sync")
        XCTAssertNotNil(firstItem.receivedAt, "received_at should parse to a Date")
        XCTAssertTrue(firstItem.vip)
        XCTAssertTrue(firstItem.isInvite)
        XCTAssertFalse(firstItem.isRead)

        let secondItem = mailbox.items[1]
        XCTAssertFalse(secondItem.vip)
        XCTAssertFalse(secondItem.isInvite)
        XCTAssertTrue(secondItem.isRead)

        // Calendar assertions
        XCTAssertEqual(calendar.events.count, 2)
        XCTAssertEqual(calendar.sweater, "amber")
        XCTAssertFalse(calendar.stale)
        XCTAssertNil(calendar.error)

        let standupEvent = calendar.events[0]
        XCTAssertEqual(standupEvent.title, "Daily standup")
        XCTAssertEqual(standupEvent.status, "accepted")
        XCTAssertTrue(standupEvent.isNow)
        XCTAssertNotNil(standupEvent.start, "start should parse to a Date")
        XCTAssertNotNil(standupEvent.end,   "end should parse to a Date")

        let next = try XCTUnwrap(calendar.next)
        XCTAssertEqual(next.title, "Lunch")
        XCTAssertEqual(next.inMinutes, 45)
    }

    // MARK: - fred_state: auth_prompt present

    func testFredStateDecodesAuthPrompt() throws {
        let json = """
        {
            "type": "fred_state",
            "mailbox": {
                "unread_count": 0,
                "items": [],
                "stale": false,
                "auth_prompt": {
                    "verification_uri": "https://microsoft.com/devicelogin",
                    "user_code": "ABCD-1234",
                    "expires_at": "2026-06-08T09:30:00Z"
                }
            },
            "calendar": {
                "events": [],
                "sweater": "sage",
                "stale": false
            }
        }
        """.data(using: .utf8)!

        let msg = ServerMsg.decode(from: json)
        guard case .fredState(let mailbox, _) = msg else {
            XCTFail("Expected .fredState, got \(msg)")
            return
        }

        let prompt = try XCTUnwrap(mailbox.authPrompt, "auth_prompt should decode to non-nil")
        XCTAssertEqual(prompt.verificationUri, "https://microsoft.com/devicelogin")
        XCTAssertEqual(prompt.userCode, "ABCD-1234")
        XCTAssertNotNil(prompt.expiresAt)
    }

    // MARK: - fred_state: absent optional fields default cleanly

    func testFredStateDecodesWithAbsentOptionals() throws {
        let json = """
        {
            "type": "fred_state",
            "mailbox": {
                "unread_count": 0,
                "items": [],
                "stale": false
            },
            "calendar": {
                "events": [],
                "sweater": "sage",
                "stale": false
            }
        }
        """.data(using: .utf8)!

        let msg = ServerMsg.decode(from: json)
        guard case .fredState(let mailbox, let calendar) = msg else {
            XCTFail("Expected .fredState, got \(msg)")
            return
        }

        XCTAssertNil(mailbox.authPrompt)
        XCTAssertNil(mailbox.error)
        XCTAssertNil(mailbox.generatedAt)
        XCTAssertNil(calendar.next)
        XCTAssertNil(calendar.error)
    }

    // MARK: - Fractional-seconds date parsing

    func testMailboxItemReceivesAtWithFractionalSeconds() throws {
        let json = """
        {
            "type": "fred_state",
            "mailbox": {
                "unread_count": 1,
                "items": [
                    {
                        "from": "Carol <carol@example.com>",
                        "subject": "Fractional test",
                        "received_at": "2026-06-08T09:30:56.510874Z",
                        "vip": false,
                        "is_invite": false,
                        "is_read": false
                    }
                ],
                "stale": false
            },
            "calendar": {
                "events": [],
                "sweater": "sage",
                "stale": false
            }
        }
        """.data(using: .utf8)!

        let msg = ServerMsg.decode(from: json)
        guard case .fredState(let mailbox, _) = msg else {
            XCTFail("Expected .fredState, got \(msg)")
            return
        }
        XCTAssertNotNil(mailbox.items.first?.receivedAt,
                        "received_at with fractional seconds should parse to a Date")
    }

    // MARK: - auth_prompt: kind, account and provider

    private func decodePrompt(_ json: String) throws -> DeviceFlowPrompt {
        try nostromo.decode(DeviceFlowPrompt.self, from: decode(json))
    }

    private func encodedKeys(_ prompt: DeviceFlowPrompt) throws -> Set<String> {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: encoder.encode(prompt))
        return Set(try XCTUnwrap(object as? [String: Any]).keys)
    }

    func testAPromptFromAnOlderDaemonDecodesAsADeviceCodePrompt() throws {
        let prompt = try decodePrompt("""
        {
            "verification_uri": "https://microsoft.com/devicelogin",
            "user_code": "ABCD-1234",
            "expires_at": "2026-06-08T09:30:00Z"
        }
        """)
        XCTAssertEqual(prompt.kind, "device_code")
        XCTAssertNil(prompt.account)
        XCTAssertNil(prompt.provider)
        XCTAssertFalse(prompt.isBrowserSignIn)
        XCTAssertEqual(prompt.userCode, "ABCD-1234")
    }

    func testABrowserPromptDecodesItsKindAccountAndProvider() throws {
        let uri = "https://accounts.google.com/o/oauth2/v2/auth?client_id=abc&state=xyz"
        let prompt = try decodePrompt("""
        {
            "kind": "browser",
            "account": "personal",
            "provider": "google",
            "verification_uri": "\(uri)",
            "user_code": "",
            "expires_at": "2026-06-08T09:30:00Z"
        }
        """)
        XCTAssertEqual(prompt.kind, "browser")
        XCTAssertEqual(prompt.account, "personal")
        XCTAssertEqual(prompt.provider, "google")
        XCTAssertTrue(prompt.isBrowserSignIn)
        XCTAssertEqual(prompt.verificationUri, uri)
        XCTAssertEqual(prompt.userCode, "")
    }

    func testADeviceCodePromptFromACurrentDaemonIsNotABrowserSignIn() throws {
        let prompt = try decodePrompt("""
        {
            "kind": "device_code",
            "provider": "microsoft",
            "verification_uri": "https://microsoft.com/devicelogin",
            "user_code": "ABCD-1234",
            "expires_at": "2026-06-08T09:30:00Z"
        }
        """)
        XCTAssertEqual(prompt.kind, "device_code")
        XCTAssertEqual(prompt.provider, "microsoft")
        XCTAssertNil(prompt.account)
        XCTAssertFalse(prompt.isBrowserSignIn)
    }

    func testABrowserPromptRidesInsideAFredStateFrame() throws {
        let json = """
        {
            "type": "fred_state",
            "mailbox": {
                "unread_count": 0, "items": [], "stale": false,
                "auth_prompt": {
                    "kind": "browser", "account": "personal", "provider": "google",
                    "verification_uri": "https://accounts.google.com/o/oauth2/v2/auth?x=1",
                    "user_code": "", "expires_at": "2026-06-08T09:30:00Z"
                }
            },
            "calendar": {
                "events": [], "sweater": "sage", "stale": false,
                "auth_prompt": {
                    "kind": "browser", "account": "work", "provider": "google",
                    "verification_uri": "https://accounts.google.com/o/oauth2/v2/auth?x=2",
                    "user_code": "", "expires_at": "2026-06-08T09:30:00Z"
                }
            }
        }
        """.data(using: .utf8)!
        // NostromoKit's CalendarSnapshot does not decode `auth_prompt` (iOS shows the mailbox's);
        // the calendar's prompt must still not break the frame.
        guard case .fredState(let mailbox, _) = ServerMsg.decode(from: json) else {
            return XCTFail("expected .fredState")
        }
        XCTAssertEqual(mailbox.authPrompt?.account, "personal")
        XCTAssertEqual(mailbox.authPrompt?.isBrowserSignIn, true)
    }

    func testAPromptRoundTripsThroughEncodeAndDecodeWithItsOptionalFields() throws {
        let expires = Date(timeIntervalSince1970: 1_780_000_000)
        let original = DeviceFlowPrompt(verificationUri: "https://accounts.google.com/o/oauth2/v2/auth?x=1",
                                        userCode: "", expiresAt: expires,
                                        kind: "browser", account: "personal", provider: "google")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let back = try nostromo.decode(DeviceFlowPrompt.self, from: encoder.encode(original))
        XCTAssertEqual(back, original)
        XCTAssertEqual(back.kind, "browser")
        XCTAssertEqual(back.account, "personal")
        XCTAssertEqual(back.provider, "google")
    }

    func testAPromptRoundTripsThroughEncodeAndDecodeWithoutItsOptionalFields() throws {
        let original = DeviceFlowPrompt(verificationUri: "https://microsoft.com/devicelogin",
                                        userCode: "ABCD-1234",
                                        expiresAt: Date(timeIntervalSince1970: 1_780_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let back = try nostromo.decode(DeviceFlowPrompt.self, from: encoder.encode(original))
        XCTAssertEqual(back, original)
        XCTAssertEqual(back.kind, "device_code", "the default kind for a prompt built the old way")
        XCTAssertNil(back.account)
        XCTAssertNil(back.provider)
    }

    func testEncodingAPromptWithoutAccountOrProviderOmitsThoseKeys() throws {
        let prompt = DeviceFlowPrompt(verificationUri: "https://microsoft.com/devicelogin",
                                      userCode: "ABCD-1234",
                                      expiresAt: Date(timeIntervalSince1970: 1_780_000_000))
        let keys = try encodedKeys(prompt)
        XCTAssertFalse(keys.contains("account"))
        XCTAssertFalse(keys.contains("provider"))
        XCTAssertTrue(keys.isSuperset(of: ["verification_uri", "user_code", "expires_at"]))
    }

    func testEncodingAPromptWithAccountAndProviderIncludesThemUnderTheWireNames() throws {
        let prompt = DeviceFlowPrompt(verificationUri: "https://accounts.google.com/o/oauth2/v2/auth?x=1",
                                      userCode: "",
                                      expiresAt: Date(timeIntervalSince1970: 1_780_000_000),
                                      kind: "browser", account: "personal", provider: "google")
        let keys = try encodedKeys(prompt)
        XCTAssertTrue(keys.isSuperset(of: ["kind", "account", "provider"]))
    }

    func testThePromptInitStaysSourceCompatibleWithTheThreeArgumentForm() {
        let prompt = DeviceFlowPrompt(verificationUri: "u", userCode: "c", expiresAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(prompt.kind, "device_code")
        XCTAssertFalse(prompt.isBrowserSignIn)
    }
}

final class WithheldWireTests: XCTestCase {
    func testWithheldDecodes() throws {
        let json = #"{"type":"withheld","topics":["fred","teri","work"],"reason":"requires_secure_connection"}"#.data(using: .utf8)!
        guard case .withheld(let topics, let reason) = ServerMsg.decode(from: json) else { return XCTFail("not withheld") }
        XCTAssertEqual(topics, ["fred", "teri", "work"])
        XCTAssertEqual(reason, "requires_secure_connection")
    }

    /// A future daemon may add fields to the frame; the client must keep decoding it.
    func testWithheldWithExtraFieldsStillDecodes() throws {
        let json = #"{"type":"withheld","topics":["teri"],"reason":"requires_secure_connection","future":{"a":1}}"#.data(using: .utf8)!
        guard case .withheld(let topics, _) = ServerMsg.decode(from: json) else { return XCTFail("not withheld") }
        XCTAssertEqual(topics, ["teri"])
    }

    func testAnUnrecognisedTypeStillDecodesToUnknown() throws {
        let json = #"{"type":"definitely_not_a_frame","x":1}"#.data(using: .utf8)!
        guard case .unknown = ServerMsg.decode(from: json) else { return XCTFail("expected .unknown") }
    }
}
