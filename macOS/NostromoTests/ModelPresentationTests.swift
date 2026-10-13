import XCTest
import NostromoKit

// ModelPresentation, ModelCatalogState and the NostromoKit wire types are compiled into this
// test target directly (logic test, no host app).
//
// Everything the model chip and popup show, with every string taken verbatim from the PRD
// ("The model chip", "The popup", "Accessibility and appearance"). Pure: no AppKit.

final class ModelPresentationTests: XCTestCase {

    // MARK: - Builders

    private func state(recorded: RecordedModelWire? = nil,
                       reported: ReportedModelWire? = nil,
                       effectiveEffort: String? = nil,
                       pending: PendingModelWire? = nil,
                       phase: SwitchPhaseWire = .steady,
                       running: Bool = false) -> SessionModelStateWire {
        SessionModelStateWire(tag: "claudia", recorded: recorded, reported: reported,
                              effectiveEffort: effectiveEffort, pending: pending,
                              phase: phase, running: running)
    }

    private func recorded(_ model: String, effort: String? = nil,
                          source: ModelSourceWire = .focus) -> RecordedModelWire {
        RecordedModelWire(model: model, effort: effort, source: source)
    }

    private func chip(_ s: SessionModelStateWire?, connected: Bool = true) -> ModelPresentation.Chip? {
        ModelPresentation.chip(state: s, isConnected: connected)
    }

    private func family(_ alias: String, rank: Int, efforts: [String], resolved: String? = nil) -> ModelFamilyWire {
        ModelFamilyWire(alias: alias, displayName: alias.capitalized, resolved: resolved, efforts: efforts, rank: rank)
    }

    private static let allLevels = ["low", "medium", "high", "xhigh", "max"]

    /// Haiku takes no effort, Sonnet takes up to high, Opus and Fable take everything.
    /// Deliberately NOT in cost order, to prove the rows are sorted by rank.
    private func catalog(stale: Bool = false) -> ModelCatalogState {
        ModelCatalogState(families: [
            family("opus", rank: 3, efforts: Self.allLevels, resolved: "claude-opus-5-5"),
            family("haiku", rank: 1, efforts: [], resolved: "claude-haiku-4-5-20251001"),
            family("fable", rank: 4, efforts: Self.allLevels, resolved: "claude-fable-5-1"),
            family("sonnet", rank: 2, efforts: ["low", "medium", "high"], resolved: "claude-sonnet-5-5"),
        ], stale: stale, fetchedAt: nil)
    }

    func testEffortRowsFollowTheFamilyOfAPinnedRecordedModel() {
        // Recorded on a pinned full name (the policy default), no alias row is checked, but the
        // efforts still come from the Sonnet family of the catalogue.
        let pinned = state(recorded: recorded("claude-sonnet-4-6", source: .cliDefault),
                           reported: ReportedModelWire(model: "claude-sonnet-4-6", family: nil), running: true)
        let rows = ModelPresentation.effortRows(state: pinned, catalog: catalog())
        XCTAssertEqual(rows.map(\.isEnabled), [true, true, true, true, false, false])
        XCTAssertEqual(rows[4].tooltip, "Sonnet doesn't support xhigh effort")
    }

    // MARK: - familyName(forModel:)

    func testFamilyNameIsDerivedFromTheFullModelName() {
        let cases: [(String, String)] = [
            ("claude-sonnet-5-5", "Sonnet"),
            ("claude-opus-4-6", "Opus"),
            ("claude-haiku-4-5-20251001", "Haiku"),
            ("claude-fable-5-1", "Fable"),
            ("claude-sonnet-4-6", "Sonnet"),     // a pinned version
        ]
        for (model, expected) in cases {
            XCTAssertEqual(ModelPresentation.familyName(forModel: model), expected, model)
        }
    }

    func testFamilyNameOfAnAliasIsTheCapitalisedAlias() {
        XCTAssertEqual(ModelPresentation.familyName(forModel: "sonnet"), "Sonnet")
        XCTAssertEqual(ModelPresentation.familyName(forModel: "opus"), "Opus")
        XCTAssertEqual(ModelPresentation.familyName(forModel: "fable"), "Fable")
    }

    func testFamilyNameOfAnUnknownFamilyIsItsCapitalisedWord() {
        XCTAssertEqual(ModelPresentation.familyName(forModel: "claude-weird-9"), "Weird")
    }

    func testFamilyNameOfDefaultIsDefault() {
        XCTAssertEqual(ModelPresentation.familyName(forModel: "default"), "Default")
    }

    // MARK: - Chip: a running session

    func testARunningSessionShowsTheFamilyItReports() throws {
        let c = try XCTUnwrap(chip(state(recorded: recorded("sonnet"),
                                         reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                                         running: true)))
        XCTAssertEqual(c.title, "Sonnet")
        XCTAssertEqual(c.tooltip, "Claude Sonnet (claude-sonnet-5-5), effort: default")
        XCTAssertEqual(c.style, .normal)
        XCTAssertTrue(c.isEnabled)
        XCTAssertEqual(c.accessibilityLabel, "Model: Sonnet, effort default. Change model")
        XCTAssertEqual(c.accessibilityHint, "⇧⌘M")
    }

    func testTheChipShowsWhatIsRunningNotWhatWasRequested() throws {
        // Asked for Opus; the CLI substituted Sonnet. The chip never shows the request as fact.
        let c = try XCTUnwrap(chip(state(recorded: recorded("opus"),
                                         reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                                         running: true)))
        XCTAssertEqual(c.title, "Sonnet")
        XCTAssertEqual(c.style, .normal)
        XCTAssertTrue(c.tooltip.contains("claude-sonnet-5-5"))
    }

