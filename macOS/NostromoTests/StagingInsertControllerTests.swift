import XCTest
import AppKit

// `StagingInsertController`: the one place a staged command can become bytes at a shell's prompt.
//
// The contract, from the drawer's spec:
//   * A person's click (or Space, or VoiceOver's press) places the command's exact UTF-8 at the prompt:
//     bracketed-paste markers only when the program asked for them, never a CR or LF. Then the terminal
//     takes the keyboard, then the daemon is told (`terminal_staging_inserted`, bytes = the text's UTF-8
//     count, `confirmed` false). In that order, once.
//   * Anything that is not a person (app-control's synthetic events, a stale or other window's event, a
//     right or control click, the second click of a double-click) inserts nothing and is reported
//     (`terminal_refusal_report`, op `stage_insert`; Copy, Remove and Clear report their own ops).
//   * The text inserted is what the row said at the mouse-down (or key-down); a replace that lands before
//     the mouse-up changes nothing. An entry that changed less than 1.5 s before is not inserted.
//   * Every disabled reason (mirror, daemon, connecting/ended, not local, full-screen program, a paste
//     still going out, just changed, not insertable) sends nothing, and the state is checked again at
//     the mouse-up.
//
// The terminal view is a fake (`FakeStagingTarget`: SwiftTerm is not in this bundle) that counts calls;
// the daemon connection is a closure that records frames; time is a variable. Cases that depend on the
// human-gesture rule run the REAL `TerminalInputGuard` (VoiceOver answered by a closure).
//
// The fixtures at the top (rig, events, gates) are shared with StagingDrawerViewTests, ScreenshotRedactionTests
// and TerminalScreenAccessTests.

// MARK: - Shared fixtures

enum StagingFixtures {
    static let terminalId = "5f0a8f7e-2d4c-4a4e-9a55-0f1f3a9d7c11"
    /// 2026-10-30T15:04:05Z
    static let baseDate = Date(timeIntervalSince1970: 1_793_372_645)

    /// `<repo>`: the test files are three directories below the root.
    static func repoRoot(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    static func fixtureData(_ name: String, file: StaticString = #filePath) throws -> Data {
        try Data(contentsOf: repoRoot(file: file).appendingPathComponent("tests/fixtures/terminal_staging/\(name)"))
    }

    /// `commands.json`: single-line commands the daemon accepts (and the app must insert).
    static func commands(file: StaticString = #filePath) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: try fixtureData("commands.json", file: file))
        return try XCTUnwrap(object as? [String], "commands.json should be an array of strings")
    }

    static func entry(_ id: String, _ number: Int, _ command: String, note: String? = nil,
                      changedAt: Date = baseDate, insertedCount: Int = 0, lastInsertedAt: Date? = nil) -> StagingEntry {
        StagingEntry(id: id, number: number, command: command, note: note, stagedAt: baseDate, changedAt: changedAt,
                     insertedCount: insertedCount, lastInsertedAt: lastInsertedAt)
    }

    /// Entries `s-1`, `s-2`, ... numbered from 1.
    static func entries(_ commands: [String]) -> [StagingEntry] {
        commands.enumerated().map { entry("s-\($0.offset + 1)", $0.offset + 1, $0.element) }
    }

    static func list(terminalId: String = StagingFixtures.terminalId, state: TerminalStagingState = .active,
                     agent: String = "Claudia", owner: String = "owner-tag", revision: Int, entries: [StagingEntry],
                     enabled: Bool = true, foreground: String? = nil) -> TerminalStagingList {
        TerminalStagingList(terminalId: terminalId, paneId: "terminal-a", state: state, ownerTag: owner,
                            agentName: agent, revision: revision, entries: entries, enabled: enabled, foreground: foreground)
    }

    /// `PRODUCTION · admin-portal · scheduler · shell`.
    static let productionTarget = TerminalTarget(project: "admin-portal", environment: "production", service: "scheduler",
                                                 shellType: "shell")

    static func terminalInfo(kind: TerminalKind = .local, status: TerminalStatus = .running) -> TerminalInfo {
        TerminalInfo(terminalId: terminalId, tag: "core-1", paneId: "terminal-a", kind: kind, label: "Terminal",
                     cwd: "/tmp", target: nil, status: status, exitCode: nil, endedReason: nil, cols: 80, rows: 24,
                     requestedBy: TerminalRequester(kind: "user", tag: nil), openedByRequest: nil, follower: nil,
                     idleClosesAt: nil)
    }
}

/// Real `NSEvent`s aimed at a window (the window must have a window number: `GestureFixtures.offscreenWindow`).
enum StagingEvents {
    static func mouse(_ type: NSEvent.EventType, in window: NSWindow, at point: NSPoint, clickCount: Int = 1,
                      modifiers: NSEvent.ModifierFlags = [],
                      timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: timestamp,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 7,
                           clickCount: clickCount, pressure: 1)!
    }

    static func key(_ keyCode: UInt16, _ characters: String, in window: NSWindow,
                    modifiers: NSEvent.ModifierFlags = [],
                    timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                         windowNumber: window.windowNumber, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: keyCode)!
    }

    /// `event` stamped the way app-control stamps what it synthesises.
    static func marked(_ event: NSEvent) throws -> NSEvent {
        try GestureFixtures.marked(event)
    }

    static func space(in window: NSWindow, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent {
        key(49, " ", in: window, timestamp: timestamp)
    }
    static func returnKey(in window: NSWindow) -> NSEvent { key(36, "\r", in: window) }
    static func keypadEnter(in window: NSWindow) -> NSEvent { key(76, "\u{3}", in: window) }
    static func escape(in window: NSWindow) -> NSEvent { key(53, "\u{1B}", in: window) }
    static func up(in window: NSWindow) -> NSEvent { key(126, "\u{F700}", in: window) }
    static func down(in window: NSWindow) -> NSEvent { key(125, "\u{F701}", in: window) }
    static func tab(in window: NSWindow, shift: Bool = false) -> NSEvent {
        key(48, "\t", in: window, modifiers: shift ? [.shift] : [])
    }
}

/// The gate the controller asks. The real one is `TerminalInputGuard.allowsControl`.
enum StagingGates {
    static let allowAll: StagingInsertController.Gate = { _, _, _ in true }
    static let refuseAll: StagingInsertController.Gate = { _, _, _ in false }

    /// The real guard, with VoiceOver answered by `voiceOver` (the machine's setting must not matter).
    static func real(voiceOver: Bool = false) -> StagingInsertController.Gate {
        return { event, control, fromMenu in
            TerminalInputGuard.allowsControl(event: event, control: control, fromMenu: fromMenu,
                                             voiceOverEnabled: { voiceOver })
        }
    }
}

/// Records the order of what the terminal and the daemon were asked to do.
final class StagingCallLog {
    var entries: [String] = []
}

/// A terminal view that only counts: `sendStagedBytes` is the single door to a shell.
final class FakeStagingTarget: StagingInsertTarget {
    var isAlternateScreen = false
    var bracketedPasteMode = false
    var log: StagingCallLog?
    /// What the terminal answers: true when it took the bytes, false when nothing went out.
    var sendResult = true
    /// The bytes the terminal took (what reached the shell).
    private(set) var sent: [[UInt8]] = []
    /// Every call to `sendStagedBytes`, taken or not.
    private(set) var attempts: [[UInt8]] = []
    private(set) var focusCount = 0

    func sendStagedBytes(_ bytes: [UInt8]) -> Bool {
        attempts.append(bytes)
        guard sendResult else {
            log?.entries.append("send-refused")
            return false
        }
        sent.append(bytes)
        log?.entries.append("send")
        return true
    }

    func focusTerminal() {
        focusCount += 1
        log?.entries.append("focus")
    }
}

/// One window's view of the terminal: its own terminal view, its own context (driver or mirror).
final class StagingSide {
    let target = FakeStagingTarget()
    var context: StagingContext?
    var controller: StagingInsertController!
}

final class StagingRigState {
    var storeClock: TimeInterval = 1_000
    var sessionDate = Date(timeIntervalSinceReferenceDate: 1_000_000)
    var stagingFrames: [TerminalClientMessage] = []
    var sessionFrames: [TerminalClientMessage] = []
    var scheduled: [() -> Void] = []
    var rowResults: [StagingInsertResult] = []
    let log = StagingCallLog()
}

/// A staging store and a terminal session store on injected clocks and recording transports, a private
/// pasteboard, and one or more windows' controllers (`StagingSide`) over them.
final class StagingRig {
    let box: StagingRigState
    let staging: TerminalStagingStore
    let sessions: TerminalSessionStore
    let pasteboard: NSPasteboard
    private(set) var primary = StagingSide()
    private var sides: [StagingSide] = []
    private var revision = 0
    private var windows: [NSWindow] = []

    var target: FakeStagingTarget { primary.target }
    var controller: StagingInsertController { primary.controller }
    var context: StagingContext? {
        get { primary.context }
        set { primary.context = newValue }
    }
    var log: StagingCallLog { box.log }
    var stagingFrames: [TerminalClientMessage] { box.stagingFrames }
    var sessionFrames: [TerminalClientMessage] { box.sessionFrames }
    var rowResults: [StagingInsertResult] { box.rowResults }

