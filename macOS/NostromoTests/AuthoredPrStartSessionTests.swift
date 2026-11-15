import XCTest
import AppKit
import NostromoKit

// "Start a session…": the sheet that starts a session for a PR whose focus is gone and hands it the message.
//
// Contract.
//  * The folder is prefilled only from the daemon's suggested folder (empty otherwise: never guessed). The
//    agent defaults to the daemon's suggestion, else claudia, else the first one there is.
//  * Start and send is off until the folder exists and an agent is chosen; Cancel sends nothing.
//  * Start and send, by a person's gesture, sends exactly one request with the folder, the agent and the
//    daemon's digest; on ok the sheet finishes as started with the new focus's tag.
//  * `changed` loads the message again (the person's folder stays) and says so; a failure keeps the sheet
//    open with its words.
//  * SP4: Start and send does nothing for app-control input, an Accessibility press or a stale event.
//
// Mutations (to be run by hand), and the test that fails for each:
//   M1 the folder is guessed from the PR's repo or the owner's folder -> testTheFolderIsPrefilledOnlyFromTheDaemonsSuggestion
//   M2 Start is on without an existing folder or without an agent      -> testStartIsOffUntilTheFolderExistsAndAnAgentIsChosen
//   M3 the agent default order changes                                 -> testTheAgentIsTheSuggestedOneElseClaudiaElseTheFirst
//   M4 Start sends twice, or the wrong digest or folder                -> testStartAndSendSendsExactlyOneRequestWithFolderAgentAndDigest
//   M5 `changed` sends again, or drops the typed folder                -> testChangedLoadsTheMessageAgainKeepsTheFolderAndSaysSo
//   M6 Start skips `HumanGesture`                                      -> testStartDoesNothingForInputThatIsNotAHumanGesture
final class AuthoredPrStartSessionTests: MouseQueueTestCase {

    private var window: NSWindow!
    private var control: NSButton!
    private var transport: RecordingTransport!
    private var outcomes: [AuthoredPrStartSessionModel.Outcome] = []

    override func setUp() {
        super.setUp()
        window = GestureFixtures.offscreenWindow(size: NSSize(width: 700, height: 800))
        control = HF.control(in: window)
        transport = RecordingTransport()
        outcomes = []
    }

    override func tearDown() {
        window.contentView = nil
        window.close()
        window = nil
        super.tearDown()
    }

    private let existing = "/Users/me/Code/nostromo"

    /// A sheet model whose folder check knows only `existing`, loaded with the daemon's answer.
    private func makeModel(agents: [String] = ["cody", "claudia"], payload: AuthoredPrPreviewPayload? = HF.payload(folder: "/Users/me/Code/nostromo", agent: "cody"),
                           permit: @escaping AuthoredPrGesture.Permit = AuthoredPrGesture.live) -> AuthoredPrStartSessionModel {
        let model = AuthoredPrStartSessionModel(row: HF.row(HF.pr(owner: HF.closedOwner())), agents: agents,
                                                transport: transport, permit: permit)
        let known = existing
        model.directoryExists = { path in path == known }
        model.onFinish = { [weak self] in self?.outcomes.append($0) }
        model.load()
        if let payload { transport.answerPreview(.ok(payload)) }
        return model
    }

    private func makeSheet(model: AuthoredPrStartSessionModel) -> AuthoredPrStartSessionViewController {
        let vc = AuthoredPrStartSessionViewController(model: model)
        window.contentView?.addSubview(vc.view)
        vc.view.frame.origin = NSPoint(x: 0, y: 60)
        return vc
    }

    // MARK: - What it shows

