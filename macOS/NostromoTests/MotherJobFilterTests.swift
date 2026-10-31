import XCTest
import NostromoKit

// MotherJobFilter, MotherJob and MotherOriginDisplay are compiled into / linked with this target (logic test).
//
// MF3: the Mother list's `From:` pop-up. `MotherJobFilter.apply` takes the jobs, the daemon's annotations
// (who queued each job), a selection and the app's current focus names, and returns the matching jobs
// grouped by state, `matched` of `total`, and the pop-up's entries.
//
// Entries, in order: All; open focuses A-Z by current name; closed focuses (`<name> (closed)`);
// unverified claims (`<name>?`); You; Unknown origin. An entry appears only if a job matches it, except
// the selected one, which always appears so the control never shows something the pop-up cannot.

final class MotherJobFilterTests: XCTestCase {

    // MARK: - Helpers

    private func job(_ id: String, _ state: String = "running", started: TimeInterval? = nil) -> MotherJob {
        MotherJob(id: id, state: state, repo: "r", isolation: "worktree", title: "title-\(id)",
                  createdAt: Date(timeIntervalSince1970: 1_000),
                  startedAt: started.map { Date(timeIntervalSince1970: $0) },
                  finishedAt: nil, planPath: nil, question: nil, pausedReason: nil,
                  adherenceStatus: nil, currentTier: nil)
    }

    private func note(_ kind: MotherOriginKind, tag: String? = nil, snapshot: String? = nil,
                      focusName: String? = nil) -> MotherJobAnnotation {
        MotherJobAnnotation(origin: MotherOriginView(kind: kind, focusTag: tag, nameSnapshot: snapshot, focusName: focusName))
    }

    private func names(_ open: [String: String]) -> (String) -> String? { { open[$0] } }

    private let nothingOpen: (String) -> String? = { _ in nil }

    private func apply(_ jobs: [MotherJob], _ annotations: [String: MotherJobAnnotation],
                       _ selection: MotherOriginSelection = .all,
                       open: [String: String] = [:]) -> MotherJobFilterResult {
        MotherJobFilter.apply(jobs: jobs, annotations: annotations, selection: selection, currentName: names(open))
    }

    private func ids(_ result: MotherJobFilterResult) -> Set<String> {
        Set(result.groups.flatMap { $0.jobs.map(\.id) })
    }

    // MARK: - Entry order

    func testEntriesAreAllThenOpenFocusesThenClosedThenUnverifiedThenYouThenUnknown() {
        let jobs = ["u", "y", "v", "c", "o", "k"].map { job($0) }
        let annotations: [String: MotherJobAnnotation] = [
            "o": note(.focus, tag: "open-1", snapshot: "Open one"),
            "c": note(.focus, tag: "gone-1", snapshot: "Gone one"),
            "v": note(.unverified, tag: "claim-1", snapshot: "Claimed"),
            "y": note(.you),
            "u": note(.unknown),
            // "k" has no annotation at all
        ]
        let r = apply(jobs, annotations, open: ["open-1": "Open one"])
        XCTAssertEqual(r.entries.map(\.title),
                       ["All", "Open one", "Gone one (closed)", "Claimed?", "You", "Unknown origin"])
        XCTAssertEqual(r.entries.map(\.selection),
                       [.all, .focus(tag: "open-1"), .focus(tag: "gone-1"), .unverified(tag: "claim-1"), .you, .unknown])
    }

    func testOpenFocusesAreSortedAToZByCurrentNameIgnoringCase() {
        let jobs = [job("1"), job("2"), job("3")]
        let annotations = [
            "1": note(.focus, tag: "t-charlie"),
            "2": note(.focus, tag: "t-alpha"),
            "3": note(.focus, tag: "t-bravo"),
        ]
        let r = apply(jobs, annotations, open: ["t-charlie": "Charlie", "t-alpha": "alpha", "t-bravo": "Bravo"])
        XCTAssertEqual(r.entries.map(\.title), ["All", "alpha", "Bravo", "Charlie"])
    }

