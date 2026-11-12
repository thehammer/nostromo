import XCTest

/// M5: the decision sheet's default choice for model requests. Placeholder so the Xcode project does not change again.
final class DecisionSheetDefaultChoiceTests: XCTestCase {
    func testPlaceholder() {}
}

/// S3b M7: the sheet that asks the operator to allow a "staging only, no output" follow. The daemon's prompt
/// carries the sentence that says the agent will NOT see the output; the sheet must show all of it, wrapped,
/// and must not let a key press answer it. Driven with the exact prompts the daemon sends.
final class DecisionSheetStagingOnlyPromptTests: XCTestCase {

    private let dot = "\u{00B7}"

    private var localPrompt: String {
        "Cody in focus-a asks to stage commands for local shell in /tmp/p. Cody can stage commands but will NOT see this terminal's output or screen. You place and run every command yourself."
    }
    private var ecsPrompt: String {
        "Staging only for PRODUCTION: Cody in focus-b asks to stage commands for production \(dot) admin-portal \(dot) scheduler. Output from PRODUCTION will NOT be sent to Cody's model. You place and run every command yourself."
    }
    private let followsNow = " Claudia follows it now; allowing moves it to Cody (staging only)."

    private var prompts: [String] {
        [localPrompt, ecsPrompt, localPrompt + followsNow, ecsPrompt + followsNow]
    }

    private func makeSheet(prompt: String, detail: String?) throws -> (sheet: DecisionSheet, window: NSWindow) {
        _ = NSApplication.shared
        let sheet = DecisionSheet(
            requestId: "req-staging-only", prompt: prompt, detail: detail,
            choices: [.init(id: "allow_staging_only", label: "Allow staging only", detail: nil),
                      .init(id: "deny", label: "Deny", detail: nil)],
            store: DecisionStore(), resolution: nil, onAnswer: { _ in })
        sheet.voiceOverEnabled = { false }
        sheet.currentEvent = { nil }
        let window = try XCTUnwrap(sheet.window)
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        addTeardownBlock { [sheet, window] in
            window.delegate = nil  // closing must not answer on the way out
            sheet.currentEvent = { nil }
            window.close()
        }
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        return (sheet, window)
    }

    private func labels(in window: NSWindow) -> [NSTextField] {
        (window.contentView?.subviews ?? []).compactMap { $0 as? NSTextField }
    }

    private func buttons(in window: NSWindow) -> [NSButton] {
        (window.contentView?.subviews ?? []).compactMap { $0 as? NSButton }
    }

    private func promptLabel(_ prompt: String, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) throws -> NSTextField {
        try XCTUnwrap(labels(in: window).first { $0.stringValue == prompt },
                      "no label shows the whole prompt \"\(prompt)\"; labels: \(labels(in: window).map(\.stringValue))",
                      file: file, line: line)
    }

    func testTheLabelShowsTheWholePromptIncludingTheNotSeeingSentence() throws {
        for prompt in prompts {
            for detail in [nil, "Cody is debugging the scheduler."] as [String?] {
                let (_, window) = try makeSheet(prompt: prompt, detail: detail)
                let label = try promptLabel(prompt, in: window)

                XCTAssertTrue(label.stringValue.contains("will NOT"), label.stringValue)
                XCTAssertEqual(label.stringValue, prompt, "nothing is cut, summarised or reworded")
            }
        }
    }

    func testThePromptLabelWrapsInsteadOfTruncating() throws {
        for prompt in prompts {
            let (_, window) = try makeSheet(prompt: prompt, detail: nil)
            let label = try promptLabel(prompt, in: window)

            XCTAssertEqual(label.maximumNumberOfLines, 0, "unlimited lines: the sentence that says what the agent will not see is never cut")
            XCTAssertEqual(label.lineBreakMode, .byWordWrapping)
            XCTAssertFalse(label.cell?.truncatesLastVisibleLine ?? false)
        }
    }

    func testThePromptLabelIsTallEnoughForEveryLineAtTheSheetsWidth() throws {
        for prompt in prompts {
            for detail in [nil, "Cody is debugging the scheduler."] as [String?] {
                let (_, window) = try makeSheet(prompt: prompt, detail: detail)
                let label = try promptLabel(prompt, in: window)
                let cell = try XCTUnwrap(label.cell)

                let width = label.frame.width
                XCTAssertGreaterThan(width, 100, "the label has a real width after layout")
                let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100_000)).height
                XCTAssertGreaterThanOrEqual(label.frame.height + 0.5, needed.rounded(.down),
                                            "the label is \(label.frame.height) tall but its text needs \(needed) at width \(width): the prompt is clipped")
                XCTAssertGreaterThan(needed, 40, "a prompt this long takes several lines, so it is wrapping, not one line")
            }
        }
    }

    func testTheChoicesAreTheTwoButtonsAndNeitherAnswersToAKey() throws {
        for prompt in prompts {
            let (_, window) = try makeSheet(prompt: prompt, detail: nil)
            let all = buttons(in: window)
            let allow = try XCTUnwrap(all.first { $0.identifier?.rawValue == "allow_staging_only" }, "no Allow staging only button")
            let deny = try XCTUnwrap(all.first { $0.identifier?.rawValue == "deny" }, "no Deny button")

            XCTAssertEqual(allow.title, "Allow staging only")
            XCTAssertEqual(deny.title, "Deny")
            for button in [allow, deny] {
                XCTAssertEqual(button.keyEquivalent, "", "\(button.title): no key may answer an agent")
                XCTAssertFalse(window.defaultButtonCell === button.cell, "\(button.title) must not be the window's default (Return) button")
            }
            XCTAssertFalse(all.contains { $0.keyEquivalent == "\r" }, "Return answers nothing in this sheet")
        }
    }
}
