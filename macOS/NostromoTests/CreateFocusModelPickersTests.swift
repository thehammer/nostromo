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


/// Draw `content` on the popover's dark surface in a window that reports itself key (or not) under
/// the pinned Dark Aqua, and measure each visible text label and titled push button in it: the
/// fill it sits on and its brightest pixel.
func modelRenderedText(in content: NSView, size: NSSize, windows: WindowBag, key: Bool,
                       background: NSColor = NSColor(calibratedWhite: 0.15, alpha: 1)) -> [(text: String, measure: RegionLuminance)] {
    let window = windows.makeStateWindow(key: key, width: size.width, height: size.height)
    window.appearance = NSAppearance(named: .darkAqua)
    let host = NSView(frame: NSRect(origin: .zero, size: size))
    host.wantsLayer = true
    host.layer?.backgroundColor = background.cgColor
    window.contentView = host
    host.addSubview(content)
    window.orderFront(nil)
    host.layoutSubtreeIfNeeded()

    func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
    return all(content).compactMap { view -> (String, RegionLuminance)? in
        let text: String
        switch view {
        case let field as NSTextField where !field.isHidden && !field.stringValue.isEmpty: text = field.stringValue
        case let button as NSButton where !(button is NSPopUpButton) && !button.isHidden && !button.attributedTitle.string.isEmpty:
            text = button.attributedTitle.string
        default: return nil
        }
        let region = view.convert(view.bounds, to: host)
        return (text, measureRegion(of: host, region: region, textArea: region.insetBy(dx: 0, dy: 2)))
    }
}

final class CreateFocusModelPickersTests: XCTestCase {

    private var sender: ModelRequestRecorder!
    private var store: ModelStore!
    private var tempDirs: [URL] = []
    private let windows = WindowBag()
    private var previousAppearance: NSAppearance?

    override func setUp() {
        super.setUp()
        previousAppearance = NSApplication.shared.appearance
        AppAppearance.apply(to: NSApplication.shared)
        sender = ModelRequestRecorder()
        store = ModelStore(sender: sender, makeRequestId: { "req-1" })
    }

    override func tearDown() {
        windows.tearDown()
        NSApplication.shared.appearance = previousAppearance
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
        XCTAssertEqual(pickers.modelPopup.titleOfSelectedItem, "CLI default")
        XCTAssertEqual(pickers.effortPopup.titleOfSelectedItem, "Default")
    }

