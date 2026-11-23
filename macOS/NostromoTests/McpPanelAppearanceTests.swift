import XCTest
import AppKit
import NostromoKit

// The `/mcp` panel and the badge's "Reconnecting…" state, RENDERED: real pixels, because frame-only tests
// missed a clipped digit before. In every row the status word, the last digit of the tool count and both
// button titles must be drawn inside their cells, the long name must truncate with an ellipsis rather than
// run into the status column, and the status words must keep 4.5:1 on the panel background.

private final class McpHost: NSView {
    override var isFlipped: Bool { true }
}

final class McpPanelAppearanceTests: XCTestCase {
    private let longName = "claude.ai LinkedIn Hiring Pro"
    private let longError = String(repeating: "502 Bad Gateway from the upstream server while starting; ", count: 8)

    private var servers: [McpServerViewWire] {
        [McpServerViewWire(name: longName, status: .needsAuth, scope: "claudeai", transport: "claudeai-proxy", toolCount: 123),
         McpServerViewWire(name: "callimachus", status: .failed, scope: "user", transport: "stdio", toolCount: 0, error: longError),
         McpServerViewWire(name: "weird", status: .unknown("weird-new-state"), scope: "user", transport: "http", toolCount: 987),
         McpServerViewWire(name: "off", status: .disabled, scope: "user", transport: "stdio", toolCount: nil),
         McpServerViewWire(name: "nostromo", status: .connected, scope: "user", transport: "stdio", toolCount: 100, nostromoBridge: true)]
    }

    private struct Shot {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        let size: NSSize

