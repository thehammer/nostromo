import XCTest
import AppKit
import Combine
import NostromoKit

// CL2 (criteria B1-B7, D7/D8): the Mac sign-in card.
//
// Behaviour only: what the store knows and sends, what the buttons do for a person and for a refused
// gesture, what the launcher runs and writes, that the overlay never moves the transcript, and a source
// scan that stands in for "never types into, automates or steals focus for the login".

// MARK: - Fixtures

private enum LoginFixture {
    static func frame(tags: [(String, String?)], bin: String? = "/opt/homebrew/bin/claude",
                      phase: String = "waiting") throws -> ClaudeLoginStateFrame {
        let sessions: [[String: Any]] = tags.map { tag, hold in
            var s: [String: Any] = ["tag": tag, "phase": phase, "queued": 0,
                                    "failed_at": "2026-01-01T00:00:00Z", "auto_resends_left": 1]
            if let hold { s["hold_id"] = hold }
            return s
        }
        var obj: [String: Any] = ["type": "claude_login_state", "needs_login": !tags.isEmpty,
                                  "watch": "keychain", "sessions": sessions]
        if let bin { obj["claude_bin"] = bin }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(ClaudeLoginStateFrame.self, from: data)
    }

    static func session(tag: String = "cody-1", hold: String? = "h1", bin: String? = "/opt/homebrew/bin/claude") throws -> ClaudeLoginSession {
        try XCTUnwrap(frame(tags: [(tag, hold)], bin: bin).sessions.first)
    }
}

private typealias Sent = (action: ClaudeLoginActionKind, tag: String, hold: String)

private final class SendLog {
    var sent: [Sent] = []
    var advertised = true
    var canSend = true
    func makeStore() -> ClaudeLoginStore {
        ClaudeLoginStore(send: { [self] in sent.append(($0, $1, $2)) },
                         featureAdvertised: { [self] in advertised },
                         canSend: { [self] in canSend })
    }
}

private final class FakeProcess: ProcessLaunching {
    var executables: Set<String> = []
    /// Exit status per executable-and-first-argument; default 0.
    var hasSessionStatus: Int32? = 0
    var newWindowStatus: Int32? = 0
    var runs: [(exe: String, args: [String])] = []
    var opened: [URL] = []
    var openResult = true

    func isExecutable(atPath path: String) -> Bool { executables.contains(path) }
    func run(_ executable: String, arguments: [String]) -> Int32? {
        runs.append((executable, arguments))
        return arguments.first == "has-session" ? hasSessionStatus : newWindowStatus
    }
    func openInTerminal(_ file: URL) -> Bool { opened.append(file); return openResult }
}

private let human: ClaudeSignInCardView.GesturePermit = { _ in .human(sourcePid: nil, sourceState: nil) }

// MARK: - Store

final class ClaudeLoginStoreTests: XCTestCase {

    func testAFrameListingATagShowsItAndALaterFrameWithoutItClearsIt() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1"), ("b", "h2")]))
        XCTAssertNotNil(store.session(tag: "a"))
        XCTAssertNotNil(store.session(tag: "b"))
        store.handle(try LoginFixture.frame(tags: [("b", "h2")]))
        XCTAssertNil(store.session(tag: "a"), "REPLACE: a tag missing from the new frame is gone")
        XCTAssertNotNil(store.session(tag: "b"))
        store.handle(try LoginFixture.frame(tags: []))
        XCTAssertNil(store.session(tag: "b"))
    }

    func testADecodedDaemonFrameReachesTheStoreThroughTheAppStore() throws {
        let log = SendLog(), store = log.makeStore()
        store.attach(to: AppStore.shared.claudeLoginEvents)
        AppStore.shared.applyForTesting(.claudeLoginState(try LoginFixture.frame(tags: [("cody-1", "h1")])))
        XCTAssertEqual(store.session(tag: "cody-1")?.holdId, "h1")
        XCTAssertEqual(store.claudeBin, "/opt/homebrew/bin/claude")
        AppStore.shared.applyForTesting(.claudeLoginState(try LoginFixture.frame(tags: [])))
        XCTAssertNil(store.session(tag: "cody-1"))
    }

    func testAtMostOneActionIsSentPerHoldID() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        XCTAssertTrue(store.retry(tag: "a"))
        XCTAssertFalse(store.retry(tag: "a"))
        XCTAssertFalse(store.discard(tag: "a"), "retry then discard is still one send")
        XCTAssertEqual(log.sent.count, 1)
        XCTAssertEqual(log.sent.first?.action, .retry)
        XCTAssertEqual(log.sent.first?.hold, "h1")

        store.handle(try LoginFixture.frame(tags: [("a", "h2")]))
        XCTAssertTrue(store.discard(tag: "a"), "a new hold_id may be acted on")
        XCTAssertEqual(log.sent.map(\.hold), ["h1", "h2"])
    }

    func testNothingIsSentWhenTheFeatureIsNotAdvertisedOrThereIsNoConnection() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", "h1")]))
        log.advertised = false
        XCTAssertFalse(store.retry(tag: "a"))
        log.advertised = true; log.canSend = false
        XCTAssertFalse(store.discard(tag: "a"))
        XCTAssertTrue(log.sent.isEmpty)

        log.canSend = true
        XCTAssertTrue(store.retry(tag: "a"), "a blocked attempt does not use up the hold_id")
        XCTAssertEqual(log.sent.count, 1)
    }

    func testNothingIsSentForASessionWithNoHoldOrNoSession() throws {
        let log = SendLog(), store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("a", nil)], phase: "paused_no_hold"))
        XCTAssertFalse(store.retry(tag: "a"))
        XCTAssertFalse(store.discard(tag: "a"))
        XCTAssertFalse(store.retry(tag: "unknown"))
        XCTAssertTrue(log.sent.isEmpty)
    }
}