    /// Frames the app sent to say a staged entry was placed.
    var insertedFrames: [TerminalClientMessage] {
        stagingFrames.filter { if case .stagingInserted = $0 { return true } else { return false } }
    }

    /// The ops of every `terminal_refusal_report` sent, in order.
    var refusals: [TerminalRefusedOp] {
        sessionFrames.compactMap { frame -> TerminalRefusedOp? in
            if case .refusalReport(_, let op, _) = frame { return op }
            return nil
        }
    }

    init(gate: @escaping StagingInsertController.Gate = StagingGates.allowAll, kind: TerminalKind? = .local,
         status: TerminalStatus? = .running, isMirror: Bool = false) {
        let s = StagingRigState()
        box = s
        // A private suite: a test of the global switch must never write the real preferences.
        let suite = UserDefaults(suiteName: "redd.staging.\(UUID().uuidString)")!
        staging = TerminalStagingStore(clock: { s.storeClock }, transport: { frame in
            s.stagingFrames.append(frame)
            s.log.entries.append("report:" + frame.wireType)
        }, defaults: suite)
        sessions = TerminalSessionStore(now: { s.sessionDate },
                                        schedule: { _, work in s.scheduled.append(work) },
                                        transport: { s.sessionFrames.append($0) })
        pasteboard = NSPasteboard(name: NSPasteboard.Name("redd.staging.\(UUID().uuidString)"))
        sessions.ingest(.terminalState(StagingFixtures.terminalInfo()))
        // As `AppStore` wires it: a person's input feeds auto-archive.
        sessions.onPersonInput = { [weak self] id, bytes in self?.staging.personTyped(terminalId: id, bytes: bytes) }
        connect(primary, gate: gate, kind: kind, status: status, isMirror: isMirror)
    }

    /// The person pressed Enter in the shell: the line is known empty.
    func typeEnter(_ bytes: [UInt8] = [0x0D]) {
        sessions.sendInput(terminalId: StagingFixtures.terminalId, bytes: bytes, fromWindow: "w-test")
    }

    /// Input frames sent for the shell (typed, or placed).
    var inputFrames: [TerminalClientMessage] {
        sessionFrames.filter { if case .input = $0 { return true } else { return false } }
    }

    private func connect(_ side: StagingSide, gate: @escaping StagingInsertController.Gate, kind: TerminalKind?,
                         status: TerminalStatus?, isMirror: Bool) {
        side.target.log = box.log
        side.context = StagingContext(terminalId: StagingFixtures.terminalId, kind: kind, status: status, isMirror: isMirror)
        side.controller = StagingInsertController(staging: staging, sessions: sessions, target: side.target,
                                                  pasteboard: pasteboard,
                                                  context: { [unowned side] in side.context }, gate: gate)
        sides.append(side)
    }

    /// Another window showing the same terminal (a mirror unless it says otherwise).
    func makeSide(isMirror: Bool = true, gate: @escaping StagingInsertController.Gate = StagingGates.allowAll,
                  kind: TerminalKind? = .local, status: TerminalStatus? = .running) -> StagingSide {
        let side = StagingSide()
        connect(side, gate: gate, kind: kind, status: status, isMirror: isMirror)
        return side
    }

    func tearDown() {
        for window in windows { window.close() }
        windows = []
        pasteboard.releaseGlobally()
    }

    // MARK: Driving the store and the clocks

    /// A frame for the terminal with the next revision.
    @discardableResult
    func ingest(_ entries: [StagingEntry], state: TerminalStagingState = .active, agent: String = "Claudia",
                owner: String = "owner-tag", enabled: Bool = true, foreground: String? = nil) -> TerminalStagingList {
        revision += 1
        let list = StagingFixtures.list(state: state, agent: agent, owner: owner, revision: revision, entries: entries,
                                        enabled: enabled, foreground: foreground)
        staging.ingest(list)
        return list
    }

    /// Time passes on the store's clock (the default is past the 1.5 s reading delay).
    func settle(_ seconds: TimeInterval = 2) {
        box.storeClock += seconds
    }

    /// Time passes on the session store's clock (its refusal reports are throttled to one a second per kind).
    func advanceSession(_ seconds: TimeInterval = 2) {
        box.sessionDate = box.sessionDate.addingTimeInterval(seconds)
    }

    /// A large paste is still going out in frames.
    func sendBacklog() {
        sessions.sendInput(terminalId: StagingFixtures.terminalId,
                           bytes: [UInt8](repeating: 0x61, count: TerminalSessionStore.inputChunkBytes + 1),
                           fromWindow: "w-test")
    }

    /// The paste's remaining frames go out.
    func drainBacklog() {
        while !box.scheduled.isEmpty { box.scheduled.removeFirst()() }
    }

    /// The daemon connection dropped: every terminal is view-only.
    func loseDaemon() {
        sessions.connectionChanged(false)
    }

    // MARK: Windows and rows

    /// A titled window, like the app's: a borderless one cannot host a sheet properly (the confirm sheet tests).
    func makeTitledWindow(size: NSSize = NSSize(width: 900, height: 700)) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        windows.append(window)
        return window
    }

    func makeWindow(size: NSSize = NSSize(width: 900, height: 700)) -> NSWindow {
        let window = GestureFixtures.offscreenWindow(size: size)
        windows.append(window)
        return window
    }

    /// A row view for `entryId` as the drawer would draw it now, in `window`, wired to `side`'s controller.
    func makeRow(entryId: String = "s-1", in window: NSWindow, side: StagingSide? = nil,
                 width: CGFloat = 320) -> StagingRowView {
        let side = side ?? primary
        let list = staging.list(for: StagingFixtures.terminalId)!
        let env = side.controller.environment()!
        let store = staging
        let rows = StagingDrawerModel.rows(for: list, env: env,
                                           shownSince: { store.shownSince(terminalId: StagingFixtures.terminalId, entryId: $0) },
                                           now: staging.now, date: StagingFixtures.baseDate.addingTimeInterval(10))
        let model = rows.first { $0.entryId == entryId }!
        let row = StagingRowView(model: model)
        row.controller = side.controller
        let s = box
        row.onResult = { s.rowResults.append($0) }
        row.frame = NSRect(x: 0, y: 0, width: width, height: row.height(forWidth: width))
        window.contentView!.addSubview(row)
        return row
    }

    /// A point inside `row`, in window coordinates.
    static func point(in row: StagingRowView) -> NSPoint {
        row.convert(NSPoint(x: 60, y: 8), to: nil)
    }

    func mouseDown(_ row: StagingRowView, in window: NSWindow, clickCount: Int = 1,
                   modifiers: NSEvent.ModifierFlags = []) {
        row.mouseDown(with: StagingEvents.mouse(.leftMouseDown, in: window, at: Self.point(in: row),
                                                clickCount: clickCount, modifiers: modifiers))
    }

    func mouseUp(_ row: StagingRowView, in window: NSWindow, clickCount: Int = 1) {
        row.mouseUp(with: StagingEvents.mouse(.leftMouseUp, in: window, at: Self.point(in: row), clickCount: clickCount))
    }

    func click(_ row: StagingRowView, in window: NSWindow) {
        mouseDown(row, in: window)
        mouseUp(row, in: window)
    }
}

// MARK: - Tests

final class StagingInsertControllerTests: XCTestCase {

    private var rigs: [StagingRig] = []

    override func tearDown() {
        for rig in rigs { rig.tearDown() }
        rigs = []
        super.tearDown()
    }

    private func makeRig(gate: @escaping StagingInsertController.Gate = StagingGates.allowAll, kind: TerminalKind? = .local,
                         status: TerminalStatus? = .running, isMirror: Bool = false) -> StagingRig {
        let rig = StagingRig(gate: gate, kind: kind, status: status, isMirror: isMirror)
        rigs.append(rig)
        return rig
    }

    /// A rig with the real guard, one entry `ls -la` that has been readable for 2 s, and its row in a window.
    private func readyRow(command: String = "ls -la", kind: TerminalKind? = .local, status: TerminalStatus? = .running,
                          isMirror: Bool = false, voiceOver: Bool = false, settle: Bool = true)
        -> (rig: StagingRig, window: NSWindow, row: StagingRowView) {
        let rig = makeRig(gate: StagingGates.real(voiceOver: voiceOver), kind: kind, status: status, isMirror: isMirror)
        rig.ingest([StagingFixtures.entry("s-1", 1, command)])
        if settle { rig.settle() }
        let window = rig.makeWindow()
        return (rig, window, rig.makeRow(in: window))
    }

    private func assertNothingPlaced(_ rig: StagingRig, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(rig.target.sent.isEmpty, "bytes reached the terminal. \(message)", file: file, line: line)
        XCTAssertEqual(rig.target.focusCount, 0, "the terminal must not take the keyboard. \(message)", file: file, line: line)
        XCTAssertTrue(rig.insertedFrames.isEmpty, "the daemon was told something was inserted. \(message)", file: file, line: line)
    }