    func testTheReportedFamilyIsDerivedFromTheFullNameWhenTheDaemonSendsNone() throws {
        let cases: [(String, String)] = [
            ("claude-sonnet-5-5", "Sonnet"), ("claude-opus-4-6", "Opus"),
            ("claude-haiku-4-5-20251001", "Haiku"), ("claude-fable-5-1", "Fable"),
            ("sonnet", "Sonnet"), ("claude-weird-9", "Weird"),
        ]
        for (model, expected) in cases {
            let c = try XCTUnwrap(chip(state(reported: ReportedModelWire(model: model, family: nil), running: true)), model)
            XCTAssertEqual(c.title, expected, model)
            XCTAssertEqual(c.tooltip, "Claude \(expected) (\(model)), effort: default", model)
        }
    }

    func testAnExplicitEffortIsAppendedToTheTitleAndNamedInTheTooltip() throws {
        let c = try XCTUnwrap(chip(state(recorded: recorded("opus", effort: "high"),
                                         reported: ReportedModelWire(model: "claude-opus-5-5", family: "opus"),
                                         running: true)))
        XCTAssertEqual(c.title, "Opus \u{00B7} high")
        XCTAssertEqual(c.tooltip, "Claude Opus (claude-opus-5-5), effort: high")
        XCTAssertEqual(c.accessibilityLabel, "Model: Opus, effort high. Change model")
        XCTAssertEqual(c.style, .normal)
    }

    func testEveryExplicitEffortLevelShowsInTheTitle() throws {
        for level in Self.allLevels {
            let c = try XCTUnwrap(chip(state(recorded: recorded("opus", effort: level),
                                             reported: ReportedModelWire(model: "claude-opus-5-5", family: "opus"),
                                             running: true)), level)
            XCTAssertEqual(c.title, "Opus \u{00B7} \(level)", level)
        }
    }

    func testNoEffortOrTheDefaultEffortLeavesTheTitleBare() throws {
        for effort in [nil, "default"] as [String?] {
            let c = try XCTUnwrap(chip(state(recorded: recorded("opus", effort: effort),
                                             reported: ReportedModelWire(model: "claude-opus-5-5", family: "opus"),
                                             running: true)), "\(String(describing: effort))")
            XCTAssertEqual(c.title, "Opus", "\(String(describing: effort))")
            XCTAssertEqual(c.tooltip, "Claude Opus (claude-opus-5-5), effort: default")
        }
    }

    // The daemon's `effective_effort` is the effort the session last confirmed, else the recorded
    // one: it is what is actually in force, so it drives the chip (and the popup's check mark).
    func testTheEffectiveEffortIsWhatTheChipShowsWhenItDiffersFromTheRecordedOne() throws {
        let c = try XCTUnwrap(chip(state(recorded: recorded("sonnet", effort: "high"),
                                         reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                                         effectiveEffort: "medium", running: true)))
        XCTAssertEqual(c.title, "Sonnet \u{00B7} medium")
        XCTAssertEqual(c.tooltip, "Claude Sonnet (claude-sonnet-5-5), effort: medium")
        XCTAssertEqual(c.accessibilityLabel, "Model: Sonnet, effort medium. Change model")
    }

    func testWithNoEffectiveEffortTheChipFallsBackToTheRecordedOne() throws {
        let c = try XCTUnwrap(chip(state(recorded: recorded("sonnet", effort: "high"),
                                         reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                                         effectiveEffort: nil, running: true)))
        XCTAssertEqual(c.title, "Sonnet \u{00B7} high")
        XCTAssertEqual(c.tooltip, "Claude Sonnet (claude-sonnet-5-5), effort: high")
        XCTAssertEqual(c.accessibilityLabel, "Model: Sonnet, effort high. Change model")
    }

    func testAnEffectiveEffortOfDefaultShowsNoSuffixEvenWhenTheRecordedOneIsExplicit() throws {
        let c = try XCTUnwrap(chip(state(recorded: recorded("sonnet", effort: "high"),
                                         reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                                         effectiveEffort: "default", running: true)))
        XCTAssertEqual(c.title, "Sonnet")
        XCTAssertEqual(c.tooltip, "Claude Sonnet (claude-sonnet-5-5), effort: default")
        XCTAssertEqual(c.accessibilityLabel, "Model: Sonnet, effort default. Change model")
    }

    func testAnEffectiveEffortWithNothingRecordedStillShows() throws {
        let c = try XCTUnwrap(chip(state(reported: ReportedModelWire(model: "claude-opus-5-5", family: "opus"),
                                         effectiveEffort: "high", running: true)))
        XCTAssertEqual(c.title, "Opus \u{00B7} high")
    }

    func testAStoppedSessionsChipAlsoFollowsTheEffectiveEffort() throws {
        let c = try XCTUnwrap(chip(state(recorded: recorded("opus", effort: "low"), effectiveEffort: "max", running: false)))
        XCTAssertEqual(c.title, "Opus \u{00B7} max")
    }

    func testARunningSessionWithAReportButNothingRecordedStillShowsTheReport() throws {
        let c = try XCTUnwrap(chip(state(reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                                         running: true)))
        XCTAssertEqual(c.title, "Sonnet")
        XCTAssertEqual(c.style, .normal)
        XCTAssertEqual(c.tooltip, "Claude Sonnet (claude-sonnet-5-5), effort: default")
    }

    func testARunningSessionThatHasNotReportedYetNeverShowsTheRecordedModelAsFact() throws {
        let c = try XCTUnwrap(chip(state(recorded: recorded("opus"), running: true)))
        XCTAssertEqual(c.title, "Opus")
        XCTAssertEqual(c.tooltip, "Starts on Opus")
        XCTAssertEqual(c.style, .pending)
    }

    // MARK: - Chip: a session that is not running

