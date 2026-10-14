import XCTest
@testable import NostromoKit

/// Whether an activity row or a tool group starts open (design contract §2.2), and the view
/// mode's wire spelling (D1). First match wins: the user's explicit choice; then, for groups
/// only, a recorded stuck auto-open or a derived stuck group; then the mode.
final class FocusFoldResolverTests: XCTestCase {

    // MARK: The oracle (written independently of the implementation)

    private func expectedOpen(_ foldable: FocusFoldResolver.Foldable, mode: TranscriptViewMode,
                              explicit: Bool?, auto: Bool?, derivedStuck: Bool) -> Bool {
        if let explicit { return explicit }
        if foldable == .toolGroup, auto == true || derivedStuck { return true }
        return mode == .allActivity
    }

    private let explicits: [Bool?] = [nil, true, false]
    private let autos: [Bool?] = [nil, true, false]
    private let foldables: [FocusFoldResolver.Foldable] = [.activityRow, .toolGroup]

    // MARK: The full matrix

    func testEveryCombinationOfInputsMatchesTheRule() {
        var combinations = 0
        for foldable in foldables {
            for mode in TranscriptViewMode.allCases {
                for explicit in explicits {
                    for auto in autos {
                        for stuck in [false, true] {
                            let got = FocusFoldResolver.isOpen(foldable, mode: mode, explicit: explicit,
                                                               auto: auto, derivedStuck: stuck)
                            XCTAssertEqual(got, expectedOpen(foldable, mode: mode, explicit: explicit, auto: auto, derivedStuck: stuck),
                                           "\(foldable) \(mode) explicit \(String(describing: explicit)) auto \(String(describing: auto)) stuck \(stuck)")
                            combinations += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(combinations, 2 * 2 * 3 * 3 * 2)
    }

    // MARK: Readable examples (so the oracle is not the only statement of the rule)

    func testWithNothingSaidTheModeDecides() {
        for foldable in foldables {
            XCTAssertFalse(FocusFoldResolver.isOpen(foldable, mode: .focus, explicit: nil, auto: nil, derivedStuck: false), "\(foldable)")
            XCTAssertTrue(FocusFoldResolver.isOpen(foldable, mode: .allActivity, explicit: nil, auto: nil, derivedStuck: false), "\(foldable)")
        }
    }

    func testTheUsersChoiceBeatsTheModeInBothDirections() {
        for foldable in foldables {
            XCTAssertTrue(FocusFoldResolver.isOpen(foldable, mode: .focus, explicit: true, auto: nil, derivedStuck: false))
            XCTAssertFalse(FocusFoldResolver.isOpen(foldable, mode: .allActivity, explicit: false, auto: nil, derivedStuck: false))
        }
    }

    func testAStuckGroupOpensItselfInFocus() {
        XCTAssertTrue(FocusFoldResolver.isOpen(.toolGroup, mode: .focus, explicit: nil, auto: nil, derivedStuck: true))
        XCTAssertTrue(FocusFoldResolver.isOpen(.toolGroup, mode: .focus, explicit: nil, auto: true, derivedStuck: false))
    }

    func testAnAutoEntryThatIsFalseDoesNotCloseAnythingByItself() {
        XCTAssertFalse(FocusFoldResolver.isOpen(.toolGroup, mode: .focus, explicit: nil, auto: false, derivedStuck: false))
        XCTAssertTrue(FocusFoldResolver.isOpen(.toolGroup, mode: .allActivity, explicit: nil, auto: false, derivedStuck: false))
        XCTAssertTrue(FocusFoldResolver.isOpen(.toolGroup, mode: .focus, explicit: nil, auto: false, derivedStuck: true))
    }

    func testTheUsersClosingBeatsAStuckAutoOpen() {
        XCTAssertFalse(FocusFoldResolver.isOpen(.toolGroup, mode: .focus, explicit: false, auto: true, derivedStuck: true))
        XCTAssertFalse(FocusFoldResolver.isOpen(.toolGroup, mode: .allActivity, explicit: false, auto: true, derivedStuck: true))
    }

    func testAnActivityRowNeverAutoOpens() {
        XCTAssertFalse(FocusFoldResolver.isOpen(.activityRow, mode: .focus, explicit: nil, auto: true, derivedStuck: true))
        XCTAssertFalse(FocusFoldResolver.isOpen(.activityRow, mode: .focus, explicit: nil, auto: true, derivedStuck: false))
        XCTAssertFalse(FocusFoldResolver.isOpen(.activityRow, mode: .focus, explicit: nil, auto: nil, derivedStuck: true))
    }

    func testAnActivityRowStillFollowsTheModeAndTheUser() {
        XCTAssertTrue(FocusFoldResolver.isOpen(.activityRow, mode: .allActivity, explicit: nil, auto: true, derivedStuck: true))
        XCTAssertTrue(FocusFoldResolver.isOpen(.activityRow, mode: .focus, explicit: true, auto: nil, derivedStuck: false))
        XCTAssertFalse(FocusFoldResolver.isOpen(.activityRow, mode: .allActivity, explicit: false, auto: nil, derivedStuck: false))
    }

    // MARK: Results

    func testAResultFoldIsTheUsersChoiceElseOpenWhenTheCallFailed() {
        for explicit in explicits {
            for isError in [false, true] {
                XCTAssertEqual(FocusFoldResolver.resultOpen(explicit: explicit, isError: isError),
                               explicit ?? isError,
                               "explicit \(String(describing: explicit)) isError \(isError)")
            }
        }
    }

    func testAFailedResultOpensUnlessTheUserClosedIt() {
        XCTAssertTrue(FocusFoldResolver.resultOpen(explicit: nil, isError: true))
        XCTAssertFalse(FocusFoldResolver.resultOpen(explicit: false, isError: true))
        XCTAssertFalse(FocusFoldResolver.resultOpen(explicit: nil, isError: false))
        XCTAssertTrue(FocusFoldResolver.resultOpen(explicit: true, isError: false))
    }

    // MARK: The mode's spelling

    private struct Wrapper: Codable, Equatable { var mode: TranscriptViewMode }

    func testTheModeIsSpelledFocusAndAllActivityOnTheWire() throws {
        let encoder = JSONEncoder()
        XCTAssertEqual(String(decoding: try encoder.encode(Wrapper(mode: .focus)), as: UTF8.self), #"{"mode":"focus"}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(Wrapper(mode: .allActivity)), as: UTF8.self), #"{"mode":"allActivity"}"#)
        XCTAssertEqual(TranscriptViewMode.focus.rawValue, "focus")
        XCTAssertEqual(TranscriptViewMode.allActivity.rawValue, "allActivity")
    }

    func testTheModeDecodesFromItsSpelling() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(Wrapper.self, from: Data(#"{"mode":"focus"}"#.utf8)).mode, .focus)
        XCTAssertEqual(try decoder.decode(Wrapper.self, from: Data(#"{"mode":"allActivity"}"#.utf8)).mode, .allActivity)
    }

    func testAnUnknownModeFailsToDecode() {
        for raw in ["expanded", "Focus", "all_activity", "", "showAll"] {
            XCTAssertThrowsError(try JSONDecoder().decode(Wrapper.self, from: Data(#"{"mode":"\#(raw)"}"#.utf8)), "raw value \(raw)")
        }
    }

    func testTheModeRoundTrips() throws {
        for mode in TranscriptViewMode.allCases {
            let data = try JSONEncoder().encode(Wrapper(mode: mode))
            XCTAssertEqual(try JSONDecoder().decode(Wrapper.self, from: data).mode, mode)
        }
        XCTAssertEqual(Set(TranscriptViewMode.allCases), [.focus, .allActivity])
    }
}
