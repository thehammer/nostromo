import XCTest
import AppKit

final class TerminalChromeModelTests: XCTestCase {

    private func info(kind: TerminalKind = .ecs, environment: String = "production", tag: String = "core-1",
                      status: TerminalStatus = .running, id: String = "t1", withTarget: Bool? = nil) -> TerminalInfo {
        let target = (withTarget ?? (kind == .ecs))
            ? TerminalTarget(project: "admin-portal", environment: environment, service: "scheduler", shellType: "shell")
            : nil
        return TerminalInfo(terminalId: id, tag: tag, paneId: "terminal-\(id)", kind: kind,
                            label: kind == .ecs ? environment : "zsh", cwd: nil, target: target, status: status,
                            exitCode: nil, endedReason: nil, cols: 80, rows: 24,
                            requestedBy: TerminalRequester(kind: "user", tag: nil), openedByRequest: nil,
                            follower: nil, idleClosesAt: nil)
    }

    func testHeaderNamesEnvironmentProjectServiceAndShell() {
        XCTAssertEqual(TerminalChromeModel.headerText(for: info()), "PRODUCTION \u{00B7} admin-portal \u{00B7} scheduler \u{00B7} shell")
    }

    func testEveryEnvironmentIsRedAndNamesItself() {
        for environment in ["production", "canada", "demo", "staging"] {
            let pane = info(environment: environment)
            XCTAssertTrue(TerminalChromeModel.isRemote(pane))
            XCTAssertEqual(TerminalChromeModel.frameColor(for: pane), Theme.hazardRed)
            XCTAssertTrue(TerminalChromeModel.headerText(for: pane).hasPrefix(environment.uppercased() + " \u{00B7} "))
        }
    }

    func testLocalPaneIsNotRedAndShowsItsLabel() {
        let pane = info(kind: .local)
        XCTAssertFalse(TerminalChromeModel.isRemote(pane))
        XCTAssertNil(TerminalChromeModel.frameColor(for: pane))
        XCTAssertEqual(TerminalChromeModel.headerText(for: pane), "zsh")
    }

    func testAPaneOfAnUnknownKindIsRemoteAndRedAndFailsTowardTheWarning() {
        let pane = info(kind: .unknown, withTarget: false)
        XCTAssertTrue(TerminalChromeModel.isRemote(pane))
        XCTAssertEqual(TerminalChromeModel.frameColor(for: pane), Theme.hazardRed)
        XCTAssertEqual(TerminalChromeModel.headerText(for: pane), pane.label, "no target: the header says what the daemon labelled it")
    }

    func testAnEcsPaneWithoutATargetIsStillRemoteAndRed() {
        let pane = info(kind: .ecs, withTarget: false)
        XCTAssertTrue(TerminalChromeModel.isRemote(pane))
        XCTAssertEqual(TerminalChromeModel.frameColor(for: pane), Theme.hazardRed)
        XCTAssertEqual(TerminalChromeModel.headerText(for: pane), pane.label)
    }

    func testOnlyAKnownLocalPaneIsNotRemote() {
        XCTAssertFalse(TerminalChromeModel.isRemote(kind: .local))
        XCTAssertTrue(TerminalChromeModel.isRemote(kind: .ecs))
        XCTAssertTrue(TerminalChromeModel.isRemote(kind: .unknown))
        XCTAssertTrue(TerminalChromeModel.isRemote(kind: nil), "no pane information yet is not a reason to look safe")
    }

    func testUnknownKindFailsTowardTheWarningAndTheConfirmation() {
        XCTAssertTrue(TerminalChromeModel.isRemote(kind: nil))
        XCTAssertEqual(PastePolicy.decide(kind: nil, text: "rm -rf x\n"), .confirm(lines: 1))
        XCTAssertEqual(PastePolicy.decide(kind: .local, text: "ls\n"), .send)
    }

