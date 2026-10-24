import XCTest
@testable import NostromoKit

final class ClaudeLoginCardModelTests: XCTestCase {
    private func session(_ phase: ClaudeLoginPhase, hold: String? = "h1", queued: Int = 0) -> ClaudeLoginSession {
        let json = """
        {"tag":"t","hold_id":\(hold.map { "\"\($0)\"" } ?? "null"),"phase":"\(phase.rawValue)","queued":\(queued),
         "failed_at":"2026-01-01T00:00:00Z","auto_resends_left":1}
        """
        return try! JSONDecoder().decode(ClaudeLoginSession.self, from: Data(json.utf8))
    }

    func testTitleAndWaitingBody() {
        let m = ClaudeLoginCardModel(session: session(.waiting), claudeBin: "/bin/claude")
        XCTAssertEqual(m.title, "Claude needs you to sign in")
        XCTAssertEqual(m.body, "Claude's sign-in expired, so your last message wasn't answered. It's saved and will be sent again once you sign in.")
        XCTAssertEqual(m.resendTitle, "Resend now")
        XCTAssertTrue(m.resendEnabled)
    }

    func testQueuedAddsLine() {
        let m = ClaudeLoginCardModel(session: session(.waiting, queued: 3), claudeBin: "/bin/claude")
        XCTAssertTrue(m.body.hasSuffix(" 3 more messages are waiting."))
    }

    func testNotResendable() {
        let m = ClaudeLoginCardModel(session: session(.notResendable), claudeBin: "/bin/claude")
        XCTAssertEqual(m.body, "Your last message may have partly run before sign-in failed, so Nostromo won't send it again on its own. After you sign in, press Resend anyway if you want it sent.")
        XCTAssertEqual(m.resendTitle, "Resend anyway")
    }

    func testResendingDisablesResend() {
        let m = ClaudeLoginCardModel(session: session(.resending), claudeBin: "/bin/claude")
        XCTAssertEqual(m.body, "Sending your message again…")
        XCTAssertFalse(m.resendEnabled)
    }

    func testPausedNoHoldHasNoDiscard() {
        let m = ClaudeLoginCardModel(session: session(.pausedNoHold, hold: nil), claudeBin: "/bin/claude")
        XCTAssertEqual(m.body, "Messages are waiting until Claude can sign in.")
        XCTAssertFalse(m.showsDiscard)
        XCTAssertTrue(ClaudeLoginCardModel(session: session(.waiting), claudeBin: "/bin/claude").showsDiscard)
    }

    func testMissingClaudeBinShowsManualCommand() {
        let none = ClaudeLoginCardModel(session: session(.waiting), claudeBin: nil)
        XCTAssertFalse(none.showsOpenTerminal)
        XCTAssertTrue(none.showsManualCommand)
        let some = ClaudeLoginCardModel(session: session(.waiting), claudeBin: "/bin/claude")
        XCTAssertTrue(some.showsOpenTerminal)
        XCTAssertFalse(some.showsManualCommand)
    }

    func testDiscardIsNotOfferedOnceTheMessageIsBeingSentAgain() {
        let m = ClaudeLoginCardModel(session: session(.resending), claudeBin: "/bin/claude")
        XCTAssertFalse(m.showsDiscard)
        for phase in [ClaudeLoginPhase.waiting, .notResendable] {
            XCTAssertTrue(ClaudeLoginCardModel(session: session(phase), claudeBin: "/bin/claude").showsDiscard, "\(phase)")
        }
    }

    func testTheWatchDefaultsToTheKeychain() {
        for phase in [ClaudeLoginPhase.waiting, .resending, .notResendable, .pausedNoHold] {
            let s = session(phase, hold: phase == .pausedNoHold ? nil : "h1")
            XCTAssertEqual(ClaudeLoginCardModel(session: s, claudeBin: "/bin/claude"),
                           ClaudeLoginCardModel(session: s, claudeBin: "/bin/claude", watch: .keychain), "\(phase)")
        }
    }

    // MARK: Copy per phase and watch

    private let signedOut = "Claude's sign-in expired, so your last message wasn't answered. "
    private let partlyRan = "Your last message may have partly run before sign-in failed, so Nostromo won't send it again on its own. After you sign in, press Resend anyway if you want it sent."

    func testWhatTheCardSaysForEveryPhaseAndWatch() {
        let cases: [(phase: ClaudeLoginPhase, watch: ClaudeLoginWatch, body: String, afterSignIn: String)] = [
            (.waiting, .keychain,
             signedOut + "It's saved and will be sent again once you sign in.",
             "Nostromo sends your message once Claude is signed in."),
            (.waiting, .unavailable,
             signedOut + "It's saved. After you sign in, press Resend now.",
             "After you sign in, press Resend now."),
            (.notResendable, .keychain, partlyRan, "After you sign in, press Resend anyway."),
            (.notResendable, .unavailable, partlyRan, "After you sign in, press Resend anyway."),
            (.resending, .keychain, "Sending your message again…",
             "Nostromo sends your message once Claude is signed in."),
            (.resending, .unavailable, "Sending your message again…",
             "Nostromo sends your message once Claude is signed in."),
            (.pausedNoHold, .keychain, "Messages are waiting until Claude can sign in.",
             "Nostromo sends your message once Claude is signed in."),
            (.pausedNoHold, .unavailable,
             "Messages are waiting until Claude can sign in. Nostromo can't see when you do, so they won't go out on their own.",
             "Nostromo can't see when you've signed in."),
        ]
        for c in cases {
            let s = session(c.phase, hold: c.phase == .pausedNoHold ? nil : "h1")
            let m = ClaudeLoginCardModel(session: s, claudeBin: "/bin/claude", watch: c.watch)
            XCTAssertEqual(m.body, c.body, "\(c.phase) / \(c.watch) body")
            XCTAssertEqual(m.afterSignIn, c.afterSignIn, "\(c.phase) / \(c.watch) afterSignIn")
        }
    }

    func testTheQueuedCountComesAfterTheWatchSpecificText() {
        let m = ClaudeLoginCardModel(session: session(.waiting, queued: 1), claudeBin: "/bin/claude", watch: .unavailable)
        XCTAssertEqual(m.body, signedOut + "It's saved. After you sign in, press Resend now. 1 more message is waiting.")
    }

    func testWhenNothingSendsItselfTheCardNeverPromisesItWill() {
        for phase in [ClaudeLoginPhase.waiting, .notResendable, .pausedNoHold] {
            let s = session(phase, hold: phase == .pausedNoHold ? nil : "h1")
            let m = ClaudeLoginCardModel(session: s, claudeBin: "/bin/claude", watch: .unavailable)
            XCTAssertFalse(m.body.contains("will be sent again"), "\(phase): \(m.body)")
            XCTAssertFalse(m.afterSignIn.contains("Nostromo sends"), "\(phase): \(m.afterSignIn)")
        }
    }
}