        func inkBounds(in rect: NSRect, isInk: (NSColor) -> Bool) -> NSRect? {
            let r = rect.intersection(NSRect(origin: .zero, size: size))
            guard !r.isNull else { return nil }
            var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
            for y in Int((r.minY * scale).rounded(.down)) ..< Int((r.maxY * scale).rounded(.up)) where y >= 0 && y < rep.pixelsHigh {
                for x in Int((r.minX * scale).rounded(.down)) ..< Int((r.maxX * scale).rounded(.up)) where x >= 0 && x < rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), isInk(c) else { continue }
                    minX = min(minX, CGFloat(x) / scale); maxX = max(maxX, CGFloat(x + 1) / scale)
                    minY = min(minY, CGFloat(y) / scale); maxY = max(maxY, CGFloat(y + 1) / scale)
                }
            }
            return minX.isFinite ? NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) : nil
        }

        func brightest(in rect: NSRect) -> Double {
            var best = 0.0
            let r = rect.intersection(NSRect(origin: .zero, size: size))
            guard !r.isNull else { return 0 }
            for y in Int((r.minY * scale).rounded(.down)) ..< Int((r.maxY * scale).rounded(.up)) where y >= 0 && y < rep.pixelsHigh {
                for x in Int((r.minX * scale).rounded(.down)) ..< Int((r.maxX * scale).rounded(.up)) where x >= 0 && x < rep.pixelsWide {
                    if let c = rep.colorAt(x: x, y: y) { best = max(best, modelRelativeLuminance(c)) }
                }
            }
            return best
        }
    }

    private func render(_ view: NSView, size: NSSize) throws -> (host: McpHost, shot: Shot) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .darkAqua)
        addTeardownBlock { window.orderOut(nil) }
        let host = McpHost(frame: NSRect(origin: .zero, size: size))
        window.contentView = host
        view.frame = host.bounds
        host.addSubview(view)
        for _ in 0..<2 { host.layoutSubtreeIfNeeded() }
        host.displayIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return (host, Shot(rep: rep, scale: CGFloat(rep.pixelsWide) / host.bounds.width, size: host.bounds.size))
    }

    private func textWidth(_ field: NSTextField) -> CGFloat {
        ceil((field.stringValue as NSString).size(withAttributes: [.font: field.font as Any]).width)
    }

    private func panel(size: NSSize) throws -> (McpPanelController, McpHost, Shot) {
        let harness = McpHarness()
        let c = McpPanelController(tag: "t", focusName: "Cody", projectPath: nil, requests: harness.requests,
                                   now: harness.now, schedule: harness.schedule)
        c.refresh()
        harness.answer("req-1", tag: "t", action: "status", .ok, servers: servers)
        let (host, shot) = try render(c.panelView, size: size)
        addTeardownBlock { _ = harness }
        return (c, host, shot)
    }

    private func isBright(_ c: NSColor) -> Bool { modelRelativeLuminance(c) > 0.2 }
    private func isInk(_ c: NSColor) -> Bool { modelRelativeLuminance(c) > 0.05 }

    func testEveryCellsContentIsDrawnInsideItAtTheMinimumAndDefaultSizes() throws {
        for size in [McpPanelView.minSize, McpPanelView.defaultSize] {
            let (c, host, shot) = try panel(size: size)
            XCTAssertEqual(c.panelView.rowViews.count, 5)
            for row in c.panelView.rowViews {
                let name = row.row?.name ?? "?"
                let tools = host.convert(row.toolsField.bounds, from: row.toolsField)
                XCTAssertLessThanOrEqual(textWidth(row.toolsField), row.toolsField.frame.width - 2,
                                         "\(name) at \(size.width): the count does not fit its column")
                if let ink = shot.inkBounds(in: tools, isInk: isInk) {
                    XCTAssertLessThanOrEqual(ink.maxX, tools.maxX - 2, "\(name): count digit touches the cell edge")
                }
                let status = host.convert(row.statusLabel.bounds, from: row.statusLabel)
                XCTAssertLessThanOrEqual(textWidth(row.statusLabel), row.statusLabel.frame.width - 2, "\(name): status word clipped")
                if let ink = shot.inkBounds(in: status, isInk: isInk) {
                    XCTAssertLessThanOrEqual(ink.maxX, status.maxX - 2, "\(name): status word touches the cell edge")
                }
                for button in [row.reconnectButton, row.toggleButton] where !button.isHidden {
                    let rect = host.convert(button.bounds, from: button)
                    XCTAssertLessThanOrEqual(textWidth(NSTextField(labelWithString: button.title).withFont(button.font)), rect.width - 12,
                                             "\(name): \(button.title) does not fit its button")
                    guard let ink = shot.inkBounds(in: rect.insetBy(dx: 3, dy: 3), isInk: isBright) else {
                        XCTFail("\(name): no title drawn in \(button.title)"); continue
                    }
                    XCTAssertGreaterThanOrEqual(ink.minX, rect.minX + 2)
                    XCTAssertLessThanOrEqual(ink.maxX, rect.maxX - 2, "\(name): \(button.title) title touches the button edge")
                }
            }
        }
    }

    func testALongNameTruncatesWithAnEllipsisInsteadOfRunningIntoTheStatusColumn() throws {
        let (c, host, shot) = try panel(size: McpPanelView.minSize)
        let row = try XCTUnwrap(c.panelView.rowViews.first { $0.row?.name == longName })
        XCTAssertEqual(row.nameField.lineBreakMode, .byTruncatingTail)
        XCTAssertGreaterThan(textWidth(row.nameField), row.nameField.frame.width, "the fixture must be too long to fit")
        let name = host.convert(row.nameField.bounds, from: row.nameField)
        let icon = host.convert(row.statusIcon.bounds, from: row.statusIcon)
        XCTAssertLessThanOrEqual(name.maxX, icon.minX, "the name column overlaps the status column")
        let gap = NSRect(x: name.maxX, y: name.minY, width: max(0, icon.minX - name.maxX), height: name.height)
        XCTAssertNil(shot.inkBounds(in: gap, isInk: isBright), "name text spilled into the gap")
        // The tail is an ellipsis: ink ends short of the column's right edge.
        let ink = try XCTUnwrap(shot.inkBounds(in: name, isInk: isInk))
        XCTAssertLessThan(ink.maxX, name.maxX - 0.5)
        // What is drawn is what fits the column: not the whole name squeezed or spilled, but a cut one.
        XCTAssertLessThanOrEqual(ink.width, name.width, "the drawn name is wider than its column")
        XCTAssertGreaterThanOrEqual(ink.minX, name.minX - 0.5)
        XCTAssertLessThan(ink.width, textWidth(row.nameField) - 20, "the drawn name is the whole name, not a cut one")
        XCTAssertEqual(name.width, row.nameField.frame.width, accuracy: 0.5)
        XCTAssertLessThan(name.width, textWidth(row.nameField), "the column is narrower than the name")
        // The column is where the header puts it: everything to its right is fixed width, so the buttons
        // still end at the row's edge.
        let toggle = host.convert(row.toggleButton.bounds, from: row.toggleButton)
        XCTAssertEqual(toggle.maxX, host.convert(row.bounds, from: row).maxX - McpColumns.inset, accuracy: 0.5)
    }

    // MARK: Row height

    /// The detail lines (a server's error, the bridge note, an action's result) sit inside their own row:
    /// each row is as tall as its content, so none draws over the next.
    func testNoRowOverlapsTheNextAndTheDetailTextLiesInsideItsRow() throws {
        let harness = McpHarness()
        let c = McpPanelController(tag: "t", focusName: "Cody", projectPath: nil, requests: harness.requests,
                                   now: harness.now, schedule: harness.schedule)
        c.permit = { _ in .human(sourcePid: nil, sourceState: nil) }
        c.refresh()
        var list = servers
        list[4] = McpServerViewWire(name: "nostromo", status: .connected, scope: "user", transport: "stdio", toolCount: 100, nostromoBridge: false)
        harness.answer("req-1", tag: "t", action: "status", .ok, servers: list)
        // A result note on the failing server (error line and note), and one on a plain server.
        c.reconnect("callimachus")
        harness.answer("req-2", tag: "t", action: "reconnect", .refused, message: "Server not found: callimachus")
        c.reconnect("weird")
        harness.answer("req-3", tag: "t", action: "reconnect", .ok, servers: list)
        let (_, _) = try render(c.panelView, size: McpPanelView.defaultSize)

        let rows = c.panelView.rowViews
        XCTAssertEqual(rows.count, 5)
        let frames = rows.map(\.frame).enumerated().sorted { $0.element.minY < $1.element.minY }
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(a.element.maxY, b.element.minY + 0.5,
                                     "row \(a.offset) (\(rows[a.offset].row?.name ?? "?")) overlaps row \(b.offset)")
        }
        var detailLines = 0
        for row in rows {
            let name = row.row?.name ?? "?"
            for field in [row.errorField, row.noteField] where !field.isHidden {
                detailLines += 1
                let rect = row.convert(field.bounds, from: field)
                XCTAssertGreaterThanOrEqual(rect.minY, row.bounds.minY - 0.5, "\(name): detail above its row")
                XCTAssertLessThanOrEqual(rect.maxY, row.bounds.maxY + 0.5, "\(name): detail text spills below its row")
                XCTAssertGreaterThan(rect.height, 8, "\(name): detail has a height")
            }
            XCTAssertGreaterThanOrEqual(row.frame.height, McpRowView.rowHeight - 0.5)
        }
        XCTAssertGreaterThanOrEqual(detailLines, 4, "the fixture has error, bridge and result lines")
        let callimachus = try XCTUnwrap(rows.first { $0.row?.name == "callimachus" })
        XCTAssertGreaterThan(callimachus.frame.height, McpRowView.rowHeight + 20, "error line and note both fit")
        let off = try XCTUnwrap(rows.first { $0.row?.name == "off" })
        XCTAssertEqual(off.frame.height, McpRowView.rowHeight, accuracy: 0.5, "a plain row stays one line tall")
    }

    func testStatusWordsKeepContrastOnThePanelBackground() throws {
        let bg = modelRelativeLuminance(Theme.bg)
        let kinds: [McpStatusKind] = [.connected, .needsAuth, .failed, .disabled, .pending, .unknown("x")]
        for k in kinds {
            XCTAssertGreaterThanOrEqual(modelContrastRatio(modelRelativeLuminance(McpRowView.color(for: k)), bg), 4.5, "\(k)")
        }
        let (c, host, shot) = try panel(size: McpPanelView.defaultSize)
        for row in c.panelView.rowViews {
            let rect = host.convert(row.statusLabel.bounds, from: row.statusLabel)
            XCTAssertGreaterThanOrEqual(modelContrastRatio(shot.brightest(in: rect), bg), 4.5, row.row?.name ?? "?")
        }
    }

    func testTheReconnectingBadgeKeepsItsTextInsideAtThePaceBarsHeight() throws {
        let harness = McpHarness()
        let badge = ToolsOfflineBadgeView()
        badge.requests = harness.requests
        badge.activeTag = { "t" }
        badge.now = harness.now
        badge.schedule = harness.schedule
        badge.apply(offline: true)
        badge.activate()
        XCTAssertEqual(badge.text, "Reconnecting…")
        let strip = McpHost(frame: NSRect(x: 0, y: 0, width: 160, height: Theme.paceBarsHeight))
        strip.wantsLayer = true
        strip.layer?.backgroundColor = Theme.bgBar.cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -4),
            badge.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -2),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: strip.leadingAnchor, constant: 4),
        ])
        let (host, shot) = try render(strip, size: strip.frame.size)
        let frame = host.convert(badge.bounds, from: badge)
        let ink = try XCTUnwrap(shot.inkBounds(in: frame, isInk: { modelRelativeLuminance($0) > 0.15 }))
        XCTAssertGreaterThanOrEqual(ink.minX, frame.minX + 2)
        XCTAssertLessThanOrEqual(ink.maxX, frame.maxX - 2)
        XCTAssertGreaterThanOrEqual(ink.minY, frame.minY + 1)
        XCTAssertLessThanOrEqual(ink.maxY, frame.maxY - 1)
        XCTAssertTrue(host.bounds.contains(frame))
    }
}

private extension NSTextField {
    func withFont(_ f: NSFont?) -> NSTextField { font = f; return self }
}
