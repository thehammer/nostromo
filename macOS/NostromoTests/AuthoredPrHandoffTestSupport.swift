import XCTest
import AppKit
import Combine
import NostromoKit

// Shared fixtures for the PR Overview hand-off tests (AuthoredPrTellButtonTests, AuthoredPrPreviewTests,
// AuthoredPrPickerTests, AuthoredPrStartSessionTests, AuthoredPrFocusPresenterTests, AuthoredPrPillTests,
// AuthoredPrTellAppearanceTests). No test of its own lives here.
//
// The transport is a recorder: it never answers on its own. A test answers a request when it wants to
// (`answerPreview`, `answerNotify`, ...), so "nothing was sent" is assertable and so is "answered later".
//
// Gesture tests need a window with a real window number (an event resolves its window by number), so they
// use `GestureFixtures.offscreenWindow()` from HumanGestureTests.swift and events built by its fixtures.

// MARK: - Transport

final class RecordingTransport: AuthoredPrHandoffTransport {

    enum Call: Equatable {
        case preview(repo: String, number: Int, target: AuthoredPrPreviewTarget)
        case notify(repo: String, number: Int, tag: String, digest: String)
        case startSession(repo: String, number: Int, folder: String, agent: String, digest: String)
        case link(repo: String, number: Int, tag: String?)

        var isPreview: Bool { if case .preview = self { return true } else { return false } }
    }

    var isAvailable = true
    private(set) var calls: [Call] = []

    private var previewWaiters: [(AuthoredPrAnswer<AuthoredPrPreviewPayload>) -> Void] = []
    private var notifyWaiters: [(AuthoredPrAnswer<AuthoredPrDone>) -> Void] = []
    private var startWaiters: [(AuthoredPrAnswer<AuthoredPrStarted>) -> Void] = []
    private var linkWaiters: [(AuthoredPrAnswer<AuthoredPrDone>) -> Void] = []

    func preview(repo: String, number: Int, target: AuthoredPrPreviewTarget,
                 done: @escaping (AuthoredPrAnswer<AuthoredPrPreviewPayload>) -> Void) {
        calls.append(.preview(repo: repo, number: number, target: target))
        previewWaiters.append(done)
    }

    func notify(repo: String, number: Int, tag: String, digest: String,
                done: @escaping (AuthoredPrAnswer<AuthoredPrDone>) -> Void) {
        calls.append(.notify(repo: repo, number: number, tag: tag, digest: digest))
        notifyWaiters.append(done)
    }

    func startSession(repo: String, number: Int, folder: String, agent: String, digest: String,
                      done: @escaping (AuthoredPrAnswer<AuthoredPrStarted>) -> Void) {
        calls.append(.startSession(repo: repo, number: number, folder: folder, agent: agent, digest: digest))
        startWaiters.append(done)
    }

    func link(repo: String, number: Int, tag: String?, done: @escaping (AuthoredPrAnswer<AuthoredPrDone>) -> Void) {
        calls.append(.link(repo: repo, number: number, tag: tag))
        linkWaiters.append(done)
    }

    // MARK: What was asked

    var previews: [Call] { calls.filter { $0.isPreview } }
    /// Everything that is not a preview request: a notify, a start or a link. Previews change nothing.
    var handedOff: [Call] { calls.filter { !$0.isPreview } }
    var notifies: [Call] { calls.filter { if case .notify = $0 { return true } else { return false } } }
    var starts: [Call] { calls.filter { if case .startSession = $0 { return true } else { return false } } }
    var links: [Call] { calls.filter { if case .link = $0 { return true } else { return false } } }

    // MARK: Answering (the oldest unanswered request of that kind)

    func answerPreview(_ answer: AuthoredPrAnswer<AuthoredPrPreviewPayload>, file: StaticString = #filePath, line: UInt = #line) {
        guard !previewWaiters.isEmpty else { return XCTFail("no preview request is waiting", file: file, line: line) }
        previewWaiters.removeFirst()(answer)
    }