    func testEnvironmentTokenIsTheUppercasedEnvironmentOrRemote() {
        XCTAssertEqual(TerminalChromeModel.environmentToken(for: info(environment: "production")), "PRODUCTION")
        XCTAssertEqual(TerminalChromeModel.environmentToken(for: info(environment: "canada")), "CANADA")
        XCTAssertEqual(TerminalChromeModel.environmentToken(for: info(kind: .ecs, withTarget: false)), "REMOTE")
        XCTAssertEqual(TerminalChromeModel.environmentToken(for: info(kind: .unknown, withTarget: false)), "REMOTE")
        XCTAssertEqual(TerminalChromeModel.environmentToken(for: info(environment: "")), "REMOTE",
                       "an empty environment is no environment")
    }

    func testPasteTargetTextNamesTheTargetOrSaysRemoteShell() {
        XCTAssertEqual(TerminalChromeModel.pasteTargetText(for: info()),
                       "PRODUCTION \u{00B7} admin-portal \u{00B7} scheduler")
        XCTAssertEqual(TerminalChromeModel.pasteTargetText(for: info(kind: .ecs, withTarget: false)), "REMOTE shell")
        XCTAssertEqual(TerminalChromeModel.pasteTargetText(for: nil), "REMOTE shell")
    }

    func testFocusEnvironmentLabelsCountARemotePaneWithoutATargetAsRemote() {
        let panes = [
            info(kind: .ecs, id: "a", withTarget: false), info(kind: .unknown, id: "b", withTarget: false),
            info(environment: "production", id: "c"), info(environment: "staging", id: "d"),
            info(kind: .local, id: "e"),
        ]
        XCTAssertEqual(TerminalChromeModel.focusEnvironmentLabels(panes, tag: "core-1"),
                       ["PRODUCTION", "REMOTE", "STAGING"], "production first, then alphabetical with REMOTE")
        XCTAssertEqual(TerminalChromeModel.focusEnvironmentLabels([info(kind: .unknown, withTarget: false)], tag: "core-1"), ["REMOTE"])
        XCTAssertEqual(TerminalChromeModel.focusEnvironmentLabels([info(kind: .ecs, status: .ended, withTarget: false)], tag: "core-1"), [])
    }

    func testFocusEnvironmentLabelsAreDistinctProductionFirstAndOnlyForOpenRemotePanesInThatFocus() {
        let panes = [
            info(environment: "staging", id: "a"), info(environment: "production", id: "b"),
            info(environment: "staging", id: "c"), info(environment: "demo", id: "d"),
            info(environment: "canada", tag: "other", id: "e"), info(kind: .local, id: "f"),
            info(environment: "canada", status: .ended, id: "g"),
        ]
        XCTAssertEqual(TerminalChromeModel.focusEnvironmentLabels(panes, tag: "core-1"), ["PRODUCTION", "DEMO", "STAGING"])
        XCTAssertEqual(TerminalChromeModel.focusEnvironmentLabels([], tag: "core-1"), [])
    }

    func testWindowTitle() {
        XCTAssertEqual(TerminalChromeModel.windowTitle(focusLabel: "Core", environments: []), "Core")
        XCTAssertEqual(TerminalChromeModel.windowTitle(focusLabel: "Core", environments: ["PRODUCTION"]),
                       "PRODUCTION \u{2014} Core")
        XCTAssertEqual(TerminalChromeModel.windowTitle(focusLabel: "Core", environments: ["PRODUCTION", "STAGING"]),
                       "PRODUCTION, STAGING \u{2014} Core")
        let long = String(repeating: "L", count: 80)
        XCTAssertTrue(TerminalChromeModel.windowTitle(focusLabel: long, environments: ["PRODUCTION"])
            .hasPrefix("PRODUCTION \u{2014} "), "the warning comes first, so a long label cannot push it out of a truncated title")
    }

    func testWhiteOnHazardRedMeetsWCAGAA() {
        XCTAssertGreaterThanOrEqual(TerminalChromeModel.contrastRatio(Theme.hazardText, Theme.hazardRed), 4.5)
    }
}