    func testTheSortUsesTheCurrentNameNotTheNameTheJobWasQueuedUnder() {
        let jobs = [job("1"), job("2")]
        let annotations = [
            "1": note(.focus, tag: "t1", snapshot: "Aardvark"),   // renamed to Zebra since
            "2": note(.focus, tag: "t2", snapshot: "Zulu"),       // renamed to Bee since
        ]
        let r = apply(jobs, annotations, open: ["t1": "Zebra", "t2": "Bee"])
        XCTAssertEqual(r.entries.map(\.title), ["All", "Bee", "Zebra"])
    }

    func testClosedFocusesAndUnverifiedClaimsAreEachSortedAndAfterTheOpenOnes() {
        let jobs = ["a", "b", "c", "d", "e"].map { job($0) }
        let annotations = [
            "a": note(.focus, tag: "closed-z", focusName: "Zed"),
            "b": note(.focus, tag: "closed-m", focusName: "Mid"),
            "c": note(.unverified, tag: "claim-b", snapshot: "Beta"),
            "d": note(.unverified, tag: "claim-a", snapshot: "Alpha"),
            "e": note(.focus, tag: "open-q", snapshot: "Quill"),
        ]
        let r = apply(jobs, annotations, open: ["open-q": "Quill"])
        XCTAssertEqual(r.entries.map(\.title),
                       ["All", "Quill", "Mid (closed)", "Zed (closed)", "Alpha?", "Beta?"])
    }

    // MARK: - Entries appear only when a job matches

    func testAnEntryIsOmittedWhenNoJobMatchesIt() {
        let r = apply([job("1")], ["1": note(.you)])
        XCTAssertEqual(r.entries.map(\.title), ["All", "You"], "no focus, no unverified, no unknown jobs: no such entries")
    }

    func testNoJobsGivesOnlyAll() {
        let r = apply([], [:])
        XCTAssertEqual(r.entries.map(\.title), ["All"])
        XCTAssertEqual(r.entries.first?.count, 0)
        XCTAssertEqual(r.matched, 0)
        XCTAssertEqual(r.total, 0)
        XCTAssertTrue(r.groups.isEmpty)
    }

    func testAFocusWithNoJobsHasNoEntry() {
        // A focus that is open in the app but queued nothing is not offered.
        let r = apply([job("1")], ["1": note(.you)], open: ["t-idle": "Idle focus"])
        XCTAssertFalse(r.entries.contains { $0.title == "Idle focus" })
    }

    func testTheSelectedEntryIsKeptEvenWhenNoJobMatchesIt() {
        let r = apply([job("1")], ["1": note(.you)], .focus(tag: "t-none"), open: ["t-none": "Quiet focus"])
        XCTAssertTrue(r.entries.contains { $0.selection == .focus(tag: "t-none") }, "the control must not show a value the pop-up lacks")
        XCTAssertEqual(r.entries.first { $0.selection == .focus(tag: "t-none") }?.count, 0)
    }

    // MARK: - Counts, matched, total

    func testEntryCountsAreTheJobsThatMatchEach() {
        let jobs = ["1", "2", "3", "4", "5", "6"].map { job($0) }
        let annotations = [
            "1": note(.focus, tag: "t-a"), "2": note(.focus, tag: "t-a"), "3": note(.focus, tag: "t-b"),
            "4": note(.you), "5": note(.unknown),
            // 6: no annotation, so unknown too
        ]
        let r = apply(jobs, annotations, open: ["t-a": "A", "t-b": "B"])
        func count(_ s: MotherOriginSelection) -> Int? { r.entries.first { $0.selection == s }?.count }
        XCTAssertEqual(count(.all), 6)
        XCTAssertEqual(count(.focus(tag: "t-a")), 2)
        XCTAssertEqual(count(.focus(tag: "t-b")), 1)
        XCTAssertEqual(count(.you), 1)
        XCTAssertEqual(count(.unknown), 2, "an unannotated job counts as unknown")
    }

    func testAllMatchesEveryJob() {
        let jobs = [job("1"), job("2"), job("3")]
        let r = apply(jobs, ["1": note(.you)])
        XCTAssertEqual(r.matched, 3)
        XCTAssertEqual(r.total, 3)
        XCTAssertEqual(ids(r), ["1", "2", "3"])
        XCTAssertEqual(r.selectionTitle, "All")
    }

