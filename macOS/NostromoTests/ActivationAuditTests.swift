import AppKit
import XCTest

final class ActivationAuditTests: XCTestCase {

    // MARK: Source scan

    /// Calls that activate the app, order a window front, change a window's Space/full-screen state,
    /// or bring another app forward (so Nostromo resigns active).
    private static let callPattern = try! NSRegularExpression(pattern:
        #"NSApp\??\.activate\(|NSApplication\.shared\.activate\(|\.activate\(options|\.activate\(\)"#
        + #"|makeKeyAndOrderFront|\.orderFront\(|orderFrontRegardless|\.makeKey\(\)|\.makeMain\("#
        + #"|deminiaturize\(|toggleFullScreen(Now)?\("#
        + #"|NSWorkspace\.shared\.(open|activateFileViewerSelecting|selectFile)\("#)

    /// Lines that match the pattern but are not window/app activation. Each entry: file, a substring of
    /// the trimmed line, and why it is exempt. Nothing else is exempt.
    private static let exemptLines: [(file: String, contains: String, why: String)] = [
        // A row view's own `activate()` (menu row selection), not NSApplication/NSRunningApplication.
        ("UI/Model/ModelPopover.swift", "rows[focusedRowIndex].activate()", "row-view method"),
    ]

    /// Offending lines ("<rel>:<n>: <text>") in one file's lines: pattern hits with no
    /// `ActivationAudit.note` before the call on the same line or on the nearest previous code line.
    static func offenders(in lines: [String], rel: String) -> [String] {
        var result: [String] = []
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || line.contains("NSLayoutConstraint") { continue }
            // Declarations (`func toggleFullScreenNow()`) define a method; they don't call it.
            if trimmed.hasPrefix("func ") { continue }
            if exemptLines.contains(where: { $0.file == rel && trimmed.contains($0.contains) }) { continue }
            let ns = line as NSString
            guard let first = callPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
            else { continue }

            var audited = ns.substring(to: first.range.location).contains("ActivationAudit.note")
            if !audited {
                var j = i - 1
                while j >= 0 {
                    let prev = lines[j].trimmingCharacters(in: .whitespaces)
                    if prev.isEmpty || prev.hasPrefix("//") { j -= 1; continue }
                    audited = prev.contains("ActivationAudit.note")
                    break
                }
            }
            if !audited { result.append("\(rel):\(i + 1): \(trimmed)") }
        }
        return result
    }

    func testEveryActivationCallSiteIsPrecededByAuditNote() throws {
        // Resolve symlinks on both sides (`/tmp` vs `/private/tmp`) before taking the relative path.
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // NostromoTests
            .deletingLastPathComponent()   // macOS
            .appendingPathComponent("Nostromo", isDirectory: true)
            .resolvingSymlinksInPath()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if url.lastPathComponent == "ActivationAudit.swift" { continue }
            let resolved = url.resolvingSymlinksInPath()
            let rel = String(resolved.path.dropFirst(appRoot.path.count + 1))
            guard let text = try? String(contentsOf: resolved, encoding: .utf8) else { continue }
            scanned += 1
            offenders += Self.offenders(in: text.components(separatedBy: "\n"), rel: rel)
        }

