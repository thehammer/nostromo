import XCTest
import AppKit
import Combine
import NostromoKit

// Shared fixtures for the Perri badge and Merge button tests (AuthoredPrMergeTests,
// AuthoredPrMergeAppearanceTests). No test of its own lives here.
//
// The transport is a recorder: it never answers on its own. A test answers a request when it wants to, so
// "nothing was sent" is assertable and so is "answered later".
//
// Gesture tests need a window with a real window number (an event resolves its window by number), so they use
// `GestureFixtures.offscreenWindow()` from HumanGestureTests.swift and the events built by its fixtures (`HF.human`).

// MARK: - Transport

/// An `AuthoredPrMergeTransport` that records the calls and answers when told. It implements the protocol's two
/// members and nothing else: that it compiles is the proof that the Merge verb has one entry and one request shape.
final class RecordingMergeTransport: AuthoredPrMergeTransport {

    struct Call: Equatable {
        let repo: String
        let number: Int
        let head: String
    }

    /// The daemon advertised `authored_prs_merge_v1` and is connected.
    var isMergeAvailable = true
    private(set) var calls: [Call] = []
    private var waiters: [(AuthoredPrAnswer<AuthoredPrDone>) -> Void] = []

    func merge(repo: String, number: Int, expectedHeadShaShort: String,
               done: @escaping (AuthoredPrAnswer<AuthoredPrDone>) -> Void) {
        calls.append(Call(repo: repo, number: number, head: expectedHeadShaShort))
        waiters.append(done)
    }

    /// Requests that have been sent and not yet answered.
    var unanswered: Int { waiters.count }

    /// Answer the oldest unanswered request.
    func answer(_ answer: AuthoredPrAnswer<AuthoredPrDone>, file: StaticString = #filePath, line: UInt = #line) {
        guard !waiters.isEmpty else { return XCTFail("no merge request is waiting", file: file, line: line) }
        waiters.removeFirst()(answer)
    }
}

// MARK: - Fixtures

enum MF {

    static let repo = "thehammer/nostromo"
    static let headA = "0aaaaaaa"
    static let headB = "0bbbbbbb"

    /// Perri's verdict, five minutes old by default.
    static func verdict(_ verdict: AuthoredPrPerriVerdict = .approved, current: Bool = true, minutesAgo: Int? = 5,
                        by: String? = "perri-1") -> AuthoredPrPerri {
        AuthoredPrPerri(verdict: verdict, at: minutesAgo.map { APT.t0.addingTimeInterval(-Double($0) * 60) },
                        by: by, forCurrentHead: current)
    }

    /// A PR that may be merged: open, in READY, not a draft, green, approved by a human, Perri approved head A.
    static func readyPr(_ number: Int = 458, title: String = "Fix the thing", head: String? = MF.headA,
                        baseRef: String? = "main", group: AuthoredPrGroup = .ready,
                        lifecycle: AuthoredPrLifecycle = .open, draft: Bool = false,
                        checks: AuthoredPrChecks = AuthoredPrChecks(state: .passing, passed: 3),
                        review: AuthoredPrReview = AuthoredPrReview(state: .approved, logins: ["dana"]),
                        perri: AuthoredPrPerri? = MF.verdict(),
                        owner: AuthoredPrOwner = .unknown) -> AuthoredPr {
        var p = APT.pr(number, repo: repo, title: title, group: group, lifecycle: lifecycle, draft: draft,
                       baseRef: baseRef, checks: checks, review: review, owner: owner)
        p.headShaShort = head
        p.perri = perri
        return p
    }

    /// The same PR after a push: a new head, and Perri's approval is for the previous one.
    static func pushed(_ pr: AuthoredPr, to head: String = MF.headB, perriReviewedIt: Bool = false) -> AuthoredPr {
        var p = pr
        p.headShaShort = head
        p.perri = perriReviewedIt ? MF.verdict(.approved, current: true) : MF.verdict(.approved, current: false)
        return p
    }