// MARK: - Card buttons

final class ClaudeSignInCardButtonTests: XCTestCase {

    private final class Copies { var texts: [String] = [] }

    private func make(permit: @escaping ClaudeSignInCardView.GesturePermit, bin: String?) throws
        -> (card: ClaudeSignInCardView, log: SendLog, process: FakeProcess, copies: Copies) {
        let log = SendLog(), process = FakeProcess(), copies = Copies()
        process.executables = [LoginTerminalLauncher.tmuxPaths[0]]
        let store = log.makeStore()
        store.handle(try LoginFixture.frame(tags: [("cody-1", "h1")], bin: bin))
        let launcher = LoginTerminalLauncher(process: process,
                                             temporaryDirectory: NSTemporaryDirectory() + "claude-sign-in-test-\(UUID().uuidString)/")
        let card = ClaudeSignInCardView(tag: "cody-1", session: try XCTUnwrap(store.session(tag: "cody-1")),
                                        claudeBin: bin, store: store, launcher: launcher, permit: permit,
                                        copyToPasteboard: { copies.texts.append($0) })
        card.frame = NSRect(x: 0, y: 0, width: 500, height: 160)
        card.layoutSubtreeIfNeeded()
        return (card, log, process, copies)
    }

    func testRefusedGesturesDoNothing() throws {
        let reasons: [HumanGestureRefusal] = [.appControl, .staleEvent, .accessibilityPress]
        for reason in reasons {
            let refuse: ClaudeSignInCardView.GesturePermit = { _ in .refused(reason: reason) }

            let withBin = try make(permit: refuse, bin: "/opt/homebrew/bin/claude")
            withBin.card.openButton.performClick(nil)
            withBin.card.resendButton.performClick(nil)
            withBin.card.discardButton.performClick(nil)
            XCTAssertTrue(withBin.process.runs.isEmpty, "\(reason): open launches nothing")
            XCTAssertTrue(withBin.process.opened.isEmpty, "\(reason): open launches nothing")
            XCTAssertTrue(withBin.log.sent.isEmpty, "\(reason): resend and discard send nothing")

            let noBin = try make(permit: refuse, bin: nil)
            noBin.card.copyButton.performClick(nil)
            XCTAssertTrue(noBin.copies.texts.isEmpty, "\(reason): copy does not copy")
        }
    }

    func testAPersonsClicksRunTheActions() throws {
        let a = try make(permit: human, bin: "/opt/homebrew/bin/claude")
        a.card.openButton.performClick(nil)
        XCTAssertEqual(a.process.runs.last?.args.first, "new-window", "open starts the sign-in")
        a.card.resendButton.performClick(nil)
        XCTAssertEqual(a.log.sent.map(\.action), [.retry])

        let b = try make(permit: human, bin: "/opt/homebrew/bin/claude")
        b.card.discardButton.performClick(nil)
        XCTAssertEqual(b.log.sent.map(\.action), [.discard])

        let c = try make(permit: human, bin: nil)
        c.card.copyButton.performClick(nil)
        XCTAssertEqual(c.copies.texts, [ClaudeLoginCardModel.manualCommand])
    }

