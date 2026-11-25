// NostromoKit — PairingCopyTests.swift
//
// Every sentence the pairing flow and the connection banners show, pinned verbatim to
// `docs/prds/daemon-pairing-flow.md` ("Failure copy", the D1/D6 sign-offs and AC38/39/48/49, and the
// "Final v1 copy" table). The PRD examples use 10.0.0.5, 10.0.0.9, iPhone and iPad; each function is
// also called with different values to prove the real address and kind are what get interpolated.

import XCTest
@testable import NostromoKit

final class PairingCopyTests: XCTestCase {

    // MARK: - Failures (PRD "Failure copy")

    func testExpired() {
        XCTAssertEqual(PairingCopy.expired(),
                       "That code has expired. Codes last five minutes. Make a new one on your Mac and enter it here.")
    }

    func testInvalid() {
        XCTAssertEqual(PairingCopy.invalid(), "That code isn't right. Check the six digits and try again.")
    }

    func testUnreachableNamesTheRealAddress() {
        XCTAssertEqual(PairingCopy.unreachable(address: "10.0.0.5"),
                       "Can't reach Nostromo at 10.0.0.5. If you're away from home, turn on your VPN and try again.")
        XCTAssertEqual(PairingCopy.unreachable(address: "studio.local"),
                       "Can't reach Nostromo at studio.local. If you're away from home, turn on your VPN and try again.")
    }

    func testLocalNetworkDeniedNamesTheRealAddress() {
        XCTAssertEqual(PairingCopy.localNetworkDenied(address: "10.0.0.5"),
                       "Nostromo can't use your local network, so it can't reach 10.0.0.5 on this Wi-Fi. "
                       + "Turn on Local Network for Nostromo in Settings, or use your VPN.")
        XCTAssertEqual(PairingCopy.localNetworkDenied(address: "192.168.1.20"),
                       "Nostromo can't use your local network, so it can't reach 192.168.1.20 on this Wi-Fi. "
                       + "Turn on Local Network for Nostromo in Settings, or use your VPN.")
    }

    func testNoLongerPairedNamesTheRealKind() {
        XCTAssertEqual(PairingCopy.noLongerPaired(kind: "iPhone"),
                       "This iPhone is no longer paired with Nostromo. Pair it again to reconnect.")
        XCTAssertEqual(PairingCopy.noLongerPaired(kind: "iPad"),
                       "This iPad is no longer paired with Nostromo. Pair it again to reconnect.")
    }

    // MARK: - Banners over last-known content

    func testTheUnreachableBannerNamesTheRealAddress() {
        XCTAssertEqual(PairingCopy.unreachableBanner(address: "10.0.0.5"),
                       "Can't reach Nostromo at 10.0.0.5. If you're away from home, turn on your VPN.")
        XCTAssertEqual(PairingCopy.unreachableBanner(address: "studio.local"),
                       "Can't reach Nostromo at studio.local. If you're away from home, turn on your VPN.")
    }

    func testTheLocalNetworkBannerNamesTheRealAddress() {
        XCTAssertEqual(PairingCopy.localNetworkBanner(address: "10.0.0.5"),
                       "Nostromo can't use your local network to reach 10.0.0.5. Turn it on in Settings or use your VPN.")
        XCTAssertEqual(PairingCopy.localNetworkBanner(address: "192.168.1.20"),
                       "Nostromo can't use your local network to reach 192.168.1.20. Turn it on in Settings or use your VPN.")
    }

    func testTheBannersAreNotTheSentencesTheFailuresUse() {
        XCTAssertNotEqual(PairingCopy.unreachableBanner(address: "10.0.0.5"), PairingCopy.unreachable(address: "10.0.0.5"))
        XCTAssertNotEqual(PairingCopy.localNetworkBanner(address: "10.0.0.5"),
                          PairingCopy.localNetworkDenied(address: "10.0.0.5"))
    }

    // MARK: - Confirmation

    func testTheConfirmationNamesTheRealKindAndAddress() {
        XCTAssertEqual(PairingCopy.confirmation(kind: "iPad", address: "10.0.0.5"),
                       "Pair this iPad with Nostromo at 10.0.0.5?")
        XCTAssertEqual(PairingCopy.confirmation(kind: "iPhone", address: "studio.local"),
                       "Pair this iPhone with Nostromo at studio.local?")
    }

    func testTheSameServerLineNamesTheRealKind() {
        XCTAssertEqual(PairingCopy.replacesPairing(kind: "iPhone"),
                       "This replaces this iPhone's current pairing. The old one will be revoked.")
        XCTAssertEqual(PairingCopy.replacesPairing(kind: "iPad"),
                       "This replaces this iPad's current pairing. The old one will be revoked.")
    }

    func testTheDifferentServerWarningNamesTheKindAndBothAddresses() {
        XCTAssertEqual(PairingCopy.differentServer(kind: "iPhone", old: "10.0.0.5", new: "10.0.0.9"),
                       "This iPhone is paired with Nostromo at 10.0.0.5. Pairing with 10.0.0.9 disconnects it from "
                       + "10.0.0.5 and removes its Nostromo content.")
        XCTAssertEqual(PairingCopy.differentServer(kind: "iPad", old: "studio.local", new: "192.168.1.20"),
                       "This iPad is paired with Nostromo at studio.local. Pairing with 192.168.1.20 disconnects it from "
                       + "studio.local and removes its Nostromo content.")
    }

    // MARK: - Settings

    func testForgottenNamesTheRealKind() {
        XCTAssertEqual(PairingCopy.forgotten(kind: "iPhone"),
                       "Forgotten on this iPhone. Revoke it from your Mac's Devices list when you can.")
        XCTAssertEqual(PairingCopy.forgotten(kind: "iPad"),
                       "Forgotten on this iPad. Revoke it from your Mac's Devices list when you can.")
    }

    func testTheNotSharedSentenceIsExactlyTheFinalV1Copy() {
        XCTAssertEqual(PairingCopy.notShared, "Mail, calendar and todos stay on your Mac in this version.")
    }

    // MARK: - Nothing else mentions mail, calendar or todos

    func testOnlyTheNotSharedSentenceMentionsMailCalendarOrTodos() {
        let others = [
            PairingCopy.expired(), PairingCopy.invalid(), PairingCopy.unreachable(address: "a"),
            PairingCopy.localNetworkDenied(address: "a"), PairingCopy.noLongerPaired(kind: "iPhone"),
            PairingCopy.unreachableBanner(address: "a"), PairingCopy.localNetworkBanner(address: "a"),
            PairingCopy.title, PairingCopy.instructions, PairingCopy.confirmation(kind: "iPhone", address: "a"),
            PairingCopy.replacesPairing(kind: "iPhone"),
            PairingCopy.differentServer(kind: "iPhone", old: "a", new: "b"), PairingCopy.forgotten(kind: "iPhone"),
        ]
        for sentence in others {
            for word in ["mail", "calendar", "todo"] {
                XCTAssertFalse(sentence.lowercased().contains(word), "\"\(sentence)\" mentions \(word)")
            }
        }
    }
}
