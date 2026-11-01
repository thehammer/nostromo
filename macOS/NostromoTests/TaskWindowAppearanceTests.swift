import XCTest
import AppKit
import NostromoKit

// BA4: how a task window looks and lays out.
//
// Contrast (contract §2.9, at least 4.5:1) is measured on a bitmap the real views draw, in a key window and
// in one that is not key, under the panel's Dark Aqua appearance: the WCAG ratio (L1 + 0.05) / (L2 + 0.05)
// over the sRGB relative luminance of the pixels that came out, not of the colours that went in. The method
// is `ToolGroupAppearanceTests`'. The measured ratio is in every failure message.
//
// Layout is measured in a real `TaskPanel` at `TaskWindowFrame.minimumSize.width`: a long, multi-line,
// hostile description must wrap the header taller, never push the panel wider.
//
// No window server beyond what `makeRigWindow` already needs, no wall clock, no daemon, no real pasteboard.

private final class NotKeyWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var isKeyWindow: Bool { false }
}

private final class NoTimer: TaskPollTimer {
    func invalidate() {}
}

/// Answers the first read of a CLI-tail output that is a tail of a longer one, so the pane shows its
/// truncation line.
private final class CutTailDaemon: TaskRequestSending {
    weak var requests: TaskRequests?

    func sendTaskOutput(requestId: String, tag: String, taskId: String, offset: UInt64?, maxBytes: UInt32) {
        let text = String(repeating: "x", count: 8_191) + "\n"
        let object: [String: Any] = ["request_id": requestId, "tag": tag, "task_id": taskId, "outcome": "ok",
                                     "text": text, "start_offset": 32_768, "end_offset": 40_960, "total_bytes": 40_960,
                                     "source": "cli_tail"]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let wire = try? JSONDecoder().decode(SessionTaskOutputResultWire.self, from: data)
        else { return XCTFail("the fake daemon built an answer that does not decode") }
        requests?.ingest(.sessionTaskOutputResult(wire))
    }

    func sendTaskStop(requestId: String, tag: String, taskId: String) {}
}

// MARK: - Contrast

private func luminance(_ color: NSColor) -> Double {
    let c = color.usingColorSpace(.sRGB) ?? color
    func linear(_ v: CGFloat) -> Double {
        let s = Double(v)
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
}

private func contrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
    let (la, lb) = (luminance(a), luminance(b))
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

private func rgbName(_ color: NSColor) -> String {
    let s = color.usingColorSpace(.sRGB) ?? color
    return String(format: "rgb(%.0f,%.0f,%.0f)", s.redComponent * 255, s.greenComponent * 255, s.blueComponent * 255)
}

/// The pixels a view drew.
private struct Rendered {
    let host: NSView
    let rep: NSBitmapImageRep
    let scale: CGFloat

    func colors(in rect: NSRect) -> [NSColor] {
        let r = rect.intersection(host.bounds)
        guard !r.isNull, r.width > 0, r.height > 0 else { return [] }
        let xs = Int((r.minX * scale).rounded(.down)) ..< Int((r.maxX * scale).rounded(.up))
        let ys = Int(((host.bounds.height - r.maxY) * scale).rounded(.down)) ..< Int(((host.bounds.height - r.minY) * scale).rounded(.up))
        var out: [NSColor] = []
        for y in ys where y >= 0 && y < rep.pixelsHigh {
            for x in xs where x >= 0 && x < rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { out.append(color) }
            }
        }
        return out
    }

    func brightest(in rect: NSRect) -> NSColor? {
        colors(in: rect).max { luminance($0) < luminance($1) }
    }

    func median(in rect: NSRect) -> NSColor? {
        let sorted = colors(in: rect).sorted { luminance($0) < luminance($1) }
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }
}

final class TaskWindowAppearanceTests: XCTestCase {

    private static let renderSize = NSSize(width: 600, height: 400)

    /// ANSI, OSC 8, bidi controls, tag characters, NUL, DEL, line breaks, C1 and the invisible fillers
    /// (copied from NostromoKit's `HostileContent`, which this target cannot see).
    private static let hostile = "\u{1B}[31mred\u{1B}[0m \u{1B}]8;;https://x\u{1B}\\label\u{1B}]8;;\u{1B}\\"
        + "\u{1B}]0;evil title\u{07}safe\u{202E}evil\u{2066}iso\u{2069}\u{200E}\u{200F}tail tag\u{E0041}\u{E007F}ged before\u{0}after "
        + "one\ntwo\r\nthree\tfour\u{7F}five \u{2028}\u{2029} a\u{034F}b\u{115F}c\u{1160}d\u{17B4}e\u{17B5}f\u{2800}g\u{3164}h\u{FFA0}i "
        + "\u{85}\u{9B}31mj\u{61C}k"