    func testAStoppedSessionShowsTheModelItWillStartOn() throws {
        let c = try XCTUnwrap(chip(state(recorded: recorded("sonnet", source: .focus), running: false)))
        XCTAssertEqual(c.title, "Sonnet")
        XCTAssertEqual(c.tooltip, "Starts on Sonnet")
        XCTAssertEqual(c.accessibilityLabel, "Model: Sonnet, effort default. Change model")
        XCTAssertEqual(c.accessibilityHint, "⇧⌘M")
    }

    func testAChosenStartModelIsSolidAndAnObservedOneIsDimmed() throws {
        let expectations: [(ModelSourceWire, ModelPresentation.ChipStyle)] = [
            (.focus, .normal), (.agentDefault, .normal),
            (.agentDeclared, .pending), (.cliDefault, .pending), (.unknown("from_the_future"), .pending),
        ]
        for (source, style) in expectations {
            let c = try XCTUnwrap(chip(state(recorded: recorded("sonnet", source: source), running: false)), "\(source)")
            XCTAssertEqual(c.style, style, "\(source)")
            XCTAssertEqual(c.title, "Sonnet", "\(source)")
            XCTAssertEqual(c.tooltip, "Starts on Sonnet", "\(source)")
        }
    }

    func testAStoppedSessionOnAPinnedModelShowsItsFamily() throws {
        let c = try XCTUnwrap(chip(state(recorded: recorded("claude-sonnet-4-6"), running: false)))
        XCTAssertEqual(c.title, "Sonnet")
        XCTAssertEqual(c.tooltip, "Starts on Sonnet")
    }

    func testAStoppedSessionWithAnExplicitEffortShowsItInTheTitle() throws {
        let c = try XCTUnwrap(chip(state(recorded: recorded("opus", effort: "high"), running: false)))
        XCTAssertEqual(c.title, "Opus \u{00B7} high")
    }

    // MARK: - Chip: nothing chosen, nothing reported

    func testNothingRecordedAndNothingReportedReadsDefault() throws {
        for running in [false, true] {
            let c = try XCTUnwrap(chip(state(running: running)), "running \(running)")
            XCTAssertEqual(c.title, "Default")
            XCTAssertEqual(c.tooltip, "Uses the Claude CLI default model")
            XCTAssertEqual(c.style, .normal)
            XCTAssertTrue(c.isEnabled)
            XCTAssertEqual(c.accessibilityHint, "⇧⌘M")
        }
    }

    // MARK: - Chip: a switch in progress

    func testASwitchWaitingForTheTurnToEndShowsFromArrowTo() throws {
        let c = try XCTUnwrap(chip(state(recorded: recorded("sonnet"),
                                         reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                                         pending: PendingModelWire(model: "opus"),
                                         phase: .waiting, running: true)))
        XCTAssertEqual(c.title, "Sonnet \u{2192} Opus")
        XCTAssertEqual(c.tooltip, "Switching after this turn")
        XCTAssertEqual(c.style, .pending)
        XCTAssertEqual(c.accessibilityLabel, "Model: switching from Sonnet to Opus after this turn")
        XCTAssertEqual(c.accessibilityHint, "⇧⌘M")
        XCTAssertTrue(c.isEnabled)
    }

    func testAWaitingSwitchToAnExplicitEffortShowsTheTargetsEffort() throws {
        let c = try XCTUnwrap(chip(state(recorded: recorded("sonnet"),
                                         reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                                         pending: PendingModelWire(model: "opus", effort: "high"),
                                         phase: .waiting, running: true)))
        XCTAssertEqual(c.title, "Sonnet \u{2192} Opus \u{00B7} high")
    }

    func testAPendingTargetGivenAsAFullModelNameShowsItsFamily() throws {
        let c = try XCTUnwrap(chip(state(recorded: recorded("sonnet"),
                                         reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                                         pending: PendingModelWire(model: "claude-opus-5-5"),
                                         phase: .waiting, running: true)))
        XCTAssertEqual(c.title, "Sonnet \u{2192} Opus")
    }

    func testASwitchBeingAppliedReadsSwitching() throws {
        let c = try XCTUnwrap(chip(state(recorded: recorded("sonnet"),
                                         reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                                         pending: PendingModelWire(model: "opus"),
                                         phase: .applying, running: true)))
        XCTAssertEqual(c.title, "Switching\u{2026}")
        XCTAssertEqual(c.tooltip, "Switching model")
        XCTAssertEqual(c.style, .pending)
        XCTAssertEqual(c.accessibilityLabel, "Model: switching from Sonnet to Opus")
        XCTAssertEqual(c.accessibilityHint, "⇧⌘M")
    }