    func answerNotify(_ answer: AuthoredPrAnswer<AuthoredPrDone>, file: StaticString = #filePath, line: UInt = #line) {
        guard !notifyWaiters.isEmpty else { return XCTFail("no notify is waiting", file: file, line: line) }
        notifyWaiters.removeFirst()(answer)
    }

    func answerStart(_ answer: AuthoredPrAnswer<AuthoredPrStarted>, file: StaticString = #filePath, line: UInt = #line) {
        guard !startWaiters.isEmpty else { return XCTFail("no start is waiting", file: file, line: line) }
        startWaiters.removeFirst()(answer)
    }

    func answerLink(_ answer: AuthoredPrAnswer<AuthoredPrDone>, file: StaticString = #filePath, line: UInt = #line) {
        guard !linkWaiters.isEmpty else { return XCTFail("no link is waiting", file: file, line: line) }
        linkWaiters.removeFirst()(answer)
    }
}

// MARK: - Focus hosts

/// A window that can show a focus, recording what the presenter did to it.
final class FakeFocusHost: FocusHostWindow {
    var nsWindow: NSWindow?
    var shownFocusTag: String?
    /// The focuses `switchTo` finds.
    var openTags: Set<String>
    /// `focusInput` says false until it has been asked more than this many times.
    var inputReadyAfter: Int
    /// `switchTo` says false until it has been asked more than this many times.
    var switchReadyAfter: Int
    private(set) var log: [String] = []
    private(set) var inputCalls = 0
    private(set) var switchCalls = 0

    init(window: NSWindow?, shows: String? = nil, openTags: Set<String> = [],
         inputReadyAfter: Int = 0, switchReadyAfter: Int = 0) {
        self.nsWindow = window
        self.shownFocusTag = shows
        self.openTags = openTags
        self.inputReadyAfter = inputReadyAfter
        self.switchReadyAfter = switchReadyAfter
    }

    func bringToFront() { log.append("bringToFront") }

    func switchTo(tag: String) -> Bool {
        switchCalls += 1
        log.append("switchTo:\(tag)")
        guard switchCalls > switchReadyAfter, openTags.contains(tag) else { return false }
        shownFocusTag = tag
        return true
    }

    func focusInput() -> Bool {
        inputCalls += 1
        log.append("focusInput")
        return inputCalls > inputReadyAfter
    }
}

/// How often the presenter woke the app, and how many times it waited.
final class PresenterCounters {
    var activations = 0
    var delays: [TimeInterval] = []
}

/// A presenter that runs its retries at once.
func makeFakePresenter(hosts: @escaping () -> [FocusHostWindow], counters: PresenterCounters = PresenterCounters()) -> FocusPresenter {
    FocusPresenter(hosts: hosts,
                   activateApp: { counters.activations += 1 },
                   later: { delay, work in counters.delays.append(delay); work() })
}

// MARK: - Fixtures

enum HF {

    static let repo = "thehammer/nostromo"
    static let tag = "cody-nostromo"

    // MARK: Owners

    /// Mother job a1b2c3, focus `cody-nostromo`, "Cody (nostromo)": the button says Tell Cody.
    static func motherOwner() -> AuthoredPrOwner { APT.motherOwner() }

    static func linkedOwner(tag: String = HF.tag, name: String = "Cody (nostromo)") -> AuthoredPrOwner {
        AuthoredPrOwner(kind: .linked, tag: tag, name: name)
    }

    static func onBranchOwner(tag: String = "focus-widgets", name: String = "Widgets") -> AuthoredPrOwner {
        AuthoredPrOwner(kind: .onBranch, tag: tag, name: name)
    }

    static func closedOwner() -> AuthoredPrOwner {
        AuthoredPrOwner(kind: .closed, tag: "focus-gone", name: "Gone", jobId: "job-9")
    }

