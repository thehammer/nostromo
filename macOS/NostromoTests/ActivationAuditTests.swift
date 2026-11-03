import AppKit
import XCTest

final class ActivationAuditTests: XCTestCase {

    // MARK: Source scan

    /// Every app activation / order-front call in the app target must be immediately preceded by
    /// an `ActivationAudit.note` (same line before the call, or the nearest previous code line).
    func testEveryActivationCallSiteIsPrecededByAuditNote() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // NostromoTests
            .deletingLastPathComponent()   // macOS
            .appendingPathComponent("Nostromo", isDirectory: true)
        let pattern = try NSRegularExpression(pattern:
            #"NSApp\??\.activate\(|\.activate\(options|\.activate\(\)|makeKeyAndOrderFront|\.orderFront\(|orderFrontRegardless|\.makeKey\(\)|\.makeMain\("#)
        // Row-view methods named activate(), not app activation.
        let rowViewFiles = ["UI/Model/ModelPopover.swift", "UI/Terminal/StagingDrawerView.swift"]

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if url.lastPathComponent == "ActivationAudit.swift" { continue }
            let rel = String(url.path.dropFirst(appRoot.path.count + 1))
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            let lines = text.components(separatedBy: "\n")

            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || line.contains("NSLayoutConstraint") { continue }
                let ns = line as NSString
                let matches = pattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
                let hits = matches.filter {
                    !(rowViewFiles.contains(rel) && ns.substring(with: $0.range) == ".activate()")
                }
                guard let first = hits.first else { continue }

                let before = ns.substring(to: first.range.location)
                var audited = before.contains("ActivationAudit.note")
                if !audited {
                    var j = i - 1
                    while j >= 0 {
                        let prev = lines[j].trimmingCharacters(in: .whitespaces)
                        if prev.isEmpty || prev.hasPrefix("//") { j -= 1; continue }
                        audited = prev.contains("ActivationAudit.note")
                        break
                    }
                }
                if !audited { offenders.append("\(rel):\(i + 1): \(trimmed)") }
            }
        }

        XCTAssertGreaterThan(scanned, 50, "source scan found too few files; is the path resolution broken?")
        XCTAssertTrue(offenders.isEmpty,
                      "Activation / order-front calls without a preceding ActivationAudit.note:\n"
                      + offenders.joined(separator: "\n"))
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.title = sentinel
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let marker = "sentinel-test-\(UUID().uuidString)"
        ActivationAudit.event(marker)
        WindowPlacementLog.shared.flush()

        let url = WindowPlacementLog.defaultFileURL
        guard let log = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("placement log not readable under test")
        }
        XCTAssertTrue(log.contains(marker), "audit line was not written; cannot assert absence")
        XCTAssertFalse(log.contains(sentinel))
    }
}
