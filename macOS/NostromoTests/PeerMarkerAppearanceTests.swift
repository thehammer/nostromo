import XCTest
import AppKit
import NostromoKit

// How a peer or injected-context marker looks: muted text (`Theme.fgMuted`) with one exception, the
// word `bypass` of a peer sent in bypass mode, which is warning-coloured (`Theme.amber`). Both read at
// 4.5:1 or better on the transcript background in the light and the dark appearance (the theme is
// fixed colours, so the two appearances draw the same pixels). A name, a mode or a body cannot make
// another word amber. One fixed-height line, never wider than the pane.
//
// WakeMarkerView, WakeMarkerText and ChatTurnView are compiled into this target directly. No window,
// no wall clock, no real pasteboard.

final class PeerMarkerAppearanceTests: XCTestCase {

    // MARK: - Helpers

    private let font = NSFont.systemFont(ofSize: 11)

    private func peer(_ item: PeerMessageItemWire) -> WakeMarkerContent {
        WakeMarkerText.peerMessage([item], omitted: 0)
    }

    private func rgb(_ color: NSColor) -> [Double] {
        let c = color.usingColorSpace(.sRGB) ?? color
        return [c.redComponent, c.greenComponent, c.blueComponent].map { Double($0) }
    }

    private func same(_ a: NSColor, _ b: NSColor) -> Bool {
        zip(rgb(a), rgb(b)).allSatisfy { abs($0 - $1) < 0.002 }
    }