    /// The row the Overview builds for `pr` (both features on unless told otherwise).
    static func row(_ pr: AuthoredPr, perri: Bool = true, merge: Bool = true,
                    attempt: AuthoredPrMergeAttempt? = nil) -> AuthoredPrRowModel {
        AuthoredPrsPresentation.row(pr, now: APT.t0, perri: perri, merge: merge, mergeAttempt: attempt)
    }

    /// Every way the button is off, with the words that say why. Each has its own number so they can share a snapshot.
    static var unavailableCases: [(name: String, pr: AuthoredPr, reason: String)] {
        let needs = "Needs Perri's review"
        return [
            ("draft", readyPr(601, draft: true), "Draft"),
            ("failing checks", readyPr(602, checks: AuthoredPrChecks(state: .failing, passed: 2, failed: 1, failingNames: ["lint"])),
             "Checks not green"),
            ("pending checks", readyPr(603, checks: AuthoredPrChecks(state: .pending, pending: 1)), "Checks not green"),
            ("no human approval", readyPr(604, review: AuthoredPrReview(state: .none)), "Waiting for human approval"),
            ("changes requested by a human", readyPr(605, review: AuthoredPrReview(state: .changesRequested, logins: ["dana"])),
             "Waiting for human approval"),
            ("no verdict from Perri", readyPr(606, perri: nil), needs),
            ("Perri only commented", readyPr(607, perri: verdict(.comment)), needs),
            ("an approval of an older version", readyPr(608, perri: verdict(.approved, current: false)),
             "Perri approved an older version"),
            ("changes requested by Perri", readyPr(609, perri: verdict(.changesRequested)), "Perri requested changes"),
        ]
    }

    /// What each daemon code must say on the row, by its wire spelling.
    static let answerWords: [(wire: String, words: String)] = [
        ("not_found", "This PR is no longer in your list, so it wasn't merged"),
        ("not_open", "This PR is no longer open, so it wasn't merged"),
        ("draft", "This PR is a draft, so it wasn't merged"),
        ("not_approved", "No human reviewer has approved it, so it wasn't merged"),
        ("checks_not_green", "Checks aren't green, so it wasn't merged"),
        ("not_mergeable", "GitHub says it can't be merged (conflicts?)"),
        ("blocked", "GitHub's branch protection blocked it"),
        ("behind", "The branch is behind its base: update it first"),
        ("head_changed", "The PR changed since you looked: review it again"),
        ("perri_not_approved", "Perri hasn't approved this version"),
        ("perri_stale", "Perri approved an older version: it needs a new review"),
        ("token_cannot_merge", "Your GitHub token cannot merge"),
        ("rate_limited", "GitHub is rate limiting: try again later"),
        ("unreachable", "GitHub or Nostromo isn't reachable: check the PR before trying again"),
        ("busy", "A merge of this PR is already running"),
        ("not_permitted", "Nostromo refused the request"),
        ("not_operator_app", "Nostromo refused the request"),
        ("requires_secure_connection", "Nostromo refused the request"),
        ("a_code_from_the_future", "The merge failed"),
    ]

    static let unreachableWords = "GitHub or Nostromo isn't reachable: check the PR before trying again"

    // MARK: Events

    static func human(in window: NSWindow) -> NSEvent { HF.human(in: window) }

    static func humanReturn(in window: NSWindow) -> NSEvent { HF.humanReturn(in: window) }
}

// MARK: - A merger wired to recorders

/// A real `AuthoredPrMerger` over a recording transport. What it would show is recorded in `shown` instead of
/// opening a popover.
final class MergeRig {
    let transport: RecordingMergeTransport
    let window: NSWindow
    let merger: AuthoredPrMerger
    private(set) var shown: [(session: AuthoredPrMergeSession, anchor: NSView)] = []
    private(set) var dismissals = 0
    /// How many times the merger said its attempts or its confirmation changed.
    private(set) var changeCount = 0
    private var changes: AnyCancellable?