    /// Every phase x running x effort combination, so no corner of the table is left to chance.
    func testEveryPhaseRunningAndEffortCombination() throws {
        let efforts: [String?] = [nil, "default", "high"]
        let pendingEfforts: [String?] = [nil, "high"]
        for running in [true, false] {
            for effort in efforts {
                // Steady: the model, with the effort only when explicit and not "default".
                let steady = try XCTUnwrap(chip(state(
                    recorded: recorded("opus", effort: effort),
                    reported: running ? ReportedModelWire(model: "claude-opus-5-5", family: "opus") : nil,
                    running: running)))
                let suffix = (effort != nil && effort != "default") ? " \u{00B7} \(effort!)" : ""
                XCTAssertEqual(steady.title, "Opus" + suffix, "steady running=\(running) effort=\(String(describing: effort))")
                XCTAssertTrue(steady.isEnabled)

                for pendingEffort in pendingEfforts {
                    let pending = PendingModelWire(model: "haiku", effort: pendingEffort)
                    let displayed = state(recorded: recorded("opus", effort: nil),
                                          reported: ReportedModelWire(model: "claude-opus-5-5", family: "opus"),
                                          pending: pending, phase: .waiting, running: running)
                    let waiting = try XCTUnwrap(chip(displayed))
                    let toSuffix = pendingEffort.map { " \u{00B7} \($0)" } ?? ""
                    XCTAssertEqual(waiting.title, "Opus \u{2192} Haiku" + toSuffix,
                                   "waiting running=\(running) pendingEffort=\(String(describing: pendingEffort))")
                    XCTAssertEqual(waiting.tooltip, "Switching after this turn")
                    XCTAssertEqual(waiting.style, .pending)
                    XCTAssertEqual(waiting.accessibilityLabel, "Model: switching from Opus to Haiku after this turn")

                    let applying = try XCTUnwrap(chip(state(recorded: recorded("opus", effort: nil),
                                                            reported: ReportedModelWire(model: "claude-opus-5-5", family: "opus"),
                                                            pending: pending, phase: .applying, running: running)))
                    XCTAssertEqual(applying.title, "Switching\u{2026}")
                    XCTAssertEqual(applying.tooltip, "Switching model")
                    XCTAssertEqual(applying.style, .pending)
                    XCTAssertEqual(applying.accessibilityLabel, "Model: switching from Opus to Haiku")
                }
            }
        }
    }

    // MARK: - Chip: connection

    func testWithoutAStateTheChipIsHiddenWhetherOrNotConnected() {
        XCTAssertNil(chip(nil, connected: true))
        XCTAssertNil(chip(nil, connected: false))
    }

    func testWhenNotConnectedTheChipKeepsTheLastKnownTitleButIsDisabled() throws {
        let running = state(recorded: recorded("sonnet"),
                            reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                            running: true)
        let connected = try XCTUnwrap(chip(running, connected: true))
        let c = try XCTUnwrap(chip(running, connected: false))
        XCTAssertEqual(c.title, connected.title)
        XCTAssertEqual(c.title, "Sonnet")
        XCTAssertFalse(c.isEnabled)
        XCTAssertEqual(c.tooltip, "Not connected to nostromd")
        XCTAssertEqual(c.tooltip, ModelPresentation.disconnectedTooltip)
        XCTAssertEqual(c.style, .pending)
        XCTAssertTrue(connected.isEnabled)
    }

    func testDisconnectedChipsKeepTheirTitleInEveryStateKind() throws {
        let states: [SessionModelStateWire] = [
            state(running: false),
            state(recorded: recorded("opus", effort: "high"), running: false),
            state(recorded: recorded("sonnet"), reported: ReportedModelWire(model: "claude-sonnet-5-5"), running: true),
            state(recorded: recorded("sonnet"), reported: ReportedModelWire(model: "claude-sonnet-5-5"),
                  pending: PendingModelWire(model: "opus"), phase: .waiting, running: true),
            state(recorded: recorded("sonnet"), reported: ReportedModelWire(model: "claude-sonnet-5-5"),
                  pending: PendingModelWire(model: "opus"), phase: .applying, running: true),
        ]
        for s in states {
            let live = try XCTUnwrap(chip(s, connected: true))
            let offline = try XCTUnwrap(chip(s, connected: false))
            XCTAssertEqual(offline.title, live.title)
            XCTAssertFalse(offline.isEnabled)
            XCTAssertEqual(offline.tooltip, ModelPresentation.disconnectedTooltip)
            XCTAssertEqual(offline.style, .pending)
            XCTAssertTrue(live.isEnabled)
        }
    }

    // MARK: - Popup copy

    func testFixedCopy() {
        XCTAssertEqual(ModelPresentation.staleCatalogNotice, "Model list may be out of date")
        XCTAssertEqual(ModelPresentation.disconnectedTooltip, "Not connected to nostromd")
    }

    func testTheFooterNamesTheAgent() {
        XCTAssertEqual(ModelPresentation.footerTitle(agent: "Claudia"), "Use for new Claudia focuses")
        XCTAssertEqual(ModelPresentation.footerTitle(agent: "claudia"), "Use for new Claudia focuses")
        XCTAssertEqual(ModelPresentation.footerTitle(agent: "cody"), "Use for new Cody focuses")
    }

    // MARK: - Model rows

    func testModelRowsAreSortedCheapestFirstWhateverTheInputOrder() {
        let rows = ModelPresentation.modelRows(state: state(recorded: recorded("sonnet")), catalog: catalog())
        XCTAssertEqual(rows.map(\.alias), ["haiku", "sonnet", "opus", "fable"])
        XCTAssertEqual(rows.map(\.title), ["Haiku", "Sonnet", "Opus", "Fable"])
    }

