// NostromoKit — ApprovalGuardBarTextTests.swift
//
// AP2b: the one line of the production-shell guard bar.

import XCTest
@testable import NostromoKit

final class ApprovalGuardBarTextTests: XCTestCase {

    private let sendInput = "send input to a production shell"
    private let openShell = "open a production shell"

    // MARK: - verb

    func testTmuxReadsAsSendingInputToAProductionShell() {
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "Bash tmux"), sendInput)
    }

    func testATmuxPathReadsAsSendingInputUsingTheBasename() {
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "Bash /opt/homebrew/bin/tmux"), sendInput)
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "Bash /usr/bin/tmux"), sendInput)
    }

    func testTmuxIsRecognisedWhateverItsCase() {
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "Bash TMUX"), sendInput)
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "Bash Tmux"), sendInput)
    }

    func testTheTmuxInputRuleIdReadsAsSendingInput() {
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "tmux_input"), sendInput)
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "TMUX_INPUT"), sendInput)
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "tmux"), sendInput)
    }

    func testOtherToolNamesOnTmuxReadAsSendingInputWhenTheFirstCommandWordIsTmux() {
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "Monitor tmux"), sendInput)
    }

    func testEcsConnectReadsAsOpeningAProductionShell() {
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "Bash ecs_connect"), openShell)
    }

    func testAwsAndSsmReadAsOpeningAProductionShell() {
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "Bash aws"), openShell)
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "Bash ssm"), openShell)
    }

    func testAToolThatOnlyContainsTmuxInItsNameReadsAsOpeningAShell() {
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "Bash ecs_open_tmux_pane"), openShell)
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "ecs_open_tmux_pane"), openShell)
    }

    func testAnMcpToolReadsAsOpeningAProductionShell() {
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "mcp__x__y"), openShell)
    }

    func testTheOtherRuleIdsReadAsOpeningAProductionShell() {
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "command"), openShell)
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "tool_name"), openShell)
    }

    func testAnEmptyOrUnknownSummaryReadsAsOpeningAProductionShell() {
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: ""), openShell)
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "   "), openShell)
        XCTAssertEqual(ApprovalGuardBarText.verb(summary: "Whatever"), openShell)
    }

    // MARK: - line

    func testTheLineNamesTheAgentAndWhatItTried() {
        XCTAssertEqual(ApprovalGuardBarText.line(agent: "Cody", summary: "Bash tmux"),
                       "Blocked: Cody tried to send input to a production shell")
        XCTAssertEqual(ApprovalGuardBarText.line(agent: "Cody", summary: "Bash ecs_connect"),
                       "Blocked: Cody tried to open a production shell")
    }

    func testAMissingAgentReadsAsAnAgent() {
        XCTAssertEqual(ApprovalGuardBarText.line(agent: nil, summary: "Bash tmux"),
                       "Blocked: An agent tried to send input to a production shell")
    }

    func testAnEmptyOrBlankAgentReadsAsAnAgent() {
        XCTAssertEqual(ApprovalGuardBarText.line(agent: "", summary: "Bash aws"),
                       "Blocked: An agent tried to open a production shell")
        XCTAssertEqual(ApprovalGuardBarText.line(agent: "  \t ", summary: "Bash aws"),
                       "Blocked: An agent tried to open a production shell")
    }
}