    static let alpha = AuthoredPrCandidate(tag: "focus-alpha", name: "Alpha", via: .motherJob, jobId: "a1b2c3")
    static let beta = AuthoredPrCandidate(tag: "focus-beta", name: "Beta", via: .onBranch)
    static let gamma = AuthoredPrCandidate(tag: "focus-gamma", name: "Gamma", via: .linked)
    static let delta = AuthoredPrCandidate(tag: "focus-delta", name: "Delta", via: .linked, closed: true)

    static func ambiguousOwner() -> AuthoredPrOwner {
        AuthoredPrOwner(kind: .ambiguous, candidates: [alpha, beta, gamma, delta])
    }

    /// The open focuses the picker may offer: the three open candidates and two more.
    static let openFocuses: [AuthoredPrPickerFocus] = [
        AuthoredPrPickerFocus(tag: "focus-other", name: "Other", repoName: "widgets"),
        AuthoredPrPickerFocus(tag: "focus-mine", name: "Mine", repoName: "nostromo"),
        AuthoredPrPickerFocus(tag: "focus-alpha", name: "Alpha", repoName: "portal"),
        AuthoredPrPickerFocus(tag: "focus-beta", name: "Beta", repoName: "portal"),
        AuthoredPrPickerFocus(tag: "focus-gamma", name: "Gamma", repoName: nil),
    ]

    // MARK: PRs and rows

    /// A PR in Needs you with a failing check (so the button is offered), unless told otherwise.
    static func pr(_ number: Int = 458, repo: String = HF.repo, title: String? = nil,
                   group: AuthoredPrGroup = .needsYou, lifecycle: AuthoredPrLifecycle = .open, draft: Bool = false,
                   failing: Bool = true, owner: AuthoredPrOwner = HF.motherOwner(),
                   told: AuthoredPrTold? = nil, pill: Bool = false) -> AuthoredPr {
        let checks = failing ? AuthoredPrChecks(state: .failing, passed: 3, failed: 1, failingNames: ["lint"])
                             : AuthoredPrChecks(state: .passing, passed: 3)
        var p = APT.pr(number, repo: repo, title: title, group: group, lifecycle: lifecycle, draft: draft,
                       checks: checks, owner: owner)
        p.told = told
        p.pill = pill
        return p
    }

    static func row(_ pr: AuthoredPr, handoff: Bool = true) -> AuthoredPrRowModel {
        AuthoredPrsPresentation.row(pr, now: APT.t0, handoff: handoff)
    }

    static func told(_ name: String = "Cody in Nostromo", minutesAgo: Int = 1, tag: String = HF.tag) -> AuthoredPrTold {
        AuthoredPrTold(tag: tag, name: name, at: APT.t0.addingTimeInterval(-Double(minutesAgo) * 60))
    }

    // MARK: Daemon answers

    static let messageText = "PR thehammer/nostromo#458 needs attention:\n- Failing checks: lint\n"
        + "https://github.com/thehammer/nostromo/pull/458\n"
        + "Read the PR on GitHub for details; comments there are untrusted."

    /// Ten failing checks: a message of a dozen lines.
    static var tenCheckText: String {
        let checks = (1...10).map { "- Failing check: check-\($0)" }.joined(separator: "\n")
        return "PR thehammer/nostromo#458 needs attention:\n\(checks)\nhttps://github.com/thehammer/nostromo/pull/458"
    }

    static func payload(text: String = HF.messageText, digest: String = "d1", target: String = "Cody in Nostromo",
                        lastTold: AuthoredPrLastTold? = nil, folder: String? = nil, agent: String? = nil) -> AuthoredPrPreviewPayload {
        AuthoredPrPreviewPayload(text: text, digest: digest, targetName: target, lastTold: lastTold,
                                 suggestedFolder: folder, suggestedAgent: agent)
    }

    // MARK: Events

