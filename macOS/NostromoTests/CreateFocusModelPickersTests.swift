import XCTest
import AppKit
import NostromoKit

// M3: choosing the model at focus creation, and the per-agent defaults list.
//
// What the user sees: the create sheet's Model and Effort pickers start on what a new focus of the
// selected agent would get (its default, else its declared model, else "Default"), follow the agent
// popup until touched, then stay. An untouched pair sends nothing; a touched one rides on the new
// Focus as initialModel / initialEffort. The defaults list shows what each agent's new focuses start
// on, and Set / Clear go to the daemon as requests.

final class CreateFocusModelPickersTests: XCTestCase {

    private var sender: ModelRequestRecorder!
    private var store: ModelStore!
    private var tempDirs: [URL] = []

    override func setUp() {
        super.setUp()
        sender = ModelRequestRecorder()
        store = ModelStore(sender: sender, makeRequestId: { "req-1" })
    }

    override func tearDown() {
        tempDirs.forEach { try? FileManager.default.removeItem(at: $0) }
        tempDirs = []
        store = nil
        sender = nil
        super.tearDown()
    }

    // MARK: Fixtures

    private static let allLevels = ["low", "medium", "high", "xhigh", "max"]

    private func family(_ alias: String, rank: Int, efforts: [String]) -> ModelFamilyWire {
        ModelFamilyWire(alias: alias, displayName: alias.capitalized, resolved: "claude-\(alias)-1", efforts: efforts, rank: rank)
    }

    /// Haiku takes no effort; Sonnet low..high; Opus everything.
    private func ingestCatalog() {
        store.ingest(.modelCatalog(families: [
            family("opus", rank: 3, efforts: Self.allLevels),
            family("haiku", rank: 1, efforts: []),
            family("sonnet", rank: 2, efforts: ["low", "medium", "high"]),
        ], stale: false, fetchedAt: nil))
    }

    /// claudia has a default (Opus, high); cody declares Sonnet; zed has nothing.
    private func ingestDefaults(
        defaults: [String: AgentModelDefaultWire] = ["claudia": AgentModelDefaultWire(model: "opus", effort: "high")],
        declared: [String: String] = ["cody": "sonnet"]
    ) {
        store.ingest(.modelDefaults(defaults: defaults, declared: declared))
    }

