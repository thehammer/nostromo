import XCTest
import AppKit
import NostromoKit

// What the hand-off puts on screen, measured from real renders (never from frames alone: a frame check cannot
// see a clipped last letter, and shipped one twice before).
//
//  * The row's button (Tell Cody, Choose focus…, Start a session…) at 320, 480 and 900 pt in dark and light
//    appearance, on the worst row there is (a 200-character title, five failing checks with 60-character
//    names, ten reviewers, a 4-digit comment count, a long owner line and a "Told Cody 59m ago"): its title is
//    drawn whole and at least 2 pt inside its own frame; no other line runs into it or past the row's right
//    edge; the told text is drawn whole.
//  * The preview popover's content at its width (440 pt) with a ten-check message: the last line of text is
//    inside the text view (not cut off by its height) and the default button's title is whole.
//  * The waiting pill on a focus row, with 1, 9, 10 and 99 PRs waiting: the count is drawn whole.
//
// MEASURING A BUTTON'S TITLE. A button's bezel is ink too, so a plain "pixels that differ from the background"
// measure finds the bezel, not the text. The title is therefore painted pure red (same string, same font, so
// the same layout) and measured by its colour (`APT.redInk`): the bezel is grey, whatever the appearance. For
// the same reason the default button's key equivalent is cleared while it is measured: only its bezel colour
// changes, never its size or its text.
//
// NAMED MUTATION TESTS. A measurement that cannot fail proves nothing, so two tests feed the very same
// helpers a deliberately broken input and demand that the check FAILS:
//   * testMutationASqueezedButtonFailsTheTitleCheck: the same button squeezed to a narrow fixed width (its
//     title is clipped): `titleCheck(...)` must say not ok, while the same button at its natural width says ok.
//   * testMutationATextViewOneLineTooShortFailsTheLastLineCheck: the preview's text view one line too short:
//     `lastLineCheck(...)` must say not ok, while the real one says ok.
// Mutations of the source (to be run by hand), and the test that fails for each:
//   M1 the row's button is allowed to compress (`compressionResistance` below required) -> testTheButtonTitleIsDrawnWhole...
//   M2 the detail lines run under the button (trailing constraint to the row edge)       -> testTheOtherLinesKeepTheirRightMarginAndStayClearOfTheButton
//   M3 the told label truncates                                                          -> testTheToldTextIsDrawnWhole
//   M4 the message view is one line too short (height constraint short)                  -> testThePreviewShowsItsLastLineAndItsButtonTitlesWhole
//   M5 the waiting pill is too narrow for two digits                                     -> testTheWaitingPillCountIsDrawnWhole...
final class AuthoredPrTellAppearanceTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        super.tearDown()
    }

    private static let widths: [CGFloat] = [320, 480, 900]
    private static let appearances: [(name: NSAppearance.Name, label: String)] = [(.darkAqua, "dark"), (.aqua, "light")]

    // MARK: - Measuring helpers

    private struct Check {
        let ok: Bool
        let detail: String
    }

    /// The bounding box, in points from the top-left, of the pixels in `rect` that differ from `fill`.
    private static func bounds(of bitmap: APT.Bitmap, in rect: NSRect, differingFrom fill: NSColor, threshold: CGFloat = 0.2) -> NSRect? {
        guard let f = fill.usingColorSpace(.sRGB) else { return nil }
        let rep = bitmap.rep, scale = bitmap.scale
        let r = rect.intersection(NSRect(origin: .zero, size: bitmap.size))
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        let x0 = max(0, Int((r.minX * scale).rounded(.down))), x1 = min(rep.pixelsWide, Int((r.maxX * scale).rounded(.up)))
        let y0 = max(0, Int((r.minY * scale).rounded(.down))), y1 = min(rep.pixelsHigh, Int((r.maxY * scale).rounded(.up)))
        guard x0 < x1, y0 < y1 else { return nil }
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let d = max(abs(c.redComponent - f.redComponent), abs(c.greenComponent - f.greenComponent), abs(c.blueComponent - f.blueComponent))
                if d > threshold {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return NSRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// Is `button`'s title (painted red) drawn whole, and at least 2 pt inside the button's frame on both sides?
    /// `title` is the string it shows. Returns a verdict rather than asserting, so a mutation test can demand
    /// that it fails.
    private func titleCheck(_ button: NSButton, title: String, host: NSView, bitmap: APT.Bitmap,
                            appearance: NSAppearance.Name) -> Check {
        let frame = APT.rect(of: button, in: host)
        guard let ink = APT.redInk(bitmap, in: frame.insetBy(dx: -1.5, dy: -2)) else {
            return Check(ok: false, detail: "the title '\(title)' drew nothing in the button's frame \(frame)")
        }
        let font = button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        guard let reference = APT.referenceInk(APT.attributed(title, font: font, color: APT.titleRed),
                                               appearance: appearance, scale: bitmap.scale) else {
            return Check(ok: false, detail: "could not draw the reference for '\(title)'")
        }
        var problems: [String] = []
        if ink.width < reference.width - bitmap.tolerance {
            problems.append("'\(title)' is clipped: ink \(ink.width) pt wide, whole is \(reference.width)")
        }
        if ink.minX < frame.minX + 2 {
            problems.append("'\(title)' starts \(ink.minX - frame.minX) pt inside the button's left edge (needs 2)")
        }
        if ink.maxX > frame.maxX - 2 {
            problems.append("'\(title)' ends \(frame.maxX - ink.maxX) pt inside the button's right edge (needs 2)")
        }
        return Check(ok: problems.isEmpty, detail: problems.joined(separator: "; "))
    }

    /// Is the last line of `message`'s text inside the area its text view shows, and drawn?
    private func lastLineCheck(_ message: AuthoredPrMessageView, host: NSView, bitmap: APT.Bitmap) -> Check {
        let tv = message.textView
        guard let layout = tv.layoutManager, let container = tv.textContainer, layout.numberOfGlyphs > 0 else {
            return Check(ok: false, detail: "no text is laid out")
        }
        layout.ensureLayout(for: container)
        var line = layout.lineFragmentUsedRect(forGlyphAt: layout.numberOfGlyphs - 1, effectiveRange: nil)
        line = line.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
        let lineInHost = tv.convert(line, to: host)
        let visible = tv.convert(tv.visibleRect, to: host)
        let scroll = APT.rect(of: message.scroll, in: host)

        var problems: [String] = []
        if !visible.insetBy(dx: -0.5, dy: -0.5).contains(lineInHost) {
            problems.append("the last line (y \(lineInHost.minY) to \(lineInHost.maxY)) is not inside what the text view shows (down to \(visible.maxY))")
        }
        // Drawn: ink of the text colour on the scroll view's own fill, within the part of the line that is shown.
        let fillPoint = NSPoint(x: scroll.minX + 3, y: scroll.minY + 3)
        let fill = bitmap.rep.colorAt(x: Int(fillPoint.x * bitmap.scale), y: Int(fillPoint.y * bitmap.scale))
        let shown = lineInHost.intersection(visible)
        if let fill, !shown.isNull, shown.height > 0,
           let ink = Self.bounds(of: bitmap, in: shown, differingFrom: fill) {
            if ink.maxY > scroll.maxY + 0.5 {
                problems.append("the last line's ink reaches \(ink.maxY), below the text view's bottom edge \(scroll.maxY)")
            }
        } else {
            problems.append("nothing is drawn on the last line")
        }
        return Check(ok: problems.isEmpty, detail: problems.joined(separator: "; "))
    }

    // MARK: - The row

    private static let title = String(repeating: "l", count: 200)

    private static func owner(for label: String) -> AuthoredPrOwner {
        switch label {
        case "Tell Cody": return HF.motherOwner()
        case "Start a session…": return HF.closedOwner()
        default: return .unknown
        }
    }

    private static let labels = ["Tell Cody", "Choose focus…", "Start a session…"]

    private static func model(label: String) -> AuthoredPrRowModel {
        let names = (1...5).map { i -> String in
            let stem = "check-\(i)-"
            return stem + String(repeating: "n", count: 60 - stem.count)
        }
        var pr = APT.pr(123, repo: "owner/name", title: title, group: .needsYou, baseRef: "slash-commands-0",
                        checks: AuthoredPrChecks(state: .failing, passed: 9, failed: 5, failingNames: names),
                        review: AuthoredPrReview(state: .changesRequested, logins: (1...10).map { "reviewer-login-\($0)" }),
                        newComments: 1234, unresolvedThreads: 12, owner: owner(for: label))
        pr.told = HF.told(minutesAgo: 59)
        let model = AuthoredPrsPresentation.row(pr, chip: "owner/name", now: APT.t0, handoff: true)
        precondition(model.tellButton?.title == label, "fixture: the row's button says \(label)")
        return model
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

    private func render(label: String, width: CGFloat, appearance: (name: NSAppearance.Name, label: String)) -> Rendered? {
        let model = Self.model(label: label)
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
        let context = "'\(label)' at \(Int(width)) pt, \(appearance.label)"
        // Painting the title red must not change the button: same string, same font.
        let before = row.tellButton.frame
        APT.paintTitleRed(row.tellButton)
        host.layoutSubtreeIfNeeded()
        let after = row.tellButton.frame
        if abs(before.width - after.width) > 0.5 || abs(before.height - after.height) > 0.5 {
            XCTFail("\(context): painting the title red changed the button's size \(before.size) to \(after.size); the measurement is not valid")
            return nil
        }
        guard let bitmap = APT.render(host) else { return nil }
        return Rendered(host: host, row: row, model: model, bitmap: bitmap, width: width,
                        appearance: appearance.name, context: context)
    }

    private func eachRendering(_ body: (Rendered) -> Void) {
        for label in Self.labels {
            for appearance in Self.appearances {
                for width in Self.widths {
                    guard let rendered = render(label: label, width: width, appearance: appearance) else { continue }
                    body(rendered)
                }
            }
        }
    }

    func testTheButtonTitleIsDrawnWholeAndInsideItsFrameForEveryLabelWidthAndAppearance() {
        eachRendering { r in
            XCTAssertFalse(r.row.tellButton.isHidden, "\(r.context): precondition, the row has its button")
            let check = titleCheck(r.row.tellButton, title: r.row.tellButton.title, host: r.host, bitmap: r.bitmap, appearance: r.appearance)
            XCTAssertTrue(check.ok, "\(r.context): \(check.detail)")
        }
    }

    func testTheButtonSitsInsideTheRowAtTheRowsRightPadding() {
        eachRendering { r in
            let button = r.rect(r.row.tellButton)
            XCTAssertTrue(r.row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(r.row.tellButton.frame),
                          "\(r.context): the button \(r.row.tellButton.frame) is inside the row \(r.row.bounds)")
            XCTAssertEqual(button.maxX, r.width - AuthoredPrRowView.sidePadding, accuracy: 0.5, "\(r.context): at the right padding")
            XCTAssertEqual(r.row.frame.height, AuthoredPrRowView.rowHeight, accuracy: 0.5, "\(r.context): the button did not change the row's height")
        }
    }

    func testTheOtherLinesKeepTheirRightMarginAndStayClearOfTheButton() {
        eachRendering { r in
            let button = r.rect(r.row.tellButton)
            let first = r.rect(r.row.statusLabel).union(r.rect(r.row.repoChip))
            let checks = r.rect(r.row.checksLabel)
            let review = r.rect(r.row.reviewLabel)
            let owner = NSRect(x: 0, y: review.maxY, width: r.width, height: AuthoredPrRowView.lineHeight)

            // The title line has no button: it keeps the 2 pt margin it always had.
            if let ink = r.bitmap.ink(in: NSRect(x: 0, y: first.minY, width: r.width, height: first.height)) {
                XCTAssertLessThanOrEqual(ink.maxX, r.width - 2, "\(r.context): the title line reaches the row's right edge")
            } else {
                XCTFail("\(r.context): the title line drew nothing")
            }
            // The three detail lines end before the button: nothing of theirs in the gap beside it, and nothing
            // past the row's margin.
            for (name, band) in [("checks line", checks), ("review line", review), ("owner line", owner)] {
                let gap = NSRect(x: button.minX - 6, y: band.minY, width: 4, height: band.height)
                XCTAssertNil(r.bitmap.ink(in: gap), "\(r.context): the \(name) runs up to or under the button")
                let beforeButton = NSRect(x: 0, y: band.minY, width: max(0, button.minX - 2), height: band.height)
                if let ink = r.bitmap.ink(in: beforeButton) {
                    XCTAssertLessThanOrEqual(ink.maxX, button.minX - 2, "\(r.context): the \(name) is closer than 2 pt to the button")
                }
            }
        }
    }

    func testTheToldTextIsDrawnWhole() {
        eachRendering { r in
            XCTAssertFalse(r.row.toldLabel.isHidden, "\(r.context): precondition, someone was told")
            XCTAssertTrue(r.row.toldLabel.stringValue.contains("Told Cody 59m ago"), "\(r.context): \(r.row.toldLabel.stringValue)")
            let font = r.row.toldLabel.font ?? NSFont.systemFont(ofSize: 11)
            let text = APT.attributed(r.row.toldLabel.stringValue, font: font, color: AuthoredPrsPalette.muted)
            let slot = r.rect(r.row.toldLabel).insetBy(dx: -1.5, dy: -2)
            guard let ink = r.bitmap.ink(in: slot) else { return XCTFail("\(r.context): the told text drew nothing") }
            guard let reference = APT.referenceInk(text, appearance: r.appearance, scale: r.bitmap.scale) else {
                return XCTFail("\(r.context): could not draw the reference")
            }
            XCTAssertGreaterThanOrEqual(ink.width, reference.width - r.bitmap.tolerance,
                                        "\(r.context): 'Told Cody 59m ago' is clipped (ink \(ink.width) pt, whole is \(reference.width))")
        }
    }

    // MARK: - The preview popover

    private struct PreviewRendered {
        let host: AuthoredPrsInkHost
        let vc: AuthoredPrPreviewViewController
        let bitmap: APT.Bitmap
        let appearance: NSAppearance.Name
        let context: String
    }

    private func renderPreview(appearance: (name: NSAppearance.Name, label: String), ownerClosed: Bool,
                               shorten: Bool = false) -> PreviewRendered? {
        let (host, window) = APT.inkHost(size: NSSize(width: AuthoredPrPreviewViewController.width, height: 600), appearance: appearance.name)
        windows.append(window)
        let transport = RecordingTransport()
        let session = AuthoredPrPreviewSession(row: HF.row(HF.pr()), tag: HF.tag, transport: transport, permit: { _, _, _ in true })
        let vc = AuthoredPrPreviewViewController(session: session)
        vc.clock = { APT.t0 }
        let content = vc.view
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.widthAnchor.constraint(equalToConstant: AuthoredPrPreviewViewController.width),
        ])
        session.start()
        transport.answerPreview(.ok(HF.payload(text: HF.tenCheckText,
                                               lastTold: AuthoredPrLastTold(name: "Cody in Nostromo", at: APT.t0.addingTimeInterval(-60)))))
        if ownerClosed { session.openFocusesChanged([]) }
        host.layoutSubtreeIfNeeded()

        if shorten {
            // The mutation: the text view one line too short.
            let height = vc.message.scroll.constraints.first { $0.firstAttribute == .height && $0.secondItem == nil }
            guard let height else {
                XCTFail("could not find the message view's height constraint (the mutation seam moved)")
                return nil
            }
            let line = (vc.message.textView.layoutManager?.defaultLineHeight(for: vc.message.textView.font ?? .systemFont(ofSize: 11))) ?? 14
            height.constant -= ceil(line)
            host.layoutSubtreeIfNeeded()
        }

        // The default button is measured as an ordinary one (only its bezel colour differs), then painted red.
        vc.sendButton.keyEquivalent = ""
        for button in [vc.sendButton, vc.cancelButton] { APT.paintTitleRed(button) }
        host.layoutSubtreeIfNeeded()
        guard let bitmap = APT.render(host) else { return nil }
        return PreviewRendered(host: host, vc: vc, bitmap: bitmap, appearance: appearance.name,
                               context: "preview, \(appearance.label)\(ownerClosed ? ", owner closed" : "")")
    }

    func testThePreviewShowsItsLastLineAndItsButtonTitlesWhole() {
        for appearance in Self.appearances {
            for closed in [false, true] {
                guard let r = renderPreview(appearance: appearance, ownerClosed: closed) else { continue }
                XCTAssertEqual(r.vc.message.textView.string, HF.tenCheckText, "\(r.context): precondition, the ten-check message is shown")

                let last = lastLineCheck(r.vc.message, host: r.host, bitmap: r.bitmap)
                XCTAssertTrue(last.ok, "\(r.context): \(last.detail)")

                for button in [r.vc.sendButton, r.vc.cancelButton] {
                    let check = titleCheck(button, title: button.title, host: r.host, bitmap: r.bitmap, appearance: r.appearance)
                    XCTAssertTrue(check.ok, "\(r.context): \(check.detail)")
                }
                XCTAssertEqual(r.vc.sendButton.title, closed ? "Start a session…" : "Send and switch ⏎", "\(r.context)")
            }
        }
    }

    func testThePreviewFitsItsWidthWithBothButtonsInsideIt() {
        for appearance in Self.appearances {
            guard let r = renderPreview(appearance: appearance, ownerClosed: false) else { continue }
            let width = AuthoredPrPreviewViewController.width
            XCTAssertEqual(r.vc.view.frame.width, width, accuracy: 0.5, r.context)
            for button in [r.vc.sendButton, r.vc.cancelButton] {
                let frame = APT.rect(of: button, in: r.host)
                XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(r.context): \(button.title) is inside the popover")
                XCTAssertLessThanOrEqual(frame.maxX, width, "\(r.context): \(button.title) is inside the popover")
            }
            let cancel = APT.rect(of: r.vc.cancelButton, in: r.host), send = APT.rect(of: r.vc.sendButton, in: r.host)
            XCTAssertLessThanOrEqual(cancel.maxX, send.minX, "\(r.context): the buttons do not overlap")
        }
    }

    // MARK: - Named mutation tests (the measurement itself must be able to fail)

    /// MUTATION: a button squeezed to a narrow fixed width. The title check must fail for it, and pass for the
    /// same button at its natural width, or the check proves nothing about the real row.
    func testMutationASqueezedButtonFailsTheTitleCheck() {
        for appearance in Self.appearances {
            func build(squeezedTo width: CGFloat?) -> (Check, NSButton)? {
                let (host, window) = APT.inkHost(size: NSSize(width: 260, height: 80), appearance: appearance.name)
                windows.append(window)
                let button = NSButton(title: "Start a session…", target: nil, action: nil)
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.font = .systemFont(ofSize: 11)
                button.lineBreakMode = .byClipping
                button.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(button)
                var constraints = [button.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
                                   button.topAnchor.constraint(equalTo: host.topAnchor, constant: 20)]
                if let width { constraints.append(button.widthAnchor.constraint(equalToConstant: width)) }
                NSLayoutConstraint.activate(constraints)
                APT.paintTitleRed(button)
                host.layoutSubtreeIfNeeded()
                guard let bitmap = APT.render(host) else { return nil }
                return (titleCheck(button, title: "Start a session…", host: host, bitmap: bitmap, appearance: appearance.name), button)
            }
            guard let natural = build(squeezedTo: nil), let squeezed = build(squeezedTo: 44) else { continue }
            XCTAssertTrue(natural.0.ok, "\(appearance.label): the check passes a button at its natural width (\(natural.0.detail))")
            XCTAssertLessThan(squeezed.1.frame.width, natural.1.frame.width, "\(appearance.label): precondition, it really is squeezed")
            XCTAssertFalse(squeezed.0.ok, "\(appearance.label): the check must FAIL a button squeezed to 44 pt, or it would not catch a clipped title")
        }
    }

    /// MUTATION: the preview's text view one line too short. The last-line check must fail for it and pass for
    /// the real one.
    func testMutationATextViewOneLineTooShortFailsTheLastLineCheck() {
        for appearance in Self.appearances {
            guard let real = renderPreview(appearance: appearance, ownerClosed: false),
                  let short = renderPreview(appearance: appearance, ownerClosed: false, shorten: true) else { continue }
            let ok = lastLineCheck(real.vc.message, host: real.host, bitmap: real.bitmap)
            XCTAssertTrue(ok.ok, "\(appearance.label): the check passes the real text view (\(ok.detail))")
            let broken = lastLineCheck(short.vc.message, host: short.host, bitmap: short.bitmap)
            XCTAssertFalse(broken.ok, "\(appearance.label): the check must FAIL a text view one line too short, or it would not catch a cut-off last line")
        }
    }

    // MARK: - The waiting pill

    private func makeItem() -> NavTabItem {
        let focus = Focus(id: "11111111-aaaa", agentTag: "cody", projectPath: "/Users/hammer/Code/nostromo", isBuiltIn: false, org: "Carefeed")
        let width = Theme.sidebarWidth
        let item = NavTabItem(focus: focus, label: "Cody in Nostromo", secondary: "main", indented: false)
        let height = Theme.navItemSubtitleHeight
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height + 20),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none   // a closing window with an animation parks a pool thread (see TestIsolationTests)
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        windows.append(window)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height + 20))
        window.contentView = host
        item.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(item)
        NSLayoutConstraint.activate([
            item.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            item.topAnchor.constraint(equalTo: host.topAnchor),
            item.widthAnchor.constraint(equalToConstant: width),
            item.heightAnchor.constraint(equalToConstant: height),
        ])
        host.layoutSubtreeIfNeeded()
        return item
    }

    /// The horizontal extent, in points, of the ink of `text` drawn alone and unclipped in the pill's font.
    private func referenceInkWidth(_ text: String, scale: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = NSSize(width: ceil(str.size().width) + 8, height: 20)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        str.draw(at: NSPoint(x: 4, y: 5))
        NSGraphicsContext.restoreGraphicsState()
        var first = Int.max, last = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.7 {
                first = min(first, x)
                last = max(last, x)
            }
        }
        return CGFloat(last - first + 1) / scale
    }

    /// Waiting PRs on one focus, through the producer and the sidebar's counting, onto a real row; the count the
    /// pill draws must be the whole number.
    func testTheWaitingPillCountIsDrawnWholeForOneNineTenAndNinetyNinePrs() throws {
        let tag = "pill-appearance"
        for count in [1, 9, 10, 99] {
            let prs = (1...count).map { HF.pr($0, owner: AuthoredPrOwner(kind: .motherJob, tag: tag, name: "Cody (nostromo)", jobId: "a1b2c3"), pill: true) }
            let snapshot = NeedsYouSnapshot(items: AuthoredPrNeedsYouProducer.items(from: APT.snapshot(prs)))
            let counts = SidebarBadgeModel.needsYouCounts(from: snapshot)
            XCTAssertEqual(counts.waiting[tag], count, "precondition: \(count) PRs are \(count) waiting items on the focus")
            XCTAssertNil(counts.blocking[tag], "and none of them blocks")

            let item = makeItem()
            item.setBadge(FocusBadge.needsYou(blocking: 0, waiting: counts.waiting[tag] ?? 0))
            (item.superview ?? item).layoutSubtreeIfNeeded()

            let pill = try XCTUnwrap(item.waitingPillFrame, "\(count): the waiting pill is shown")
            let text = try XCTUnwrap(item.waitingPillText, "\(count): it has a count")
            XCTAssertEqual(text, "\(count)", "the pill says the number of PRs")
            let rep = try XCTUnwrap(item.bitmapImageRepForCachingDisplay(in: item.bounds))
            item.cacheDisplay(in: item.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / item.bounds.width
            // Where the count sits: right of the 10 pt glyph, which is inset by max(8, (width - content) / 2), or 0 when collapsed.
            let textWidth = ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]).width)
            let inset = item.waitingPillIsCollapsed ? 0 : max(8, (pill.width - (12 + textWidth)) / 2)
            let from = pill.minX + inset + 10 + 1   // just right of the glyph
            let to = pill.maxX - 1.5                 // keep the pill's own 1 pt outline out of the measurement
            var first = Int.max, last = -1
            for py in 0..<rep.pixelsHigh {
                let fromTop = (CGFloat(py) + 0.5) / scale
                let y = item.isFlipped ? fromTop : item.bounds.height - fromTop   // bitmap rows run top-down
                guard abs(y - pill.midY) <= 4 else { continue }   // middle rows only, clear of the outline
                for px in Int(from * scale)..<Int(to * scale) {
                    guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                    // Waiting: amber text on clear (its outline is 60% alpha, under the bar).
                    if Double(c.alphaComponent) > 0.7 {
                        first = min(first, px)
                        last = max(last, px)
                    }
                }
            }
            let name = "waiting pill, \(count) PRs\(item.waitingPillIsCollapsed ? ", collapsed" : "")"
            XCTAssertGreaterThan(last, -1, "\(name): no count drawn at all")
            let drawn = CGFloat(last - first + 1) / scale
            let whole = referenceInkWidth(text, scale: scale)
            XCTAssertGreaterThanOrEqual(drawn, whole - 0.5, "\(name): the count's last glyph is clipped (ink \(drawn) pt wide, whole is \(whole))")
            XCTAssertLessThanOrEqual(CGFloat(last + 1) / scale, pill.maxX - 2, "\(name): the count's ink is within 2 pt of the pill's right edge")
        }
    }
}
