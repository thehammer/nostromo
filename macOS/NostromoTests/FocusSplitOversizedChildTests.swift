import XCTest
import AppKit
import NostromoKit

// MV-3: a general guard. NO child of a focus's split may change the size of a window that cannot
// grow, however much height it asks for. The Mother job detail was the instance that did (its content
// demanded more height than the window had, so MainLayout became taller than the window); this is the
// same failure with the detail taken out of the picture: a view that asks for 5,000 pt of height, shaped
// the several ways a view asks for height, placed in the regions of the real Mother focus.
//
// Shapes of the demand:
//   - intrinsic:      an intrinsic content height of 5,000 at the default compression resistance
//   - intrinsic-req:  the same with vertical compression resistance .required
//   - required-const: a view holding a subview with a REQUIRED height constraint of 5,000
//   - stack-const:    an NSStackView holding a subview with a required height constraint of 5,000
//   - label-stack:    an NSStackView of 400 one-line labels (tall because of how many there are)
//
// Placements (each shape in each): as the active tab of the Mother pane's TabRegionView; as an inactive
// (hidden) tab, then selected; and pinned to all four edges of the other region of the Mother split (the REPL).
final class FocusSplitOversizedChildTests: XCTestCase {

    // MARK: - Oversized views

    private static let demand: CGFloat = 5_000

    private final class IntrinsicTall: NSView {
        let height: CGFloat
        init(height: CGFloat, compression: NSLayoutConstraint.Priority) {
            self.height = height
            super.init(frame: .zero)
            setContentCompressionResistancePriority(compression, for: .vertical)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }
    }

    private enum Shape: String, CaseIterable {
        case intrinsic = "intrinsic"
        case intrinsicRequired = "intrinsic-req"
        case requiredConstraint = "required-const"
        case stackConstraint = "stack-const"
        case labelStack = "label-stack"
    }

    private func makeTall(_ shape: Shape) -> NSView {
        switch shape {
        case .intrinsic:
            return IntrinsicTall(height: Self.demand, compression: .defaultHigh)
        case .intrinsicRequired:
            return IntrinsicTall(height: Self.demand, compression: .required)
        case .requiredConstraint:
            let outer = NSView()
            let inner = NSView()
            inner.translatesAutoresizingMaskIntoConstraints = false
            outer.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.topAnchor.constraint(equalTo: outer.topAnchor),
                inner.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
                inner.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
                inner.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
                inner.heightAnchor.constraint(equalToConstant: Self.demand),   // required
            ])
            return outer
        case .stackConstraint:
            let stack = NSStackView()
            stack.orientation = .vertical
            let inner = NSView()
            inner.translatesAutoresizingMaskIntoConstraints = false
            inner.heightAnchor.constraint(equalToConstant: Self.demand).isActive = true   // required
            stack.addArrangedSubview(inner)
            return stack
        case .labelStack:
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            for n in 0..<400 {
                stack.addArrangedSubview(NSTextField(labelWithString: "ROW-\(n) one line of text"))
            }
            return stack
        }
    }

    // MARK: - Placements

    func testAnOversizedActiveTabOfTheMotherPaneCannotChangeTheWindow() throws {
        var index = 940
        for shape in Shape.allCases {
            let w = try MD.makeWindow(self, index: index)
            index += 1
            MD.assertFits(w, "control: before the oversized tab, \(shape.rawValue)")

            let tall = makeTall(shape)
            let paneId = "oversized:\(shape.rawValue)"
            w.pane.addTab(TabRegionView.Tab(paneId: paneId, label: "tall", view: tall))   // activates it
            MD.pump(w.window)

            XCTAssertTrue(w.pane.hasTab(paneId) && tall.isDescendant(of: w.layout), "precondition: the oversized tab is in the window")
            XCTAssertEqual(w.pane.activePaneId, paneId, "precondition: the oversized tab is frontmost")
            MD.assertFits(w, "active oversized tab, \(shape.rawValue)")
            w.close()
        }
    }

    func testAnOversizedInactiveTabOfTheMotherPaneCannotChangeTheWindowEitherBeforeOrAfterItIsSelected() throws {
        var index = 945
        for shape in Shape.allCases {
            let w = try MD.makeWindow(self, index: index)
            index += 1

            let tall = makeTall(shape)
            let paneId = "oversized:\(shape.rawValue)"
            let overview = w.pane.activePaneId
            w.pane.addTab(TabRegionView.Tab(paneId: paneId, label: "tall", view: tall), activate: false)
            MD.pump(w.window)

            XCTAssertEqual(w.pane.activePaneId, overview, "precondition: the oversized tab is not frontmost")
            MD.assertFits(w, "inactive oversized tab, \(shape.rawValue)")

            w.pane.selectTab(paneId)
            MD.pump(w.window)
            MD.assertFits(w, "oversized tab just selected, \(shape.rawValue)")

            w.pane.selectTab(overview)
            MD.pump(w.window)
            MD.assertFits(w, "oversized tab deselected again, \(shape.rawValue)")
            w.close()
        }
    }

    func testAnOversizedChildOfTheOtherRegionOfTheMotherSplitCannotChangeTheWindow() throws {
        var index = 950
        for shape in Shape.allCases {
            let w = try MD.makeWindow(self, index: index)
            index += 1
            let repl = try XCTUnwrap(MD.allSubviews(w.layout).compactMap { $0 as? ReplView }.first,
                                     "the Mother focus has no REPL region")

            let tall = makeTall(shape)
            tall.translatesAutoresizingMaskIntoConstraints = false
            repl.addSubview(tall)
            NSLayoutConstraint.activate([
                tall.topAnchor.constraint(equalTo: repl.topAnchor),
                tall.bottomAnchor.constraint(equalTo: repl.bottomAnchor),
                tall.leadingAnchor.constraint(equalTo: repl.leadingAnchor),
                tall.trailingAnchor.constraint(equalTo: repl.trailingAnchor),
            ])
            MD.pump(w.window)

            XCTAssertTrue(tall.isDescendant(of: w.layout), "precondition: the oversized child is in the window")
            MD.assertFits(w, "oversized child pinned inside the REPL region, \(shape.rawValue)")
            w.close()
        }
    }

    /// Oversized content arriving later, on top of a job detail that is already showing.
    func testAnOversizedTabAddedNextToAShowingJobDetailCannotChangeTheWindow() throws {
        let rig = try MD.makeRig(self, long: [], index: 955)
        MD.assertFits(rig, "control: short job detail")

        for (n, shape) in Shape.allCases.enumerated() {
            let paneId = "oversized-\(n):\(shape.rawValue)"
            rig.w.pane.addTab(TabRegionView.Tab(paneId: paneId, label: "tall", view: makeTall(shape)))
            MD.pump(rig.window)
            MD.assertFits(rig.w, detail: rig.detail, "oversized tab \(shape.rawValue) added beside the job detail")

            rig.w.pane.selectTab("mother_job:\(rig.jobId)")
            MD.pump(rig.window)
            MD.assertFits(rig, "back on the job detail with \(shape.rawValue) tab open")
        }
    }
}