    func testModelPickerListsDefaultThenFamiliesCheapestFirst() {
        let pickers = makePickers(agent: "zed")
        XCTAssertEqual(pickers.modelTitles, ["CLI default", "Haiku", "Sonnet", "Opus"])
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

    // The first item means different things per agent: its own resolved start, or the CLI's default.
    func testTheModelPickersFirstItemNamesWhatDefaultMeansForTheAgent() {
        let pickers = makePickers(agent: "claudia")
        XCTAssertEqual(pickers.modelTitles.first, "Agent default (Opus)", "claudia has a default: Opus")
        pickers.agentChanged(to: "cody")
        XCTAssertEqual(pickers.modelTitles.first, "Agent default (Sonnet)", "cody declares Sonnet")
        pickers.agentChanged(to: "zed")
        XCTAssertEqual(pickers.modelTitles.first, "CLI default", "zed has nothing of its own")
    }

    // MARK: Pickers: effort needs a model

    func testTheEffortPickerIsOffWithAReasonWhenNoModelResolves() {
        let pickers = makePickers(agent: "zed")
        XCTAssertFalse(pickers.effortPopup.isEnabled)
        XCTAssertEqual(pickers.effortPopup.toolTip, "Choose a model first")
        XCTAssertEqual(pickers.effortPopup.titleOfSelectedItem, "Default")
    }

    func testTheEffortPickerIsOnWhenTheAgentResolvesAModel() {
        for agent in ["claudia", "cody"] {
            let pickers = makePickers(agent: agent)
            XCTAssertTrue(pickers.effortPopup.isEnabled, agent)
            XCTAssertNil(pickers.effortPopup.toolTip, agent)
        }
    }

    func testPickingAModelTurnsTheEffortPickerOn() {
        let pickers = makePickers(agent: "zed")
        pickers.userPickModel("opus")
        XCTAssertTrue(pickers.effortPopup.isEnabled)
        XCTAssertNil(pickers.effortPopup.toolTip)
    }

    func testAnEffortCannotBePickedWhileNoModelResolves() {
        let pickers = makePickers(agent: "zed")
        pickers.userPickEffort("high")
        XCTAssertNil(pickers.selectedEffort)
        XCTAssertNil(pickers.choice, "nothing was chosen, so nothing is sent")
    }

    func testGoingBackToDefaultModelDropsTheEffortWhenNoModelResolves() {
        let pickers = makePickers(agent: "zed")
        pickers.userPickModel("opus")
        pickers.userPickEffort("high")
        pickers.userPickModel(nil)   // "CLI default"
        XCTAssertFalse(pickers.effortPopup.isEnabled)
        XCTAssertNil(pickers.selectedEffort, "a stale effort would be sent with no model to attach to")
        XCTAssertEqual(pickers.choice, CreateFocusModelPickers.Choice(model: nil, effort: nil))
    }

    func testGoingBackToDefaultModelKeepsTheEffortWhenTheAgentResolvesAModel() {
        let pickers = makePickers(agent: "cody")   // declares Sonnet
        pickers.userPickModel("opus")
        pickers.userPickEffort("high")
        pickers.userPickModel(nil)                 // "Agent default (Sonnet)", which offers high
        XCTAssertTrue(pickers.effortPopup.isEnabled)
        XCTAssertEqual(pickers.selectedEffort, "high")
        XCTAssertEqual(pickers.choice, CreateFocusModelPickers.Choice(model: "sonnet", effort: "high"))
    }

    func testChangingToAnAgentWithNoModelDropsATouchedEffort() {
        let pickers = makePickers(agent: "cody")
        pickers.userPickEffort("low")
        pickers.agentChanged(to: "zed")
        XCTAssertFalse(pickers.effortPopup.isEnabled)
        XCTAssertNil(pickers.selectedEffort)
        XCTAssertEqual(pickers.choice, CreateFocusModelPickers.Choice(model: nil, effort: nil))
    }

    // MARK: VoiceOver

    func testThePickersHaveVoiceOverLabels() {
        let pickers = makePickers(agent: "claudia")
        XCTAssertEqual(pickers.modelPopup.accessibilityLabel(), "Model")
        XCTAssertEqual(pickers.effortPopup.accessibilityLabel(), "Effort")
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


    // MARK: Sheet: VoiceOver and legibility

    func testTheSheetsModelAndEffortPickersAreLabelledForVoiceOver() {
        let sheet = makeSheet { _ in }
        XCTAssertEqual(sheet.pickers.modelPopup.accessibilityLabel(), "Model")
        XCTAssertEqual(sheet.pickers.effortPopup.accessibilityLabel(), "Effort")
    }

    /// The sheet's content drawn the way the pinned Dark Aqua window draws it, in a window that
    /// reports itself key or not. Returns the host, with the sheet's content inside.
    private func renderedSheet(_ sheet: CreateFocusSheet, key: Bool) throws -> (host: NSView, content: NSView) {
        let sheetWindow = try XCTUnwrap(sheet.window)
        let content = try XCTUnwrap(sheetWindow.contentView)
        let size = content.frame.size
        sheetWindow.contentView = NSView()   // let go of the content so a test window can show it
        let window = windows.makeStateWindow(key: key, width: size.width, height: size.height)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        var background = NSColor.windowBackgroundColor.cgColor
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.cgColor }
        host.layer?.backgroundColor = background
        window.contentView = host
        host.addSubview(content)
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return (host, content)
    }

    func testTheModelAndEffortRowsOfTheSheetAreLegibleInTheKeyWindowAndAnInactiveOne() throws {
        for key in [true, false] {
            let sheet = makeSheet { _ in }
            let (host, content) = try renderedSheet(sheet, key: key)
            func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
            let labels = all(content).compactMap { $0 as? NSTextField }.filter { ["Model:", "Effort:"].contains($0.stringValue) }
            XCTAssertEqual(labels.count, 2, "the Model: and Effort: captions")
            var measured: [(String, RegionLuminance)] = labels.map { label in
                let region = label.convert(label.bounds, to: host)
                return (label.stringValue, measureRegion(of: host, region: region, textArea: region.insetBy(dx: 0, dy: 2)))
            }
            for popup in [sheet.pickers.modelPopup, sheet.pickers.effortPopup] {
                XCTAssertTrue(popup.isEnabled, "precondition: claudia resolves a model, so both pickers are on")
                let region = popup.convert(popup.bounds, to: host)
                // The text sits left of the pop-up arrows.
                let text = NSRect(x: region.minX + 8, y: region.minY + 4, width: region.width - 30, height: region.height - 8)
                measured.append((popup.titleOfSelectedItem ?? "popup", measureRegion(of: host, region: region, textArea: text)))
            }
            for (text, m) in measured {
                let ratio = modelContrastRatio(m.brightestText, m.fill)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\"\(text)\" in a \(key ? "key" : "inactive") window: \(ratio):1 (text \(m.brightestText) on \(m.fill))")
                XCTAssertGreaterThan(m.brightestText, m.fill, "\"\(text)\": light on dark")
            }
        }
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
    private let windows = WindowBag()
    private var previousAppearance: NSAppearance?

    override func setUp() {
        super.setUp()
        previousAppearance = NSApplication.shared.appearance
        AppAppearance.apply(to: NSApplication.shared)
        sender = ModelRequestRecorder()
        store = ModelStore(sender: sender, makeRequestId: { "req-1" })
    }

    override func tearDown() {
        windows.tearDown()
        NSApplication.shared.appearance = previousAppearance
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

    // MARK: Loading, not received vs none

    func testBeforeTheFirstDefaultsFrameTheListSaysItIsLoadingNotThatThereAreNone() {
        let view = ModelDefaultsView(store: store)
        XCTAssertEqual(view.emptyStateText, "Loading agent defaults\u{2026}")
        XCTAssertTrue(view.rows.isEmpty)
    }

    func testOnceADefaultsFrameWithNothingInItArrivesTheListSaysThereAreNone() {
        let view = ModelDefaultsView(store: store)
        store.ingest(.modelDefaults(defaults: [:], declared: [:]))
        pumpMain()
        XCTAssertEqual(view.emptyStateText, "No agent defaults yet")
    }

    func testARowedListShowsNoEmptyStateLine() {
        store.ingest(.modelDefaults(defaults: ["claudia": AgentModelDefaultWire(model: "opus")], declared: [:]))
        XCTAssertNil(ModelDefaultsView(store: store).emptyStateText)
    }

    // MARK: VoiceOver

    func testTheListAndItsClearButtonsHaveVoiceOverLabels() {
        store.ingest(.modelDefaults(defaults: ["claudia": AgentModelDefaultWire(model: "opus"),
                                               "cody": AgentModelDefaultWire(model: "sonnet")], declared: [:]))
        let view = ModelDefaultsView(store: store)
        XCTAssertEqual(view.accessibilityLabel(), "Agent defaults")
        XCTAssertEqual(view.accessibilityRole(), .group)
        XCTAssertEqual(view.clearButtons.map { $0.accessibilityLabel() },
                       ["Clear default for claudia", "Clear default for cody"])
    }

    // MARK: Legibility (bitmap)

    /// Every text label and Clear button of the list drawn on the popover's dark surface, under the
    /// pinned Dark Aqua, in a window that is key or not.
    private func measureList(key: Bool) -> [(text: String, measure: RegionLuminance)] {
        let view = ModelDefaultsView(store: store)
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        return modelRenderedText(in: view, size: size, windows: windows, key: key)
    }

    func testEveryLineOfTheDefaultsListIsLegibleInTheKeyWindowAndAnInactiveOne() {
        store.ingest(.modelCatalog(families: catalog.families, stale: false, fetchedAt: nil))
        store.ingest(.modelDefaults(defaults: ["claudia": AgentModelDefaultWire(model: "opus", effort: "high")],
                                    declared: ["perri": "sonnet"]))
        for key in [true, false] {
            let measured = measureList(key: key)
            XCTAssertGreaterThanOrEqual(measured.count, 5, "header, 2 names, 2 summaries, 1 clear: \(measured.map(\.text))")
            for (text, m) in measured {
                let ratio = modelContrastRatio(m.brightestText, m.fill)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\"\(text)\" in a \(key ? "key" : "inactive") window: \(ratio):1")
                XCTAssertGreaterThan(m.brightestText, m.fill, "\"\(text)\": light on dark")
            }
        }
    }

    func testTheLoadingAndEmptyLinesAreLegibleInTheKeyWindowAndAnInactiveOne() {
        for key in [true, false] {
            for frame in [false, true] {
                let fresh = ModelStore(sender: sender, makeRequestId: { "req-1" })
                if frame { fresh.ingest(.modelDefaults(defaults: [:], declared: [:])) }
                let view = ModelDefaultsView(store: fresh)
                view.layoutSubtreeIfNeeded()
                let size = view.fittingSize
                view.frame = NSRect(origin: .zero, size: size)
                let measured = modelRenderedText(in: view, size: size, windows: windows, key: key)
                XCTAssertGreaterThanOrEqual(measured.count, 2, "header and the empty-state line")
                for (text, m) in measured {
                    let ratio = modelContrastRatio(m.brightestText, m.fill)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\"\(text)\" in a \(key ? "key" : "inactive") window: \(ratio):1")
                }
            }
        }
    }
}