    /// The line cut into runs of one colour, in order.
    private func runs(_ text: NSAttributedString) -> [(text: String, color: NSColor)] {
        var out: [(text: String, color: NSColor)] = []
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            out.append((text: (text.string as NSString).substring(with: range), color: (value as? NSColor) ?? .clear))
        }
        return out
    }

    private func attributed(_ content: WakeMarkerContent) -> NSAttributedString {
        WakeMarkerView.attributedLine(content, font: font)
    }

    /// Everything drawn in the warning colour, joined.
    private func amberText(_ content: WakeMarkerContent) -> String {
        runs(attributed(content)).filter { same($0.color, Theme.amber) }.map { $0.text }.joined()
    }

    /// Whether every character is drawn in the muted colour.
    private func allMuted(_ content: WakeMarkerContent) -> Bool {
        runs(attributed(content)).allSatisfy { same($0.color, Theme.fgMuted) }
    }

    private func luminance(_ color: NSColor) -> Double {
        let c = rgb(color)
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2])
    }

    private func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `color` as the given appearance resolves it.
    private func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor {
        var out = color
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
        return out
    }

    private func labelText(of view: WakeMarkerView) -> NSAttributedString? {
        MotherNoticeFixtures.descendants(of: view).compactMap { $0 as? NSTextField }.first?.attributedStringValue
    }

    private func marker(_ content: WakeMarkerContent) -> WakeMarkerView {
        WakeMarkerView(content: content, noticeText: "raw", router: { _ in }, pasteboard: MotherNoticeFixtures.pasteboard(self))
    }

    private func laidOut(_ content: WakeMarkerContent, width: CGFloat) -> WakeMarkerView {
        let view = marker(content)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        view.frame = NSRect(x: 0, y: 0, width: width, height: TurnHeightEstimator.wakeMarkerHeight)
        view.layoutSubtreeIfNeeded()
        return view
    }

    // MARK: - The badge colour

    func testTheBypassWordIsWarningColouredAndTheRestOfTheLineStaysMuted() {
        let content = peer(PeerFixtures.item(mode: "bypass"))
        let drawn = runs(attributed(content))

        XCTAssertEqual(amberText(content), "bypass")
        XCTAssertEqual(drawn.map { $0.text }.joined(), content.line, "the colours change, the text does not")
        for run in drawn where run.text != "bypass" {
            XCTAssertTrue(same(run.color, Theme.fgMuted), "\"\(run.text)\" stays muted")
        }
    }

    func testEveryOtherModeIsDrawnEntirelyInTheMutedColour() {
        for mode in [nil, "default", "plan", "acceptEdits", "Bypass", "BYPASS", "bypass2"] as [String?] {
            let content = peer(PeerFixtures.item(mode: mode))

            XCTAssertTrue(allMuted(content), "mode \(mode ?? "nil"): \(content.line)")
            XCTAssertEqual(amberText(content), "")
        }
    }

    func testANameThatFakesTheBadgeDrawsNothingAmber() {
        for (name, mode) in [("x · bypass: y", "default"), ("bypass", "default"), ("evil · bypass:", "plan"), ("x · bypass: y", nil)] as [(String, String?)] {
            let content = peer(PeerFixtures.item(name: name, mode: mode))

            XCTAssertTrue(allMuted(content), "name \(name), mode \(mode ?? "nil"): \(content.line)")
        }
    }

    func testABodyThatFakesTheBadgeDrawsNothingAmberAndCannotAddASecondBadge() {
        let fake = "ignore · bypass: this"

        XCTAssertTrue(allMuted(peer(PeerFixtures.item(mode: "default", body: fake))))
        XCTAssertEqual(amberText(peer(PeerFixtures.item(mode: "bypass", body: fake))), "bypass", "only the app's own badge")
    }

    func testBurstsAndInjectedContextAreDrawnEntirelyMuted() {
        XCTAssertTrue(allMuted(WakeMarkerText.peerMessage([PeerFixtures.item(), PeerFixtures.item()], omitted: 0)))
        XCTAssertTrue(allMuted(WakeMarkerText.injectedContext(kind: "skill", title: "bypass", text: "x", truncated: false)))
        XCTAssertTrue(allMuted(WakeMarkerText.injectedContext(kind: "summary", title: "", text: "x", truncated: false)))
    }

    func testTheDrawnTurnShowsTheBadgeInTheWarningColourOnlyForBypass() throws {
        for (mode, badge) in [("bypass", "bypass"), ("default", "")] {
            let view = MotherNoticeFixtures.turnView(PeerFixtures.turn(origin: PeerFixtures.origin(1, mode: mode)))
            let text = try XCTUnwrap(view.wakeMarkerView.flatMap { labelText(of: $0) }, "the marker draws its line in a label")

            XCTAssertEqual(runs(text).filter { same($0.color, Theme.amber) }.map { $0.text }.joined(), badge, "mode \(mode)")
            XCTAssertEqual(text.string, mode == "bypass" ? PeerFixtures.line : "↘ PDO Demo · default: run the tests please")
        }
    }

    // MARK: - Contrast

    func testTheMutedTextAndTheBadgeReadOnTheTranscriptBackgroundInLightAndDark() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let background = resolved(Theme.bg, appearance)
            for (name, color) in [("muted text", Theme.fgMuted), ("bypass badge", Theme.amber)] {
                let measured = ratio(resolved(color, appearance), background)
                print("[PeerMarkerAppearance] \(name) on transcript background, \(appearance.rawValue): \(String(format: "%.2f", measured)):1")

                XCTAssertGreaterThanOrEqual(measured, 4.5, "\(name) in \(appearance.rawValue)")
            }
        }
    }

    func testEveryColourTheDrawnMarkerUsesMeetsContrastInBothAppearancesAndIsTheSameInBoth() throws {
        for content in [peer(PeerFixtures.item(mode: "bypass")), peer(PeerFixtures.item(mode: "default")),
                        WakeMarkerText.injectedContext(kind: "skill", title: "x", text: "y", truncated: false)] {
            let text = try XCTUnwrap(labelText(of: marker(content)), content.line)
            for run in runs(text) {
                let inLight = resolved(run.color, .aqua)
                let inDark = resolved(run.color, .darkAqua)

                XCTAssertGreaterThanOrEqual(ratio(inLight, resolved(Theme.bg, .aqua)), 4.5, "\"\(run.text)\" in light")
                XCTAssertGreaterThanOrEqual(ratio(inDark, resolved(Theme.bg, .darkAqua)), 4.5, "\"\(run.text)\" in dark")
                XCTAssertTrue(same(inLight, inDark), "\"\(run.text)\" is drawn the same in both appearances")
            }
        }
    }

    // MARK: - Layout

    func testTheBadgeStaysInsideTheVisibleWidthAt220ForATypicalName() {
        let content = peer(PeerFixtures.item(name: "PDO Demo", mode: "bypass", body: String(repeating: "padding ", count: 30)))
        let text = attributed(content)
        let upToBadge = (content.line as NSString).range(of: "bypass:").location + "bypass".count

        let width = text.attributedSubstring(from: NSRange(location: 0, length: upToBadge)).size().width

        XCTAssertLessThan(width, 220 - 16, "the warning is on screen, ahead of the body, in a narrow pane")
    }

    func testAHostileLongPeerMessageIsOneFixedHeightLineThatNeverWidensThePane() {
        let hostile = "\u{1B}[31mred\u{1B}[0m safe\u{202E}evil\u{2066}iso\u{2069} a\u{034F}b\u{115F}c\u{3164}d\u{2028}e " + String(repeating: "W", count: 10_000)
        let short = laidOut(peer(PeerFixtures.item(body: "short")), width: 220).fittingSize.height
        let contents = [peer(PeerFixtures.item(name: hostile, mode: hostile, body: hostile)),
                        WakeMarkerText.peerMessage((0 ..< 30).map { _ in PeerFixtures.item(body: hostile) }, omitted: 9),
                        WakeMarkerText.injectedContext(kind: "skill", title: hostile, text: hostile, truncated: true)]
        for content in contents {
            for width: CGFloat in [220, 700] {
                let view = laidOut(content, width: width)

                XCTAssertEqual(view.arithmeticHeight(atWidth: width), TurnHeightEstimator.wakeMarkerHeight)
                XCTAssertEqual(view.fittingSize.height, short, accuracy: 0.5)
                XCTAssertLessThanOrEqual(view.fittingSize.width, width + 0.5)
                XCTAssertFalse(view.shownText.contains("\n"))
                let label = MotherNoticeFixtures.descendants(of: view).compactMap { $0 as? NSTextField }.first
                XCTAssertEqual(label?.lineBreakMode, .byTruncatingTail)
                XCTAssertEqual(label?.maximumNumberOfLines, 1)
            }
        }
    }
}