    func testNoButtonIsADefaultButtonOrAnEnterShortcut() throws {
        let c = try make(permit: human, bin: "/opt/homebrew/bin/claude")
        for b in [c.card.openButton, c.card.copyButton, c.card.resendButton, c.card.discardButton] {
            XCTAssertEqual(b.keyEquivalent, "", "\(b.title) must not answer to Return or Esc")
        }
    }
}

// MARK: - Terminal launcher

final class LoginTerminalLauncherTests: XCTestCase {

    private var tmp: String!

    override func setUp() {
        super.setUp()
        tmp = NSTemporaryDirectory() + "claude-sign-in-test-\(UUID().uuidString)/"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        super.tearDown()
    }

    private func launcher(_ p: FakeProcess) -> LoginTerminalLauncher {
        LoginTerminalLauncher(process: p, temporaryDirectory: tmp)
    }

    private func perms(_ url: URL) throws -> Int {
        let n = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return try XCTUnwrap(n).intValue
    }

    func testInsideTmuxItOpensANamedWindowAndWritesNoScript() {
        let p = FakeProcess()
        p.executables = [LoginTerminalLauncher.tmuxPaths[0]]
        let l = launcher(p)
        XCTAssertEqual(l.open(claudeBin: "/x/claude"), .tmuxWindow)
        XCTAssertEqual(p.runs.last?.args, ["new-window", "-n", "claude-sign-in", "--", "/x/claude", "auth", "login"])
        XCTAssertEqual(p.runs.last?.exe, "/opt/homebrew/bin/tmux")
        XCTAssertTrue(p.opened.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.scriptURL.path))
    }

    func testTmuxIsLookedForInHomebrewThenUsrLocalThenUsr() {
        XCTAssertEqual(LoginTerminalLauncher.tmuxPaths, ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"])
        let p = FakeProcess()
        p.executables = ["/usr/local/bin/tmux", "/usr/bin/tmux"]
        _ = launcher(p).open(claudeBin: "/x/claude")
        XCTAssertEqual(p.runs.first?.exe, "/usr/local/bin/tmux")
    }

    func testWithoutALiveTmuxSessionItFallsBackToATerminalCommandFile() throws {
        let p = FakeProcess()
        p.executables = [LoginTerminalLauncher.tmuxPaths[0]]
        p.hasSessionStatus = 1
        let l = launcher(p)
        XCTAssertEqual(l.open(claudeBin: "/x/claude"), .terminalApp)
        XCTAssertFalse(p.runs.contains { $0.args.first == "new-window" })
        XCTAssertEqual(p.opened, [l.scriptURL])
        XCTAssertEqual(try String(contentsOf: l.scriptURL, encoding: .utf8), "#!/bin/sh\nexec '/x/claude' auth login\n")
        XCTAssertEqual(try perms(l.scriptURL), 0o700)
        XCTAssertEqual(try perms(l.scriptURL.deletingLastPathComponent()), 0o700)
    }

    func testWithNoTmuxAtAllItUsesTheTerminalFallback() {
        let p = FakeProcess()
        XCTAssertEqual(launcher(p).open(claudeBin: "/x/claude"), .terminalApp)
        XCTAssertTrue(p.runs.isEmpty)
        XCTAssertEqual(p.opened.count, 1)
    }

    func testAPathWithASpaceAndAQuoteIsQuotedForTheShell() throws {
        let p = FakeProcess()
        let l = launcher(p)
        XCTAssertEqual(l.open(claudeBin: "/Users/o'brien/my tools/claude"), .terminalApp)
        XCTAssertEqual(try String(contentsOf: l.scriptURL, encoding: .utf8),
                       "#!/bin/sh\nexec '/Users/o'\\''brien/my tools/claude' auth login\n")
    }

    func testAPathWithANewlineIsRefusedAndNothingIsWritten() {
        let p = FakeProcess()
        p.executables = [LoginTerminalLauncher.tmuxPaths[0]]
        let l = launcher(p)
        XCTAssertNil(l.open(claudeBin: "/x/claude\nrm -rf ~"))
        XCTAssertTrue(p.runs.isEmpty)
        XCTAssertTrue(p.opened.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.scriptURL.path))
    }
}

// MARK: - Overlay host

final class ClaudeSignInOverlayHostTests: XCTestCase {