    // MARK: - SB-1/2: what is placed

    func testEveryGoldenCommandIsPlacedAsExactlyItsUTF8WithNoLineBreakThenFocusThenOneReport() throws {
        let commands = try StagingFixtures.commands()
        XCTAssertGreaterThan(commands.count, 20, "commands.json should be found")
        for command in commands {
            let rig = makeRig()
            rig.ingest([StagingFixtures.entry("s-1", 1, command)])
            rig.settle()

            let snapshot = try XCTUnwrap(rig.controller.snapshot(entryId: "s-1"), command)
            XCTAssertNil(snapshot.reason, command)
            let result = rig.controller.insert(snapshot, event: nil, control: NSView())

            let utf8 = Array(command.utf8)
            XCTAssertEqual(result, .inserted(bytes: utf8.count), command)
            XCTAssertEqual(rig.target.sent, [utf8], "exactly one send of exactly the command: \(command)")
            let sent = try XCTUnwrap(rig.target.sent.first)
            XCTAssertFalse(sent.contains(0x0D) || sent.contains(0x0A), "a line break was added: \(command)")
            XCTAssertEqual(rig.target.focusCount, 1, command)
            XCTAssertEqual(rig.log.entries, ["send", "focus", "report:terminal_staging_inserted"],
                           "the order is send, then focus, then report: \(command)")
            XCTAssertEqual(rig.stagingFrames,
                           [.stagingInserted(terminalId: StagingFixtures.terminalId, entryId: "s-1", bytes: utf8.count, confirmed: false)],
                           command)
        }
    }