    /// A button in the window, for an entry point that wants a control (made when first used, so a rig whose
    /// window holds an Overview does not grow a stray subview).
    lazy var control: NSButton = HF.control(in: window)

    /// `allowEverything` skips the gesture check (for tests that are not about the gesture). Without it the live
    /// check runs: use `MF.human(in:)` events.
    init(window: NSWindow? = nil, allowEverything: Bool = false) {
        let window = window ?? GestureFixtures.offscreenWindow(size: NSSize(width: 600, height: 400))
        let transport = RecordingMergeTransport()
        let permit: AuthoredPrGesture.Permit = allowEverything ? { _, _, _ in true } : AuthoredPrGesture.live
        let merger = AuthoredPrMerger(transport: transport, permit: permit)
        self.window = window
        self.transport = transport
        self.merger = merger
        merger.present = { [unowned self] session, anchor in self.shown.append((session, anchor)) }
        merger.dismiss = { [unowned self] in self.dismissals += 1 }
        changes = merger.changes.sink { [unowned self] in self.changeCount += 1 }
    }

    func close() {
        changes = nil
        window.contentView = nil
        window.close()
    }

    func allowEverything() { merger.permit = { _, _, _ in true } }

    var session: AuthoredPrMergeSession? { merger.presented }

    /// A person's click on the row's Merge button.
    func activate(_ model: AuthoredPrRowModel, event: NSEvent? = nil) {
        merger.activate(model, anchor: control, event: event ?? MF.human(in: window), control: control)
    }

    /// A person's click on Merge in the confirmation that is up.
    func confirm(file: StaticString = #filePath, line: UInt = #line) {
        guard let session = merger.presented else { return XCTFail("no confirmation is up", file: file, line: line) }
        session.confirm(event: MF.human(in: window), control: control)
    }

    /// Open the confirmation for `pr` and confirm it: the request is sent and waiting for an answer.
    func mergeAndWait(_ pr: AuthoredPr, file: StaticString = #filePath, line: UInt = #line) {
        activate(MF.row(pr))
        confirm(file: file, line: line)
    }
}

// MARK: - An Overview with a merger

/// An Overview (no store) with a merger over a recording transport, in an off-screen window that can take gestures.
final class MergeOverviewRig {
    let window: NSWindow
    let overview: AuthoredPrsOverviewView
    let rig: MergeRig
    let clock: APT.FakeClock
    var transport: RecordingMergeTransport { rig.transport }
    var merger: AuthoredPrMerger { rig.merger }
    var outline: AuthoredPrsOutlineView { overview.outline }

    /// `allowEverything` skips the gesture check; the gesture tests turn it off.
    init(_ prs: [AuthoredPr], perri: Bool = true, merge: Bool = true, allowEverything: Bool = true,
         size: NSSize = NSSize(width: 700, height: 700)) {
        let window = GestureFixtures.offscreenWindow(size: size)
        let rig = MergeRig(window: window, allowEverything: allowEverything)
        let clock = APT.FakeClock()
        let overview = AuthoredPrsOverviewView(clock: clock.read, timeZone: APT.utc, store: nil)
        self.clock = clock
        self.window = window
        self.rig = rig
        self.overview = overview
        window.contentView = overview
        overview.layoutSubtreeIfNeeded()
        overview.merger = rig.merger
        overview.setPerriAvailable(perri)
        overview.setMergeAvailable(merge)
        overview.apply(snapshot: APT.snapshot(prs), connection: .connected)
        overview.layoutSubtreeIfNeeded()
    }

    func close() {
        rig.close()
    }

    /// A new snapshot arrives from the daemon.
    func apply(_ prs: [AuthoredPr]) {
        overview.apply(snapshot: APT.snapshot(prs), connection: .connected)
        overview.layoutSubtreeIfNeeded()
    }