    private func pumpMain(_ seconds: TimeInterval = 0.3) {
        let e = expectation(description: "pump")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: 20)
    }

    private func makePickers(agent: String? = nil) -> CreateFocusModelPickers {
        ingestCatalog()
        ingestDefaults()
        let pickers = CreateFocusModelPickers(store: store)
        pickers.agentChanged(to: agent)
        return pickers
    }

    // MARK: Pickers: start, follow, stick

    func testPickersStartOnTheAgentsDefaultModelAndEffort() {
        let pickers = makePickers(agent: "claudia")
        XCTAssertEqual(pickers.selectedModel, "opus")
        XCTAssertEqual(pickers.selectedEffort, "high")
    }

    func testPickersStartOnTheAgentsDeclaredModelWhenItHasNoDefault() {
        let pickers = makePickers(agent: "cody")
        XCTAssertEqual(pickers.selectedModel, "sonnet")
        XCTAssertNil(pickers.selectedEffort)
    }

    func testPickersStartOnDefaultWhenTheAgentHasNeither() {
        let pickers = makePickers(agent: "zed")
        XCTAssertNil(pickers.selectedModel)
        XCTAssertNil(pickers.selectedEffort)
        XCTAssertEqual(pickers.modelPopup.titleOfSelectedItem, "Default")
        XCTAssertEqual(pickers.effortPopup.titleOfSelectedItem, "Default")
    }

    func testModelPickerListsDefaultThenFamiliesCheapestFirst() {
        let pickers = makePickers(agent: "zed")
        XCTAssertEqual(pickers.modelTitles, ["Default", "Haiku", "Sonnet", "Opus"])
    }

    func testUntouchedPickersFollowTheAgentPopup() {
        let pickers = makePickers(agent: "claudia")
        pickers.agentChanged(to: "cody")
        XCTAssertEqual(pickers.selectedModel, "sonnet")
        XCTAssertNil(pickers.selectedEffort)
        pickers.agentChanged(to: "zed")
        XCTAssertNil(pickers.selectedModel)
        pickers.agentChanged(to: "claudia")
        XCTAssertEqual(pickers.selectedModel, "opus")
        XCTAssertEqual(pickers.selectedEffort, "high")
    }

    func testAPickedModelStaysWhenTheAgentChanges() {
        let pickers = makePickers(agent: "claudia")
        pickers.userPickModel("haiku")
        pickers.agentChanged(to: "cody")
        XCTAssertEqual(pickers.selectedModel, "haiku")
        pickers.agentChanged(to: "claudia")
        XCTAssertEqual(pickers.selectedModel, "haiku", "the agent's default does not take it back")
    }

    func testAPickedEffortStaysWhileTheModelStillFollowsTheAgent() {
        let pickers = makePickers(agent: "cody")
        pickers.userPickEffort("low")
        pickers.agentChanged(to: "claudia")
        XCTAssertEqual(pickers.selectedEffort, "low", "touching effort alone keeps it")
        XCTAssertEqual(pickers.selectedModel, "opus", "the untouched model still follows the agent")
    }

    func testAnEffortTheNewModelDoesNotOfferFallsBackToDefault() {
        let pickers = makePickers(agent: "claudia")
        pickers.userPickEffort("max")
        pickers.userPickModel("sonnet")   // offers low..high
        XCTAssertNil(pickers.selectedEffort, "Sonnet does not offer max")
    }

    /// PRD: levels the selected model doesn't support are shown disabled (the model popup does this
    /// for a model whose list is empty: "doesn't support effort levels"). The sheet must agree.
    func testAModelThatTakesNoEffortOffersOnlyDefault() {
        let pickers = makePickers(agent: "claudia")
        pickers.userPickEffort("max")
        pickers.userPickModel("haiku")
        XCTAssertNil(pickers.selectedEffort, "Haiku takes no effort")
        let enabled = pickers.effortPopup.menu?.items.filter(\.isEnabled).map(\.title)
        XCTAssertEqual(enabled, ["Default"])
        XCTAssertEqual(pickers.choice, CreateFocusModelPickers.Choice(model: "haiku", effort: nil))
    }

    func testPickersFollowDefaultsThatArriveWhileTheSheetIsOpen() {
        ingestCatalog()
        let pickers = CreateFocusModelPickers(store: store)
        pickers.agentChanged(to: "claudia")
        XCTAssertNil(pickers.selectedModel, "no defaults known yet")

        ingestDefaults()
        pumpMain()

        XCTAssertEqual(pickers.selectedModel, "opus")
        XCTAssertEqual(pickers.selectedEffort, "high")
    }

    // MARK: Pickers: choice

    func testAnUntouchedPairHasNoChoice() {
        XCTAssertNil(makePickers(agent: "claudia").choice, "the daemon resolves the defaults itself")
        XCTAssertNil(makePickers(agent: "zed").choice)
    }

    func testAnUntouchedPairStaysUntouchedAcrossAgentChanges() {
        let pickers = makePickers(agent: "claudia")
        pickers.agentChanged(to: "cody")
        XCTAssertNil(pickers.choice)
    }

    func testATouchedModelIsTheChoice() {
        let pickers = makePickers(agent: "zed")
        pickers.userPickModel("sonnet")
        XCTAssertEqual(pickers.choice, CreateFocusModelPickers.Choice(model: "sonnet", effort: nil))
    }

    func testTheChoiceIsWhatThePickersShowIncludingAnEffortCarriedOverFromTheAgentsDefault() {
        let pickers = makePickers(agent: "claudia")   // Opus, high
        pickers.userPickModel("sonnet")                // Sonnet offers high, so it stays
        XCTAssertEqual(pickers.selectedEffort, "high")
        XCTAssertEqual(pickers.choice, CreateFocusModelPickers.Choice(model: "sonnet", effort: "high"))
    }

    func testATouchedModelAndEffortAreTheChoice() {
        let pickers = makePickers(agent: "zed")
        pickers.userPickModel("opus")
        pickers.userPickEffort("max")
        XCTAssertEqual(pickers.choice, CreateFocusModelPickers.Choice(model: "opus", effort: "max"))
    }

    func testATouchedEffortAloneRidesOnTheAgentsResolvedModel() {
        let pickers = makePickers(agent: "cody")
        pickers.userPickEffort("low")
        XCTAssertEqual(pickers.choice, CreateFocusModelPickers.Choice(model: "sonnet", effort: "low"))
    }

    // MARK: Sheet

    private func makeSheet(onCreate: @escaping (Focus) -> Void) -> CreateFocusSheet {
        ingestCatalog()
        ingestDefaults()
        return CreateFocusSheet(orgResolver: RepoOrgResolver(lookup: { _ in .resolved(nil) }),
                                agents: ["claudia", "cody"], projects: ["/tmp/alpha"],
                                modelStore: store, onCreate: onCreate)
    }

    func testASheetLeftAloneCreatesAFocusWithNoModelChoice() {
        var created: [Focus] = []
        let sheet = makeSheet { created.append($0) }
        sheet.createTapped()
        pumpMain()
        XCTAssertEqual(created.count, 1)
        XCTAssertNil(created.first?.initialModel)
        XCTAssertNil(created.first?.initialEffort)
    }

    func testASheetStartsOnTheFirstAgentsDefault() {
        let sheet = makeSheet { _ in }
        XCTAssertEqual(sheet.pickers.selectedModel, "opus")
        XCTAssertEqual(sheet.pickers.selectedEffort, "high")
        sheet.selectAgent(at: 1)
        XCTAssertEqual(sheet.pickers.selectedModel, "sonnet")
        XCTAssertNil(sheet.pickers.selectedEffort)
    }

    func testTheCreatedFocusCarriesThePickedModelAndEffort() {
        var created: [Focus] = []
        let sheet = makeSheet { created.append($0) }
        sheet.pickers.userPickModel("opus")
        sheet.pickers.userPickEffort("xhigh")
        sheet.createTapped()
        pumpMain()
        XCTAssertEqual(created.first?.initialModel, "opus")
        XCTAssertEqual(created.first?.initialEffort, "xhigh")
    }

    func testThePickedModelSurvivesChangingTheAgentAndIsWhatTheFocusCarries() {
        var created: [Focus] = []
        let sheet = makeSheet { created.append($0) }
        sheet.pickers.userPickModel("haiku")
        sheet.selectAgent(at: 1)
        sheet.createTapped()
        pumpMain()
        XCTAssertEqual(created.first?.agentTag, "cody")
        XCTAssertEqual(created.first?.initialModel, "haiku")
        XCTAssertNil(created.first?.initialEffort)
    }

    // MARK: Focus persistence and the wire

    private func makeFocus(model: String? = nil, effort: String? = nil) -> Focus {
        Focus(id: UUID().uuidString, agentTag: "claudia", projectPath: "/tmp/alpha", isBuiltIn: false,
              initialModel: model, initialEffort: effort)
    }

    func testAFocusKeepsItsInitialModelThroughCodable() throws {
        let focus = makeFocus(model: "opus", effort: "high")
        let back = try JSONDecoder().decode(Focus.self, from: JSONEncoder().encode(focus))
        XCTAssertEqual(back, focus)
        XCTAssertEqual(back.initialModel, "opus")
        XCTAssertEqual(back.initialEffort, "high")
    }

    func testAFocusSavedBeforeModelChoiceExistedStillDecodes() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(makeFocus(model: "opus", effort: "high"))) as? [String: Any])
        json = json.filter { !$0.key.lowercased().contains("initial") }
        let back = try JSONDecoder().decode(Focus.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(back.agentTag, "claudia")
        XCTAssertNil(back.initialModel)
        XCTAssertNil(back.initialEffort)
    }

    private func makeFocusStore() throws -> FocusStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("create-focus-model-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return FocusStore(storageURL: dir.appendingPathComponent("focuses.json"))
    }

    func testTheRegistryProjectionCarriesTheInitialModelToTheDaemon() throws {
        let focusStore = try makeFocusStore()
        focusStore.add(makeFocus(model: "opus", effort: "high"))

        let wire = try XCTUnwrap(focusStore.wireProjection().first { $0.agent_name == "claudia" })
        XCTAssertEqual(wire.initial_model, "opus")
        XCTAssertEqual(wire.initial_effort, "high")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
        XCTAssertEqual(json["initial_model"] as? String, "opus")
        XCTAssertEqual(json["initial_effort"] as? String, "high")
    }

    func testTheRegistryProjectionOmitsTheInitialModelWhenNoneWasChosen() throws {
        let focusStore = try makeFocusStore()
        focusStore.add(makeFocus())

        let wire = try XCTUnwrap(focusStore.wireProjection().first { $0.agent_name == "claudia" })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
        XCTAssertNil(json["initial_model"])
        XCTAssertNil(json["initial_effort"])
    }

    func testCreatingAFocusWithAModelFlushesTheRegistryBeforeSwitchingToIt() throws {
        let focusStore = try makeFocusStore()
        var events: [String] = []
        FocusCreation.commit(makeFocus(model: "opus"), store: focusStore,
                             flushRegistry: { events.append("flush") }, switch: { _ in events.append("switch") })
        XCTAssertEqual(events, ["flush", "switch"], "the daemon must hold the choice before the session starts")
    }

    func testCreatingAFocusWithoutAModelDoesNotForceAFlush() throws {
        let focusStore = try makeFocusStore()
        var events: [String] = []
        FocusCreation.commit(makeFocus(), store: focusStore,
                             flushRegistry: { events.append("flush") }, switch: { _ in events.append("switch") })
        XCTAssertEqual(events, ["switch"])
    }
}

