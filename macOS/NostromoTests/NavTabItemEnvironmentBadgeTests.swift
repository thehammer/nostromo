import XCTest
import AppKit

// The red environment badges (PRODUCTION, STAGING, ...) on a sidebar focus row, next to the label.
//
// What a person must be able to rely on, at the sidebar's width and narrower:
//   * the layout has no unsatisfiable REQUIRED constraint: AppKit breaks one of two that conflict and logs
//     it, and the frames then show whichever it kept. This is checked directly: every required
//     constraint on the row and its subviews must hold for the frames the layout produced;
//   * the badges never sit on top of the count pill, the attention dot or the sweater dot;
//   * the badges stay inside the row, and the first (PRODUCTION) is at least partly visible;
//   * the label keeps enough width to stay recognisable (40 pt, or its whole text when shorter);
//   * badges never change the row's height.

final class NavTabItemEnvironmentBadgeTests: XCTestCase {

    private static let longName = "A very long focus label that cannot possibly fit in a narrow sidebar row"

    private struct Scenario {
        let name: String
        var label = "Cody in Nostromo"
        var environments = ["PRODUCTION", "STAGING"]
        var pill: String? = nil
        var attention = false
        var sweater: NSColor? = nil
    }

    private let widths: [CGFloat] = [Theme.sidebarWidth, 120, 100]

    private func dynamicFocus() -> Focus {
        Focus(id: "11111111-aaaa", agentTag: "cody", projectPath: "/Users/hammer/Code/nostromo", isBuiltIn: false, org: "Carefeed")
    }

    private func makeItem(_ scenario: Scenario, width: CGFloat, secondary: String? = "main") -> NavTabItem {
        let item = NavTabItem(focus: dynamicFocus(), label: scenario.label, secondary: secondary, indented: false)
        item.sweaterColor = scenario.sweater
        item.needsAttention = scenario.attention
        if let pill = scenario.pill {
            item.setBadge(FocusBadge(pill: pill, level: .attention, accessibilityLabel: "\(pill) things"))
        }
        item.environments = scenario.environments
        let height = secondary != nil ? Theme.navItemSubtitleHeight : Theme.navItemHeight
        item.frame = NSRect(x: 0, y: 0, width: width, height: height)
        item.layoutSubtreeIfNeeded()
        return item
    }

    // MARK: Walking the row

