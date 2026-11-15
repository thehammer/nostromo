import XCTest
import AppKit
import SwiftUI
import NostromoKit

// The Overview's header, the group headers and every count pill, measured from a real render: a count drawn
// into a pill must be drawn whole and sit well inside it (a frame-only check passed a clipped last digit in
// #456 and #457; see NeedsYouPillsTests.testTheCountIsDrawnWholeAndInsideThePillForBothKinds, whose method
// this copies: render, measure ink, compare with the same text drawn whole).
//
// "Ink" is a pixel that differs from the palette background. A count pill's own fill is too faint to count, so
// the ink inside a pill is its text. A pill needs 5 pt of padding each side (it is built with 6): that is
// what fails when the pill is made narrower than its text, whichever way.
//
// Mutations (to be run by hand), and the test that fails for each:
//   M1 `AuthoredPrsChipView.width(for:)` loses the last glyph's width (or a fixed few points)
//        -> testGroupHeaderCountsAreDrawnWholeAndInsideTheirPill, testPinnedOverviewCountPillsAreDrawnWholeAndInsideTheirPill,
//           testTheOverviewRowsCountIsInsideTheRowAndItsPill
//   M2 the title label stops resisting compression (the count's last digit clipped)
//        -> testTheHeadersCountDigitsAreDrawnWhole
//   M3 the freshness or a note stops truncating at the tail (`.byClipping`)
//        -> testAHeaderNoteTruncatesWithAnEllipsisRatherThanClipping, testFreshnessIsWholeWithRoomAndTruncatedWithout
//   M4 the refresh button loses its image or sits past the header's padding
//        -> testTheRefreshButtonIsDrawnInsideTheHeader
final class AuthoredPrsHeaderAppearanceTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        super.tearDown()
    }

    private static let appearances: [(name: NSAppearance.Name, label: String)] = [(.darkAqua, "dark"), (.aqua, "light")]

    private func grown(_ rect: NSRect) -> NSRect { rect.insetBy(dx: -1.5, dy: -2) }

    // MARK: - Header

    private static let hiddenOrg = String(repeating: "l", count: 60)

    /// 100 open PRs, a relay that has been offline, a paused poll and ten hidden orgs: the longest header.
    private static func snapshot() -> AuthoredPrsSnapshot {
        APT.snapshot((1...100).map { APT.pr($0, group: .waiting) },
                     relay: AuthoredPrsRelay(state: .offline, since: APT.t0.addingTimeInterval(-3600)),
                     poll: AuthoredPrsPoll(state: .paused, checkedAt: APT.t0.addingTimeInterval(-120), intervalSecs: 300,
                                           resumesAt: APT.t0.addingTimeInterval(600)),
                     hiddenOrgs: Array(repeating: hiddenOrg, count: 10))
    }

    private struct RenderedHeader {
        let host: AuthoredPrsInkHost
        let header: AuthoredPrsHeaderView
        let model: AuthoredPrsHeaderModel
        let bitmap: APT.Bitmap
        let width: CGFloat
        let appearance: NSAppearance.Name
        let context: String

        func rect(_ view: NSView) -> NSRect { APT.rect(of: view, in: host) }
    }

    private func renderHeader(width: CGFloat, appearance: (name: NSAppearance.Name, label: String)) -> RenderedHeader? {
        let snapshot = Self.snapshot()
        let model = AuthoredPrsPresentation.header(snapshot, now: APT.t0, timeZone: APT.utc)
        var notes: [AuthoredPrsHeaderView.Note] = []
        if let hidden = AuthoredPrsPresentation.hiddenOrgsNote(snapshot) { notes.append(.init(text: hidden, isWarning: true)) }
        if let asOf = model.asOf { notes.append(.init(text: asOf)) }
        let height = AuthoredPrsHeaderView.height(noteCount: notes.count)
        let (host, window) = APT.inkHost(size: NSSize(width: width, height: height + 8), appearance: appearance.name)
        windows.append(window)
        let header = AuthoredPrsHeaderView()
        host.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: host.topAnchor),
            header.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: height),
        ])
        header.apply(model: model, notes: notes)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = APT.render(host) else { return nil }
        return RenderedHeader(host: host, header: header, model: model, bitmap: bitmap, width: width,
                              appearance: appearance.name, context: "\(Int(width)) pt, \(appearance.label)")
    }

    private func eachHeader(_ body: (RenderedHeader) -> Void) {
        for appearance in Self.appearances {
            for width in [CGFloat(360), 900] {
                if let rendered = renderHeader(width: width, appearance: appearance) { body(rendered) }
            }
        }
    }

    /// The height of the last ink of `text` truncated at the tail into a label of `width`, drawn by a plain label.
    private func referenceTruncatedTail(_ text: String, font: NSFont, color: NSColor, width: CGFloat,
                                        appearance: NSAppearance.Name) -> CGFloat? {
        let (host, window) = APT.inkHost(size: NSSize(width: width + 16, height: 28), appearance: appearance)
        windows.append(window)
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.frame = NSRect(x: 8, y: 4, width: width, height: 20)
        host.addSubview(label)
        guard let bitmap = APT.render(host) else { return nil }
        return bitmap.trailingInkHeight(in: label.frame)
    }

    func testTheHeadersCountDigitsAreDrawnWhole() {
        eachHeader { r in
            XCTAssertEqual(r.header.titleLabel.stringValue, "My open PRs · 100", "\(r.context): precondition: a 3-digit count")
            let text = APT.attributed(r.model.countText, font: .systemFont(ofSize: 13, weight: .semibold), color: AuthoredPrsPalette.text)
            guard let ink = r.bitmap.ink(in: grown(r.rect(r.header.titleLabel))),
                  let reference = APT.referenceInk(text, appearance: r.appearance, scale: r.bitmap.scale) else {
                return XCTFail("\(r.context): the count drew nothing")
            }
            XCTAssertGreaterThanOrEqual(ink.width, reference.width - r.bitmap.tolerance,
                                        "\(r.context): the count is clipped (ink \(ink.width), whole \(reference.width))")
        }
    }

    func testFreshnessIsWholeWithRoomAndTruncatedWithout() {
        let font = NSFont.systemFont(ofSize: 11)
        eachHeader { r in
            let freshness = r.model.freshness
            XCTAssertTrue(freshness.contains("relay offline since") && freshness.contains("polling every 5m")
                          && freshness.contains("paused: GitHub rate limit low, resumes"), "precondition: the longest freshness: \(freshness)")
            let label = r.header.freshnessLabel
            let slot = r.rect(label)
            let natural = APT.attributed(freshness, font: font, color: AuthoredPrsPalette.muted).size().width
            guard let ink = r.bitmap.ink(in: slot) else { return XCTFail("\(r.context): the freshness drew nothing") }

            XCTAssertLessThanOrEqual(ink.maxX, r.rect(r.header.refreshButton).minX, "\(r.context): the freshness stays off the refresh button")
            XCTAssertGreaterThanOrEqual(ink.minX, r.rect(r.header.titleLabel).maxX, "\(r.context): the freshness stays off the count")
            if natural <= slot.width {
                let text = APT.attributed(freshness, font: font, color: AuthoredPrsPalette.muted)
                guard let reference = APT.referenceInk(text, appearance: r.appearance, scale: r.bitmap.scale) else { return }
                XCTAssertGreaterThanOrEqual(ink.width, reference.width - r.bitmap.tolerance,
                                            "\(r.context): there is room, yet the freshness is clipped (ink \(ink.width), whole \(reference.width))")
            } else {
                XCTAssertEqual(label.lineBreakMode, .byTruncatingTail, "\(r.context): too long for its slot: it truncates at the tail")
                let expected = referenceTruncatedTail(freshness, font: font, color: AuthoredPrsPalette.muted, width: slot.width, appearance: r.appearance)
                let actual = r.bitmap.trailingInkHeight(in: slot)
                if let expected, let actual {
                    XCTAssertEqual(actual, expected, accuracy: 1.5, "\(r.context): the freshness ends like a tail-truncated label does (an ellipsis), not mid-glyph")
                }
            }
        }
        // At 360 pt there is certainly no room: the truncating branch must have been the one taken.
        if let narrow = renderHeader(width: 360, appearance: Self.appearances[0]) {
            let natural = APT.attributed(narrow.model.freshness, font: font, color: AuthoredPrsPalette.muted).size().width
            XCTAssertGreaterThan(natural, narrow.rect(narrow.header.freshnessLabel).width, "precondition: 360 pt cannot hold the freshness")
        }
    }

    func testAHeaderNoteTruncatesWithAnEllipsisRatherThanClipping() {
        eachHeader { r in
            let note = APT.descendants(of: r.header).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("Some repos hidden") }
            guard let note else { return XCTFail("\(r.context): the hidden-orgs note is not in the header") }
            let slot = r.rect(note)
            let natural = APT.attributed(note.stringValue, font: .systemFont(ofSize: 11), color: AuthoredPrsPalette.warning).size().width
            XCTAssertGreaterThan(natural, slot.width, "\(r.context): precondition: the note is wider than the header")
            XCTAssertEqual(note.lineBreakMode, .byTruncatingTail, r.context)

            guard let ink = r.bitmap.ink(in: slot, threshold: 0.15) else { return XCTFail("\(r.context): the note drew nothing") }
            XCTAssertLessThanOrEqual(ink.maxX, r.width - 16 + r.bitmap.tolerance, "\(r.context): the note stays inside the header's padding")
            // The note ends in a run of 'l' stems. Tail truncation ends in the ellipsis's low dots; clipping in a stem.
            guard let tail = r.bitmap.trailingInkHeight(in: slot) else { return XCTFail("\(r.context): no ink at the note's end") }
            XCTAssertLessThan(tail, 5, "\(r.context): the note ends in something \(tail) pt tall: clipped, not an ellipsis")
        }
    }

    func testTheRefreshButtonIsDrawnInsideTheHeader() {
        eachHeader { r in
            XCTAssertTrue(r.header.refreshButton.isEnabled, "\(r.context): precondition: a refresh may be asked for")
            let button = r.rect(r.header.refreshButton)
            XCTAssertNotNil(r.bitmap.ink(in: button), "\(r.context): ⟳ is drawn")
            XCTAssertLessThanOrEqual(button.maxX, r.width - 12 + 0.5, "\(r.context): ⟳ is inside the header's padding")
        }
    }

    // MARK: - Pills

    /// The ink inside `chip` is its text: whole, and with 5 pt of padding each side.
    private func assertPill(_ chip: NSView, text: String, in host: NSView, bitmap: APT.Bitmap, appearance: NSAppearance.Name,
                            _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let pill = APT.rect(of: chip, in: host)
        guard let ink = bitmap.ink(in: pill) else { return XCTFail("\(context): '\(text)' drew nothing", file: file, line: line) }
        if let reference = APT.referenceInk(APT.attributed(text, font: AuthoredPrsChipView.font, color: AuthoredPrsPalette.text),
                                            appearance: appearance, scale: bitmap.scale) {
            XCTAssertGreaterThanOrEqual(ink.width, reference.width - bitmap.tolerance,
                                        "\(context): '\(text)' is clipped (ink \(ink.width) pt wide, whole is \(reference.width))", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(ink.minX - pill.minX, 5, "\(context): '\(text)' is \(ink.minX - pill.minX) pt from the pill's left edge", file: file, line: line)
        XCTAssertGreaterThanOrEqual(pill.maxX - ink.maxX, 5, "\(context): '\(text)' is \(pill.maxX - ink.maxX) pt from the pill's right edge", file: file, line: line)
        XCTAssertGreaterThanOrEqual(ink.minY - pill.minY, 1, "\(context): '\(text)' touches the pill's top", file: file, line: line)
        XCTAssertGreaterThanOrEqual(pill.maxY - ink.maxY, 1, "\(context): '\(text)' touches the pill's bottom", file: file, line: line)
    }

    func testGroupHeaderCountsAreDrawnWholeAndInsideTheirPill() {
        let prs = (1...100).map { APT.pr($0, group: .needsYou) }
        guard let group = AuthoredPrsPresentation.groups(prs, now: APT.t0, timeZone: APT.utc).first else { return XCTFail("no group") }
        XCTAssertEqual(group.count, 100, "precondition")
        XCTAssertEqual(group.title, "NEEDS YOU", "precondition")

        for appearance in Self.appearances {
            for width in [CGFloat(360), 900] {
                let context = "group header, \(Int(width)) pt, \(appearance.label)"
                let (host, window) = APT.inkHost(size: NSSize(width: width, height: AuthoredPrsGroupHeaderView.height + 8), appearance: appearance.name)
                windows.append(window)
                let header = AuthoredPrsGroupHeaderView()
                header.frame = NSRect(x: 0, y: 0, width: width, height: AuthoredPrsGroupHeaderView.height)
                host.addSubview(header)
                header.configure(group)
                host.layoutSubtreeIfNeeded()
                guard let bitmap = APT.render(host) else { continue }

                XCTAssertEqual(header.countPill.text, "100", context)
                assertPill(header.countPill, text: "100", in: host, bitmap: bitmap, appearance: appearance.name, context)

                let title = APT.attributed("NEEDS YOU", font: .systemFont(ofSize: 11, weight: .semibold), color: AuthoredPrsPalette.muted)
                if let ink = bitmap.ink(in: grown(APT.rect(of: header.titleLabel, in: host))),
                   let reference = APT.referenceInk(title, appearance: appearance.name, scale: bitmap.scale) {
                    XCTAssertGreaterThanOrEqual(ink.width, reference.width - bitmap.tolerance, "\(context): NEEDS YOU is clipped")
                } else {
                    XCTFail("\(context): the group's title drew nothing")
                }
                XCTAssertLessThanOrEqual(APT.rect(of: header.countPill, in: host).maxX, width - 12 + 0.5, "\(context): the pill is inside the row")
            }
        }
    }

    func testPinnedOverviewCountPillsAreDrawnWholeAndInsideTheirPill() {
        for appearance in Self.appearances {
            for count in [1, 9, 10, 99, 100] {
                let context = "count pill \(count), \(appearance.label)"
                let (host, window) = APT.inkHost(size: NSSize(width: 120, height: 32), appearance: appearance.name)
                windows.append(window)
                let chip = AuthoredPrsChipView(text: "\(count)")
                host.addSubview(chip)
                NSLayoutConstraint.activate([
                    chip.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
                    chip.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                ])
                host.layoutSubtreeIfNeeded()
                guard let bitmap = APT.render(host) else { continue }
                XCTAssertGreaterThanOrEqual(chip.frame.width, AuthoredPrsChipView.height, "\(context): never narrower than it is tall")
                assertPill(chip, text: "\(count)", in: host, bitmap: bitmap, appearance: appearance.name, context)
            }
        }
    }

    func testTheOverviewRowsCountIsInsideTheRowAndItsPill() {
        let rowWidth: CGFloat = 260
        for appearance in Self.appearances {
            for count in [1, 9, 10, 99, 100] {
                let context = "Overview row, count \(count), \(appearance.label)"
                let (host, window) = APT.inkHost(size: NSSize(width: rowWidth, height: 28), appearance: appearance.name)
                windows.append(window)
                let hosting = NSHostingView(rootView: MotherOverviewRow(count: count).frame(width: rowWidth, height: 28))
                hosting.frame = host.bounds
                host.addSubview(hosting)
                for _ in 0..<3 {
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(mode: .default, before: .distantPast)
                }
                guard let bitmap = APT.render(host) else { continue }

                guard let all = bitmap.ink(in: host.bounds) else {
                    XCTFail("\(context): the row drew nothing at all (SwiftUI did not render into the bitmap)")
                    continue
                }
                XCTAssertLessThanOrEqual(all.maxX, rowWidth - 2, "\(context): the rightmost ink is at \(all.maxX) of \(rowWidth)")
                guard let chip = APT.descendants(of: hosting).compactMap({ $0 as? AuthoredPrsChipView }).first else {
                    XCTFail("\(context): the count pill is not in the row")
                    continue
                }
                XCTAssertLessThanOrEqual(APT.rect(of: chip, in: host).maxX, rowWidth + 0.5, "\(context): the pill is inside the row")
                assertPill(chip, text: "\(count)", in: host, bitmap: bitmap, appearance: appearance.name, context)
            }
        }
    }
}