    func testAFocusSelectionShowsOnlyThatFocusesJobsAndSaysHowManyOfHowMany() {
        let jobs = [job("1", "running"), job("2", "queued"), job("3", "running"), job("4", "failed")]
        let annotations = [
            "1": note(.focus, tag: "t-a"), "2": note(.focus, tag: "t-b"),
            "3": note(.focus, tag: "t-a"), "4": note(.you),
        ]
        let r = apply(jobs, annotations, .focus(tag: "t-a"), open: ["t-a": "A", "t-b": "B"])
        XCTAssertEqual(r.matched, 2)
        XCTAssertEqual(r.total, 4)
        XCTAssertEqual(ids(r), ["1", "3"])
        XCTAssertEqual(r.groups.map(\.state), ["running"], "only groups with a matching job remain")
        XCTAssertEqual(r.selectionTitle, "A")
    }

    func testTheFilteredGroupsKeepTheListsOrdering() {
        let jobs = [job("old", "running", started: 100), job("new", "running", started: 200), job("other", "running", started: 300)]
        let annotations = ["old": note(.you), "new": note(.you), "other": note(.unknown)]
        let r = apply(jobs, annotations, .you)
        XCTAssertEqual(r.groups.first?.jobs.map(\.id), ["new", "old"], "newest first, as in the unfiltered list")
    }

    func testEachSelectionKindMatchesOnlyItsOwnJobs() {
        let jobs = ["f", "v", "y", "u"].map { job($0) }
        let annotations = [
            "f": note(.focus, tag: "t"), "v": note(.unverified, tag: "c", snapshot: "C"),
            "y": note(.you), "u": note(.unknown),
        ]
        let open = ["t": "T"]
        XCTAssertEqual(ids(apply(jobs, annotations, .focus(tag: "t"), open: open)), ["f"])
        XCTAssertEqual(ids(apply(jobs, annotations, .unverified(tag: "c"), open: open)), ["v"])
        XCTAssertEqual(ids(apply(jobs, annotations, .you, open: open)), ["y"])
        XCTAssertEqual(ids(apply(jobs, annotations, .unknown, open: open)), ["u"])
    }

    func testAnUnverifiedClaimDoesNotMatchTheVerifiedFocusWithTheSameTag() {
        let jobs = [job("real"), job("claim")]
        let annotations = [
            "real": note(.focus, tag: "t1"),
            "claim": note(.unverified, tag: "t1", snapshot: "Claimed"),
        ]
        let open = ["t1": "Real focus"]
        XCTAssertEqual(ids(apply(jobs, annotations, .focus(tag: "t1"), open: open)), ["real"])
        XCTAssertEqual(ids(apply(jobs, annotations, .unverified(tag: "t1"), open: open)), ["claim"])
    }

    func testAKindThisBuildDoesNotKnowIsFilteredAsUnknown() {
        let r = apply([job("1")], ["1": note(.other("robot"), tag: "t")], .unknown)
        XCTAssertEqual(r.matched, 1)
        XCTAssertEqual(r.entries.map(\.title), ["All", "Unknown origin"])
    }

    // MARK: - No match

    func testASelectionWithNoMatchesYieldsZeroMatchedAndATitleForTheMessage() {
        let r = apply([job("1"), job("2")], ["1": note(.you), "2": note(.you)], .focus(tag: "t-quiet"), open: ["t-quiet": "Quiet focus"])
        XCTAssertEqual(r.matched, 0)
        XCTAssertEqual(r.total, 2)
        XCTAssertTrue(r.groups.isEmpty)
        XCTAssertEqual(r.selectionTitle, "Quiet focus")
    }

    func testASelectedFocusThatIsNoLongerOpenIsTitledByItsTagAndClosed() {
        let r = apply([job("1")], ["1": note(.you)], .focus(tag: "claudia-DEADBEEF"))
        XCTAssertEqual(r.matched, 0)
        XCTAssertEqual(r.selectionTitle, "claudia-DEADBEEF (closed)")
        XCTAssertTrue(r.entries.contains { $0.title == "claudia-DEADBEEF (closed)" })
    }