    private func allViews(in item: NavTabItem) -> [NSView] {
        func walk(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + walk($0) } }
        return [item] + walk(item)
    }

    private func badgeViews(in item: NavTabItem) -> [NSView] {
        allViews(in: item).filter { $0.accessibilityLabel()?.hasPrefix("remote shell open:") == true }
    }

    private func primaryLabel(in item: NavTabItem, text: String) -> NSTextField? {
        allViews(in: item).compactMap { $0 as? NSTextField }.first { $0.stringValue == text }
    }

    private func sweaterDotFrame(in item: NavTabItem) -> NSRect? {
        allViews(in: item).first {
            $0 !== item && !$0.isHiddenOrHasHiddenAncestor && $0.frame.size == NSSize(width: 6, height: 6)
                && $0.layer?.cornerRadius == 3
        }.map { item.convert($0.bounds, from: $0) }
    }

    /// What of `view` can be seen: its rect in the row, cut by every ancestor between it and the row that clips.
    private func visibleRect(of view: NSView, in item: NavTabItem) -> NSRect {
        var rect = item.convert(view.bounds, from: view)
        var ancestor = view.superview
        while let current = ancestor, current !== item {
            if current.layer?.masksToBounds == true {
                rect = rect.intersection(item.convert(current.bounds, from: current))
            }
            ancestor = current.superview
        }
        return rect
    }

    private func overlaps(_ a: NSRect, _ b: NSRect) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width > 0.5 && i.height > 0.5
    }

    // MARK: Generic required-constraint checker

    /// The value of `attribute` for `view` in the row's coordinates (alignment rect, as constraints use).
    private func value(of attribute: NSLayoutConstraint.Attribute, for view: NSView, in item: NavTabItem) -> CGFloat? {
        let rect: NSRect
        if view === item {
            rect = item.bounds
        } else {
            guard let superview = view.superview else { return nil }
            rect = item.convert(view.alignmentRect(forFrame: view.frame), from: superview)
        }
        switch attribute {
        case .leading, .left: return rect.minX
        case .trailing, .right: return rect.maxX
        case .top: return item.isFlipped ? rect.minY : rect.maxY
        case .bottom: return item.isFlipped ? rect.maxY : rect.minY
        case .width: return rect.width
        case .height: return rect.height
        case .centerX: return rect.midX
        case .centerY: return rect.midY
        default: return nil
        }
    }

    /// Descriptions of every required, active constraint under `item` that its frames do not satisfy.
    private func violatedRequiredConstraints(in item: NavTabItem) -> [String] {
        let tolerance: CGFloat = 0.51
        var seen = Set<ObjectIdentifier>()
        var violations: [String] = []
        for view in allViews(in: item) {
            for constraint in view.constraints {
                guard seen.insert(ObjectIdentifier(constraint)).inserted,
                      constraint.isActive, constraint.priority == .required,
                      let first = constraint.firstItem as? NSView,
                      let lhs = value(of: constraint.firstAttribute, for: first, in: item) else { continue }
                var rhs: CGFloat
                if let secondObject = constraint.secondItem {
                    guard let second = secondObject as? NSView,
                          let secondValue = value(of: constraint.secondAttribute, for: second, in: item) else { continue }
                    rhs = constraint.multiplier * secondValue + constraint.constant
                } else {
                    guard constraint.firstAttribute == .width || constraint.firstAttribute == .height else { continue }
                    rhs = constraint.constant
                }
                let holds: Bool
                switch constraint.relation {
                case .equal: holds = abs(lhs - rhs) <= tolerance
                case .lessThanOrEqual: holds = lhs <= rhs + tolerance
                case .greaterThanOrEqual: holds = lhs >= rhs - tolerance
                @unknown default: holds = true
                }
                if !holds { violations.append("\(constraint) (lhs \(lhs), rhs \(rhs))") }
            }
        }
        return violations
    }

    // MARK: The assertions every layout must satisfy

    private func assertSound(_ item: NavTabItem, _ scenario: Scenario, width: CGFloat,
                             file: StaticString = #filePath, line: UInt = #line) {
        let context = "\(scenario.name) at \(Int(width)) pt"

        // (i) No unsatisfiable required constraint.
        XCTAssertEqual(violatedRequiredConstraints(in: item), [], "required constraints broken: \(context)", file: file, line: line)

        let badges = badgeViews(in: item)
        XCTAssertEqual(badges.count, scenario.environments.count, "a badge per environment: \(context)", file: file, line: line)

        // (ii) Badges stay inside the row and off the pill and the dots.
        let rowBounds = item.bounds.insetBy(dx: -0.5, dy: -0.5)
        var others: [(String, NSRect)] = []
        if let pill = item.pillFrame { others.append(("the count pill", pill)) }
        if let dot = item.attentionDotFrame { others.append(("the attention dot", dot)) }
        if let sweater = sweaterDotFrame(in: item) { others.append(("the sweater dot", sweater)) }
        others.append(("the label", item.labelFrame))
        for badge in badges where !badge.isHiddenOrHasHiddenAncestor {
            let visible = visibleRect(of: badge, in: item)
            guard !visible.isNull, visible.width > 0 else { continue }
            XCTAssertTrue(rowBounds.contains(visible), "a badge pokes out of the row (\(visible)): \(context)", file: file, line: line)
            for (name, frame) in others {
                XCTAssertFalse(overlaps(visible, frame), "a badge (\(visible)) overlaps \(name) (\(frame)): \(context)", file: file, line: line)
            }
        }

        // (iii) The label keeps its identity.
        if let label = primaryLabel(in: item, text: scenario.label) {
            let wanted = min(label.intrinsicContentSize.width, 40)
            XCTAssertGreaterThanOrEqual(item.labelFrame.width, wanted - 0.5,
                                        "the label is squeezed below \(wanted) pt: \(context)", file: file, line: line)
        } else {
            XCTFail("label \(scenario.label) not found: \(context)", file: file, line: line)
        }

        // (iv) PRODUCTION, the first badge, is at least partly visible.
        if let first = badges.first(where: { $0.accessibilityLabel() == "remote shell open: PRODUCTION" }) {
            XCTAssertFalse(first.isHiddenOrHasHiddenAncestor, "PRODUCTION badge is hidden: \(context)", file: file, line: line)
            XCTAssertGreaterThan(visibleRect(of: first, in: item).width, 4,
                                 "PRODUCTION badge is not visible: \(context)", file: file, line: line)
        } else if scenario.environments.first == "PRODUCTION" {
            XCTFail("no PRODUCTION badge: \(context)", file: file, line: line)
        }
    }

    private func check(_ scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) {
        for width in widths {
            for secondary in [Optional("main"), nil] {
                assertSound(makeItem(scenario, width: width, secondary: secondary), scenario, width: width, file: file, line: line)
            }
        }
    }

    // MARK: Tests

    func testTwoBadgesAlone() {
        check(Scenario(name: "PRODUCTION + STAGING"))
    }

    func testOneBadgeAlone() {
        check(Scenario(name: "PRODUCTION only", environments: ["PRODUCTION"]))
    }

    func testBadgesWithACountPill() {
        check(Scenario(name: "badges + pill", pill: "12"))
    }

    func testBadgesWithTheAttentionDot() {
        check(Scenario(name: "badges + attention dot", attention: true))
    }

    func testBadgesWithPillAttentionDotAndSweater() {
        check(Scenario(name: "badges + pill + attention + sweater", pill: "3", attention: true, sweater: .systemOrange))
    }

    func testBadgesWithASweaterDot() {
        check(Scenario(name: "badges + sweater", sweater: .systemOrange))
    }

    func testBadgesWithALongLabel() {
        check(Scenario(name: "long label", label: Self.longName))
    }

    func testBadgesWithALongLabelAndEverythingElse() {
        check(Scenario(name: "long label + pill + attention + sweater", label: Self.longName, pill: "99",
                       attention: true, sweater: .systemOrange))
    }

    func testThreeBadges() {
        check(Scenario(name: "three badges", environments: ["PRODUCTION", "CANADA", "STAGING"], pill: "2", attention: true))
    }

    func testTheBadgeIsLabelledForAccessibility() {
        let item = makeItem(Scenario(name: "a11y"), width: Theme.sidebarWidth)
        let badge = badgeViews(in: item).first { $0.accessibilityLabel() == "remote shell open: PRODUCTION" }
        XCTAssertNotNil(badge)
        XCTAssertEqual(item.environmentBadgeTexts, ["PRODUCTION", "STAGING"])
    }

    // MARK: Row height and restoring

    func testBadgesNeverChangeTheRowHeightOrTheLabelsPlace() throws {
        for secondary in [Optional("main"), nil] {
            for width in widths {
                var plain = Scenario(name: "no badges", pill: "3", attention: true)
                plain.environments = []
                let with = Scenario(name: "badges", pill: "3", attention: true)
                let a = makeItem(plain, width: width, secondary: secondary)
                let b = makeItem(with, width: width, secondary: secondary)
                XCTAssertEqual(b.frame.height, a.frame.height)
                XCTAssertEqual(b.fittingSize.height, a.fittingSize.height, "\(Int(width)) pt")
                XCTAssertEqual(b.labelFrame.origin.y, a.labelFrame.origin.y, accuracy: 0.5)
                XCTAssertEqual(b.labelFrame.height, a.labelFrame.height, accuracy: 0.5)
            }
        }
    }

    func testRemovingTheBadgesGivesTheLabelItsFullWidthBack() {
        let withLabel = Scenario(name: "long label", label: Self.longName, environments: [])
        let never = makeItem(withLabel, width: Theme.sidebarWidth)
        let item = makeItem(Scenario(name: "long label", label: Self.longName), width: Theme.sidebarWidth)
        item.environments = []
        item.layoutSubtreeIfNeeded()
        XCTAssertEqual(item.labelFrame.width, never.labelFrame.width, accuracy: 0.5)
        XCTAssertTrue(badgeViews(in: item).isEmpty)
    }

    func testChangingTheEnvironmentsRelaysOutWithoutBreakingAnything() {
        let scenario = Scenario(name: "changed environments", pill: "5", attention: true)
        let item = makeItem(scenario, width: 120)
        item.environments = ["PRODUCTION"]
        item.layoutSubtreeIfNeeded()
        XCTAssertEqual(violatedRequiredConstraints(in: item), [])
        item.environments = ["PRODUCTION", "CANADA", "STAGING"]
        item.layoutSubtreeIfNeeded()
        XCTAssertEqual(violatedRequiredConstraints(in: item), [])
        item.needsAttention = false
        item.layoutSubtreeIfNeeded()
        XCTAssertEqual(violatedRequiredConstraints(in: item), [])
    }
}
