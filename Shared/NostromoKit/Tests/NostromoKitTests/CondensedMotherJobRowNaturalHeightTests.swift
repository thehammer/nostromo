// NostromoKit — CondensedMotherJobRowNaturalHeightTests.swift
//
// MF5: the condensed row has a fixed height and clips. These host the real two lines (origin button,
// badges, notified slot) with nothing forcing a height and assert they need no more than the row has.

#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import NostromoKit

final class CondensedMotherJobRowNaturalHeightTests: XCTestCase {

    private func origin(_ kind: MotherOriginKind, tag: String?, name: String?) -> MotherOriginDisplay {
        MotherOriginDisplay.make(
            annotation: MotherJobAnnotation(origin: MotherOriginView(
                kind: kind, focusTag: tag, nameSnapshot: name, focusName: name)),
            currentName: { $0 == tag ? name : nil })
    }

    private func model(state: String, origin: MotherOriginDisplay, badges: [String] = [],
                       mark: MotherNoticeMark? = nil) -> MotherJobRowModel {
        MotherJobRowModel(
            id: "job-1", state: state, title: "Fix the login flow", repo: "nostromo", branch: nil,
            question: "Which branch should this target?", relativeTimestamp: "4m ago",
            progressLine: "≈60% · gates 2/3 · ETA ~5-15 min", attentionBadges: badges,
            progressAccessibility: nil, showsProgressLine: true, origin: origin, prNumber: 907,
            failureReason: "gate failed", cost: "$2.14", noticeMark: mark)
    }

    func testTheRealTwoLinesFitTheFixedRowHeightWithoutClipping() throws {
        let focus = origin(.focus, tag: "claudia-1", name: "Claudia")
        let told = MotherNoticeMark.make(
            notice: MotherNoticeAnnotation(status: .told, lastState: "succeeded", atMs: 1_000),
            originName: "Claudia", now: Date(timeIntervalSince1970: 1_000))
        let models = [
            model(state: "running", origin: focus, badges: ["Needs decision", "Stalled"], mark: told),
            model(state: "awaiting", origin: focus, badges: ["Stalled"], mark: told),
            model(state: "failed", origin: origin(.you, tag: nil, name: nil)),
            model(state: "succeeded", origin: origin(.unverified, tag: "x", name: "Mallory"), mark: told),
        ]
        for m in models {
            for width in [220, 260, 340, 400, 600] as [CGFloat] {
                let content = CondensedMotherJobRowContent(model: m, onOriginTap: {})
                let host = NSHostingView(rootView: content.naturalLines(width: width))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.height, MotherRowMetrics.rowHeight + 0.5,
                                         "\(m.state) at \(width) pt needs more than the row's height, so it would clip")
            }
        }
    }
}
#endif