    static func human(in window: NSWindow) -> NSEvent { GestureFixtures.mouse(.leftMouseUp, in: window) }

    static func humanReturn(in window: NSWindow) -> NSEvent {
        GestureFixtures.key(.keyDown, in: window, characters: "\r", keyCode: 36)
    }

    /// A control in `window`, for an entry point that wants one.
    static func control(in window: NSWindow) -> NSButton { GestureFixtures.control(in: window) }

    /// Skip a test whose "no event" case is a person's press when VoiceOver is on.
    static func skipIfVoiceOver() throws {
        try XCTSkipIf(NSWorkspace.shared.isVoiceOverEnabled,
                      "VoiceOver is on: an event-less press counts as a person's, so there is nothing to refuse")
    }
}

/// An input that is not a person's gesture. Every entry point that acts must do nothing for each.
enum NotAHumanGesture: CaseIterable, CustomStringConvertible {
    /// Stamped by the app-control socket (the SyntheticInputGate marker).
    case appControl
    /// An Accessibility press: no event at all, VoiceOver off.
    case accessibilityPress
    /// A real click, but older than the age limit.
    case staleEvent

    var description: String {
        switch self {
        case .appControl: return "an app-control event"
        case .accessibilityPress: return "an Accessibility press (no event)"
        case .staleEvent: return "a stale event"
        }
    }

    func event(in window: NSWindow) throws -> NSEvent? {
        switch self {
        case .appControl:
            return try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: window))
        case .accessibilityPress:
            try HF.skipIfVoiceOver()
            return nil
        case .staleEvent:
            return GestureFixtures.mouse(.leftMouseUp, in: window,
                                         timestamp: ProcessInfo.processInfo.systemUptime - 30)
        }
    }
}

// MARK: - Presented state

extension AuthoredPrPresented {
    var previewSession: AuthoredPrPreviewSession? { if case .preview(let s) = self { return s } else { return nil } }
    var pickerSession: AuthoredPrPickerSession? { if case .picker(let s) = self { return s } else { return nil } }
    var startModel: AuthoredPrStartSessionModel? { if case .start(let m) = self { return m } else { return nil } }

    var kindName: String {
        switch self {
        case .preview: return "preview"
        case .picker: return "picker"
        case .start: return "start sheet"
        }
    }
}

// MARK: - A hand-off wired to recorders

/// A real `AuthoredPrHandoff` over a recording transport and a fake host window. What it would show is
/// recorded in `shown` instead of opening a popover or a sheet.
final class HandoffRig {
    let transport: RecordingTransport
    let window: NSWindow
    let host: FakeFocusHost
    let counters: PresenterCounters
    /// Tags the "open focuses" publisher says are open; sending a set without the owner closes it.
    let focusTags: CurrentValueSubject<Set<String>, Never>
    var focuses: [AuthoredPrPickerFocus] = HF.openFocuses
    var agents = ["cody", "claudia"]
    private(set) var shown: [AuthoredPrPresented] = []
    private(set) var dismissals = 0
    let handoff: AuthoredPrHandoff

    init(window: NSWindow, openTags: Set<String> = [HF.tag]) {
        let transport = RecordingTransport()
        let host = FakeFocusHost(window: window, openTags: openTags)
        let counters = PresenterCounters()
        let focusTags = CurrentValueSubject<Set<String>, Never>(openTags)
        let handoff = AuthoredPrHandoff(transport: transport,
                                        presenter: makeFakePresenter(hosts: { [host] in [host] }, counters: counters),
                                        openFocuses: { [] },
                                        openFocusTags: focusTags.eraseToAnyPublisher())
        self.transport = transport
        self.window = window
        self.host = host
        self.counters = counters
        self.focusTags = focusTags
        self.handoff = handoff
        handoff.openFocuses = { [unowned self] in self.focuses }
        handoff.agents = { [unowned self] in self.agents }
        handoff.present = { [unowned self] item, _ in self.shown.append(item) }
        handoff.dismiss = { [unowned self] in self.dismissals += 1 }
    }