        XCTAssertGreaterThan(scanned, 50, "source scan found too few files; is the path resolution broken?")
        XCTAssertTrue(offenders.isEmpty,
                      "Activation / Space-affecting calls without a preceding ActivationAudit.note:\n"
                      + offenders.joined(separator: "\n"))
    }

    /// Mutation check: each pattern, unaudited, is flagged; with a note before it, it is not.
    func testScanFlagsEachPatternWhenUnauditedAndPassesWhenAudited() {
        let calls = [
            "NSApp.activate(ignoringOtherApps: true)",
            "NSApplication.shared.activate(ignoringOtherApps: true)",
            "other.activate(options: [])",
            "w.makeKeyAndOrderFront(nil)",
            "w.orderFrontRegardless()",
            "panel.deminiaturize(nil)",
            "window.toggleFullScreen(nil)",
            "window.toggleFullScreenNow()",
            "NSWorkspace.shared.open(url)",
            "NSWorkspace.shared.activateFileViewerSelecting([url])",
            "NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p)",
        ]
        for call in calls {
            XCTAssertEqual(Self.offenders(in: ["    \(call)"], rel: "X.swift").count, 1, "not flagged: \(call)")
            XCTAssertTrue(Self.offenders(in: ["    ActivationAudit.note(\"r\")", "    \(call)"], rel: "X.swift").isEmpty,
                          "audited call flagged: \(call)")
            XCTAssertTrue(Self.offenders(in: ["    { ActivationAudit.note(\"r\"); \(call) }"], rel: "X.swift").isEmpty,
                          "same-line audit not honoured: \(call)")
            // A note AFTER the call does not cover it.
            XCTAssertEqual(Self.offenders(in: ["    \(call)", "    ActivationAudit.note(\"r\")"], rel: "X.swift").count, 1,
                           "late note accepted: \(call)")
        }
    }

    func testScanExemptsOnlyTheListedRowViewLine() {
        XCTAssertTrue(Self.offenders(in: ["rows[focusedRowIndex].activate()"], rel: "UI/Model/ModelPopover.swift").isEmpty)
        XCTAssertEqual(Self.offenders(in: ["other.activate()"], rel: "UI/Model/ModelPopover.swift").count, 1)
        XCTAssertEqual(Self.offenders(in: ["rows[focusedRowIndex].activate()"], rel: "UI/Other.swift").count, 1)
    }

    // MARK: Formatter

    func testFormatCarriesReasonFlagsAndEveryWindowField() {
        let windows = [
            ActivationAudit.WindowInfo(number: 101, displayUUID: "UUID-A", isVisible: true, isKey: true, occlusion: 2),
            ActivationAudit.WindowInfo(number: 202, displayUUID: "UUID-B", isVisible: false, isKey: false, occlusion: 0),
        ]
        let line = ActivationAudit.format(reason: "unit-reason", detail: "cmd", site: "File.swift:9",
                                          appActive: true, caller: "in-app", keyDisplay: "UUID-A",
                                          windows: windows)
        for expected in ["unit-reason", "appActive=true", "keyDisplay=UUID-A", "File.swift:9",
                         "#101", "UUID-A", "visible=true", "key=true", "occ=2",
                         "#202", "UUID-B", "visible=false", "key=false", "occ=0"] {
            XCTAssertTrue(line.contains(expected), "missing \(expected) in: \(line)")
        }
    }

    func testFormatReportsNoneWhenNoKeyDisplay() {
        let line = ActivationAudit.format(reason: "r", detail: "", site: nil, appActive: false,
                                          caller: "in-app", keyDisplay: nil, windows: [])
        XCTAssertTrue(line.contains("keyDisplay=none"))
        XCTAssertTrue(line.contains("appActive=false"))
    }

    // MARK: No content

    func testWindowInfoHasNoTitleOrContentFields() {
        let info = ActivationAudit.WindowInfo(number: 1, displayUUID: "u", isVisible: true, isKey: false, occlusion: 0)
        let labels = Mirror(reflecting: info).children.compactMap(\.label)
        XCTAssertEqual(labels, ["number", "displayUUID", "isVisible", "isKey", "occlusion"])
    }

    func testAuditLineNeverContainsWindowTitle() throws {
        let sentinel = "SECRET-TITLE-\(UUID().uuidString)"
        // An NSPanel is a window the audit includes, so a title leak would show up in the line.
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.title = sentinel
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer { window.close() }
        XCTAssertNotNil(ActivationAudit.windowInfo(of: window), "sentinel window is not audited; test is vacuous")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("activation-audit-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let savedSink = ActivationAudit.sink
        let log = WindowPlacementLog(fileURL: tmp)
        ActivationAudit.sink = log
        defer { ActivationAudit.sink = savedSink }

        let marker = "sentinel-test-\(UUID().uuidString)"
        ActivationAudit.event(marker)
        log.flush()

        let text = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(text.contains(marker), "audit line was not written; cannot assert absence")
        XCTAssertTrue(text.contains("#\(window.windowNumber)"), "sentinel window absent from the line; test is vacuous")
        XCTAssertFalse(text.contains(sentinel))
    }
}