    func rowView(_ pr: AuthoredPr, file: StaticString = #filePath, line: UInt = #line) throws -> AuthoredPrRowView {
        try XCTUnwrap(overview.rowView(forRowId: pr.id), "row \(pr.id) is on screen", file: file, line: line)
    }

    /// Press the row's Merge button as a click would (the action runs; the gesture check sees `NSApp.currentEvent`).
    func press(_ pr: AuthoredPr, file: StaticString = #filePath, line: UInt = #line) throws {
        try rowView(pr, file: file, line: line).mergeButton.performClick(nil)
    }

    /// A person's click on Merge in the confirmation that is up.
    func confirm(file: StaticString = #filePath, line: UInt = #line) {
        guard let session = merger.presented else { return XCTFail("no confirmation is up", file: file, line: line) }
        session.confirm(event: MF.human(in: window), control: overview.outline)
        overview.layoutSubtreeIfNeeded()
    }

    /// The daemon answers the oldest merge request.
    func answer(_ answer: AuthoredPrAnswer<AuthoredPrDone>, file: StaticString = #filePath, line: UInt = #line) {
        transport.answer(answer, file: file, line: line)
        overview.layoutSubtreeIfNeeded()
    }

    /// Press, confirm and leave the request waiting for the daemon's answer.
    func mergeAndWait(_ pr: AuthoredPr, file: StaticString = #filePath, line: UInt = #line) throws {
        try press(pr, file: file, line: line)
        confirm(file: file, line: line)
    }

    /// The rows' Merge button state as the person sees it.
    func buttonTitle(_ pr: AuthoredPr) throws -> String { try rowView(pr).mergeButton.title }
    func buttonIsEnabled(_ pr: AuthoredPr) throws -> Bool { try rowView(pr).mergeButton.isEnabled }
    func noticeText(_ pr: AuthoredPr) throws -> String? {
        let row = try rowView(pr)
        return row.noticeLabel.isHidden ? nil : row.noticeLabel.stringValue
    }

    /// The scroll view the list is in.
    var scroll: NSScrollView? { overview.outline.enclosingScrollView }
}

// MARK: - A live transport with recorders behind it

/// The live transport with its outgoing frames recorded, for the tests of how a request is matched to its answer.
final class LiveMergeFixture {
    private(set) var sent: [ClientAuthoredPrMerge] = []
    /// Frames of any other verb that went out: a merge must never produce one.
    private(set) var otherSends = 0
    var mergeSupported = true
    private(set) var transport: AuthoredPrHandoffTransportLive!

    init(timeout: TimeInterval = 15) {
        transport = AuthoredPrHandoffTransportLive(
            timeout: timeout,
            supported: { true },
            sendPreview: { [unowned self] _ in self.otherSends += 1 },
            sendNotify: { [unowned self] _ in self.otherSends += 1 },
            sendStart: { [unowned self] _ in self.otherSends += 1 },
            sendLink: { [unowned self] _ in self.otherSends += 1 },
            mergeSupported: { [unowned self] in self.mergeSupported },
            sendMerge: { [unowned self] in self.sent.append($0) })
    }
}

// MARK: - Colour maths for the contrast checks

enum ContrastMath {

    /// `color` as drawn in `appearance`: dynamic colours resolve, then convert to sRGB.
    static func resolved(_ color: NSColor, in appearance: NSAppearance.Name) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var out: (r: CGFloat, g: CGFloat, b: CGFloat) = (0, 0, 0)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            if let c = color.usingColorSpace(.sRGB) { out = (c.redComponent, c.greenComponent, c.blueComponent) }
        }
        return out
    }

    /// WCAG relative luminance.
    static func luminance(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// WCAG contrast ratio of `foreground` over `background`, each as drawn in `appearance`.
    static func ratio(_ foreground: NSColor, over background: NSColor, in appearance: NSAppearance.Name) -> CGFloat {
        let a = luminance(resolved(foreground, in: appearance)), b = luminance(resolved(background, in: appearance))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
