import XCTest
import AppKit
import NostromoKit

// What a PR row actually puts on screen, measured from a real render (never from frames alone: a frame check
// missed a clipped digit in #456 and #457). The worst row there is, drawn at 320, 480 and 900 pt in dark and
// light appearance over the palette background:
//   a 200-character title, five failing checks with 60-character names, ten reviewers, a 3-digit PR number,
//   a 4-digit comment count, a Draft badge and an `owner/name` repo chip.
//
// "Ink" is a pixel that differs from the background. Whole-ness is judged against the ink of the same text
// drawn alone and unclipped (`APT.referenceInk`).
//
// Mutations (to be run by hand), and the test that fails for each:
//   M1 remove tail truncation on the title (`lineBreakMode = .byClipping`)
//        -> testALongTitleEndsInAnEllipsisNotAClippedGlyph
//   M2 narrow the chip by 4 pt (`AuthoredPrsChipView.width(for:)` minus 4)
//        -> testTheRepoChipAndDraftBadgeTextHaveFivePointsOfPaddingAndAreDrawnWhole
//   M3 the number, status or age label stops resisting compression (clipped on a narrow row)
//        -> testThePrNumberIsDrawnWhole, testTheStatusGlyphAndItsWordAreBothDrawn, testTheAgeIsDrawnWhole (320 pt)
//   M4 a line is allowed past the row's padding (trailing constraint removed)
//        -> testNoLineInksPastTheRowsRightEdge
//   M5 a line's height or gap changes without `rowHeight` -> testTheLaidOutRowHeightIsTheRowHeightAtEveryWidth
final class AuthoredPrRowAppearanceTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        super.tearDown()
    }

    private static let widths: [CGFloat] = [320, 480, 900]
    private static let appearances: [(name: NSAppearance.Name, label: String)] = [(.darkAqua, "dark"), (.aqua, "light")]

    private static let title = String(repeating: "l", count: 200)

    private static func model() -> AuthoredPrRowModel {
        let names = (1...5).map { i -> String in
            let stem = "check-\(i)-"
            return stem + String(repeating: "n", count: 60 - stem.count)
        }
        let pr = APT.pr(123, repo: "owner/name", title: title, group: .needsYou, draft: true, baseRef: "slash-commands-0",
                        checks: AuthoredPrChecks(state: .failing, passed: 9, failed: 5, failingNames: names),
                        review: AuthoredPrReview(state: .changesRequested, logins: (1...10).map { "reviewer-login-\($0)" }),
                        newComments: 1234, unresolvedThreads: 12, owner: APT.motherOwner())
        return AuthoredPrsPresentation.row(pr, chip: "owner/name", now: APT.t0)
    }

    private struct Rendered {
        let host: AuthoredPrsInkHost
        let row: AuthoredPrRowView
        let model: AuthoredPrRowModel
        let bitmap: APT.Bitmap
        let width: CGFloat
        let appearance: NSAppearance.Name
        let context: String

        func rect(_ view: NSView) -> NSRect { APT.rect(of: view, in: host) }
    }

    private func render(width: CGFloat, appearance: (name: NSAppearance.Name, label: String)) -> Rendered? {
        let model = Self.model()
        let (host, window) = APT.inkHost(size: NSSize(width: width, height: 120), appearance: appearance.name)
        windows.append(window)
        let row = AuthoredPrRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: host.topAnchor),
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.widthAnchor.constraint(equalToConstant: width),
        ])
        row.configure(model)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = APT.render(host) else { return nil }
        return Rendered(host: host, row: row, model: model, bitmap: bitmap, width: width, appearance: appearance.name,
                        context: "\(Int(width)) pt, \(appearance.label)")
    }

    private func eachRendering(_ body: (Rendered) throws -> Void) rethrows {
        for appearance in Self.appearances {
            for width in Self.widths {
                guard let rendered = render(width: width, appearance: appearance) else { continue }
                try body(rendered)
            }
        }
    }

    /// `rect` grown a little each way so ink that a too-small frame would clip is still seen.
    private func grown(_ rect: NSRect) -> NSRect { rect.insetBy(dx: -1.5, dy: -2) }

    /// The ink of `view`'s text must be at least as wide as the same text drawn whole.
    private func assertWhole(_ r: Rendered, _ view: NSView, _ text: NSAttributedString, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let ink = r.bitmap.ink(in: grown(r.rect(view))) else {
            return XCTFail("\(r.context): \(what) drew nothing", file: file, line: line)
        }
        guard let reference = APT.referenceInk(text, appearance: r.appearance, scale: r.bitmap.scale) else {
            return XCTFail("could not draw the reference for \(what)", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(ink.width, reference.width - r.bitmap.tolerance,
                                    "\(r.context): \(what) is clipped (ink \(ink.width) pt wide, whole is \(reference.width))", file: file, line: line)
    }

    // MARK: - Nothing runs past the right edge

    func testNoLineInksPastTheRowsRightEdge() {
        eachRendering { r in
            let first = r.rect(r.row.statusLabel).union(r.rect(r.row.repoChip))
            let checks = r.rect(r.row.checksLabel)
            let review = r.rect(r.row.reviewLabel)
            let bands: [(String, NSRect)] = [
                ("title line", NSRect(x: 0, y: first.minY, width: r.width, height: first.height)),
                ("checks line", NSRect(x: 0, y: checks.minY, width: r.width, height: checks.height)),
                ("review line", NSRect(x: 0, y: review.minY, width: r.width, height: review.height)),
                ("owner line", NSRect(x: 0, y: review.maxY, width: r.width, height: AuthoredPrRowView.lineHeight)),
            ]
            for (name, band) in bands {
                guard let ink = r.bitmap.ink(in: band) else {
                    XCTFail("\(r.context): the \(name) drew nothing")
                    continue
                }
                XCTAssertLessThanOrEqual(ink.maxX, r.width - 2, "\(r.context): the \(name) reaches the row's right edge (ink ends at \(ink.maxX) of \(r.width))")
                XCTAssertGreaterThanOrEqual(ink.minX, 2, "\(r.context): the \(name) starts at the row's left edge")
            }
        }
    }

    // MARK: - Number, status, age

    func testThePrNumberIsDrawnWhole() {
        eachRendering { r in
            let text = APT.attributed(r.model.numberText, font: .systemFont(ofSize: 12, weight: .semibold), color: AuthoredPrsPalette.text)
            XCTAssertEqual(r.model.numberText, "#123", "precondition: three digits")
            assertWhole(r, r.row.numberLabel, text, "the PR number")
        }
    }

    func testTheStatusGlyphAndItsWordAreBothDrawn() {
        eachRendering { r in
            let color = AuthoredPrsPalette.statusColor(r.model.statusKind)
            let glyph = NSAttributedString(string: r.model.statusGlyph, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: color])
            let space = NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: color])
            let word = NSAttributedString(string: r.model.statusWord, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: color])
            let whole = NSMutableAttributedString(attributedString: glyph)
            whole.append(space)
            whole.append(word)
            assertWhole(r, r.row.statusLabel, whole, "the status glyph and word")

            let label = r.rect(r.row.statusLabel)
            let glyphZone = NSRect(x: label.minX - 1.5, y: label.minY - 2, width: glyph.size().width + 1.5, height: label.height + 4)
            let wordStart = label.minX + glyph.size().width + space.size().width
            let wordZone = NSRect(x: wordStart, y: label.minY - 2, width: label.maxX + 1.5 - wordStart, height: label.height + 4)
            XCTAssertNotNil(r.bitmap.ink(in: glyphZone), "\(r.context): the status glyph \(r.model.statusGlyph) is drawn")
            XCTAssertNotNil(r.bitmap.ink(in: wordZone), "\(r.context): the status word '\(r.model.statusWord)' is drawn")
        }
    }

    func testTheAgeIsDrawnWhole() {
        eachRendering { r in
            XCTAssertEqual(r.model.age, "2h", "precondition")
            let text = APT.attributed(r.model.age, font: .systemFont(ofSize: 11), color: AuthoredPrsPalette.muted)
            assertWhole(r, r.row.ageLabel, text, "the age")
            if let ink = r.bitmap.ink(in: grown(r.rect(r.row.ageLabel))) {
                XCTAssertLessThanOrEqual(ink.maxX, r.width - 2, "\(r.context): the age is inside the row")
            }
        }
    }

    // MARK: - Chips

    func testTheRepoChipAndDraftBadgeTextHaveFivePointsOfPaddingAndAreDrawnWhole() {
        eachRendering { r in
            XCTAssertFalse(r.row.draftBadge.isHidden, "precondition: the row is a draft")
            let chips: [(String, AuthoredPrsChipView, String)] = [("repo chip", r.row.repoChip, r.model.repoChip), ("Draft badge", r.row.draftBadge, "Draft")]
            for (name, chip, text) in chips {
                XCTAssertEqual(chip.text, text, "precondition")
                let pill = r.rect(chip)
                guard let ink = r.bitmap.ink(in: pill) else {
                    XCTFail("\(r.context): the \(name) text drew nothing")
                    continue
                }
                let reference = APT.referenceInk(APT.attributed(text, font: AuthoredPrsChipView.font, color: AuthoredPrsPalette.text),
                                                 appearance: r.appearance, scale: r.bitmap.scale)
                if let reference {
                    XCTAssertGreaterThanOrEqual(ink.width, reference.width - r.bitmap.tolerance,
                                                "\(r.context): the \(name) text is clipped (ink \(ink.width), whole \(reference.width))")
                }
                XCTAssertGreaterThanOrEqual(ink.minX - pill.minX, 5, "\(r.context): the \(name) text is \(ink.minX - pill.minX) pt from the chip's left edge")
                XCTAssertGreaterThanOrEqual(pill.maxX - ink.maxX, 5, "\(r.context): the \(name) text is \(pill.maxX - ink.maxX) pt from the chip's right edge")
                XCTAssertLessThanOrEqual(pill.maxX, r.width - AuthoredPrRowView.sidePadding + 0.5, "\(r.context): the \(name) is inside the row's padding")
            }
        }
    }

    // MARK: - The title

    func testALongTitleEndsInAnEllipsisNotAClippedGlyph() {
        var truncatedRenderings = 0
        eachRendering { r in
            let slot = r.rect(r.row.titleLabel)
            XCTAssertEqual(r.row.titleLabel.lineBreakMode, .byTruncatingTail, "\(r.context): the title truncates at the tail")
            XCTAssertEqual(r.row.titleLabel.stringValue, Self.title, "\(r.context): the label holds all 200 characters; only the drawing is shortened")
            let text = APT.attributed(Self.title, font: .systemFont(ofSize: 12), color: AuthoredPrsPalette.text)
            let nextLeft = min(r.rect(r.row.draftBadge).minX, r.rect(r.row.repoChip).minX)

            guard let ink = r.bitmap.ink(in: slot, threshold: 0.15) else {
                return XCTFail("\(r.context): the title drew nothing")
            }
            XCTAssertLessThanOrEqual(ink.maxX, nextLeft - 1, "\(r.context): the title's ink stops before the chips")
            guard text.size().width > slot.width else { return }   // it fits whole: nothing to truncate at this width
            truncatedRenderings += 1
            // The title is a run of 'l', each a tall stem. A tail-truncated line ends in the ellipsis's low dots;
            // a clipped one ends in a slice of a stem.
            guard let tail = r.bitmap.trailingInkHeight(in: slot) else {
                return XCTFail("\(r.context): no ink at the end of the title")
            }
            XCTAssertLessThan(tail, 5, "\(r.context): the title ends in something \(tail) pt tall: a clipped glyph, not an ellipsis")
        }
        // 320 and 480 pt cannot hold 200 characters, in either appearance.
        XCTAssertGreaterThanOrEqual(truncatedRenderings, 4, "precondition: the narrow rows truncate their title")
    }

    // MARK: - Height

    func testTheLaidOutRowHeightIsTheRowHeightAtEveryWidth() {
        eachRendering { r in
            XCTAssertEqual(r.row.frame.width, r.width, accuracy: 0.5, "\(r.context)")
            XCTAssertEqual(r.row.frame.height, AuthoredPrRowView.rowHeight, accuracy: 0.5, "\(r.context): the laid-out height")
            XCTAssertEqual(r.row.fittingSize.height, AuthoredPrRowView.rowHeight, accuracy: 0.5, "\(r.context): the fitting height")
        }
    }
}