    func testASelectedFocusWithJobsThatHasSinceClosedIsTitledByTheNameItWasQueuedUnder() {
        let jobs = [job("1")]
        let r = apply(jobs, ["1": note(.focus, tag: "t1", snapshot: "Fix login", focusName: "Fix the login flow")], .focus(tag: "t1"))
        XCTAssertEqual(r.matched, 1)
        XCTAssertEqual(r.selectionTitle, "Fix the login flow (closed)")
    }

    func testASelectedUnverifiedClaimWithNoJobsIsTitledByItsTag() {
        let r = apply([job("1")], ["1": note(.you)], .unverified(tag: "claim-9"))
        XCTAssertEqual(r.matched, 0)
        XCTAssertEqual(r.selectionTitle, "claim-9?")
    }

    func testSelectingYouOrUnknownWithNoMatchesStillHasATitle() {
        let jobs = [job("1")]
        XCTAssertEqual(apply(jobs, ["1": note(.unknown)], .you).selectionTitle, "You")
        XCTAssertEqual(apply(jobs, ["1": note(.you)], .unknown).selectionTitle, "Unknown origin")
    }

    // MARK: - Missing annotations

    func testAJobWithNoAnnotationIsFromAnUnknownOrigin() {
        XCTAssertEqual(MotherJobFilter.selection(for: nil), .unknown)
        let r = apply([job("bare")], [:], .unknown)
        XCTAssertEqual(r.matched, 1)
        XCTAssertEqual(ids(r), ["bare"])
    }

    func testAnAnnotationWithNoOriginAndAFocusWithNoTagAreUnknown() {
        XCTAssertEqual(MotherJobFilter.selection(for: MotherJobAnnotation(origin: nil, notify: "quiet")), .unknown)
        XCTAssertEqual(MotherJobFilter.selection(for: note(.focus, tag: nil)), .unknown)
    }

    func testAnAnnotationForAJobNotInTheListChangesNothing() {
        let r = apply([job("1")], ["1": note(.you), "ghost": note(.focus, tag: "t-ghost")], open: ["t-ghost": "Ghost"])
        XCTAssertEqual(r.entries.map(\.title), ["All", "You"])
        XCTAssertEqual(r.total, 1)
    }

    // MARK: - Renames

    func testARenameChangesTheEntryTitleAndNotTheSelection() {
        let jobs = [job("1")]
        let annotations = ["1": note(.focus, tag: "t1", snapshot: "Before")]
        let before = apply(jobs, annotations, open: ["t1": "Before"])
        let after = apply(jobs, annotations, open: ["t1": "After"])
        XCTAssertEqual(before.entries.map(\.title), ["All", "Before"])
        XCTAssertEqual(after.entries.map(\.title), ["All", "After"])
        XCTAssertEqual(before.entries.last?.selection, after.entries.last?.selection, "the selection is the tag, so a rename keeps it")
    }

    func testAClosedFocusMovesFromTheOpenGroupToTheClosedGroupWhenItsTabCloses() {
        let jobs = [job("1"), job("2")]
        let annotations = [
            "1": note(.focus, tag: "t-a", snapshot: "Alpha"),
            "2": note(.focus, tag: "t-b", snapshot: "Bravo"),
        ]
        let bothOpen = apply(jobs, annotations, open: ["t-a": "Alpha", "t-b": "Bravo"])
        XCTAssertEqual(bothOpen.entries.map(\.title), ["All", "Alpha", "Bravo"])
        let alphaClosed = apply(jobs, annotations, open: ["t-b": "Bravo"])
        XCTAssertEqual(alphaClosed.entries.map(\.title), ["All", "Bravo", "Alpha (closed)"])
    }

    // MARK: - Hostile names

    private let hostile = "safe\u{202E}evil\u{2066}iso\u{200E}\u{1B}[31mred\u{1B}[0m\u{0}nul\u{3164}fill\u{E0041}tag\nline\u{2028}sep\u{2029}end"

