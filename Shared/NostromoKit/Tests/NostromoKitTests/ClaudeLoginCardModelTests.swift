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
        XCTAssertEqual(m.body, "Your last message may have partly run before sign-in failed, so Nostromo won't send it again on its own.")
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
}