    func testEachModelRowShowsTheResolvedFullNameAsSecondaryText() {
        let rows = ModelPresentation.modelRows(state: state(recorded: recorded("sonnet")), catalog: catalog())
        XCTAssertEqual(rows.map(\.secondary),
                       ["claude-haiku-4-5-20251001", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1"])
    }

    func testTheRowMatchingTheRecordedAliasIsTheCurrentOne() {
        let rows = ModelPresentation.modelRows(state: state(recorded: recorded("opus")), catalog: catalog())
        XCTAssertEqual(rows.filter(\.isCurrent).map(\.alias), ["opus"])
    }

    func testWithNothingRecordedTheReportedFamilyIsTheCurrentRow() {
        let s = state(reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"), running: true)
        let rows = ModelPresentation.modelRows(state: s, catalog: catalog())
        XCTAssertEqual(rows.filter(\.isCurrent).map(\.alias), ["sonnet"])
    }

    func testARunningSessionsReportedFamilyWinsOverTheRecordedAlias() {
        // Asked for Opus, the CLI runs Sonnet: the check mark follows what is running (like the chip).
        let s = state(recorded: recorded("opus"),
                      reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"), running: true)
        let rows = ModelPresentation.modelRows(state: s, catalog: catalog())
        XCTAssertEqual(rows.filter(\.isCurrent).map(\.alias), ["sonnet"])
        XCTAssertEqual(chip(s)?.title, "Sonnet", "the chip and the check mark agree")
    }

    func testAStoppedSessionsStaleReportIsIgnoredSoTheRecordedAliasIsChecked() {
        let s = state(recorded: recorded("opus"),
                      reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"), running: false)
        XCTAssertEqual(ModelPresentation.modelRows(state: s, catalog: catalog()).filter(\.isCurrent).map(\.alias), ["opus"])
    }

    func testAPinnedRecordedModelChecksItsFamilysRow() {
        let s = state(recorded: recorded("claude-sonnet-4-6"),
                      reported: ReportedModelWire(model: "claude-sonnet-4-6", family: "sonnet"), running: true)
        let rows = ModelPresentation.modelRows(state: s, catalog: catalog())
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.filter(\.isCurrent).map(\.alias), ["sonnet"], "a pinned version is a member of its family's row")
    }

    func testNothingRecordedOrReportedChecksNoRow() {
        let rows = ModelPresentation.modelRows(state: state(), catalog: catalog())
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { !$0.isCurrent })
        let noState = ModelPresentation.modelRows(state: nil, catalog: catalog())
        XCTAssertEqual(noState.count, 4)
        XCTAssertTrue(noState.allSatisfy { !$0.isCurrent })
    }

    func testModelRowAccessibilityLabelsNameTheResolvedModelAndSelection() {
        let rows = ModelPresentation.modelRows(state: state(recorded: recorded("opus")), catalog: catalog())
        let opus = rows.first { $0.alias == "opus" }
        let sonnet = rows.first { $0.alias == "sonnet" }
        XCTAssertEqual(opus?.accessibilityLabel, "Opus, claude-opus-5-5, selected")
        XCTAssertEqual(sonnet?.accessibilityLabel, "Sonnet, claude-sonnet-5-5")
    }

    func testAFamilyWithoutAResolvedNameIsLabelledByItsTitleAlone() {
        let c = ModelCatalogState(families: [family("opus", rank: 3, efforts: Self.allLevels, resolved: nil)],
                                  stale: false, fetchedAt: nil)
        let rows = ModelPresentation.modelRows(state: state(recorded: recorded("sonnet")), catalog: c)
        XCTAssertEqual(rows.first?.accessibilityLabel, "Opus")
        XCTAssertEqual(rows.first?.secondary, "")
    }

    func testWithoutACatalogThereAreNoModelRows() {
        XCTAssertEqual(ModelPresentation.modelRows(state: state(recorded: recorded("opus")), catalog: nil), [])
    }

    // MARK: - Effort rows

    private func effortRows(_ s: SessionModelStateWire?, _ c: ModelCatalogState? = nil) -> [ModelPresentation.EffortRow] {
        ModelPresentation.effortRows(state: s, catalog: c ?? catalog())
    }

    func testEffortRowsAreDefaultThenLowToMax() {
        let rows = effortRows(state(recorded: recorded("opus")))
        XCTAssertEqual(rows.map(\.value), ["default", "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(rows.first?.title, "Default")
        XCTAssertEqual(rows.dropFirst().map(\.title), ["low", "medium", "high", "xhigh", "max"])
    }

    func testTheCurrentEffortIsTheRecordedOneOrDefault() {
        XCTAssertEqual(effortRows(state(recorded: recorded("opus", effort: "high"))).filter(\.isCurrent).map(\.value), ["high"])
        XCTAssertEqual(effortRows(state(recorded: recorded("opus", effort: nil))).filter(\.isCurrent).map(\.value), ["default"])
        XCTAssertEqual(effortRows(state(recorded: recorded("opus", effort: "default"))).filter(\.isCurrent).map(\.value), ["default"])
        XCTAssertEqual(effortRows(state()).filter(\.isCurrent).map(\.value), ["default"])
    }

    func testEveryLevelIsEnabledWhenTheCurrentModelOffersThem() {
        let rows = effortRows(state(recorded: recorded("opus")))
        XCTAssertEqual(rows.count, 6)
        XCTAssertTrue(rows.allSatisfy { $0.isEnabled })
    }

    func testLevelsTheCurrentModelLacksAreDisabledWithAReason() throws {
        // Sonnet offers low, medium, high.
        let rows = effortRows(state(recorded: recorded("sonnet")))
        for value in ["default", "low", "medium", "high"] {
            XCTAssertTrue(try XCTUnwrap(rows.first { $0.value == value }).isEnabled, value)
        }
        let xhigh = try XCTUnwrap(rows.first { $0.value == "xhigh" })
        XCTAssertFalse(xhigh.isEnabled)
        XCTAssertEqual(xhigh.tooltip, "Sonnet doesn't support xhigh effort")
        XCTAssertEqual(xhigh.accessibilityLabel, "xhigh, unavailable. Sonnet doesn't support xhigh effort")
        let max = try XCTUnwrap(rows.first { $0.value == "max" })
        XCTAssertFalse(max.isEnabled)
        XCTAssertEqual(max.tooltip, "Sonnet doesn't support max effort")
    }

    func testTheReasonNamesTheFamilyAndTheLevel() throws {
        // Another family offers `high`, so the level is a row; haiku's own list lacks it.
        let c = ModelCatalogState(families: [family("haiku", rank: 1, efforts: ["low", "medium"]),
                                             family("opus", rank: 3, efforts: ["low", "medium", "high"])],
                                  stale: false, fetchedAt: nil)
        let rows = effortRows(state(recorded: recorded("haiku")), c)
        let high = try XCTUnwrap(rows.first { $0.value == "high" })
        XCTAssertFalse(high.isEnabled)
        XCTAssertEqual(high.tooltip, "Haiku doesn't support high effort")
    }

    func testAModelWithNoEffortSupportDisablesEveryExplicitLevel() throws {
        let rows = effortRows(state(recorded: recorded("haiku")))   // haiku: efforts == []
        XCTAssertEqual(rows.count, 6)
        for row in rows where row.value != "default" {
            XCTAssertFalse(row.isEnabled, row.value)
            XCTAssertEqual(row.tooltip, "Haiku doesn't support effort levels", row.value)
            XCTAssertEqual(row.accessibilityLabel, "\(row.title), unavailable. Haiku doesn't support effort levels")
        }
    }

    func testDefaultIsNeverDisabled() throws {
        let rows = effortRows(state(recorded: recorded("haiku")))
        let d = try XCTUnwrap(rows.first { $0.value == "default" })
        XCTAssertTrue(d.isEnabled)
    }

    func testTheCurrentEffortRowIsLabelledSelected() throws {
        let rows = effortRows(state(recorded: recorded("opus", effort: "high")))
        let high = try XCTUnwrap(rows.first { $0.value == "high" })
        XCTAssertEqual(high.accessibilityLabel, "high, selected")
    }

    func testAModelAbsentFromTheCatalogueEnablesEveryLevel() {
        let rows = effortRows(state(recorded: recorded("claude-weird-9")))
        XCTAssertEqual(rows.count, 6)
        XCTAssertTrue(rows.allSatisfy { $0.isEnabled }, "the daemon validates what the catalogue does not list")
    }

    func testWithoutACatalogueEveryLevelIsEnabled() {
        let rows = ModelPresentation.effortRows(state: state(recorded: recorded("opus")), catalog: nil)
        XCTAssertEqual(rows.map(\.value), ["default", "low", "medium", "high", "xhigh", "max"])
        XCTAssertTrue(rows.allSatisfy { $0.isEnabled })
    }

    func testEffortSupportFollowsTheCurrentModelRowNotTheFirstOne() throws {
        // Reported-only (no recorded): the current model is the reported family.
        let s = state(reported: ReportedModelWire(model: "claude-haiku-4-5-20251001", family: "haiku"), running: true)
        let rows = effortRows(s)
        XCTAssertFalse(try XCTUnwrap(rows.first { $0.value == "high" }).isEnabled)
    }

    // MARK: - currentEffort(state:)

    func testTheCurrentEffortIsTheEffectiveOneThenTheRecordedOneThenDefault() {
        XCTAssertEqual(ModelPresentation.currentEffort(state: state(recorded: recorded("opus", effort: "high"), effectiveEffort: "medium")), "medium")
        XCTAssertEqual(ModelPresentation.currentEffort(state: state(recorded: recorded("opus", effort: "high"), effectiveEffort: nil)), "high")
        XCTAssertEqual(ModelPresentation.currentEffort(state: state(recorded: recorded("opus", effort: "high"), effectiveEffort: "default")), "default")
        XCTAssertEqual(ModelPresentation.currentEffort(state: state(recorded: recorded("opus"), effectiveEffort: nil)), "default")
        XCTAssertEqual(ModelPresentation.currentEffort(state: state()), "default")
        XCTAssertEqual(ModelPresentation.currentEffort(state: nil), "default")
    }

    func testTheEffortRowCheckFollowsTheEffectiveEffort() {
        let rows = effortRows(state(recorded: recorded("opus", effort: "high"), effectiveEffort: "medium"))
        XCTAssertEqual(rows.filter(\.isCurrent).map(\.value), ["medium"])
        XCTAssertEqual(rows.first { $0.value == "medium" }?.accessibilityLabel, "medium, selected")
    }

    // MARK: - currentAlias(state:catalog:)

    private func alias(_ s: SessionModelStateWire?) -> String? {
        ModelPresentation.currentAlias(state: s, catalog: catalog())
    }

    func testARunningSessionThatReportedIsCurrentOnTheFamilyItReports() {
        let s = state(recorded: recorded("opus"),
                      reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"), running: true)
        XCTAssertEqual(alias(s), "sonnet")
    }

    func testAReportWithNoFamilyIsResolvedAgainstTheCatalogue() {
        // By the resolved name...
        XCTAssertEqual(alias(state(recorded: recorded("opus"),
                                   reported: ReportedModelWire(model: "claude-sonnet-5-5", family: nil), running: true)), "sonnet")
        // ...or by the family word of a version the catalogue does not list.
        XCTAssertEqual(alias(state(recorded: recorded("opus"),
                                   reported: ReportedModelWire(model: "claude-haiku-3-5", family: nil), running: true)), "haiku")
    }

    func testAReportedFamilyThatIsNotACatalogueAliasIsResolvedFromTheFullName() {
        let s = state(recorded: recorded("opus"),
                      reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet-latest"), running: true)
        XCTAssertEqual(alias(s), "sonnet")
    }

    func testARecordedAliasIsItself() {
        XCTAssertEqual(alias(state(recorded: recorded("opus"), running: false)), "opus")
        XCTAssertEqual(alias(state(recorded: recorded("haiku"), running: false)), "haiku")
    }

    func testAPinnedRecordedNameResolvesToItsFamilyByTheFamilyWord() {
        XCTAssertEqual(alias(state(recorded: recorded("claude-opus-5-5"), running: false)), "opus")
        XCTAssertEqual(alias(state(recorded: recorded("claude-sonnet-4-6"), running: false)), "sonnet")
    }

    func testAPinnedNameWhoseFamilyTheCatalogueLacksChecksNothing() {
        XCTAssertNil(alias(state(recorded: recorded("claude-weird-9"), running: false)))
    }

    func testARunningSessionThatHasNotReportedYetIsCurrentOnTheRecordedModel() {
        XCTAssertEqual(alias(state(recorded: recorded("opus"), running: true)), "opus")
        XCTAssertEqual(alias(state(recorded: recorded("claude-sonnet-4-6"), running: true)), "sonnet")
    }

    func testAStoppedSessionIsCurrentOnTheRecordedModelNotItsOldReport() {
        let s = state(recorded: recorded("opus"),
                      reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"), running: false)
        XCTAssertEqual(alias(s), "opus")
    }

    func testWithNothingRecordedOrReportedThereIsNoCurrentAlias() {
        XCTAssertNil(alias(state()))
        XCTAssertNil(alias(nil))
    }

    func testARunningSessionWithAReportButNothingRecordedIsCurrentOnTheReport() {
        XCTAssertEqual(alias(state(reported: ReportedModelWire(model: "claude-opus-5-5", family: "opus"), running: true)), "opus")
    }

    // MARK: - Chip: a pending effort-only switch

    // The daemon's `pending` is the FULL target. For an effort-only switch its model is the
    // focus's own, so the chip must not read "Sonnet → Sonnet".

    private func sonnetRunning(effort: String?, pending: PendingModelWire?, phase: SwitchPhaseWire = .waiting,
                               effective: String? = nil) -> SessionModelStateWire {
        state(recorded: recorded("sonnet", effort: effort),
              reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
              effectiveEffort: effective ?? effort, pending: pending, phase: phase, running: true)
    }

    func testAPendingEffortOnlySwitchShowsTheEffortChange() throws {
        let c = try XCTUnwrap(chip(sonnetRunning(effort: "high", pending: PendingModelWire(model: "sonnet", effort: "medium"))))
        XCTAssertEqual(c.title, "Sonnet \u{00B7} high \u{2192} medium")
        XCTAssertEqual(c.tooltip, "Switching after this turn")
        XCTAssertEqual(c.accessibilityLabel, "Model: switching effort from high to medium after this turn")
        XCTAssertEqual(c.style, .pending)
        XCTAssertTrue(c.isEnabled)
        XCTAssertEqual(c.accessibilityHint, "\u{21E7}\u{2318}M")
    }

    func testAPendingEffortChangeFromTheDefaultReadsFamilyArrowEffort() throws {
        for current in [nil, "default"] as [String?] {
            let c = try XCTUnwrap(chip(sonnetRunning(effort: current, pending: PendingModelWire(model: "sonnet", effort: "medium"))))
            XCTAssertEqual(c.title, "Sonnet \u{2192} medium", "current \(String(describing: current))")
            XCTAssertEqual(c.accessibilityLabel, "Model: switching effort from default to medium after this turn")
        }
    }

    func testAPendingResetToTheDefaultEffortSaysDefault() throws {
        for target in [nil, "default"] as [String?] {
            let c = try XCTUnwrap(chip(sonnetRunning(effort: "high", pending: PendingModelWire(model: "sonnet", effort: target))))
            XCTAssertEqual(c.title, "Sonnet \u{00B7} high \u{2192} default", "pending effort \(String(describing: target))")
            XCTAssertEqual(c.tooltip, "Switching after this turn")
            XCTAssertEqual(c.accessibilityLabel, "Model: switching effort from high to default after this turn")
        }
    }

    func testAPendingEffortSwitchOnAPinnedModelOfTheSameFamilyIsStillEffortOnly() throws {
        let c = try XCTUnwrap(chip(sonnetRunning(effort: "high", pending: PendingModelWire(model: "claude-sonnet-4-6", effort: "medium"))))
        XCTAssertEqual(c.title, "Sonnet \u{00B7} high \u{2192} medium")
        XCTAssertEqual(c.accessibilityLabel, "Model: switching effort from high to medium after this turn")
    }

    func testTheCurrentEffortOfAnEffortOnlySwitchIsTheEffectiveOne() throws {
        let c = try XCTUnwrap(chip(sonnetRunning(effort: "high", pending: PendingModelWire(model: "sonnet", effort: "low"),
                                                 effective: "medium")))
        XCTAssertEqual(c.title, "Sonnet \u{00B7} medium \u{2192} low")
    }

    func testAnEffortOnlySwitchBeingAppliedStillReadsSwitching() throws {
        let c = try XCTUnwrap(chip(sonnetRunning(effort: "high", pending: PendingModelWire(model: "sonnet", effort: "medium"),
                                                 phase: .applying)))
        XCTAssertEqual(c.title, "Switching\u{2026}")
        XCTAssertEqual(c.tooltip, "Switching model")
        XCTAssertEqual(c.style, .pending)
    }

    func testAPendingModelChangeStillReadsFromArrowToWithTheTargetsEffort() throws {
        let c = try XCTUnwrap(chip(sonnetRunning(effort: "high", pending: PendingModelWire(model: "opus", effort: "high"))))
        XCTAssertEqual(c.title, "Sonnet \u{2192} Opus \u{00B7} high")
        XCTAssertEqual(c.accessibilityLabel, "Model: switching from Sonnet to Opus after this turn")
    }

    // MARK: - Effort rows from the catalogue

    private func levelCatalog(_ levels: [[String]]) -> ModelCatalogState {
        ModelCatalogState(families: levels.enumerated().map { i, efforts in
            family(["haiku", "sonnet", "opus", "fable"][i], rank: i + 1, efforts: efforts)
        }, stale: false, fetchedAt: nil)
    }

    func testTheEffortLevelsAreTheUnionOfEveryFamilysLevelsInCanonicalOrder() {
        // No family lists them in canonical order, and none lists them all.
        let c = levelCatalog([["high", "low"], ["max", "medium"], ["xhigh"]])
        let rows = effortRows(state(recorded: recorded("opus")), c)
        XCTAssertEqual(rows.map(\.value), ["default", "low", "medium", "high", "xhigh", "max"])
    }

    func testALevelNewlyOfferedByTheCLIAppearsAfterTheStandardOnes() {
        let c = levelCatalog([[], ["low", "medium", "high"], ["low", "medium", "high", "xhigh", "max", "ultra"]])
        let rows = effortRows(state(recorded: recorded("opus")), c)
        XCTAssertEqual(rows.map(\.value), ["default", "low", "medium", "high", "xhigh", "max", "ultra"])
        XCTAssertEqual(rows.last?.title, "ultra")
        XCTAssertEqual(rows.last?.isEnabled, true, "the current model (opus) offers it")
    }

    func testUnknownLevelsAreAppendedInTheOrderTheCatalogueFirstShowsThem() {
        let c = levelCatalog([["zeta", "low"], ["alpha", "zeta"], ["omega", "alpha", "max"]])
        let rows = effortRows(state(recorded: recorded("opus")), c)
        XCTAssertEqual(rows.map(\.value), ["default", "low", "max", "zeta", "alpha", "omega"])
    }

    func testLevelsTheCurrentFamilyDoesNotOfferStayVisibleButDisabled() throws {
        let c = levelCatalog([[], ["low", "medium", "high"], ["low", "medium", "high", "xhigh", "max", "ultra"]])
        let rows = effortRows(state(recorded: recorded("sonnet")), c)
        XCTAssertEqual(rows.map(\.value), ["default", "low", "medium", "high", "xhigh", "max", "ultra"])
        XCTAssertEqual(rows.map(\.isEnabled), [true, true, true, true, false, false, false])
        let ultra = try XCTUnwrap(rows.last)
        XCTAssertEqual(ultra.tooltip, "Sonnet doesn't support ultra effort")
        XCTAssertEqual(ultra.accessibilityLabel, "ultra, unavailable. Sonnet doesn't support ultra effort")
    }

    func testALevelNoFamilyOffersIsNotShown() {
        let c = levelCatalog([[], ["high"], ["high", "max"]])
        let rows = effortRows(state(recorded: recorded("opus")), c)
        XCTAssertEqual(rows.map(\.value), ["default", "high", "max"], "the rows are what the catalogue offers, not a fixed five")
    }

    func testWithoutACatalogueOrWithNoLevelsAnywhereTheStandardFiveAreShown() {
        let standard = ["default"] + ModelPresentation.effortLevels
        XCTAssertEqual(ModelPresentation.effortRows(state: state(recorded: recorded("opus")), catalog: nil).map(\.value), standard)
        let none = levelCatalog([[], [], []])
        XCTAssertEqual(ModelPresentation.effortRows(state: state(recorded: recorded("opus")), catalog: none).map(\.value), standard)
        let empty = ModelCatalogState(families: [], stale: false, fetchedAt: nil)
        XCTAssertEqual(ModelPresentation.effortRows(state: state(recorded: recorded("opus")), catalog: empty).map(\.value), standard)
        XCTAssertEqual(ModelPresentation.effortLevels, ["low", "medium", "high", "xhigh", "max"])
    }

    // MARK: - failureMessage(status:code:message:)

    private func failure(_ status: ModelRequestStatusWire, _ code: String? = nil, _ message: String? = nil) -> String? {
        ModelPresentation.failureMessage(status: status, code: code, message: message)
    }

    func testOutcomesThatAreNotFailuresHaveNoMessage() {
        for status in [ModelRequestStatusWire.applied, .pendingTurnEnd, .unchanged, .awaitingUser, .unknown("teleported")] {
            XCTAssertNil(failure(status), "\(status)")
            XCTAssertNil(failure(status, "unknown_model", "whatever"), "\(status) even with a code and a message")
        }
    }

    func testARefusalWithAKnownCodeHasItsOwnReason() {
        XCTAssertEqual(failure(.refused, "unknown_model"), "Couldn't switch: that model isn't available")
        XCTAssertEqual(failure(.refused, "not_permitted"), "Couldn't switch: this session's model can't be changed")
        XCTAssertEqual(failure(.refused, "unknown_focus"), "Couldn't switch: this focus no longer exists")
    }

    func testAKnownCodeWinsOverTheDaemonsMessage() {
        XCTAssertEqual(failure(.refused, "unknown_model", "No such model: banana"), "Couldn't switch: that model isn't available")
    }

    func testOtherRefusalsAndFailuresUseTheDaemonsMessageWithItsFirstLetterLowered() {
        XCTAssertEqual(failure(.refused, "effort_unsupported", "Sonnet doesn't support xhigh effort."),
                       "Couldn't switch: sonnet doesn't support xhigh effort.")
        XCTAssertEqual(failure(.failed, nil, "The session would not restart."), "Couldn't switch: the session would not restart.")
        XCTAssertEqual(failure(.refused, nil, "Opus is out."), "Couldn't switch: opus is out.")
        XCTAssertEqual(failure(.failed, "some_new_code", "already lower"), "Couldn't switch: already lower")
    }

    func testAFailureWithNothingElseSaysSomethingWentWrong() {
        XCTAssertEqual(failure(.failed), "Couldn't switch: something went wrong")
        XCTAssertEqual(failure(.refused), "Couldn't switch: something went wrong")
        XCTAssertEqual(failure(.failed, nil, ""), "Couldn't switch: something went wrong", "an empty message is no message")
        XCTAssertEqual(failure(.refused, "some_new_code", nil), "Couldn't switch: something went wrong")
    }

    func testDeniedAndExpiredAreDeclinedStates() {
        XCTAssertEqual(failure(.denied), "Couldn't switch: the request was declined")
        XCTAssertEqual(failure(.expired), "Couldn't switch: the request expired")
    }
}