    func testTheCardShowsOnlyWhileTheStoreListsItsTagAndOnlyTheCardTakesHits() throws {
        let store = SendLog().makeStore()
        let host = ClaudeSignInOverlayHost(tag: "cody-1", store: store, permit: human)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        XCTAssertNil(host.card)

        store.handle(try LoginFixture.frame(tags: [("other", "h9")]))
        XCTAssertNil(host.card, "another focus's session does not show here")

        store.handle(try LoginFixture.frame(tags: [("cody-1", "h1")]))
        host.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(host.card)
        XCTAssertTrue(card.superview === host)
        XCTAssertNil(host.hitTest(NSPoint(x: 1, y: 399)), "outside the card the click goes to the transcript")
        XCTAssertNotNil(host.hitTest(NSPoint(x: card.frame.midX, y: card.frame.midY)), "inside the card it is the card's")

        store.handle(try LoginFixture.frame(tags: []))
        XCTAssertNil(host.card)
        XCTAssertNil(card.superview)
    }

    private func overlay(on rig: SafetyRig, store: ClaudeLoginStore) -> ClaudeSignInOverlayHost {
        let host = ClaudeSignInOverlayHost(tag: "cody-1", store: store, permit: human)
        host.translatesAutoresizingMaskIntoConstraints = false
        let content = rig.window.contentView!
        content.addSubview(host, positioned: .above, relativeTo: rig.overlay)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: rig.scrollView.topAnchor),
            host.leadingAnchor.constraint(equalTo: rig.scrollView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: rig.scrollView.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: rig.scrollView.bottomAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        return host
    }

    func testTheCardArrivingAndLeavingMovesNothingAndKeepsTheComposer() throws {
        for following in [true, false] {
            let rig = following ? SafetyRig.followingTail(self) : SafetyRig.scrolledUp(self)
            let store = SendLog().makeStore()
            let host = overlay(on: rig, store: store)
            let scrollFrame = rig.scrollView.frame, barFrame = rig.inputBar.frame
            let arrive = try LoginFixture.frame(tags: [("cody-1", "h1")])
            let leave = try LoginFixture.frame(tags: [])

            rig.assertNoMove("sign-in card arrives (following: \(following))", following: following) {
                store.handle(arrive)
                rig.window.contentView?.layoutSubtreeIfNeeded()
            }
            XCTAssertNotNil(host.card)
            XCTAssertEqual(rig.scrollView.frame, scrollFrame)
            XCTAssertEqual(rig.inputBar.frame, barFrame)
            XCTAssertTrue(rig.window.firstResponder === rig.textView, "the composer keeps focus")
            XCTAssertEqual(rig.textView.string, SafetyRig.typedText)

            rig.assertNoMove("sign-in card leaves (following: \(following))", following: following) {
                store.handle(leave)
                rig.window.contentView?.layoutSubtreeIfNeeded()
            }
            XCTAssertNil(host.card)
            XCTAssertEqual(rig.textView.string, SafetyRig.typedText)
        }
    }
}

// MARK: - Source scan

final class ClaudeSignInSourceScanTests: XCTestCase {

    private func files() throws -> [String] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Nostromo/UI/Login")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
    }

    func testTheScanSeesTheFourLoginFiles() throws {
        let found = try files()
        for f in ["ClaudeLoginStore.swift", "ClaudeSignInCardView.swift", "ClaudeSignInOverlayHost.swift", "LoginTerminalLauncher.swift"] {
            XCTAssertTrue(found.contains(f), "\(f) missing from UI/Login: \(found)")
        }
    }

    func testTheLoginUINeverAutomatesTheLoginOrTouchesFocusOrTheKeychain() throws {
        let forbidden = ["send-keys", "osascript", "NSAppleScript", "CGEvent", "security", "keyEquivalent", "makeFirstResponder"]
            + DecisionCoordinatorTests.forbiddenForegroundAndFocusCalls
        for file in try files() {
            let lines = try DecisionCoordinatorTests.codeLines(ofSourceAt: "UI/Login/\(file)")
            for needle in forbidden {
                let hits = lines.filter { $0.contains(needle) }
                XCTAssertTrue(hits.isEmpty, "UI/Login/\(file) must not use `\(needle)`: \(hits)")
            }
        }
    }

    func testTheInstalledAppStillHasNoEntitlements() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("signing/Nostromo.installed.entitlements")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let dict = try XCTUnwrap(plist as? [String: Any])
        // Parsed, not grepped: the file's comment names the forbidden keys.
        for key in ["get-task-allow", "com.apple.security.cs.allow-dyld-environment-variables",
                    "allow-dyld-environment-variables", "com.apple.security.cs.disable-library-validation",
                    "disable-library-validation"] {
            XCTAssertNil(dict[key], "\(key) must never be an entitlement of the installed app")
        }
        XCTAssertTrue(dict.isEmpty, "the installed app's entitlements stay empty: \(dict.keys)")
    }
}