    func testItAsksForTheMessageForANewSessionAndShowsItVerbatim() {
        let text = "PR thehammer/nostromo#458 needs attention:\n- Failing checks: lint\n  <not html> **not bold**"
        let model = makeModel(payload: HF.payload(text: text))
        XCTAssertEqual(transport.calls, [.preview(repo: HF.repo, number: 458, target: .newSession)])
        let vc = makeSheet(model: model)
        XCTAssertEqual(vc.message.textView.string, text)
        XCTAssertFalse(vc.message.textView.isEditable)
        XCTAssertTrue(vc.message.textView.isSelectable)
    }

    // MARK: - Folder

    func testTheFolderIsPrefilledOnlyFromTheDaemonsSuggestion() {
        let suggested = makeModel(payload: HF.payload(folder: "/Users/me/Code/nostromo"))
        XCTAssertEqual(suggested.folder, "/Users/me/Code/nostromo")

        let none = makeModel(payload: HF.payload(folder: nil))
        XCTAssertEqual(none.folder, "", "no suggestion: left empty, never guessed from the PR's repo")
        XCTAssertEqual(makeSheet(model: none).folderField.stringValue, "")
        XCTAssertEqual(makeSheet(model: suggested).folderField.stringValue, "/Users/me/Code/nostromo")
    }

    func testStartIsOffUntilTheFolderExistsAndAnAgentIsChosen() {
        let model = makeModel(payload: HF.payload(folder: "/nowhere"))
        let vc = makeSheet(model: model)
        XCTAssertFalse(model.canStart, "the suggested folder does not exist")
        XCTAssertFalse(vc.startButton.isEnabled)

        model.folder = existing
        XCTAssertTrue(model.canStart)
        XCTAssertTrue(vc.startButton.isEnabled, "the button follows")

        model.folder = "relative/path"
        XCTAssertFalse(model.canStart, "a folder is an absolute path")

        let noAgents = makeModel(agents: [], payload: HF.payload(folder: existing))
        XCTAssertNil(noAgents.agent)
        XCTAssertFalse(noAgents.canStart, "no agent to start")
    }

    func testStartIsOffWhileTheMessageIsStillComing() {
        let model = makeModel(payload: nil)
        model.folder = existing
        XCTAssertFalse(model.canStart, "no message yet: nothing to send")
        let vc = makeSheet(model: model)
        XCTAssertFalse(vc.startButton.isEnabled)
        model.start(event: HF.human(in: window), control: control)
        XCTAssertTrue(transport.handedOff.isEmpty)
    }