    func testWhenTheProgramAskedForBracketedPasteTheBytesAreWrappedAndStillHaveNoLineBreak() throws {
        for command in try StagingFixtures.commands() {
            let rig = makeRig()
            rig.target.bracketedPasteMode = true
            rig.ingest([StagingFixtures.entry("s-1", 1, command)])
            rig.settle()

            let snapshot = try XCTUnwrap(rig.controller.snapshot(entryId: "s-1"))
            let utf8 = Array(command.utf8)
            XCTAssertEqual(rig.controller.insert(snapshot, event: nil, control: NSView()), .inserted(bytes: utf8.count), command)

            let expected = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] + utf8 + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
            XCTAssertEqual(rig.target.sent, [expected], command)
            let sent = try XCTUnwrap(rig.target.sent.first)
            XCTAssertFalse(sent.contains(0x0D) || sent.contains(0x0A), "a line break was added: \(command)")
            XCTAssertEqual(rig.stagingFrames,
                           [.stagingInserted(terminalId: StagingFixtures.terminalId, entryId: "s-1", bytes: utf8.count, confirmed: false)],
                           "the report counts the text's bytes, not the markers: \(command)")
        }
    }

    func testTheReportSaysUnconfirmedAndNeverCarriesTheText() throws {
        let rig = makeRig()
        rig.ingest([StagingFixtures.entry("s-1", 1, "echo CANARY-TEXT-9d3f")])
        rig.settle()
        _ = rig.controller.insert(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1")), event: nil, control: NSView())

        let frame = try XCTUnwrap(rig.insertedFrames.first)
        let json = String(decoding: try XCTUnwrap(frame.encoded()), as: UTF8.self)
        XCTAssertFalse(json.contains("CANARY-TEXT-9d3f"), json)
        XCTAssertTrue(json.contains("\"confirmed\":false"), json)
    }

    func testAnEntryThatIsInsertedTwiceIsPlacedTwiceAndReportedTwice() throws {
        let rig = makeRig()
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls")])
        rig.settle()
        for _ in 0..<2 {
            let snapshot = try XCTUnwrap(rig.controller.snapshot(entryId: "s-1"))
            XCTAssertEqual(rig.controller.insert(snapshot, event: nil, control: NSView()), .inserted(bytes: 2))
        }
        XCTAssertEqual(rig.target.sent, [Array("ls".utf8), Array("ls".utf8)])
        XCTAssertEqual(rig.insertedFrames.count, 2)
    }

    // MARK: - A terminal that does not take the bytes places nothing

    func testATerminalThatDoesNotTakeTheBytesIsNotFocusedAndNothingIsReportedAsPlaced() throws {
        let rig = makeRig()
        rig.target.sendResult = false
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls -la")])
        rig.settle()

        let snapshot = try XCTUnwrap(rig.controller.snapshot(entryId: "s-1"))
        XCTAssertEqual(rig.controller.insert(snapshot, event: nil, control: NSView()), .refused(.notSent))

        XCTAssertEqual(rig.target.attempts, [Array("ls -la".utf8)], "the terminal was asked exactly once, and not asked again")
        XCTAssertTrue(rig.target.sent.isEmpty, "nothing reached the shell")
        XCTAssertEqual(rig.target.focusCount, 0, "the terminal must not take the keyboard for a placement that did not happen")
        XCTAssertTrue(rig.insertedFrames.isEmpty, "the daemon is not told something was inserted")
        XCTAssertTrue(rig.stagingFrames.isEmpty, "no staging frame of any kind goes out")
        XCTAssertEqual(rig.log.entries, ["send-refused"], "no focus and no report after a refusal")
    }

    func testTheReasonForANotSentRefusalIsAnAppWrittenNonEmptyTextOfItsOwn() {
        let text = StagingDisabledReason.notSent.text
        XCTAssertFalse(text.isEmpty)
        let others: [StagingDisabledReason] = [.mirror, .daemonDisconnected, .connecting, .ended, .alternateScreen,
                                               .sendingPaste, .lineMayHaveText, .historyExpansion, .justChanged, .notInsertable]
        XCTAssertFalse(others.map { $0.text }.contains(text), "the person is told what actually happened")
    }

    func testAnEntryRefusedByTheTerminalCanBePlacedOnceTheTerminalTakesBytesAgainAndThenReportsOnce() throws {
        let rig = makeRig()
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls -la")])
        rig.settle()

        rig.target.sendResult = false
        let refused = try XCTUnwrap(rig.controller.snapshot(entryId: "s-1"))
        XCTAssertEqual(rig.controller.insert(refused, event: nil, control: NSView()), .refused(.notSent))
        XCTAssertNil(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1")).reason, "a refusal by the terminal does not disable the row")

        rig.target.sendResult = true
        let again = try XCTUnwrap(rig.controller.snapshot(entryId: "s-1"))
        XCTAssertEqual(rig.controller.insert(again, event: nil, control: NSView()), .inserted(bytes: 6))

        XCTAssertEqual(rig.target.sent, [Array("ls -la".utf8)], "placed exactly once")
        XCTAssertEqual(rig.target.focusCount, 1)
        XCTAssertEqual(rig.stagingFrames,
                       [.stagingInserted(terminalId: StagingFixtures.terminalId, entryId: "s-1", bytes: 6, confirmed: false)],
                       "reported once, for the placement that happened")
        XCTAssertEqual(rig.log.entries, ["send-refused", "send", "focus", "report:terminal_staging_inserted"])
    }

    func testAClickOnARowWhoseTerminalDoesNotTakeTheBytesEndsInANotSentRefusal() {
        let (rig, window, row) = readyRow()
        rig.target.sendResult = false

        rig.click(row, in: window)

        XCTAssertEqual(rig.rowResults, [.refused(.notSent)])
        XCTAssertTrue(rig.target.sent.isEmpty)
        XCTAssertEqual(rig.target.focusCount, 0)
        XCTAssertTrue(rig.insertedFrames.isEmpty)
        XCTAssertTrue(rig.refusals.isEmpty, "the person did click: this is not a non-human refusal")
    }

    func testAnAcceptedPlacementIsStillReportedAsPlacedExactlyOnce() throws {
        let rig = makeRig()
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls -la")])
        rig.settle()

        let snapshot = try XCTUnwrap(rig.controller.snapshot(entryId: "s-1"))
        XCTAssertEqual(rig.controller.insert(snapshot, event: nil, control: NSView()), .inserted(bytes: 6))

        XCTAssertEqual(rig.target.attempts, [Array("ls -la".utf8)])
        XCTAssertEqual(rig.target.focusCount, 1)
        XCTAssertEqual(rig.insertedFrames.count, 1)
        XCTAssertEqual(rig.log.entries, ["send", "focus", "report:terminal_staging_inserted"])
    }

    // MARK: - Defence in depth: the controller re-checks what the snapshot says

    func testATextTheAppWillNotInsertIsRefusedEvenIfASnapshotSaysItIsFine() {
        let rig = makeRig()
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls")])
        rig.settle()
        for bad in ["ls\nrm -rf x", "ls\r", "ls\u{1B}[31m", "", "ls\u{202E}", String(repeating: "a", count: 1_001)] {
            let snapshot = StagingSnapshot(terminalId: StagingFixtures.terminalId, entryId: "s-1", command: bad, reason: nil)
            XCTAssertEqual(rig.controller.insert(snapshot, event: nil, control: NSView()), .refused(.notInsertable), bad.debugDescription)
        }
        assertNothingPlaced(rig)
    }

    func testASnapshotOfAnotherTerminalOrAMissingEntryInsertsNothing() {
        let rig = makeRig()
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls")])
        rig.settle()
        let other = StagingSnapshot(terminalId: "another-terminal", entryId: "s-1", command: "ls", reason: nil)
        let missing = StagingSnapshot(terminalId: StagingFixtures.terminalId, entryId: "s-404", command: "ls", reason: nil)
        XCTAssertEqual(rig.controller.insert(other, event: nil, control: NSView()), .gone)
        XCTAssertEqual(rig.controller.insert(missing, event: nil, control: NSView()), .gone)
        assertNothingPlaced(rig)
    }

    func testACommandIsNotPlacedInARemoteTerminalWhoseLineMayHaveTextEvenWithAHandBuiltSnapshot() {
        // S2 inverts the S1 rule (`.notLocal`): a remote pane is live, but a terminal this app did not open (its
        // line is unknown, which counts as text) refuses until the first Enter.
        for kind in [TerminalKind.ecs, .unknown] {
            let rig = makeRig(kind: kind)
            rig.ingest([StagingFixtures.entry("s-1", 1, "ls")])
            rig.settle()
            let snapshot = StagingSnapshot(terminalId: StagingFixtures.terminalId, entryId: "s-1", command: "ls", reason: nil)
            XCTAssertEqual(rig.controller.insert(snapshot, event: nil, control: NSView()), .refused(.lineMayHaveText), "\(kind)")
            assertNothingPlaced(rig)
        }
    }

    func testWithNoTerminalTheControllerHasNothingToDo() {
        let rig = makeRig()
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls")])
        rig.settle()
        rig.context = nil

        XCTAssertNil(rig.controller.terminalId)
        XCTAssertNil(rig.controller.environment())
        XCTAssertNil(rig.controller.snapshot(entryId: "s-1"))
        XCTAssertEqual(rig.controller.remove(entryId: "s-1", event: nil, control: NSView()), .gone)
        XCTAssertEqual(rig.controller.clearAll(event: nil, control: NSView()), .gone)
        XCTAssertFalse(rig.controller.copy(entryId: "s-1", event: nil, control: NSView()))
        rig.controller.refuseClick()
        assertNothingPlaced(rig)
        XCTAssertTrue(rig.stagingFrames.isEmpty)
        XCTAssertTrue(rig.sessionFrames.isEmpty)
    }

    // MARK: - SB-3: only a person's single left click

    func testAMarkedAppControlClickInsertsNothingAndIsReportedAsAStageInsertRefusal() throws {
        let (rig, window, row) = readyRow()
        rig.mouseDown(row, in: window)
        let up = try StagingEvents.marked(StagingEvents.mouse(.leftMouseUp, in: window, at: StagingRig.point(in: row)))
        row.mouseUp(with: up)

        XCTAssertEqual(rig.rowResults, [.notAPerson])
        assertNothingPlaced(rig)
        XCTAssertEqual(rig.refusals, [.stageInsert])
    }

    func testAStaleEventInsertsNothingAndIsReported() {
        let (rig, window, row) = readyRow()
        rig.mouseDown(row, in: window)
        let stale = ProcessInfo.processInfo.systemUptime - 5
        row.mouseUp(with: StagingEvents.mouse(.leftMouseUp, in: window, at: StagingRig.point(in: row), timestamp: stale))

        XCTAssertEqual(rig.rowResults, [.notAPerson])
        assertNothingPlaced(rig)
        XCTAssertEqual(rig.refusals, [.stageInsert])
    }

    func testAnEventStampedInTheFutureInsertsNothing() {
        let (rig, window, row) = readyRow()
        rig.mouseDown(row, in: window)
        let future = ProcessInfo.processInfo.systemUptime + 5
        row.mouseUp(with: StagingEvents.mouse(.leftMouseUp, in: window, at: StagingRig.point(in: row), timestamp: future))

        XCTAssertEqual(rig.rowResults, [.notAPerson])
        assertNothingPlaced(rig)
    }

    func testNoEventWithVoiceOverOffInsertsNothingAndIsReported() throws {
        let (rig, _, row) = readyRow(voiceOver: false)
        let snapshot = try XCTUnwrap(rig.controller.snapshot(entryId: "s-1"))

        XCTAssertEqual(rig.controller.insert(snapshot, event: nil, control: row), .notAPerson,
                       "an Accessibility press from another process")
        assertNothingPlaced(rig)
        XCTAssertEqual(rig.refusals, [.stageInsert])
    }

    func testNoEventWithVoiceOverOnIsVoiceOversOwnPressAndInserts() throws {
        let (rig, _, row) = readyRow(voiceOver: true)
        let snapshot = try XCTUnwrap(rig.controller.snapshot(entryId: "s-1"))

        XCTAssertEqual(rig.controller.insert(snapshot, event: nil, control: row), .inserted(bytes: 6))
        XCTAssertEqual(rig.target.sent, [Array("ls -la".utf8)])
        XCTAssertEqual(rig.insertedFrames.count, 1)
        XCTAssertTrue(rig.refusals.isEmpty)
    }

    func testAMarkedEventIsRefusedEvenWithVoiceOverOn() throws {
        let (rig, window, row) = readyRow(voiceOver: true)
        let snapshot = try XCTUnwrap(rig.controller.snapshot(entryId: "s-1"))
        let marked = try StagingEvents.marked(StagingEvents.mouse(.leftMouseUp, in: window, at: StagingRig.point(in: row)))

        XCTAssertEqual(rig.controller.insert(snapshot, event: marked, control: row), .notAPerson)
        assertNothingPlaced(rig)
    }

    func testAnEventFromAnotherWindowInsertsNothing() {
        let (rig, window, row) = readyRow()
        let other = rig.makeWindow()
        rig.mouseDown(row, in: window)
        row.mouseUp(with: StagingEvents.mouse(.leftMouseUp, in: other, at: StagingRig.point(in: row)))

        XCTAssertEqual(rig.rowResults, [.notAPerson])
        assertNothingPlaced(rig)
        XCTAssertEqual(rig.refusals, [.stageInsert])
    }

    func testAKeyDownThatIsNotInTheRowsWindowInsertsNothing() throws {
        let (rig, _, row) = readyRow()
        let other = rig.makeWindow()
        let snapshot = try XCTUnwrap(rig.controller.snapshot(entryId: "s-1"))

        XCTAssertEqual(rig.controller.insert(snapshot, event: StagingEvents.space(in: other), control: row), .notAPerson)
        assertNothingPlaced(rig)
    }

    func testAControlClickInsertsNothingAndIsReported() {
        let (rig, window, row) = readyRow()
        rig.mouseDown(row, in: window, modifiers: [.control])
        rig.mouseUp(row, in: window)

        assertNothingPlaced(rig)
        XCTAssertTrue(rig.rowResults.isEmpty, "a click that can never insert gives no result")
        XCTAssertEqual(rig.refusals, [.stageInsert])
    }

    func testTheSecondClickOfADoubleClickInsertsNothingAndIsReportedButTheFirstInserted() {
        let (rig, window, row) = readyRow()
        rig.click(row, in: window)
        XCTAssertEqual(rig.target.sent.count, 1, "the first click of a double-click is an ordinary click")

        rig.mouseDown(row, in: window, clickCount: 2)
        rig.mouseUp(row, in: window, clickCount: 2)

        XCTAssertEqual(rig.target.sent.count, 1, "the second click must not place the command again")
        XCTAssertEqual(rig.insertedFrames.count, 1)
        XCTAssertEqual(rig.refusals, [.stageInsert])
    }

    func testARefusalIsReportedAtMostOncePerSecondPerKind() {
        let (rig, window, row) = readyRow()
        for _ in 0..<3 {
            rig.mouseDown(row, in: window, clickCount: 2)
        }
        XCTAssertEqual(rig.refusals, [.stageInsert], "three refusals within a second are one report")

        rig.advanceSession(2)
        rig.mouseDown(row, in: window, clickCount: 2)
        XCTAssertEqual(rig.refusals, [.stageInsert, .stageInsert])
    }

    func testAMouseUpOutsideTheRowInsertsNothing() {
        let (rig, window, row) = readyRow()
        rig.mouseDown(row, in: window)
        let outside = row.convert(NSPoint(x: row.bounds.width + 50, y: 8), to: nil)
        row.mouseUp(with: StagingEvents.mouse(.leftMouseUp, in: window, at: outside))

        assertNothingPlaced(rig)
        XCTAssertTrue(rig.rowResults.isEmpty)
    }

    func testAMouseUpWithoutAMouseDownOnTheRowInsertsNothing() {
        let (rig, window, row) = readyRow()
        rig.mouseUp(row, in: window)

        assertNothingPlaced(rig)
        XCTAssertTrue(rig.rowResults.isEmpty)
    }

    func testAnOrdinaryFreshClickInsertsWithTheRealGuard() {
        let (rig, window, row) = readyRow()
        rig.click(row, in: window)

        XCTAssertEqual(rig.rowResults, [.inserted(bytes: 6)])
        XCTAssertEqual(rig.target.sent, [Array("ls -la".utf8)])
        XCTAssertEqual(rig.log.entries, ["send", "focus", "report:terminal_staging_inserted"])
        XCTAssertTrue(rig.refusals.isEmpty)
    }

    // MARK: - Space and VoiceOver's press, through the row

    func testSpaceOnARowInsertsOnlyForAHumanKeyEvent() throws {
        let (rig, window, row) = readyRow()

        let marked = try StagingEvents.marked(StagingEvents.space(in: window))
        XCTAssertEqual(row.activate(with: marked), .notAPerson)
        assertNothingPlaced(rig, "a marked Space")
        XCTAssertEqual(rig.refusals, [.stageInsert])

        XCTAssertEqual(row.activate(with: StagingEvents.space(in: window)), .inserted(bytes: 6))
        XCTAssertEqual(rig.target.sent, [Array("ls -la".utf8)])
    }

    func testActivatingARowWithNoEventFollowsTheVoiceOverRule() {
        let off = readyRow(voiceOver: false)
        XCTAssertEqual(off.row.activate(with: nil), .notAPerson)
        assertNothingPlaced(off.rig, "no event, VoiceOver off")

        let on = readyRow(voiceOver: true)
        XCTAssertEqual(on.row.activate(with: nil), .inserted(bytes: 6))
        XCTAssertEqual(on.rig.target.sent, [Array("ls -la".utf8)])
    }

    func testAccessibilityPressInsertsOnlyWhenTheGateAllows() {
        let allowed = makeRig(gate: StagingGates.allowAll)
        allowed.ingest([StagingFixtures.entry("s-1", 1, "ls")])
        allowed.settle()
        let allowedRow = allowed.makeRow(in: allowed.makeWindow())
        XCTAssertTrue(allowedRow.accessibilityPerformPress())
        XCTAssertEqual(allowed.target.sent, [Array("ls".utf8)])

        let refused = makeRig(gate: StagingGates.refuseAll)
        refused.ingest([StagingFixtures.entry("s-1", 1, "ls")])
        refused.settle()
        let refusedRow = refused.makeRow(in: refused.makeWindow())
        _ = refusedRow.accessibilityPerformPress()
        assertNothingPlaced(refused, "a refused accessibility press")
        XCTAssertEqual(refused.refusals, [.stageInsert])
    }

    // MARK: - SB-4: what is inserted is what was on screen at the mouse-down

    func testAReplaceBetweenMouseDownAndMouseUpInsertsTheOriginalText() {
        let (rig, window, row) = readyRow(command: "echo original")
        rig.mouseDown(row, in: window)

        rig.ingest([StagingFixtures.entry("s-1", 1, "rm -rf the-replacement")])
        rig.mouseUp(row, in: window)

        XCTAssertEqual(rig.target.sent, [Array("echo original".utf8)], "the text the person clicked on")
        XCTAssertEqual(rig.stagingFrames,
                       [.stagingInserted(terminalId: StagingFixtures.terminalId, entryId: "s-1", bytes: 13, confirmed: false)])
    }

    func testAnEntryChangedLessThanOneAndAHalfSecondsBeforeTheMouseDownInsertsNothing() {
        let (rig, window, row) = readyRow(command: "echo first")
        rig.ingest([StagingFixtures.entry("s-1", 1, "echo second")])
        rig.settle(1.0)
        let fresh = rig.makeRow(in: window)

        rig.click(fresh, in: window)

        assertNothingPlaced(rig)
        XCTAssertEqual(rig.rowResults, [.refused(.justChanged)])
        XCTAssertEqual(StagingDisabledReason.justChanged.text, "Just changed: read it again")
        _ = row
    }

    func testAnEntryChangedExactlyOneAndAHalfSecondsAgoMayBeInserted() throws {
        let rig = makeRig()
        rig.ingest([StagingFixtures.entry("s-1", 1, "echo first")])
        rig.settle(1.5)

        let snapshot = try XCTUnwrap(rig.controller.snapshot(entryId: "s-1"))
        XCTAssertNil(snapshot.reason)
        XCTAssertEqual(rig.controller.insert(snapshot, event: nil, control: NSView()), .inserted(bytes: 10))
    }

    func testAnEntryRemovedBetweenMouseDownAndMouseUpInsertsNothing() {
        let (rig, window, row) = readyRow()
        rig.mouseDown(row, in: window)

        rig.ingest([])
        rig.mouseUp(row, in: window)

        assertNothingPlaced(rig)
        XCTAssertEqual(rig.rowResults, [.gone])
    }

    func testAListThatDisappearsBetweenMouseDownAndMouseUpInsertsNothing() {
        let (rig, window, row) = readyRow()
        rig.mouseDown(row, in: window)

        rig.ingest([], state: .none)
        rig.mouseUp(row, in: window)

        assertNothingPlaced(rig)
        XCTAssertEqual(rig.rowResults, [.gone])
    }

    func testAnEntryThatChangedOnlyTheNoteStillCountsAsJustChanged() throws {
        let rig = makeRig()
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls")])
        rig.settle()
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls", note: "a new note")])

        XCTAssertEqual(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1")).reason, .justChanged)
    }

    // MARK: - SB-5: every disabled reason sends nothing, by click and by Space

    private func assertDisabled(_ expected: StagingDisabledReason, kind: TerminalKind? = .local,
                                status: TerminalStatus? = .running, isMirror: Bool = false, settle: Bool = true,
                                prepare: (StagingRig) -> Void = { _ in },
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let (rig, window, row) = readyRow(kind: kind, status: status, isMirror: isMirror, settle: settle)
        prepare(rig)
        // The row was drawn before `prepare`: draw it again as the drawer would.
        let fresh = rig.makeRow(in: window)
        row.removeFromSuperview()

        XCTAssertEqual(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1"), file: file, line: line).reason, expected, file: file, line: line)
        XCTAssertEqual(fresh.model.disabledReason, expected, "the row says why", file: file, line: line)

        rig.click(fresh, in: window)
        XCTAssertEqual(rig.rowResults, [.refused(expected)], "click", file: file, line: line)
        assertNothingPlaced(rig, "click", file: file, line: line)

        XCTAssertEqual(fresh.activate(with: StagingEvents.space(in: window)), .refused(expected), "Space", file: file, line: line)
        assertNothingPlaced(rig, "Space", file: file, line: line)
        XCTAssertTrue(rig.refusals.isEmpty, "a refused-by-state click is not a non-human refusal", file: file, line: line)
    }

    func testAMirrorWindowInsertsNothing() throws {
        try assertDisabled(.mirror, isMirror: true)
    }

    func testAnUnreachableDaemonInsertsNothing() throws {
        try assertDisabled(.daemonDisconnected, prepare: { $0.loseDaemon() })
    }

    func testAConnectingShellInsertsNothing() throws {
        try assertDisabled(.connecting, status: .connecting)
    }

    func testAShellWithAnUnknownOrMissingStatusCountsAsStillConnecting() throws {
        try assertDisabled(.connecting, status: .unknown)
        try assertDisabled(.connecting, status: nil)
    }

    func testAnEndedShellInsertsNothing() throws {
        try assertDisabled(.ended, status: .ended)
    }

    func testARemoteUnknownOrUnidentifiedTerminalWithAnUnknownLineInsertsNothingUntilAnEnter() throws {
        try assertDisabled(.lineMayHaveText, kind: .ecs)
        try assertDisabled(.lineMayHaveText, kind: .unknown)
        try assertDisabled(.lineMayHaveText, kind: nil)
    }

    func testAFullScreenProgramInsertsNothing() throws {
        try assertDisabled(.alternateScreen, prepare: { $0.target.isAlternateScreen = true })
    }

    func testAPasteStillGoingOutInsertsNothingUntilItIsSent() throws {
        try assertDisabled(.sendingPaste, prepare: { $0.sendBacklog() })

        let rig = makeRig()
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls")])
        rig.settle()
        rig.sendBacklog()
        XCTAssertEqual(rig.controller.environment()?.isSendingInput, true)
        rig.drainBacklog()
        XCTAssertEqual(rig.controller.environment()?.isSendingInput, false)
        XCTAssertNil(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1")).reason, "the paste is out: the entry may be placed")
    }

    func testAnEntryJustChangedInsertsNothing() throws {
        try assertDisabled(.justChanged, settle: false)
    }

    func testATextTheAppWillNotInsertShowsAndInsertsNothing() throws {
        let rig = makeRig(gate: StagingGates.real())
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls\u{09}-la")])
        rig.settle()
        let window = rig.makeWindow()
        let row = rig.makeRow(in: window)

        XCTAssertEqual(row.model.disabledReason, .notInsertable)
        rig.click(row, in: window)
        XCTAssertEqual(row.activate(with: StagingEvents.space(in: window)), .refused(.notInsertable))
        assertNothingPlaced(rig)
    }

    func testTheReasonsAreCheckedInThePriorityOrderWhenSeveralApply() throws {
        let rig = makeRig(kind: .ecs, status: .ended, isMirror: true)
        rig.target.isAlternateScreen = true
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls\u{09}")])
        XCTAssertEqual(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1")).reason, .mirror)

        rig.context?.isMirror = false
        XCTAssertEqual(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1")).reason, .ended)
        rig.context?.status = .running
        XCTAssertEqual(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1")).reason, .alternateScreen)
        rig.target.isAlternateScreen = false
        XCTAssertEqual(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1")).reason, .lineMayHaveText)
        rig.context?.kind = .local
        XCTAssertEqual(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1")).reason, .justChanged)
        rig.settle()
        XCTAssertEqual(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1")).reason, .notInsertable)
    }

    // MARK: - SB-5: the state is checked again at the mouse-up

    private func assertTurnsBadBetweenDownAndUp(_ expected: StagingDisabledReason, turn: (StagingRig) -> Void,
                                                file: StaticString = #filePath, line: UInt = #line) {
        let (rig, window, row) = readyRow()
        rig.mouseDown(row, in: window)
        XCTAssertNil(rig.controller.snapshot(entryId: "s-1")?.reason, "fine at the mouse-down", file: file, line: line)

        turn(rig)
        rig.mouseUp(row, in: window)

        XCTAssertEqual(rig.rowResults, [.refused(expected)], file: file, line: line)
        assertNothingPlaced(rig, file: file, line: line)
    }

    func testAFullScreenProgramThatStartsBetweenMouseDownAndMouseUpInsertsNothing() {
        assertTurnsBadBetweenDownAndUp(.alternateScreen) { $0.target.isAlternateScreen = true }
    }

    func testTheWindowBecomingAMirrorBetweenMouseDownAndMouseUpInsertsNothing() {
        assertTurnsBadBetweenDownAndUp(.mirror) { $0.context?.isMirror = true }
    }

    func testTheShellEndingBetweenMouseDownAndMouseUpInsertsNothing() {
        assertTurnsBadBetweenDownAndUp(.ended) { $0.context?.status = .ended }
    }

    func testThePaneBecomingRemoteBetweenMouseDownAndMouseUpInsertsNothing() {
        assertTurnsBadBetweenDownAndUp(.lineMayHaveText) { $0.context?.kind = .ecs }
    }

    func testAPasteStartingBetweenMouseDownAndMouseUpInsertsNothing() {
        assertTurnsBadBetweenDownAndUp(.sendingPaste) { $0.sendBacklog() }
    }

    func testTheDaemonDroppingBetweenMouseDownAndMouseUpInsertsNothing() {
        assertTurnsBadBetweenDownAndUp(.daemonDisconnected) { $0.loseDaemon() }
    }

    // MARK: - Copy

    func testCopyPutsExactlyTheCommandOnThePasteboardForEveryGoldenCommand() throws {
        for command in try StagingFixtures.commands() {
            let rig = makeRig()
            rig.ingest([StagingFixtures.entry("s-1", 1, command)])
            rig.settle()   // Copy waits out the reading delay too
            XCTAssertTrue(rig.controller.copy(entryId: "s-1", event: nil, control: NSView()), command)
            XCTAssertEqual(rig.pasteboard.string(forType: .string), command)
            XCTAssertEqual(rig.pasteboard.pasteboardItems?.count, 1, "nothing else is put on the pasteboard")
            assertNothingPlaced(rig, "Copy places nothing at the prompt")
        }
    }

    func testCopyWorksFromAMirrorWindow() {
        let rig = makeRig(isMirror: true)
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls -la")])
        rig.settle()
        XCTAssertTrue(rig.controller.copy(entryId: "s-1", event: nil, control: NSView()))
        XCTAssertEqual(rig.pasteboard.string(forType: .string), "ls -la")
    }

    func testCopyOfAMissingEntryCopiesNothing() {
        let rig = makeRig()
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls -la")])
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("sentinel", forType: .string)

        XCTAssertFalse(rig.controller.copy(entryId: "s-404", event: nil, control: NSView()))
        XCTAssertEqual(rig.pasteboard.string(forType: .string), "sentinel")
    }

    func testCopyRefusesNonHumanEventsLeavesThePasteboardAloneAndReportsStagingCopy() throws {
        let rig = makeRig(gate: StagingGates.real())
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls -la")])
        rig.settle()   // so the gate is the only thing that can refuse
        let window = rig.makeWindow()
        let control = GestureFixtures.control(in: window)
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("sentinel", forType: .string)

        let marked = try StagingEvents.marked(StagingEvents.mouse(.leftMouseUp, in: window, at: NSPoint(x: 30, y: 30)))
        XCTAssertFalse(rig.controller.copy(entryId: "s-1", event: marked, control: control))
        rig.advanceSession()
        XCTAssertFalse(rig.controller.copy(entryId: "s-1", event: nil, control: control), "no event, VoiceOver off")
        rig.advanceSession()
        let stale = StagingEvents.mouse(.leftMouseUp, in: window, at: NSPoint(x: 30, y: 30),
                                        timestamp: ProcessInfo.processInfo.systemUptime - 5)
        XCTAssertFalse(rig.controller.copy(entryId: "s-1", event: stale, control: control))

        XCTAssertEqual(rig.pasteboard.string(forType: .string), "sentinel")
        XCTAssertEqual(rig.refusals, [.stagingCopy, .stagingCopy, .stagingCopy])
    }

    func testAMenuSelectionIsPermittedToCopyEvenThoughItsMouseEventBelongsToTheMenu() {
        let rig = makeRig(gate: StagingGates.real())
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls -la")])
        rig.settle()
        let window = rig.makeWindow()
        let menuWindow = rig.makeWindow()
        let control = GestureFixtures.control(in: window)

        let fromMenu = StagingEvents.mouse(.leftMouseUp, in: menuWindow, at: NSPoint(x: 5, y: 5))
        XCTAssertTrue(rig.controller.copy(entryId: "s-1", event: fromMenu, control: control))
        XCTAssertEqual(rig.pasteboard.string(forType: .string), "ls -la")
        XCTAssertTrue(rig.refusals.isEmpty)
    }

    // MARK: - Copy waits out the reading delay, and only that

    func testCopyOfAnEntryShownLessThanOneAndAHalfSecondsAgoCopiesNothingAndLeavesThePasteboardAlone() {
        let rig = makeRig()
        rig.ingest([StagingFixtures.entry("s-1", 1, "echo just-arrived")])
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("sentinel", forType: .string)

        XCTAssertFalse(rig.controller.isReadable(entryId: "s-1"))
        XCTAssertFalse(rig.controller.copy(entryId: "s-1", event: nil, control: NSView()), "no time at all")
        rig.settle(1.0)
        XCTAssertFalse(rig.controller.isReadable(entryId: "s-1"))
        XCTAssertFalse(rig.controller.copy(entryId: "s-1", event: nil, control: NSView()), "one second")

        XCTAssertEqual(rig.pasteboard.string(forType: .string), "sentinel", "an unread command is never put on the pasteboard")
        assertNothingPlaced(rig, "Copy places nothing at the prompt")
    }

    func testCopyWorksExactlyOneAndAHalfSecondsAfterTheTextFirstAppeared() {
        let rig = makeRig()
        rig.ingest([StagingFixtures.entry("s-1", 1, "echo read-me")])
        rig.settle(1.0)
        rig.settle(0.5)

        XCTAssertTrue(rig.controller.isReadable(entryId: "s-1"))
        XCTAssertTrue(rig.controller.copy(entryId: "s-1", event: nil, control: NSView()))
        XCTAssertEqual(rig.pasteboard.string(forType: .string), "echo read-me")
    }

    func testCopyOfAChangedCommandWaitsAgainAndTheOldTextIsNotWhatIsCopied() {
        let rig = makeRig()
        rig.ingest([StagingFixtures.entry("s-1", 1, "echo first")])
        rig.settle()
        XCTAssertTrue(rig.controller.copy(entryId: "s-1", event: nil, control: NSView()))
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("sentinel", forType: .string)

        rig.ingest([StagingFixtures.entry("s-1", 1, "echo second")])

        XCTAssertFalse(rig.controller.isReadable(entryId: "s-1"))
        XCTAssertFalse(rig.controller.copy(entryId: "s-1", event: nil, control: NSView()), "the new text has not been readable yet")
        XCTAssertEqual(rig.pasteboard.string(forType: .string), "sentinel")

        rig.settle()
        XCTAssertTrue(rig.controller.copy(entryId: "s-1", event: nil, control: NSView()))
        XCTAssertEqual(rig.pasteboard.string(forType: .string), "echo second")
    }

    func testAChangeToAnotherEntryAlsoMakesEveryEntryWaitBeforeItCanBeCopied() {
        let rig = makeRig()
        rig.ingest(StagingFixtures.entries(["ls", "pwd"]))
        rig.settle()
        XCTAssertTrue(rig.controller.isReadable(entryId: "s-1"))

        rig.ingest(StagingFixtures.entries(["ls", "pwd --changed"]))   // the rows below or above may have moved

        XCTAssertFalse(rig.controller.isReadable(entryId: "s-1"), "an entry that did not change waits too")
        XCTAssertFalse(rig.controller.copy(entryId: "s-1", event: nil, control: NSView()))
        rig.settle()
        XCTAssertTrue(rig.controller.copy(entryId: "s-1", event: nil, control: NSView()))
    }

    /// Copy is not a placement: whatever else disables a row, Copy still works once its text has been readable.
    func testCopyStillWorksAfterTheDelayOnARowThatIsDisabledForAnotherReason() throws {
        let cases: [(name: String, command: String, isMirror: Bool, alternateScreen: Bool, expected: StagingDisabledReason)] = [
            ("a mirror window", "ls -la", true, false, .mirror),
            ("a full-screen program", "ls -la", false, true, .alternateScreen),
            ("a text the app will not insert", "ls\u{09}-la", false, false, .notInsertable),
        ]
        for c in cases {
            let rig = makeRig(isMirror: c.isMirror)
            rig.target.isAlternateScreen = c.alternateScreen
            rig.ingest([StagingFixtures.entry("s-1", 1, c.command)])
            rig.settle()
            XCTAssertEqual(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1")).reason, c.expected, "harness: \(c.name) disables the row")

            XCTAssertTrue(rig.controller.copy(entryId: "s-1", event: nil, control: NSView()), c.name)
            XCTAssertEqual(rig.pasteboard.string(forType: .string), c.command, c.name)
            assertNothingPlaced(rig, c.name)
        }
    }

    // MARK: - Remove and Clear all

    func testRemoveFromTheDriverSendsTheRemoveFrameAndNoBytes() {
        let rig = makeRig()
        rig.ingest(StagingFixtures.entries(["ls", "pwd"]))

        XCTAssertEqual(rig.controller.remove(entryId: "s-2", event: nil, control: NSView()), .done)
        XCTAssertEqual(rig.stagingFrames, [.stagingRemove(terminalId: StagingFixtures.terminalId, entryId: "s-2")])
        XCTAssertTrue(rig.target.sent.isEmpty)
    }

    func testClearAllFromTheDriverSendsTheClearFrameAndNoBytes() {
        let rig = makeRig()
        rig.ingest(StagingFixtures.entries(["ls", "pwd"]))

        XCTAssertEqual(rig.controller.clearAll(event: nil, control: NSView()), .done)
        XCTAssertEqual(rig.stagingFrames, [.stagingClear(terminalId: StagingFixtures.terminalId)])
        XCTAssertTrue(rig.target.sent.isEmpty)
    }

    func testRemoveAndClearAllFromAMirrorSendNothing() {
        let rig = makeRig(isMirror: true)
        rig.ingest(StagingFixtures.entries(["ls", "pwd"]))

        XCTAssertEqual(rig.controller.remove(entryId: "s-1", event: nil, control: NSView()), .refused(.mirror))
        XCTAssertEqual(rig.controller.clearAll(event: nil, control: NSView()), .refused(.mirror))
        XCTAssertTrue(rig.stagingFrames.isEmpty)
        XCTAssertTrue(rig.sessionFrames.isEmpty)
        XCTAssertTrue(rig.target.sent.isEmpty)
    }

    func testRemovingAnEntryThatIsGoneOrClearingAGoneListSendsNothing() {
        let rig = makeRig()
        rig.ingest(StagingFixtures.entries(["ls"]))
        XCTAssertEqual(rig.controller.remove(entryId: "s-404", event: nil, control: NSView()), .gone)
        rig.ingest([], state: .none)
        XCTAssertEqual(rig.controller.clearAll(event: nil, control: NSView()), .gone)
        XCTAssertTrue(rig.stagingFrames.isEmpty)
    }

    func testRemoveAndClearAllRefuseNonHumanEventsAndReportTheirOwnOps() throws {
        let rig = makeRig(gate: StagingGates.real())
        rig.ingest(StagingFixtures.entries(["ls", "pwd"]))
        let window = rig.makeWindow()
        let control = GestureFixtures.control(in: window)
        let marked = try StagingEvents.marked(StagingEvents.mouse(.leftMouseUp, in: window, at: NSPoint(x: 30, y: 30)))

        XCTAssertEqual(rig.controller.remove(entryId: "s-1", event: marked, control: control), .notAPerson)
        XCTAssertEqual(rig.controller.clearAll(event: marked, control: control), .notAPerson)
        XCTAssertEqual(rig.controller.remove(entryId: "s-1", event: nil, control: control), .notAPerson, "no event, VoiceOver off")

        XCTAssertTrue(rig.stagingFrames.isEmpty, "a refused Remove or Clear all reaches no daemon")
        XCTAssertEqual(rig.refusals, [.stagingRemove, .stagingClear])
        XCTAssertTrue(rig.target.sent.isEmpty)
    }

    func testRemoveAndClearAllAreAllowedFromARealMenuSelection() {
        let rig = makeRig(gate: StagingGates.real())
        rig.ingest(StagingFixtures.entries(["ls", "pwd"]))
        let window = rig.makeWindow()
        let menuWindow = rig.makeWindow()
        let control = GestureFixtures.control(in: window)
        let fromMenu = StagingEvents.mouse(.leftMouseUp, in: menuWindow, at: NSPoint(x: 5, y: 5))

        XCTAssertEqual(rig.controller.remove(entryId: "s-1", event: fromMenu, control: control), .done)
        XCTAssertEqual(rig.controller.clearAll(event: fromMenu, control: control), .done)
        XCTAssertEqual(rig.stagingFrames, [.stagingRemove(terminalId: StagingFixtures.terminalId, entryId: "s-1"),
                                           .stagingClear(terminalId: StagingFixtures.terminalId)])
    }
}


// MARK: - S2: archive, switches, auto-archive, line state, hazards, UI events

extension StagingInsertControllerTests {

    private func placedEntry(_ id: String, _ number: Int, _ command: String) -> StagingEntry {
        StagingFixtures.entry(id, number, command, insertedCount: 1, lastInsertedAt: StagingFixtures.baseDate)
    }

    private var archiveFrame: (String) -> TerminalClientMessage {
        { .stagingRemove(terminalId: StagingFixtures.terminalId, entryId: $0, archive: "manual") }
    }

    // MARK: Archive

    func testArchivingAPlacedRowSendsTheFrameAndTheRowMovesToTheFooter() {
        let rig = makeRig()
        rig.ingest([placedEntry("s-1", 1, "ls"), StagingFixtures.entry("s-2", 2, "pwd")])
        XCTAssertEqual(rig.controller.archive(entryIds: ["s-1"], event: nil, control: NSView(), fromMenu: false), .done)
        XCTAssertEqual(rig.stagingFrames, [archiveFrame("s-1")])
        XCTAssertEqual(rig.staging.archivedEntries(for: StagingFixtures.terminalId).map(\.entryId), ["s-1"])
        XCTAssertEqual(rig.staging.list(for: StagingFixtures.terminalId)?.entries.map(\.id), ["s-2"])
    }

    func testOnlyAPlacedEntryCanBeArchived() {
        let rig = makeRig()
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls")])
        XCTAssertEqual(rig.controller.archive(entryIds: ["s-1", "s-404"], event: nil, control: NSView(), fromMenu: false), .gone)
        XCTAssertTrue(rig.stagingFrames.isEmpty)
    }

    func testArchivePlacedArchivesOnlyTheCheckedRows() {
        let rig = makeRig()
        rig.ingest([placedEntry("s-1", 1, "ls"), StagingFixtures.entry("s-2", 2, "pwd"), placedEntry("s-3", 3, "date")])
        XCTAssertEqual(rig.controller.archivePlaced(event: nil, control: NSView(), fromMenu: true), .done)
        XCTAssertEqual(rig.stagingFrames, [archiveFrame("s-1"), archiveFrame("s-3")])
        XCTAssertEqual(rig.staging.list(for: StagingFixtures.terminalId)?.entries.map(\.id), ["s-2"])
    }

    func testAMirrorWindowCannotArchive() {
        let rig = makeRig(isMirror: true)
        rig.ingest([placedEntry("s-1", 1, "ls")])
        XCTAssertEqual(rig.controller.archive(entryIds: ["s-1"], event: nil, control: NSView(), fromMenu: false), .refused(.mirror))
        XCTAssertTrue(rig.stagingFrames.isEmpty)
    }

    func testASyntheticEventArchivesNothingAndIsReported() {
        let rig = makeRig(gate: StagingGates.real())
        rig.ingest([placedEntry("s-1", 1, "ls")])
        XCTAssertEqual(rig.controller.archive(entryIds: ["s-1"], event: nil, control: NSView(), fromMenu: true), .notAPerson)
        XCTAssertEqual(rig.controller.archivePlaced(event: nil, control: NSView(), fromMenu: true), .notAPerson)
        XCTAssertTrue(rig.stagingFrames.isEmpty)
        XCTAssertEqual(rig.refusals, [.stagingArchive], "reported (throttled to one a second)")
    }

    // MARK: Switches

    func testTheSwitchesAreGatedAndSendTheirFrames() {
        let id = StagingFixtures.terminalId
        let allowed = makeRig()
        XCTAssertTrue(allowed.controller.setStagingEnabledHere(false, event: nil, control: NSView(), fromMenu: true))
        XCTAssertEqual(allowed.stagingFrames, [.stagingSetEnabled(terminalId: id, enabled: false)])

        let refused = makeRig(gate: StagingGates.real())
        XCTAssertFalse(refused.controller.setStagingEnabledHere(false, event: nil, control: NSView(), fromMenu: true))
        XCTAssertTrue(refused.stagingFrames.isEmpty)
        XCTAssertEqual(refused.refusals, [.stagingSwitch])

        let global = makeRig()
        XCTAssertTrue(StagingInsertController.setGlobalStaging(false, event: nil, control: NSView(), staging: global.staging,
                                                               sessions: global.sessions, gate: StagingGates.allowAll))
        XCTAssertFalse(global.staging.globalEnabled)
        XCTAssertEqual(global.stagingFrames, [.stagingSetGlobal(enabled: false)])
        XCTAssertFalse(StagingInsertController.setGlobalStaging(true, event: nil, control: NSView(), staging: global.staging,
                                                                sessions: global.sessions, gate: StagingGates.refuseAll))
        XCTAssertFalse(global.staging.globalEnabled, "a refused press changes nothing")
    }

    func testTheHideAndReopenControlsAreGated() {
        let rig = makeRig(gate: StagingGates.real())
        XCTAssertFalse(rig.controller.allowsHideControl(event: nil, control: NSView(), fromMenu: false))
        XCTAssertEqual(rig.refusals, [.stagingHide])
        let open = makeRig()
        XCTAssertTrue(open.controller.allowsHideControl(event: nil, control: NSView(), fromMenu: true))
    }

    // MARK: Auto-archive

    func testAutoArchiveIsOffByDefaultAndASyntheticEventCannotTurnItOn() {
        XCTAssertFalse(TerminalStagingStore.autoArchiveEnabled)
        let rig = makeRig(gate: StagingGates.real())
        XCTAssertFalse(rig.controller.setAutoArchive(true, event: nil, control: NSView()))
        XCTAssertFalse(TerminalStagingStore.autoArchiveEnabled)
        XCTAssertEqual(rig.refusals, [.stagingSwitch])
    }

    private func autoArchiveRig() -> (rig: StagingRig, window: NSWindow, row: StagingRowView) {
        let (rig, window, row) = readyRow(command: "ls -la")
        XCTAssertTrue(rig.controller.setAutoArchive(true, event: StagingEvents.mouse(.leftMouseUp, in: window, at: .zero), control: row))
        addTeardownBlock { _ = TerminalStagingStore.setAutoArchive(false) }
        return (rig, window, row)
    }

    func testAutoArchiveArchivesAfterAPersonsEnterForTheIdenticalCommandOnly() {
        let (rig, window, row) = autoArchiveRig()
        rig.click(row, in: window)
        XCTAssertEqual(rig.rowResults, [.inserted(bytes: 6)])
        XCTAssertTrue(rig.stagingFrames.filter { if case .stagingRemove = $0 { return true } else { return false } }.isEmpty,
                      "not before the Enter")
        rig.typeEnter()
        XCTAssertEqual(rig.stagingFrames.last, .stagingRemove(terminalId: StagingFixtures.terminalId, entryId: "s-1", archive: "auto"))
        XCTAssertEqual(rig.staging.archivedEntries(for: StagingFixtures.terminalId).map(\.entryId), ["s-1"])
    }

    func testCtrlUBeforeTheEnterOrAReplaceThatChangedTheCommandDropsTheAutoArchive() {
        let (rig, window, row) = autoArchiveRig()
        rig.click(row, in: window)
        rig.typeEnter([0x15, 0x0D])
        XCTAssertTrue(rig.staging.archivedEntries(for: StagingFixtures.terminalId).isEmpty, "Ctrl-U before the Enter")

        let again = makeRig()
        again.ingest([StagingFixtures.entry("s-1", 1, "ls -la")])
        again.settle()
        let window2 = again.makeWindow()
        let row2 = again.makeRow(in: window2)
        again.click(row2, in: window2)
        again.ingest([StagingFixtures.entry("s-1", 1, "rm -rf /srv")])
        again.typeEnter()
        XCTAssertTrue(again.staging.archivedEntries(for: StagingFixtures.terminalId).isEmpty, "the command was replaced")
    }

    func testWithAutoArchiveOffAnEnterArchivesNothing() {
        let (rig, window, row) = readyRow(command: "ls -la")
        rig.click(row, in: window)
        rig.typeEnter()
        XCTAssertTrue(rig.staging.archivedEntries(for: StagingFixtures.terminalId).isEmpty)
    }

    // MARK: Line state, hazards, foreground

    func testAProductionRowRefusesUntilAnEnterAndAfterEveryPlacementUntilTheNext() {
        let rig = makeRig(gate: StagingGates.real(), kind: .ecs)
        rig.context?.target = StagingFixtures.productionTarget
        rig.ingest([StagingFixtures.entry("s-1", 1, "ls"), StagingFixtures.entry("s-2", 2, "pwd")])
        rig.settle()
        let window = rig.makeWindow()
        let first = rig.makeRow(entryId: "s-1", in: window)

        rig.click(first, in: window)
        XCTAssertEqual(rig.rowResults, [.refused(.lineMayHaveText)], "unknown counts as text")

        rig.typeEnter()
        let fresh = rig.makeRow(entryId: "s-1", in: window)
        rig.click(fresh, in: window)
        XCTAssertEqual(rig.rowResults.last, .inserted(bytes: 2))
        rig.typeEnter(Array("ls".utf8))     // the real terminal view sends the placed bytes through the session store

        let second = rig.makeRow(entryId: "s-2", in: window)
        rig.click(second, in: window)
        XCTAssertEqual(rig.rowResults.last, .refused(.lineMayHaveText), "text may be on the line: the Enter first")
    }

    func testAHandBuiltSnapshotForAHistoryExpansionRowIsRefusedInProduction() {
        let rig = makeRig(kind: .ecs)
        rig.context?.target = StagingFixtures.productionTarget
        rig.typeEnter()
        rig.ingest([StagingFixtures.entry("s-1", 1, "!!")])
        rig.settle()
        let snapshot = StagingSnapshot(terminalId: StagingFixtures.terminalId, entryId: "s-1", command: "!!", reason: nil)
        XCTAssertEqual(rig.controller.insert(snapshot, event: nil, control: NSView()), .refused(.historyExpansion))
        XCTAssertTrue(rig.target.attempts.isEmpty)
    }

    func testALocalPaneWhoseListSaysAProgramIsRunningGetsTheProductionRules() throws {
        let rig = makeRig(kind: .local)
        rig.typeEnter()
        rig.ingest([StagingFixtures.entry("s-1", 1, "!!")], foreground: "ssh")
        rig.settle()
        XCTAssertEqual(rig.controller.environment()?.safety, .localRunning(program: "ssh"))
        XCTAssertEqual(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1")).reason, .historyExpansion)
        rig.ingest([StagingFixtures.entry("s-1", 1, "!!")], foreground: nil)
        rig.settle()
        XCTAssertNil(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1")).reason, "the program ended: a local row again")
    }

    func testAnActivationRefusedByTheReadingDelayIsCountedOncePerSecond() {
        let (rig, window, row) = readyRow(settle: false)
        rig.click(row, in: window)
        rig.click(row, in: window)
        let events = rig.stagingFrames.filter { $0 == .stagingUIEvent(terminalId: StagingFixtures.terminalId, event: "just_changed") }
        XCTAssertEqual(events.count, 1, "throttled to one a second")
        XCTAssertEqual(rig.rowResults, [.refused(.justChanged), .refused(.justChanged)])
    }

    func testRestartingTheReadingDelayMakesAnImmediateClickJustChanged() throws {
        let (rig, window, row) = readyRow()
        XCTAssertNil(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1")).reason)
        rig.staging.restartReadingDelay(terminalId: StagingFixtures.terminalId)
        rig.click(row, in: window)
        XCTAssertEqual(rig.rowResults, [.refused(.justChanged)])
        XCTAssertTrue(rig.target.attempts.isEmpty)
        rig.settle()
        XCTAssertNil(try XCTUnwrap(rig.controller.snapshot(entryId: "s-1")).reason)
    }
}


extension StagingInsertControllerTests {

    func testADrawerMoveBetweenMouseDownAndMouseUpInsertsNothingEvenAfterTheDelayRanOut() {
        let (rig, window, row) = readyRow()
        rig.mouseDown(row, in: window)
        rig.staging.restartReadingDelay(terminalId: StagingFixtures.terminalId)
        rig.settle(5)
        rig.mouseUp(row, in: window)

        XCTAssertEqual(rig.rowResults, [.refused(.justChanged)])
        XCTAssertTrue(rig.target.attempts.isEmpty)
        XCTAssertTrue(rig.insertedFrames.isEmpty)
    }
}
