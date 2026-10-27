import XCTest
import AppKit

final class TerminalChromeModelTests: XCTestCase {

    private func info(kind: TerminalKind = .ecs, environment: String = "production", tag: String = "core-1",
                      status: TerminalStatus = .running, id: String = "t1") -> TerminalInfo {
        let target = kind == .ecs
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
        XCTAssertEqual(TerminalChromeModel.windowTitle(focusLabel: "Core", environments: ["PRODUCTION", "STAGING"]),
                       "Core \u{2014} PRODUCTION, STAGING")
    }

    func testWhiteOnHazardRedMeetsWCAGAA() {
        XCTAssertGreaterThanOrEqual(TerminalChromeModel.contrastRatio(Theme.hazardText, Theme.hazardRed), 4.5)
    }
}