// MARK: - Per-agent defaults list

final class ModelDefaultsViewTests: XCTestCase {

    private var sender: ModelRequestRecorder!
    private var store: ModelStore!

    override func setUp() {
        super.setUp()
        sender = ModelRequestRecorder()
        store = ModelStore(sender: sender, makeRequestId: { "req-1" })
    }

    override func tearDown() {
        store = nil
        sender = nil
        super.tearDown()
    }

    private var catalog: ModelCatalogState {
        ModelCatalogState(families: [
            ModelFamilyWire(alias: "sonnet", displayName: "Sonnet", resolved: "claude-sonnet-1", efforts: [], rank: 2),
            ModelFamilyWire(alias: "opus", displayName: "Opus", resolved: "claude-opus-1", efforts: [], rank: 3),
        ], stale: false, fetchedAt: nil)
    }

    private func pumpMain(_ seconds: TimeInterval = 0.3) {
        let e = expectation(description: "pump")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: 20)
    }

    func testNoDefaultsFrameYetMeansNoRows() {
        XCTAssertEqual(ModelDefaultsView.rows(defaults: nil, catalog: catalog), [])
    }

    func testRowsListEveryAgentWithADefaultOrADeclaredModelSortedByName() {
        let defaults = ModelDefaultsState(
            defaults: ["claudia": AgentModelDefaultWire(model: "opus", effort: "high"),
                       "cody": AgentModelDefaultWire(model: "sonnet")],
            declared: ["cody": "opus", "perri": "sonnet"])

        let rows = ModelDefaultsView.rows(defaults: defaults, catalog: catalog)

        XCTAssertEqual(rows, [
            ModelDefaultRow(agent: "claudia", summary: "Opus \u{00B7} high", hasDefault: true),
            ModelDefaultRow(agent: "cody", summary: "Sonnet", hasDefault: true),
            ModelDefaultRow(agent: "perri", summary: "Sonnet (agent's own)", hasDefault: false),
        ])
    }

    func testADefaultBeatsTheDeclaredModelInItsRow() {
        let defaults = ModelDefaultsState(defaults: ["cody": AgentModelDefaultWire(model: "sonnet")], declared: ["cody": "opus"])
        let rows = ModelDefaultsView.rows(defaults: defaults, catalog: catalog)
        XCTAssertEqual(rows.map(\.summary), ["Sonnet"])
        XCTAssertEqual(rows.map(\.hasDefault), [true])
    }

    func testTheDefaultEffortIsNotShown() {
        let defaults = ModelDefaultsState(defaults: ["cody": AgentModelDefaultWire(model: "opus", effort: "default")], declared: [:])
        XCTAssertEqual(ModelDefaultsView.rows(defaults: defaults, catalog: catalog).map(\.summary), ["Opus"])
    }

    func testAnAgentWithNeitherADefaultNorADeclaredModelHasNoRow() {
        let defaults = ModelDefaultsState(defaults: [:], declared: [:])
        XCTAssertEqual(ModelDefaultsView.rows(defaults: defaults, catalog: catalog), [])
    }

    func testSettingADefaultAsksTheDaemonAndTheListShowsItOnceTheDaemonAnswers() {
        store.ingest(.modelDefaults(defaults: [:], declared: ["claudia": "sonnet"]))
        let view = ModelDefaultsView(store: store)
        XCTAssertEqual(view.rows.map(\.summary), ["Sonnet (agent's own)"])

        let id = store.setDefault(agent: "claudia", model: "opus", effort: "high")

        XCTAssertEqual(id, "req-1")
        XCTAssertEqual(sender.calls.last,
                       .defaultSet(agent: "claudia", model: "opus", effort: "high", clear: false, requestId: "req-1"))
        XCTAssertEqual(view.rows.map(\.hasDefault), [false], "nothing changes until the daemon confirms")

        store.ingest(.modelDefaults(defaults: ["claudia": AgentModelDefaultWire(model: "opus", effort: "high")],
                                    declared: ["claudia": "sonnet"]))
        pumpMain()
        XCTAssertEqual(view.rows, [ModelDefaultRow(agent: "claudia", summary: "Opus \u{00B7} high", hasDefault: true)])
    }

    func testClearingADefaultAsksTheDaemonAndTheRowFallsBackToTheDeclaredModel() {
        store.ingest(.modelDefaults(defaults: ["claudia": AgentModelDefaultWire(model: "opus")],
                                    declared: ["claudia": "sonnet"]))
        let view = ModelDefaultsView(store: store)
        XCTAssertEqual(view.clearButtons.count, 1)

        view.clear(agent: "claudia")

        XCTAssertEqual(sender.calls.last,
                       .defaultSet(agent: "claudia", model: nil, effort: nil, clear: true, requestId: "req-1"))

        store.ingest(.modelDefaults(defaults: [:], declared: ["claudia": "sonnet"]))
        pumpMain()
        XCTAssertEqual(view.rows, [ModelDefaultRow(agent: "claudia", summary: "Sonnet (agent's own)", hasDefault: false)])
        XCTAssertTrue(view.clearButtons.isEmpty, "an agent that only declares a model has nothing to clear")
    }

    func testOnlyAgentsWithADefaultGetAClearButton() {
        store.ingest(.modelDefaults(defaults: ["claudia": AgentModelDefaultWire(model: "opus")],
                                    declared: ["perri": "sonnet"]))
        let view = ModelDefaultsView(store: store)
        XCTAssertEqual(view.rows.map(\.agent), ["claudia", "perri"])
        XCTAssertEqual(view.clearButtons.map { $0.identifier?.rawValue }, ["claudia"])
    }
}
