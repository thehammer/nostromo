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
}