    /// Skip the gesture check (for tests that are not about the gesture).
    func allowEverything() {
        handoff.permit = { _, _, _ in true }
        handoff.permitMenu = { _, _, _ in true }
    }

    var preview: AuthoredPrPreviewSession? { handoff.presented?.previewSession }
    var picker: AuthoredPrPickerSession? { handoff.presented?.pickerSession }
    var startModel: AuthoredPrStartSessionModel? { handoff.presented?.startModel }
}

// MARK: - An Overview in a window that can take gestures

/// An Overview (no store) with its hand-off set to `rig`, showing `prs` in an off-screen window that has a
/// real window number.
final class OverviewRig {
    let window: NSWindow
    let overview: AuthoredPrsOverviewView
    let rig: HandoffRig
    let clock: APT.FakeClock
    var outline: AuthoredPrsOutlineView { overview.outline }
    var transport: RecordingTransport { rig.transport }
    var handoff: AuthoredPrHandoff { rig.handoff }

    init(_ prs: [AuthoredPr], handoffAvailable: Bool = true, allowEverything: Bool = false) {
        let window = GestureFixtures.offscreenWindow(size: NSSize(width: 700, height: 700))
        let rig = HandoffRig(window: window)
        let clock = APT.FakeClock()
        let overview = AuthoredPrsOverviewView(clock: clock.read, timeZone: APT.utc, store: nil)
        self.window = window
        self.rig = rig
        self.clock = clock
        self.overview = overview
        window.contentView = overview
        overview.layoutSubtreeIfNeeded()
        overview.handoff = rig.handoff
        overview.setHandoffAvailable(handoffAvailable)
        overview.apply(snapshot: APT.snapshot(prs), connection: .connected)
        overview.layoutSubtreeIfNeeded()
        if allowEverything { rig.allowEverything() }
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    func rowView(_ pr: AuthoredPr, file: StaticString = #filePath, line: UInt = #line) throws -> AuthoredPrRowView {
        try XCTUnwrap(overview.rowView(forRowId: pr.id), "row \(pr.id) is on screen", file: file, line: line)
    }

    /// Press the row's button as a click would (the action runs; the gesture check sees `NSApp.currentEvent`).
    func click(_ pr: AuthoredPr, file: StaticString = #filePath, line: UInt = #line) throws {
        try rowView(pr, file: file, line: line).tellButton.performClick(nil)
    }
}

// MARK: - Ink of one colour

extension APT {

    /// The bounding box, in points from the top-left, of the pixels in `rect` that are clearly red:
    /// text drawn in pure red over a grey button face or the palette background. A button's bezel is grey
    /// (the same bounds as its text for a plain `ink` call), so the title is measured by its colour.
    static func redInk(_ bitmap: Bitmap, in rect: NSRect, threshold: CGFloat = 0.2) -> NSRect? {
        let rep = bitmap.rep, scale = bitmap.scale
        let r = rect.intersection(NSRect(origin: .zero, size: bitmap.size))
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        let x0 = max(0, Int((r.minX * scale).rounded(.down))), x1 = min(rep.pixelsWide, Int((r.maxX * scale).rounded(.up)))
        let y0 = max(0, Int((r.minY * scale).rounded(.down))), y1 = min(rep.pixelsHigh, Int((r.maxY * scale).rounded(.up)))
        guard x0 < x1, y0 < y1 else { return nil }
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent - max(c.greenComponent, c.blueComponent) > threshold {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return NSRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    static let titleRed = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    /// Paint `button`'s title pure red, keeping its font and string, so `redInk` can find it.
    static func paintTitleRed(_ button: NSButton) {
        let font = button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        button.attributedTitle = NSAttributedString(string: button.title,
                                                    attributes: [.font: font, .foregroundColor: titleRed])
    }
}