    private func assertNothingForbidden(_ s: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let bad = v <= 0x1F || v == 0x7F || (0x80...0x9F).contains(v) || v == 0x200E || v == 0x200F
                || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || (0xE0000...0xE007F).contains(v)
                || v == 0x034F || v == 0x115F || v == 0x1160 || v == 0x17B4 || v == 0x17B5 || v == 0x2800
                || v == 0x3164 || v == 0xFFA0 || v == 0x2028 || v == 0x2029
            XCTAssertFalse(bad, "\(message): U+\(String(v, radix: 16, uppercase: true)) survived in \(s.prefix(60))", file: file, line: line)
        }
    }

    func testHostileNamesAreSanitisedInEveryEntryTitleAndTheSelectionTitle() {
        let jobs = ["o", "c", "v"].map { job($0) }
        let annotations = [
            "o": note(.focus, tag: "t-open", snapshot: hostile),
            "c": note(.focus, tag: "t-closed", snapshot: hostile, focusName: hostile),
            "v": note(.unverified, tag: hostile, snapshot: hostile),
        ]
        for selection in [MotherOriginSelection.all, .focus(tag: "t-open"), .focus(tag: "t-closed"), .unverified(tag: hostile)] {
            let r = apply(jobs, annotations, selection, open: ["t-open": hostile])
            for entry in r.entries { assertNothingForbidden(entry.title, "entry title") }
            assertNothingForbidden(r.selectionTitle, "selection title")
        }
    }

    func testAHugeNameDoesNotMakeAHugeEntryTitle() {
        let huge = "echo " + String(repeating: "x", count: 9_995)
        let jobs = [job("o"), job("c")]
        let annotations = [
            "o": note(.focus, tag: "t-open"),
            "c": note(.focus, tag: "t-closed", focusName: huge),
        ]
        let r = apply(jobs, annotations, open: ["t-open": huge])
        for entry in r.entries {
            XCTAssertLessThanOrEqual(entry.title.count, 40 + " (closed)".count, "title is \(entry.title.count) long")
        }
        XCTAssertLessThanOrEqual(r.selectionTitle.count, 40 + " (closed)".count)
    }

    func testASelectedFocusWithAHostileTagAndNoJobsIsSanitisedAndCapped() {
        let tag = hostile + String(repeating: "x", count: 5_000)
        let r = apply([job("1")], ["1": note(.you)], .focus(tag: tag))
        assertNothingForbidden(r.selectionTitle, "selection title")
        XCTAssertLessThanOrEqual(r.selectionTitle.count, 40 + " (closed)".count)
        XCTAssertTrue(r.selectionTitle.hasSuffix("(closed)"))
    }

    // MARK: - Empty states (MF3-4, MF3-6)

    func testNoJobsAtAllShowsTheEmptyListText() {
        XCTAssertEqual(apply([], [:]).emptyState,
                       .noJobs(text: "No Mother jobs. Agents queue them with mother_enqueue_job; jobs show who queued them here."))
    }

    func testNoJobsAtAllWinsOverAFilterThatWasSet() {
        XCTAssertEqual(apply([], [:], .you).emptyState, .noJobs(text: MotherJobListEmptyState.noJobsText))
    }

    func testAFilterWithNoMatchesNamesWhoseJobsThereAreNone() {
        let r = apply([job("a")], ["a": note(.you)], .focus(tag: "t1"), open: ["t1": "Fix login"])
        XCTAssertEqual(r.emptyState, .noMatch(text: "No jobs from Fix login."))
        XCTAssertEqual(r.matched, 0)
        XCTAssertEqual(r.total, 1)
    }

    func testAFilterOnAClosedFocusSaysSo() {
        let r = apply([job("a")], ["a": note(.you)], .focus(tag: "gone"))
        XCTAssertEqual(r.emptyState, .noMatch(text: "No jobs from gone (closed)."))
    }

    func testAListWithMatchesHasNoEmptyState() {
        XCTAssertEqual(apply([job("a")], ["a": note(.you)], .you).emptyState, .none)
        XCTAssertEqual(apply([job("a")], [:]).emptyState, .none)
    }

    func testClearingTheFilterAfterNoMatchRestoresEveryJob() {
        let jobs = [job("a"), job("b")]
        let annotations = ["a": note(.you), "b": note(.you)]
        XCTAssertEqual(apply(jobs, annotations, .focus(tag: "t")).emptyState, .noMatch(text: "No jobs from t (closed)."))
        let cleared = apply(jobs, annotations, .all)
        XCTAssertEqual(cleared.emptyState, .none)
        XCTAssertEqual(ids(cleared), ["a", "b"])
    }
}