    func testTypingAFolderIsWhatStartUses() {
        let model = makeModel(payload: HF.payload(folder: nil))
        let vc = makeSheet(model: model)
        XCTAssertFalse(vc.startButton.isEnabled)
        vc.folderField.stringValue = existing
        vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: vc.folderField))
        XCTAssertEqual(model.folder, existing)
        XCTAssertTrue(vc.startButton.isEnabled)
    }

    // MARK: - Agent

    func testTheAgentIsTheSuggestedOneElseClaudiaElseTheFirst() {
        XCTAssertEqual(makeModel(agents: ["cody", "claudia"], payload: HF.payload(agent: "cody")).agent, "cody", "the daemon's suggestion")
        XCTAssertEqual(makeModel(agents: ["cody", "claudia"], payload: HF.payload(agent: nil)).agent, "claudia", "else claudia")
        XCTAssertEqual(makeModel(agents: ["cody", "marty"], payload: HF.payload(agent: nil)).agent, "cody", "else the first")
        XCTAssertEqual(makeModel(agents: ["cody", "claudia"], payload: HF.payload(agent: "nobody")).agent, "claudia",
                       "a suggestion that is not an available agent is ignored")
        let vc = makeSheet(model: makeModel(agents: ["cody", "claudia"], payload: HF.payload(agent: "cody")))
        XCTAssertEqual(vc.agentPopup.titleOfSelectedItem, "cody", "the popup shows it")
    }

    func testChoosingAnotherAgentIsWhatStartSends() {
        let model = makeModel(payload: HF.payload(folder: "/Users/me/Code/nostromo", agent: "cody"))
        let vc = makeSheet(model: model)
        vc.agentPopup.selectItem(withTitle: "claudia")
        _ = NSApp.sendAction(vc.agentPopup.action!, to: vc.agentPopup.target, from: vc.agentPopup)
        XCTAssertEqual(model.agent, "claudia")
    }

    // MARK: - Cancel

    func testCancelSendsNothing() {
        let model = makeModel(permit: { _, _, _ in true })
        let vc = makeSheet(model: model)
        vc.cancelButton.performClick(nil)
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertTrue(transport.handedOff.isEmpty)
        XCTAssertEqual(transport.calls.count, 1, "only the preview request")
        XCTAssertEqual(vc.cancelButton.keyEquivalent, "\u{1b}", "Esc is Cancel")
    }

    // MARK: - Start and send

    func testStartAndSendSendsExactlyOneRequestWithFolderAgentAndDigest() {
        let model = makeModel(payload: HF.payload(digest: "digest-9", folder: "/Users/me/Code/nostromo", agent: "cody"))
        XCTAssertTrue(model.canStart, "precondition")

        model.start(event: HF.human(in: window), control: control)
        model.start(event: HF.human(in: window), control: control)

        XCTAssertEqual(transport.starts, [.startSession(repo: HF.repo, number: 458, folder: "/Users/me/Code/nostromo",
                                                        agent: "cody", digest: "digest-9")],
                       "one request, however often it is pressed")
        XCTAssertTrue(transport.notifies.isEmpty && transport.links.isEmpty)
        XCTAssertTrue(outcomes.isEmpty, "waiting for the daemon")

        transport.answerStart(.ok(AuthoredPrStarted(tag: "cody-pr-nostromo-458")))
        XCTAssertEqual(outcomes, [.started(tag: "cody-pr-nostromo-458")])
    }

    func testStartAndSendFromTheButton() {
        let model = makeModel(permit: { _, _, _ in true })
        let vc = makeSheet(model: model)
        XCTAssertTrue(vc.startButton.isEnabled)
        XCTAssertEqual(vc.startButton.title, "Start and send")
        vc.startButton.performClick(nil)
        XCTAssertEqual(transport.starts.count, 1)
    }

    func testAStartedSessionShowsItsFocusUnderAHandOff() throws {
        let rig = HandoffRig(window: window, openTags: ["cody-pr-nostromo-458"])
        rig.handoff.activate(HF.row(HF.pr(owner: HF.closedOwner())), anchor: control, event: HF.human(in: window), control: control)
        let model = try XCTUnwrap(rig.startModel, "the button opens the sheet")
        model.directoryExists = { _ in true }
        rig.transport.answerPreview(.ok(HF.payload(folder: "/Users/me/Code/nostromo", agent: "cody")))

        model.start(event: HF.human(in: window), control: control)
        XCTAssertTrue(rig.host.log.isEmpty, "nothing is switched to before the daemon says ok")
        rig.transport.answerStart(.ok(AuthoredPrStarted(tag: "cody-pr-nostromo-458")))

        XCTAssertNil(rig.handoff.presented, "the sheet is gone")
        XCTAssertEqual(rig.host.log, ["switchTo:cody-pr-nostromo-458", "bringToFront", "focusInput"])
    }

    // MARK: - changed, failure

    func testChangedLoadsTheMessageAgainKeepsTheFolderAndSaysSo() {
        let model = makeModel(payload: HF.payload(text: "old", digest: "old", folder: "/Users/me/Code/nostromo", agent: "cody"))
        let vc = makeSheet(model: model)
        model.folder = existing
        model.start(event: HF.human(in: window), control: control)

        transport.answerStart(.failed(code: "changed"))

        XCTAssertEqual(transport.previews.count, 2, "the message is asked for again")
        XCTAssertEqual(vc.noteLabelText, "The PR changed; check the message again")
        XCTAssertTrue(outcomes.isEmpty, "the sheet stays open")

        transport.answerPreview(.ok(HF.payload(text: "new", digest: "new", folder: "/somewhere/else", agent: "marty")))
        XCTAssertEqual(vc.message.textView.string, "new", "the new text is shown")
        XCTAssertEqual(model.folder, existing, "what the person had is kept: the suggestion only fills an empty sheet")
        XCTAssertEqual(transport.starts.count, 1, "nothing is started for the new text yet")

        model.start(event: HF.human(in: window), control: control)
        XCTAssertEqual(transport.starts.last,
                       .startSession(repo: HF.repo, number: 458, folder: existing, agent: "cody", digest: "new"))
    }

    func testAFailureKeepsTheSheetOpenWithItsWords() {
        for code in ["bad_folder", "unknown_agent", "already_open", "start_failed", "unavailable", "unheard_of"] {
            transport = RecordingTransport()
            outcomes = []
            let model = makeModel()
            let vc = makeSheet(model: model)
            model.start(event: HF.human(in: window), control: control)

            transport.answerStart(.failed(code: code))

            XCTAssertEqual(vc.noteLabelText, AuthoredPrsHandoffWords.failure(code: code), "\(code): its words")
            XCTAssertTrue(outcomes.isEmpty, "\(code): still open")
            XCTAssertTrue(vc.startButton.isEnabled, "\(code): the person can fix it and try again")
        }
    }

    func testNoAnswerKeepsTheSheetOpenAndSaysNostromoIsNotReachable() {
        let model = makeModel()
        let vc = makeSheet(model: model)
        model.start(event: HF.human(in: window), control: control)
        transport.answerStart(.unreachable)
        XCTAssertEqual(vc.noteLabelText, "Couldn't send: Nostromo isn't reachable")
        XCTAssertTrue(outcomes.isEmpty)
    }

    func testAPreviewThatFailsLeavesTheSheetOpenWithNothingToStart() {
        let model = makeModel(payload: nil)
        transport.answerPreview(.failed(code: "unknown_pr"))
        let vc = makeSheet(model: model)
        model.folder = existing
        XCTAssertEqual(vc.noteLabelText, "Couldn't send: this PR is no longer in the list")
        XCTAssertFalse(model.canStart)
    }

    // MARK: - SP4

    func testStartDoesNothingForInputThatIsNotAHumanGesture() throws {
        let model = makeModel()
        XCTAssertTrue(model.canStart, "precondition")
        for kind in NotAHumanGesture.allCases {
            let event = try kind.event(in: window)
            model.start(event: event, control: control)
            XCTAssertTrue(transport.starts.isEmpty, "\(kind): nothing was started")
            XCTAssertTrue(outcomes.isEmpty, "\(kind): the sheet did not advance")
            XCTAssertTrue(model.canStart, "\(kind): still ready")
        }
        model.start(event: HF.human(in: window), control: control)
        XCTAssertEqual(transport.starts.count, 1, "a person's click still starts it")
    }

    func testPressingStartWithNoPersonBehindItStartsNothing() throws {
        try HF.skipIfVoiceOver()
        let model = makeModel()
        let vc = makeSheet(model: model)
        vc.startButton.performClick(nil)
        XCTAssertTrue(transport.starts.isEmpty)
    }
}

private extension AuthoredPrStartSessionViewController {
    /// The warning line under the message, whichever label shows it: the last non-empty label of the sheet that
    /// is not one of the fixed captions.
    var noteLabelText: String? {
        let captions: Set<String> = ["Folder", "Agent", "Message"]
        return APT.descendants(of: view).compactMap { ($0 as? NSTextField) }
            .filter { !$0.isHidden }
            .map(\.stringValue)
            .filter { !$0.isEmpty && !captions.contains($0) && !$0.hasPrefix("Start a session for PR") }
            .last { $0.hasPrefix("Couldn't") || $0.hasPrefix("The PR changed") || $0.hasPrefix("That focus") }
    }
}