    /// Several hundred characters over several lines, with wide words and one very long unbroken run.
    private static let hostileDescription = hostile + "\n" + String(repeating: "overflowing description words ", count: 14)
        + "\n" + String(repeating: "W", count: 120)

    private static func forbidden(_ scalar: Unicode.Scalar, allowingLineBreaks: Bool) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A:
            return !allowingLineBreaks
        case 0x0000 ... 0x001F, 0x007F, 0x0080 ... 0x009F,
             0x061C, 0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069,
             0xE0000 ... 0xE007F,
             0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0:
            return true
        default:
            return false
        }
    }

    // MARK: Fixtures

    private func content(kind: TaskKindWire = .shell, description: String = "npm run build --watch",
                         status: TaskStatusWire = .running, summary: String? = nil, totalTokens: UInt64? = nil,
                         toolUses: UInt64? = nil, lastToolName: String? = nil) -> TaskWindowContent {
        let ended = status.isTerminal
        let meta = TaskMetaWire(id: "t1", kind: kind, description: description, toolUseId: "toolu_1", status: status,
                                startedAtMs: 1_000, endedAtMs: ended ? 6_000 : nil, totalTokens: totalTokens,
                                toolUses: toolUses, lastToolName: lastToolName)
        let detail = summary.map { SessionTaskDetailWire(tag: "kate", taskId: "t1", completionSummary: $0) }
        return TaskWindowContent.make(tag: "kate", focusName: "kate", meta: meta, row: nil, detail: detail, nowMs: 31_000,
                                      timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func unloadedModel() -> TaskOutputModel {
        TaskOutputModel(tag: "kate", taskId: "t1", requests: TaskRequests(schedule: { _, _ in }),
                        schedule: { _, _ in NoTimer() }, now: Date.init)
    }

    private func outputView(model: TaskOutputModel? = nil) -> TaskOutputView {
        TaskOutputView(focusTag: "kate", taskId: "t1", model: model ?? unloadedModel(), pasteboard: rigPrivatePasteboard(self))
    }

    /// A model that holds the tail of a 40 KB CLI output, so its pane shows `Showing the last 8 KB of 40 KB`.
    private func truncatedModel() -> TaskOutputModel {
        let daemon = CutTailDaemon()
        let requests = TaskRequests(schedule: { _, _ in })
        requests.sender = daemon
        daemon.requests = requests
        let model = TaskOutputModel(tag: "kate", taskId: "t1", requests: requests, schedule: { _, _ in NoTimer() }, now: Date.init)
        model.acquire()
        addTeardownBlock { model.release() }
        return model
    }

    private func makeWindow(keyWindow: Bool, size: NSSize) -> NSWindow {
        _ = NSApplication.shared
        if keyWindow {
            return makeRigWindow(self, size: size, appearance: NSAppearance(named: .darkAqua))
        }
        let window = NotKeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                  backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        addTeardownBlock { window.close() }
        return window
    }

    /// `view` laid out in a window of the given key state, and the pixels it drew.
    private func render(_ view: NSView, keyWindow: Bool, file: StaticString = #filePath, line: UInt = #line) -> Rendered? {
        let size = Self.renderSize
        let window = makeWindow(keyWindow: keyWindow, size: size)
        XCTAssertEqual(window.isKeyWindow, keyWindow, file: file, line: line)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("could not render the view", file: file, line: line)
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return Rendered(host: view, rep: rep, scale: CGFloat(rep.pixelsWide) / view.bounds.width)
    }

    private func label(showing text: String, in view: NSView) -> NSTextField? {
        guard !text.isEmpty else { return nil }
        return rigAllSubviews(of: view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == text && !$0.isHiddenOrHasHiddenAncestor }
    }

    /// The colour behind the header's text: the median pixel of a strip of its trailing margin, where nothing draws.
    private func background(of header: NSView, in rendered: Rendered) -> NSColor? {
        let rect = header.convert(header.bounds, to: rendered.host)
        return rendered.median(in: NSRect(x: rect.maxX - 8, y: rect.minY + 4, width: 6, height: max(1, rect.height - 8)))
    }

    private func assertLegible(_ field: NSTextField?, named name: String, in rendered: Rendered, base: NSColor, keyWindow: Bool,
                               file: StaticString = #filePath, line: UInt = #line) {
        let state = keyWindow ? "key window" : "non-key window"
        guard let field else {
            XCTFail("\(state): \(name) is not drawn", file: file, line: line)
            return
        }
        let rect = field.convert(field.bounds, to: rendered.host)
        guard let ink = rendered.brightest(in: rect) else {
            XCTFail("\(state): \(name) drew no pixels in \(rect)", file: file, line: line)
            return
        }
        let ratio = contrastRatio(ink, base)
        XCTAssertGreaterThanOrEqual(ratio, 4.5,
                                    "\(state): \(name) measured \(String(format: "%.2f", ratio)):1 (text \(rgbName(ink)) on \(rgbName(base))), the floor is 4.5:1",
                                    file: file, line: line)
    }

    // MARK: Contrast

    private func assertHeaderTextLegible(keyWindow: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let view = outputView()
        view.apply(content: content(status: .completed, summary: "Built 12 files in 5 s"))
        guard let rendered = render(view, keyWindow: keyWindow, file: file, line: line),
              let base = background(of: view.header, in: rendered)
        else { return XCTFail("nothing drawn", file: file, line: line) }
        let header = view.header

        for (name, text) in [("kind", header.kindText), ("status", header.statusText),
                             ("description", header.descriptionText), ("closing summary", header.summaryText)] {
            assertLegible(label(showing: text, in: header), named: name, in: rendered, base: base, keyWindow: keyWindow,
                          file: file, line: line)
        }
    }

    func testHeaderTextMeetsContrastInTheKeyWindow() { assertHeaderTextLegible(keyWindow: true) }

    func testHeaderTextMeetsContrastInAWindowThatIsNotKey() { assertHeaderTextLegible(keyWindow: false) }

    private func assertMutedFieldsLegible(keyWindow: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let view = SubagentTaskView(focusTag: "kate", taskId: "t1", source: nil)
        view.apply(content: content(kind: .agent, description: "Write failing tests", totalTokens: 18_200, toolUses: 11,
                                    lastToolName: "Edit"))
        guard let rendered = render(view, keyWindow: keyWindow, file: file, line: line),
              let base = background(of: view.header, in: rendered)
        else { return XCTFail("nothing drawn", file: file, line: line) }
        let header = view.header
        XCTAssertFalse(header.metaText.isEmpty, "premise: the started and running-for line", file: file, line: line)
        XCTAssertFalse(header.activityText.isEmpty, "premise: the agent's activity line", file: file, line: line)

        for (name, text) in [("started and running for", header.metaText), ("activity", header.activityText)] {
            assertLegible(label(showing: text, in: header), named: name, in: rendered, base: base, keyWindow: keyWindow,
                          file: file, line: line)
        }
    }

    func testMutedHeaderFieldsMeetContrastInTheKeyWindow() { assertMutedFieldsLegible(keyWindow: true) }

    func testMutedHeaderFieldsMeetContrastInAWindowThatIsNotKey() { assertMutedFieldsLegible(keyWindow: false) }

    private func assertFailedStatusLegible(keyWindow: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let view = outputView()
        view.apply(content: content(status: .failed, summary: "Exit code 1: the build failed"))
        guard let rendered = render(view, keyWindow: keyWindow, file: file, line: line),
              let base = background(of: view.header, in: rendered)
        else { return XCTFail("nothing drawn", file: file, line: line) }
        let header = view.header
        XCTAssertEqual(header.statusText, "failed", "premise", file: file, line: line)
        XCTAssertEqual(header.statusColor, TaskWindowPalette.failed, "premise: a failed status is drawn in the failed colour",
                       file: file, line: line)

        assertLegible(label(showing: header.statusText, in: header), named: "failed status", in: rendered, base: base,
                      keyWindow: keyWindow, file: file, line: line)
        assertLegible(label(showing: header.summaryText, in: header), named: "failed closing summary", in: rendered, base: base,
                      keyWindow: keyWindow, file: file, line: line)
    }

    func testFailedStatusMeetsContrastInTheKeyWindow() { assertFailedStatusLegible(keyWindow: true) }

    func testFailedStatusMeetsContrastInAWindowThatIsNotKey() { assertFailedStatusLegible(keyWindow: false) }

    private func assertTruncationLineLegible(keyWindow: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let view = outputView(model: truncatedModel())
        view.apply(content: content())
        guard let notice = view.noticeText else { return XCTFail("premise: the pane shows a truncation line", file: file, line: line) }
        XCTAssertEqual(notice, "Showing the last 8 KB of 40 KB", "premise", file: file, line: line)
        guard let rendered = render(view, keyWindow: keyWindow, file: file, line: line),
              let base = background(of: view.header, in: rendered)
        else { return XCTFail("nothing drawn", file: file, line: line) }

        assertLegible(label(showing: notice, in: view), named: "truncation line", in: rendered, base: base,
                      keyWindow: keyWindow, file: file, line: line)
    }

    func testTruncationLineMeetsContrastInTheKeyWindow() { assertTruncationLineLegible(keyWindow: true) }

    func testTruncationLineMeetsContrastInAWindowThatIsNotKey() { assertTruncationLineLegible(keyWindow: false) }

    func testTheHeaderLooksTheSameWhetherOrNotItsWindowIsKey() throws {
        func descriptionInk(keyWindow: Bool) throws -> NSColor {
            let view = outputView()
            view.apply(content: content(status: .completed, summary: "Built 12 files in 5 s"))
            let rendered = try XCTUnwrap(render(view, keyWindow: keyWindow))
            let field = try XCTUnwrap(label(showing: view.header.descriptionText, in: view.header))
            return try XCTUnwrap(rendered.brightest(in: field.convert(field.bounds, to: rendered.host)))
        }

        let key = try descriptionInk(keyWindow: true)
        let notKey = try descriptionInk(keyWindow: false)

        XCTAssertEqual(contrastRatio(key, notKey), 1.0, accuracy: 0.05, "the header does not dim in an inactive window")
    }

    // MARK: Narrow width

    private typealias Body = NSView & TaskWindowBody

    private struct NarrowCase {
        let name: String
        let make: () -> Body
        let kind: TaskKindWire
    }

    private func narrowCases() -> [NarrowCase] {
        [NarrowCase(name: "TaskOutputView", make: { self.outputView() }, kind: .shell),
         NarrowCase(name: "TaskNoOutputView", make: { TaskNoOutputView(focusTag: "kate", taskId: "t1") }, kind: .workflow),
         NarrowCase(name: "SubagentTaskView", make: { SubagentTaskView(focusTag: "kate", taskId: "t1", source: nil) }, kind: .agent)]
    }

    private func headerView(of body: Body) -> TaskWindowHeaderView? {
        switch body {
        case let view as TaskOutputView: return view.header
        case let view as TaskNoOutputView: return view.header
        case let view as SubagentTaskView: return view.header
        default: return nil
        }
    }

    /// `body` in a real task panel as wide as the panel's minimum, content applied and laid out.
    private func inNarrowPanel(_ body: Body, content: TaskWindowContent) -> TaskPanel {
        _ = NSApplication.shared
        let width = TaskWindowFrame.minimumSize.width
        let panel = TaskPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 360),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = TaskWindowFrame.minimumSize
        panel.contentView = body
        addTeardownBlock { panel.close() }
        panel.setContentSize(NSSize(width: width, height: 360))
        body.apply(content: content)
        body.layoutSubtreeIfNeeded()
        body.layoutSubtreeIfNeeded()
        return panel
    }

    private func wideContent(for testCase: NarrowCase, description: String) -> TaskWindowContent {
        content(kind: testCase.kind, description: description, status: .failed,
                summary: String(repeating: "The closing summary says a good deal about how it went. ", count: 6),
                totalTokens: testCase.kind == .agent ? 18_200 : nil, toolUses: testCase.kind == .agent ? 11 : nil,
                lastToolName: testCase.kind == .agent ? "Edit" : nil)
    }

    func testTheHeaderFitsTheMinimumWidthWithoutForcingThePanelWider() throws {
        let width = TaskWindowFrame.minimumSize.width

        for testCase in narrowCases() {
            let body = testCase.make()
            let panel = inNarrowPanel(body, content: wideContent(for: testCase, description: Self.hostileDescription))
            let header = try XCTUnwrap(headerView(of: body), testCase.name)

            XCTAssertEqual(panel.frame.width, width, accuracy: 0.5, "\(testCase.name): the panel stays at its minimum width")
            XCTAssertEqual(body.bounds.width, width, accuracy: 0.5, "\(testCase.name): and so does its content")
            XCTAssertGreaterThanOrEqual(header.frame.minX, -0.5, "\(testCase.name)")
            XCTAssertLessThanOrEqual(header.frame.maxX, width + 0.5, "\(testCase.name): the header's frame fits the width")
            XCTAssertLessThanOrEqual(header.fittingSize.width, width + 0.5,
                                     "\(testCase.name): the header does not ask for more than the width (\(header.fittingSize.width))")
        }
    }

    func testNoHeaderLabelIsWiderThanTheHeader() throws {
        for testCase in narrowCases() {
            let body = testCase.make()
            _ = inNarrowPanel(body, content: wideContent(for: testCase, description: Self.hostileDescription))
            let header = try XCTUnwrap(headerView(of: body), testCase.name)

            let labels = rigAllSubviews(of: header).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }
            XCTAssertGreaterThanOrEqual(labels.count, 4, "\(testCase.name): premise: kind, status, description and more are drawn")
            for field in labels {
                let rect = field.convert(field.bounds, to: header)
                XCTAssertLessThanOrEqual(rect.width, header.bounds.width + 0.5, "\(testCase.name): '\(field.stringValue.prefix(20))' is wider than the header")
                XCTAssertGreaterThanOrEqual(rect.minX, -0.5, "\(testCase.name): '\(field.stringValue.prefix(20))' starts left of the header")
                XCTAssertLessThanOrEqual(rect.maxX, header.bounds.width + 0.5, "\(testCase.name): '\(field.stringValue.prefix(20))' ends right of the header")
            }
        }
    }

    func testALongDescriptionWrapsTheHeaderTallerRatherThanWider() throws {
        let width = TaskWindowFrame.minimumSize.width

        for testCase in narrowCases() {
            let shortBody = testCase.make()
            _ = inNarrowPanel(shortBody, content: wideContent(for: testCase, description: "npm run build"))
            let longBody = testCase.make()
            let panel = inNarrowPanel(longBody, content: wideContent(for: testCase, description: Self.hostileDescription))
            let shortHeader = try XCTUnwrap(headerView(of: shortBody), testCase.name)
            let longHeader = try XCTUnwrap(headerView(of: longBody), testCase.name)

            XCTAssertGreaterThan(longHeader.frame.height, shortHeader.frame.height + 10,
                                 "\(testCase.name): the long description wraps: \(longHeader.frame.height) vs \(shortHeader.frame.height)")
            XCTAssertEqual(longHeader.frame.width, shortHeader.frame.width, accuracy: 0.5, "\(testCase.name): the width does not change")
            XCTAssertEqual(longHeader.frame.width, width, accuracy: 0.5, "\(testCase.name)")
            XCTAssertEqual(panel.frame.width, width, accuracy: 0.5, "\(testCase.name)")
        }
    }

    func testHostileContentLeavesNoForbiddenScalarInTheDrawnHeaderItsTooltipOrItsAccessibilityLabel() throws {
        for testCase in narrowCases() {
            let body = testCase.make()
            _ = inNarrowPanel(body, content: wideContent(for: testCase, description: Self.hostileDescription))
            let header = try XCTUnwrap(headerView(of: body), testCase.name)
            let drawn: [(String, String, Bool)] = [
                ("kind", header.kindText, false), ("status", header.statusText, false),
                ("description", header.descriptionText, false), ("started and running for", header.metaText, false),
                ("activity", header.activityText, false), ("closing summary", header.summaryText, true),
                ("description tooltip", header.descriptionToolTip ?? "", false),
                ("header tooltip", header.toolTip ?? "", false),
                ("accessibility label", header.accessibilityLabel() ?? "", false),
            ]

            XCTAssertTrue(header.descriptionText.contains("safe"), "\(testCase.name): what is readable survives: \(header.descriptionText.prefix(80))")
            XCTAssertFalse((header.descriptionToolTip ?? "").isEmpty, "\(testCase.name): the description has a tooltip")
            XCTAssertFalse((header.accessibilityLabel() ?? "").isEmpty, "\(testCase.name): the header has an accessibility label")
            for (field, text, allowsLineBreaks) in drawn {
                for scalar in text.unicodeScalars where Self.forbidden(scalar, allowingLineBreaks: allowsLineBreaks) {
                    XCTFail("\(testCase.name): \(field) holds U+\(String(scalar.value, radix: 16, uppercase: true))")
                    break
                }
            }
        }
    }
}
