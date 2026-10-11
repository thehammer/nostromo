import XCTest
import AppKit

// Slice T5: the "Send to agent" confirmation sheet and the per-source project memory it
// uses. The real sheet is built headlessly with a fake `WorkSending` that records what it
// is asked to send and lets the test answer by hand. Nothing here depends on a window
// server, on the wall clock, or on more than one display:
//   - the sheet is never shown (its window is only built), and Return/Esc are checked as
//     "the default/cancel button has the right key equivalent, lives in the window, and
//     its click does the right thing" rather than by synthesising key events;
//   - a change that hops through the main queue (an org lookup) is awaited by flushing the
//     main queue until the state holds (pass or fail depends on state, never on elapsed
//     time), and org lookups are gated by semaphores the test releases;
//   - the project memory lives in an ephemeral UserDefaults suite, never `.standard`.

// MARK: - Helpers

/// Run everything already queued on the main queue, and whatever that queues in turn.
private func flushMain(generations: Int = 3) {
    for _ in 0..<generations {
        var ran = false
        DispatchQueue.main.async { ran = true }
        while !ran { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    }
}

/// Flush the main queue until `condition` holds (true), giving up after a generous number
/// of turns (false). The bound counts turns, not seconds.
@discardableResult
private func waitUntil(maxTurns: Int = 500, _ condition: () -> Bool) -> Bool {
    for _ in 0..<maxTurns {
        if condition() { return true }
        flushMain(generations: 1)
    }
    return condition()
}

private let wireClient = NostromodClient(socketPath: "/dev/null")

/// Decode a targeted frame exactly the way the app does, so dates and optional fields go
/// through the app's own decoding.
private func decodeFrame(_ type: String, _ result: [String: Any]) -> ServerMsg {
    let frame: [String: Any] = ["type": type, "request_id": "r-1", "result": result]
    let raw = try! JSONSerialization.data(withJSONObject: frame)
    let obj = try! JSONSerialization.jsonObject(with: raw) as! [String: Any]
    return wireClient.decode(type_: type, json: obj, raw: raw)
}

private let alpha = "/Users/test/Code/alpha"
private let beta = "/Users/test/Code/beta"
private let gamma = "/Users/test/Code/gamma"

/// A marker as the daemon sends it.
private func markerJSON(_ kind: String = "focus", target: String = "claudia-core-12",
                        label: String = "CORE-12", createdAt: String = "2026-10-09T15:00:00Z") -> [String: Any] {
    ["kind": kind, "target_id": target, "label": label, "created_at": createdAt]
}

/// A `SendPreview` decoded from the wire.
private func makePreview(itemId: String = "jira:CORE-12", agent: String = "claudia",
                         workingDirectory: String? = nil, label: String = "CORE-12",
                         context: String = "Here is a work item from Teri.\nSource: jira",
                         existing: [[String: Any]] = []) -> SendPreview {
    var value: [String: Any] = ["item_id": itemId, "agent": agent, "label": label, "context": context,
                                "existing": existing]
    if let workingDirectory { value["working_directory"] = workingDirectory }
    guard case .workSendPreview(_, .ok(let preview)) =
            decodeFrame("work_send_preview", ["status": "ok", "value": value]) else {
        fatalError("preview did not decode")
    }
    return preview
}

private func makeMarker(_ kind: String = "focus", target: String = "claudia-core-12",
                        label: String = "CORE-12", createdAt: String = "2026-10-09T15:00:00Z") -> SentMarker {
    makePreview(existing: [markerJSON(kind, target: target, label: label, createdAt: createdAt)]).existing[0]
}

/// The daemon's answer to a send.
private func sendOK(_ kind: String, focusTag: String? = nil, jobId: String? = nil) -> WorkResponse {
    var value: [String: Any] = ["kind": kind]
    if let focusTag { value["focus_tag"] = focusTag }
    if let jobId { value["job_id"] = jobId }
    guard case .workSendResult(_, let result) =
            decodeFrame("work_send_result", ["status": "ok", "value": value]) else {
        fatalError("outcome did not decode")
    }
    return .sendResult(result)
}

private func outcome(_ kind: String, focusTag: String? = nil, jobId: String? = nil) -> SendOutcome {
    guard case .sendResult(.ok(let o)) = sendOK(kind, focusTag: focusTag, jobId: jobId) else {
        fatalError("outcome did not decode")
    }
    return o
}

private func sendErr(_ code: String, _ message: String) -> WorkResponse {
    guard case .workSendResult(_, let result) =
            decodeFrame("work_send_result", ["status": "err", "value": ["code": code, "message": message]]) else {
        fatalError("error did not decode")
    }
    return .sendResult(result)
}

/// Records every request and answers only when the test says so.
private final class FakeSender: WorkSending {
    var requests: [WorkSendRequest] = []
    private var completions: [(WorkResponse) -> Void] = []
    /// When set, answers inside `sendWork`, the way a disconnected store does.
    var answerImmediately: WorkResponse?

    func sendWork(_ request: WorkSendRequest, completion: @escaping (WorkResponse) -> Void) {
        requests.append(request)
        if let answerImmediately {
            completion(answerImmediately)
        } else {
            completions.append(completion)
        }
    }

    /// Answer request number `index` (0-based).
    func answer(_ response: WorkResponse, at index: Int = 0) {
        completions[index](response)
    }
}

/// Org lookups the test releases by hand, so "before the answer" is a state it can look at.
private final class GatedOrgs {
    private let lock = NSLock()
    private var gates: [String: DispatchSemaphore] = [:]
    var answers: [String: RepoOrg.Lookup]

    init(_ answers: [String: RepoOrg.Lookup]) { self.answers = answers }

    private func gate(_ path: String) -> DispatchSemaphore {
        lock.lock(); defer { lock.unlock() }
        if let g = gates[path] { return g }
        let g = DispatchSemaphore(value: 0)
        gates[path] = g
        return g
    }

    func lookup(_ path: String) -> RepoOrg.Lookup {
        // The bound only keeps a failed test from leaving this thread parked for good.
        _ = gate(path).wait(timeout: .now() + 30)
        return answers[path] ?? .resolved(nil)
    }

    func release(_ path: String) { gate(path).signal() }

    func releaseAll() { [alpha, beta, gamma].forEach { release($0) } }
}

/// A sheet over a fake sender, an ephemeral project memory and (optionally) gated org lookups.
private final class SheetRig {
    let sender = FakeSender()
    let suiteName = "SendToAgentSheetTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let mru: TeriProjectMRU
    let orgs: GatedOrgs?
    let resolver: RepoOrgResolver
    private(set) var results: [SendToAgentResult] = []
    private(set) var sheet: SendToAgentSheet!

    init(preview: SendPreview = makePreview(workingDirectory: alpha),
         mruKey: String? = "jira:CORE",
         mruSeed: [String: String] = [:],
         agents: [String] = ["claudia", "debbie", "cody"],
         projects: [String] = [alpha, beta, gamma],
         orgs: GatedOrgs? = nil) {
        defaults = UserDefaults(suiteName: suiteName)!
        mru = TeriProjectMRU(defaults: defaults)
        self.orgs = orgs
        resolver = orgs.map { gated in RepoOrgResolver(lookup: gated.lookup) }
            ?? RepoOrgResolver(lookup: { _ in .resolved(nil) })
        for (key, path) in mruSeed { mru.record(path, for: key) }
        sheet = SendToAgentSheet(itemId: preview.itemId, mruKey: mruKey, preview: preview, agents: agents,
                                 projects: projects, orgResolver: resolver, mru: mru, sender: sender,
                                 onFinished: { [unowned self] result in self.results.append(result) })
    }

    deinit {
        orgs?.releaseAll()
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// What is stored under the MRU key, read straight from the defaults.
    var storedMRU: [String: String]? {
        defaults.dictionary(forKey: "nostromo.teri.projectMRU.v1") as? [String: String]
    }
}

// MARK: - The sheet

final class SendToAgentSheetTests: XCTestCase {

    // MARK: Defaults

    func testDefaultsAreFilledFromThePreview() {
        let rig = SheetRig(preview: makePreview(agent: "debbie", workingDirectory: beta, label: "WEB-42",
                                                context: "Here is a work item from Teri.\nStack: app/f0.py"))
        let sheet = rig.sheet!

        XCTAssertEqual(sheet.destination, .focus)
        XCTAssertEqual(sheet.selectedAgent, "debbie")
        XCTAssertEqual(sheet.workingDirectory, beta)
        XCTAssertEqual(sheet.labelText, "WEB-42")
        XCTAssertEqual(sheet.contextText, "Here is a work item from Teri.\nStack: app/f0.py")
        XCTAssertEqual(sheet.primaryButtonTitle, "Start")
        XCTAssertNil(sheet.secondaryButtonTitle)
        XCTAssertTrue(sheet.isStartEnabled)
        XCTAssertTrue(sheet.isMotherEnabled)
        XCTAssertEqual(sheet.errorText, "")
        XCTAssertFalse(sheet.isSending)
        XCTAssertTrue(rig.sender.requests.isEmpty, "opening the sheet sends nothing")
    }

    func testTheProjectComesFromTheMRUWhenThePreviewHasNone() {
        let rig = SheetRig(preview: makePreview(workingDirectory: nil), mruKey: "jira:CORE",
                           mruSeed: ["jira:CORE": beta, "jira:OTHER": gamma])

        XCTAssertEqual(rig.sheet.workingDirectory, beta)
        XCTAssertTrue(rig.sheet.isStartEnabled)
    }

    func testThePreviewsProjectWinsOverTheMRU() {
        let rig = SheetRig(preview: makePreview(workingDirectory: alpha), mruKey: "jira:CORE",
                           mruSeed: ["jira:CORE": beta])

        XCTAssertEqual(rig.sheet.workingDirectory, alpha)
    }

    func testNoPreviewProjectAndNothingRememberedMeansNoProject() {
        let rig = SheetRig(preview: makePreview(workingDirectory: nil), mruKey: "jira:CORE",
                           mruSeed: ["jira:OTHER": beta])

        XCTAssertNil(rig.sheet.workingDirectory)
    }

    func testWithoutAnMRUKeyTheMemoryIsNotConsulted() {
        let rig = SheetRig(preview: makePreview(workingDirectory: nil), mruKey: nil,
                           mruSeed: ["jira:CORE": beta, "todos": gamma])

        XCTAssertNil(rig.sheet.workingDirectory)
    }

    // MARK: No project

    func testStartIsDisabledWithoutAProjectAndNothingCanBeSent() {
        let rig = SheetRig(preview: makePreview(workingDirectory: nil), mruKey: nil)
        let sheet = rig.sheet!

        XCTAssertFalse(sheet.isStartEnabled)
        XCTAssertFalse(sheet.isMotherEnabled)

        sheet.primaryTapped()
        sheet.primaryButton.performClick(nil)

        XCTAssertTrue(rig.sender.requests.isEmpty)
        XCTAssertFalse(sheet.isSending)
        XCTAssertTrue(rig.results.isEmpty)
    }

    func testChoosingAProjectEnablesStartAndMother() {
        let rig = SheetRig(preview: makePreview(workingDirectory: nil), mruKey: nil)
        let sheet = rig.sheet!

        sheet.selectProject(beta)

        XCTAssertEqual(sheet.workingDirectory, beta)
        XCTAssertTrue(sheet.isStartEnabled)
        XCTAssertTrue(sheet.isMotherEnabled)
    }

    func testChoosingNoProjectAgainDisablesStartAndMotherAgain() {
        let rig = SheetRig(preview: makePreview(workingDirectory: alpha))
        let sheet = rig.sheet!

        sheet.selectProject(nil)

        XCTAssertNil(sheet.workingDirectory)
        XCTAssertFalse(sheet.isStartEnabled)
        XCTAssertFalse(sheet.isMotherEnabled)
    }

    // MARK: Mother

    func testChoosingMotherWarnsThatItRunsUnattended() {
        let rig = SheetRig()
        let sheet = rig.sheet!
        XCTAssertEqual(sheet.motherWarningText, "", "no warning for a focus")

        sheet.setDestination(.motherJob)

        XCTAssertEqual(sheet.destination, .motherJob)
        XCTAssertEqual(sheet.motherWarningText, "Mother runs unattended; a raw item is not a plan")

        sheet.setDestination(.focus)

        XCTAssertEqual(sheet.destination, .focus)
        XCTAssertEqual(sheet.motherWarningText, "")
    }

    func testClearingTheProjectWhileMotherIsChosenFallsBackToAFocus() {
        let rig = SheetRig()
        let sheet = rig.sheet!
        sheet.setDestination(.motherJob)

        sheet.selectProject(nil)

        XCTAssertEqual(sheet.destination, .focus)
        XCTAssertEqual(sheet.motherWarningText, "")
        XCTAssertFalse(sheet.isMotherEnabled)
    }

    func testMotherCannotBeChosenWithoutAProject() {
        let rig = SheetRig(preview: makePreview(workingDirectory: nil), mruKey: nil)
        let sheet = rig.sheet!

        sheet.setDestination(.motherJob)

        XCTAssertEqual(sheet.destination, .focus)
        XCTAssertEqual(sheet.motherWarningText, "")
    }

    // MARK: Start sends exactly what is on the sheet

    func testStartSendsOneRequestWithThePreviewsDefaults() throws {
        let rig = SheetRig(preview: makePreview(itemId: "sentry:42", agent: "debbie", workingDirectory: alpha,
                                                label: "WEB-42", context: "CTX"))

        rig.sheet.primaryTapped()

        let request = try XCTUnwrap(rig.sender.requests.first)
        XCTAssertEqual(rig.sender.requests.count, 1)
        XCTAssertEqual(request.itemId, "sentry:42")
        XCTAssertEqual(request.destination, "focus")
        XCTAssertEqual(request.agent, "debbie")
        XCTAssertEqual(request.workingDirectory, alpha)
        XCTAssertEqual(request.label, "WEB-42")
        XCTAssertEqual(request.context, "CTX")
        XCTAssertFalse(request.allowDuplicate)
        XCTAssertFalse(request.requestId.isEmpty)
    }

    func testEveryEditedFieldIsInTheRequest() throws {
        let rig = SheetRig(preview: makePreview(itemId: "jira:CORE-12", agent: "claudia", workingDirectory: alpha))
        let sheet = rig.sheet!

        sheet.setDestination(.motherJob)
        sheet.selectAgent("cody")
        sheet.selectProject(gamma)
        sheet.typeLabel("  My own label  ")
        sheet.typeContext("Edited context\nwith two lines")

        XCTAssertEqual(sheet.selectedAgent, "cody")
        XCTAssertEqual(sheet.workingDirectory, gamma)
        XCTAssertEqual(sheet.labelText.trimmingCharacters(in: .whitespacesAndNewlines), "My own label")
        XCTAssertEqual(sheet.contextText, "Edited context\nwith two lines")

        sheet.primaryTapped()

        let request = try XCTUnwrap(rig.sender.requests.first)
        XCTAssertEqual(rig.sender.requests.count, 1)
        XCTAssertEqual(request.itemId, "jira:CORE-12")
        XCTAssertEqual(request.destination, "mother_job")
        XCTAssertEqual(request.agent, "cody")
        XCTAssertEqual(request.workingDirectory, gamma)
        XCTAssertEqual(request.label, "My own label", "the label is trimmed")
        XCTAssertEqual(request.context, "Edited context\nwith two lines")
        XCTAssertFalse(request.allowDuplicate)
    }

    func testWhileTheDaemonIsAnsweringTheSheetIsSendingAndStartIsDisabled() {
        let rig = SheetRig()
        let sheet = rig.sheet!

        sheet.primaryTapped()

        XCTAssertTrue(sheet.isSending)
        XCTAssertFalse(sheet.isStartEnabled)
        XCTAssertTrue(rig.results.isEmpty, "not finished until the daemon answers")
    }

    func testTappingStartTwiceSendsOnce() {
        let rig = SheetRig()
        let sheet = rig.sheet!

        sheet.primaryTapped()
        sheet.primaryTapped()
        sheet.primaryButton.performClick(nil)

        XCTAssertEqual(rig.sender.requests.count, 1)
    }

    // MARK: Success

    func testASuccessfulSendFinishesWithTheOutcomeAndRemembersTheProject() {
        let rig = SheetRig(preview: makePreview(workingDirectory: nil), mruKey: "jira:CORE",
                           mruSeed: [:])
        let sheet = rig.sheet!
        sheet.selectProject(beta)
        sheet.primaryTapped()

        rig.sender.answer(sendOK("created", focusTag: "claudia-core-12"))

        XCTAssertEqual(rig.results, [.sent(outcome("created", focusTag: "claudia-core-12"))])
        XCTAssertEqual(rig.mru.lastProject(for: "jira:CORE"), beta)
        XCTAssertFalse(sheet.isSending)
    }

    func testAMotherJobOutcomeIsPassedThroughUnchanged() {
        let rig = SheetRig()
        rig.sheet.setDestination(.motherJob)
        rig.sheet.primaryTapped()

        rig.sender.answer(sendOK("mother_job", jobId: "abc123"))

        XCTAssertEqual(rig.results, [.sent(outcome("mother_job", jobId: "abc123"))])
    }

    func testTheDaemonSayingExistingIsPassedThroughToo() {
        let rig = SheetRig()
        rig.sheet.primaryTapped()

        rig.sender.answer(sendOK("existing", focusTag: "claudia-core-12"))

        XCTAssertEqual(rig.results, [.sent(outcome("existing", focusTag: "claudia-core-12"))])
    }

    func testNothingIsRememberedWhenTheItemHasNoMRUKey() {
        let rig = SheetRig(preview: makePreview(workingDirectory: alpha), mruKey: nil)
        rig.sheet.primaryTapped()

        rig.sender.answer(sendOK("created", focusTag: "claudia-x"))

        XCTAssertEqual(rig.results.count, 1)
        XCTAssertNil(rig.storedMRU, "a repo doc has its own repo; nothing to remember")
    }

    func testTheProjectIsRememberedUnderThisItemsKeyOnly() {
        let rig = SheetRig(preview: makePreview(workingDirectory: nil), mruKey: "sentry:web-app",
                           mruSeed: ["jira:CORE": gamma])
        rig.sheet.selectProject(beta)
        rig.sheet.primaryTapped()

        rig.sender.answer(sendOK("created", focusTag: "debbie-x"))

        XCTAssertEqual(rig.mru.lastProject(for: "sentry:web-app"), beta)
        XCTAssertEqual(rig.mru.lastProject(for: "jira:CORE"), gamma, "other keys are untouched")
    }

    // MARK: Failure

    func testAFailedSendShowsTheMessageInlineAndLeavesTheSheetOpenAndUsable() {
        let rig = SheetRig(preview: makePreview(workingDirectory: nil), mruKey: "jira:CORE")
        let sheet = rig.sheet!
        sheet.selectProject(beta)
        sheet.primaryTapped()

        rig.sender.answer(sendErr("mother_failed", "mother add failed: no such repo"))

        XCTAssertTrue(sheet.errorText.contains("mother add failed: no such repo"), sheet.errorText)
        XCTAssertTrue(rig.results.isEmpty, "the sheet stays open")
        XCTAssertFalse(sheet.isSending)
        XCTAssertTrue(sheet.isStartEnabled)
        XCTAssertNil(rig.storedMRU, "a project that failed is not remembered")
        XCTAssertNil(rig.mru.lastProject(for: "jira:CORE"))
    }

    func testATimeoutAndALostConnectionAreShownInlineToo() {
        let failures: [(String, WorkResponse)] = [
            ("timed out", .timedOut),
            ("connection lost", .failed(WorkError(code: "connection_lost", message: "The connection to nostromd was lost"))),
        ]
        for (name, response) in failures {
            let rig = SheetRig()
            rig.sheet.primaryTapped()

            rig.sender.answer(response)

            XCTAssertFalse(rig.sheet.errorText.isEmpty, name)
            if case .failed(let error) = response {
                XCTAssertTrue(rig.sheet.errorText.contains(error.message), "\(name): \(rig.sheet.errorText)")
            }
            XCTAssertTrue(rig.results.isEmpty, "\(name): the sheet stays open")
            XCTAssertTrue(rig.sheet.isStartEnabled, name)
            XCTAssertNil(rig.storedMRU, name)
        }
    }

    func testASenderThatFailsImmediatelyLeavesAnErrorAndAUsableSheet() {
        let rig = SheetRig()
        rig.sender.answerImmediately = .failed(WorkError(code: "not_connected", message: "Not connected to nostromd"))

        rig.sheet.primaryTapped()

        XCTAssertTrue(rig.sheet.errorText.contains("Not connected to nostromd"), rig.sheet.errorText)
        XCTAssertFalse(rig.sheet.isSending)
        XCTAssertTrue(rig.sheet.isStartEnabled)
        XCTAssertTrue(rig.results.isEmpty)
    }

    func testAfterAFailureTheUserCanFixThingsAndStartAgain() throws {
        let rig = SheetRig(preview: makePreview(workingDirectory: alpha), mruKey: "jira:CORE")
        let sheet = rig.sheet!
        sheet.primaryTapped()
        rig.sender.answer(sendErr("spawn_failed", "could not start the agent"))

        sheet.selectProject(beta)
        sheet.primaryTapped()

        XCTAssertEqual(rig.sender.requests.count, 2)
        let retry = try XCTUnwrap(rig.sender.requests.last)
        XCTAssertEqual(retry.workingDirectory, beta)
        XCTAssertNotEqual(retry.requestId, rig.sender.requests[0].requestId, "each attempt has its own request id")

        rig.sender.answer(sendOK("created", focusTag: "claudia-core-12"), at: 1)

        XCTAssertEqual(rig.results, [.sent(outcome("created", focusTag: "claudia-core-12"))])
        XCTAssertEqual(rig.mru.lastProject(for: "jira:CORE"), beta, "the project that worked is the one remembered")
    }

    // MARK: Repeat sends

    func testAnItemWithALiveFocusDefaultsToGoToExistingAndOffersCreateAnother() {
        let rig = SheetRig(preview: makePreview(existing: [markerJSON("focus", target: "claudia-core-12", label: "CORE-12")]))
        let sheet = rig.sheet!

        XCTAssertEqual(sheet.primaryButtonTitle, "Go to existing focus")
        XCTAssertEqual(sheet.secondaryButtonTitle, "Create another")
        XCTAssertTrue(sheet.isStartEnabled)
    }

    func testAnItemWithAJobDefaultsToGoToExistingJob() {
        let rig = SheetRig(preview: makePreview(existing: [markerJSON("mother_job", target: "abc123", label: "CORE-12")]))

        XCTAssertEqual(rig.sheet.primaryButtonTitle, "Go to existing job")
        XCTAssertEqual(rig.sheet.secondaryButtonTitle, "Create another")
    }

    func testGoToExistingSendsNothingAndHandsBackTheMarker() {
        let marker = makeMarker("focus", target: "claudia-core-12", label: "CORE-12")
        let rig = SheetRig(preview: makePreview(existing: [markerJSON("focus", target: "claudia-core-12", label: "CORE-12")]))

        rig.sheet.primaryTapped()

        XCTAssertTrue(rig.sender.requests.isEmpty, "nothing is created")
        XCTAssertEqual(rig.results, [.goToExisting(marker)])
        XCTAssertNil(rig.storedMRU)
    }

    func testGoToExistingIsAvailableEvenWithoutAProject() {
        let rig = SheetRig(preview: makePreview(workingDirectory: nil,
                                                existing: [markerJSON("focus", target: "claudia-core-12")]),
                           mruKey: nil)

        XCTAssertTrue(rig.sheet.isStartEnabled, "jumping to what exists needs no project")
        rig.sheet.primaryTapped()
        XCTAssertEqual(rig.results, [.goToExisting(makeMarker())])
    }

    func testWithSeveralExistingMarkersGoToExistingTargetsTheNewest() {
        let older = markerJSON("focus", target: "claudia-core-12", label: "first", createdAt: "2026-10-08T09:00:00Z")
        let newer = markerJSON("focus", target: "claudia-core-12-2", label: "second", createdAt: "2026-10-09T09:00:00Z")
        let rig = SheetRig(preview: makePreview(existing: [older, newer]))

        rig.sheet.primaryTapped()

        XCTAssertEqual(rig.results,
                       [.goToExisting(makeMarker("focus", target: "claudia-core-12-2", label: "second",
                                                 createdAt: "2026-10-09T09:00:00Z"))])
    }

    func testCreateAnotherSendsWithAllowDuplicateAndTheEditedFields() throws {
        let rig = SheetRig(preview: makePreview(itemId: "jira:CORE-12", agent: "claudia", workingDirectory: alpha,
                                                existing: [markerJSON("focus")]),
                           mruKey: "jira:CORE")
        let sheet = rig.sheet!
        sheet.selectAgent("cody")
        sheet.typeLabel("CORE-12 again")

        sheet.secondaryTapped()

        let request = try XCTUnwrap(rig.sender.requests.first)
        XCTAssertEqual(rig.sender.requests.count, 1)
        XCTAssertTrue(request.allowDuplicate)
        XCTAssertEqual(request.destination, "focus")
        XCTAssertEqual(request.agent, "cody")
        XCTAssertEqual(request.label, "CORE-12 again")
        XCTAssertEqual(request.workingDirectory, alpha)
        XCTAssertTrue(rig.results.isEmpty, "waiting for the daemon")

        rig.sender.answer(sendOK("created", focusTag: "cody-core-12-again"))

        XCTAssertEqual(rig.results, [.sent(outcome("created", focusTag: "cody-core-12-again"))])
        XCTAssertEqual(rig.mru.lastProject(for: "jira:CORE"), alpha)
    }

    func testAFirstTimeSheetHasNoCreateAnother() {
        let rig = SheetRig()

        XCTAssertNil(rig.sheet.secondaryButtonTitle)
    }

    // MARK: Cancel, Esc and Return

    func testCancelSendsNothingAndReportsCancelled() {
        let rig = SheetRig()

        rig.sheet.cancelTapped()

        XCTAssertTrue(rig.sender.requests.isEmpty)
        XCTAssertEqual(rig.results, [.cancelled])
        XCTAssertNil(rig.storedMRU)
    }

    func testEscapeIsTheCancelButtonsKeyAndClickingItCancels() throws {
        let rig = SheetRig()
        let sheet = rig.sheet!
        XCTAssertEqual(sheet.cancelButton.keyEquivalent, "\u{1b}")
        XCTAssertTrue(sheet.cancelButton.isEnabled)
        let content = try XCTUnwrap(sheet.window?.contentView)
        XCTAssertTrue(sheet.cancelButton.isDescendant(of: content), "a key equivalent only fires for a button in the window")

        sheet.cancelButton.performClick(nil)

        XCTAssertTrue(rig.sender.requests.isEmpty)
        XCTAssertEqual(rig.results, [.cancelled])
    }

    func testReturnIsTheStartButtonsKeyAndClickingItSends() throws {
        let rig = SheetRig()
        let sheet = rig.sheet!
        XCTAssertEqual(sheet.primaryButton.keyEquivalent, "\r")
        XCTAssertTrue(sheet.primaryButton.isEnabled)
        let content = try XCTUnwrap(sheet.window?.contentView)
        XCTAssertTrue(sheet.primaryButton.isDescendant(of: content), "a key equivalent only fires for a button in the window")

        sheet.primaryButton.performClick(nil)

        XCTAssertEqual(rig.sender.requests.count, 1)
        XCTAssertFalse(rig.sender.requests[0].allowDuplicate)
    }

    func testInExistingModeReturnGoesToTheExistingFocusAndSendsNothing() {
        let rig = SheetRig(preview: makePreview(existing: [markerJSON()]))

        XCTAssertEqual(rig.sheet.primaryButton.keyEquivalent, "\r")
        rig.sheet.primaryButton.performClick(nil)

        XCTAssertTrue(rig.sender.requests.isEmpty)
        XCTAssertEqual(rig.results, [.goToExisting(makeMarker())])
    }

    // MARK: Org

    func testTheOrgFollowsTheProjectAndIsADashUntilItIsKnown() {
        let orgs = GatedOrgs([alpha: .resolved("Carefeed"), beta: .resolved("Personal"), gamma: .resolved(nil)])
        let rig = SheetRig(preview: makePreview(workingDirectory: alpha), orgs: orgs)
        let sheet = rig.sheet!
        XCTAssertEqual(sheet.orgText, "—", "not resolved yet")

        orgs.release(alpha)
        XCTAssertTrue(waitUntil { sheet.orgText == "Carefeed" }, sheet.orgText)

        sheet.selectProject(beta)
        orgs.release(beta)
        XCTAssertTrue(waitUntil { sheet.orgText == "Personal" }, sheet.orgText)

        sheet.selectProject(gamma)
        orgs.release(gamma)
        XCTAssertTrue(waitUntil { sheet.orgText == "—" }, "a repo with no known owner has no org: \(sheet.orgText)")
        flushMain()
        XCTAssertEqual(sheet.orgText, "—")

        sheet.selectProject(nil)
        XCTAssertEqual(sheet.orgText, "—")
    }

    func testALateOrgAnswerForAnEarlierProjectDoesNotOverwriteTheCurrentOne() {
        let orgs = GatedOrgs([alpha: .resolved("Carefeed"), beta: .resolved("Personal")])
        let rig = SheetRig(preview: makePreview(workingDirectory: alpha), orgs: orgs)
        let sheet = rig.sheet!

        // The user moves on to beta while alpha's lookup is still pending.
        sheet.selectProject(beta)
        orgs.release(beta)
        XCTAssertTrue(waitUntil { sheet.orgText == "Personal" }, sheet.orgText)

        // Now alpha's lookup finishes. Callers waiting on one path are called in the order
        // they asked, in one main-queue block, so once ours has run the sheet's has too.
        var alphaDelivered = false
        rig.resolver.resolve(alpha) { _ in alphaDelivered = true }
        orgs.release(alpha)
        XCTAssertTrue(waitUntil { alphaDelivered }, "alpha's lookup never delivered")

        XCTAssertEqual(sheet.orgText, "Personal", "the answer for the project that is selected now wins")
    }
}

// MARK: - The project memory

final class TeriProjectMRUTests: XCTestCase {
    private var suites: [String] = []

    private func makeDefaults() -> UserDefaults {
        let name = "TeriProjectMRUTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        suites.removeAll()
        super.tearDown()
    }

    func testAnUnknownKeyHasNoProject() {
        let mru = TeriProjectMRU(defaults: makeDefaults())

        XCTAssertNil(mru.lastProject(for: "jira:CORE"))
    }

    func testARecordedProjectIsReadBack() {
        let mru = TeriProjectMRU(defaults: makeDefaults())

        mru.record("/Users/test/Code/portal", for: "jira:CORE")

        XCTAssertEqual(mru.lastProject(for: "jira:CORE"), "/Users/test/Code/portal")
    }

    func testRecordingAgainReplacesTheProjectForThatKey() {
        let mru = TeriProjectMRU(defaults: makeDefaults())
        mru.record("/Users/test/Code/portal", for: "jira:CORE")

        mru.record("/Users/test/Code/api", for: "jira:CORE")

        XCTAssertEqual(mru.lastProject(for: "jira:CORE"), "/Users/test/Code/api")
    }

    func testKeysAreIndependent() {
        let mru = TeriProjectMRU(defaults: makeDefaults())

        mru.record("/Users/test/Code/portal", for: "jira:CORE")
        mru.record("/Users/test/Code/web", for: "sentry:web-app")
        mru.record("/Users/test/Code/notes", for: "todos")
        mru.record("/Users/test/Code/api", for: "jira:CORE")

        XCTAssertEqual(mru.lastProject(for: "jira:CORE"), "/Users/test/Code/api")
        XCTAssertEqual(mru.lastProject(for: "sentry:web-app"), "/Users/test/Code/web")
        XCTAssertEqual(mru.lastProject(for: "todos"), "/Users/test/Code/notes")
        XCTAssertNil(mru.lastProject(for: "jira:INT"))
    }

    func testItIsStoredAsOneStringDictionaryUnderTheVersionedKey() {
        let defaults = makeDefaults()
        let mru = TeriProjectMRU(defaults: defaults)

        mru.record("/Users/test/Code/portal", for: "jira:CORE")
        mru.record("/Users/test/Code/web", for: "sentry:web-app")

        XCTAssertEqual(defaults.dictionary(forKey: "nostromo.teri.projectMRU.v1") as? [String: String],
                       ["jira:CORE": "/Users/test/Code/portal", "sentry:web-app": "/Users/test/Code/web"])
    }

    func testAProjectSurvivesBeingReadByAFreshInstance() {
        let defaults = makeDefaults()
        TeriProjectMRU(defaults: defaults).record("/Users/test/Code/portal", for: "jira:CORE")

        XCTAssertEqual(TeriProjectMRU(defaults: defaults).lastProject(for: "jira:CORE"), "/Users/test/Code/portal")
    }

    func testEntriesAlreadyInTheDefaultsAreKeptWhenOneIsAdded() {
        let defaults = makeDefaults()
        defaults.set(["todos": "/Users/test/Code/notes"], forKey: "nostromo.teri.projectMRU.v1")
        let mru = TeriProjectMRU(defaults: defaults)

        mru.record("/Users/test/Code/portal", for: "jira:CORE")

        XCTAssertEqual(mru.lastProject(for: "todos"), "/Users/test/Code/notes")
        XCTAssertEqual(mru.lastProject(for: "jira:CORE"), "/Users/test/Code/portal")
    }
}
