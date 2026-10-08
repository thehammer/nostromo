import XCTest
import Combine
// Focus and FocusStore are compiled into this target directly (logic test — no host app).

// MARK: - FocusLabelTests

/// Behavioural tests for the optional, user-chosen `Focus.label`: how it is
/// normalized, how it names a focus, that it survives persistence, and that
/// `FocusStore.rename` / `add` honour the "many sessions per agent + repo"
/// requirement.
///
/// The label is a *name*, never an *address*: `id` and `sessionTag` (the key the
/// daemon routes pane content, layouts and sessions by) must not move when a
/// label is set, changed or cleared.
final class FocusLabelTests: XCTestCase {

    // MARK: - Helpers

    private let adminPortal = "/Users/hammer/Code/admin-portal"

    private func makeFocus(
        id: String = UUID().uuidString,
        agent: String = "claudia",
        path: String? = "/Users/hammer/Code/admin-portal",
        label: String? = nil
    ) -> Focus {
        var f = Focus(id: id, agentTag: agent, projectPath: path, isBuiltIn: false, org: "Carefeed")
        f.label = label
        return f
    }

    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    /// A fresh `focuses.json` location inside a throwaway directory (never `~/.nostromo`).
    private func makeStorageURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-label-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir.appendingPathComponent("focuses.json")
    }

    private func dynamicFocuses(_ store: FocusStore) -> [Focus] {
        store.focuses.filter { !$0.isBuiltIn }
    }

    // MARK: - Label normalization

    func testMaxLabelLengthIsSixty() {
        XCTAssertEqual(Focus.maxLabelLength, 60)
    }

    func testNormalizedLabelOfNilIsNil() {
        XCTAssertNil(Focus.normalizedLabel(nil))
    }

    func testNormalizedLabelOfBlankInputsIsNil() {
        for raw in ["", " ", "     ", "\n", "\t", " \n\t \r\n "] {
            XCTAssertNil(Focus.normalizedLabel(raw), "blank input \(raw.debugDescription) means 'no label'")
        }
    }

    func testNormalizedLabelTrimsSurroundingWhitespaceAndNewlines() {
        XCTAssertEqual(Focus.normalizedLabel("  Hotfix  "), "Hotfix")
        XCTAssertEqual(Focus.normalizedLabel("\n\tHotfix\n"), "Hotfix")
    }

    func testNormalizedLabelKeepsInteriorSpacesAndCase() {
        XCTAssertEqual(Focus.normalizedLabel("  Login  Flow v2 "), "Login  Flow v2")
    }

    func testNormalizedLabelAtExactlyTheLimitIsKeptWhole() {
        let sixty = String(repeating: "a", count: 60)
        XCTAssertEqual(Focus.normalizedLabel(sixty), sixty)
    }

    func testNormalizedLabelOverTheLimitIsCappedAtSixtyCharacters() {
        let long = String(repeating: "a", count: 61)
        XCTAssertEqual(Focus.normalizedLabel(long), String(repeating: "a", count: 60))
        let veryLong = String(repeating: "b", count: 500)
        XCTAssertEqual(Focus.normalizedLabel(veryLong)?.count, 60)
    }

    func testNormalizedLabelCapCountsCharactersNotBytes() {
        let emoji = String(repeating: "😀", count: 70)
        let result = Focus.normalizedLabel(emoji)
        XCTAssertEqual(result?.count, 60, "the limit is 60 user-visible characters")
        XCTAssertEqual(result, String(repeating: "😀", count: 60), "capping must not split a character")
    }

    func testNormalizedLabelTrimsBeforeCappingSoPaddingDoesNotEatTheBudget() {
        let padded = String(repeating: " ", count: 10) + String(repeating: "x", count: 70)
        XCTAssertEqual(Focus.normalizedLabel(padded), String(repeating: "x", count: 60))
    }

    /// Whatever the order of trim/cap, the result must be a settled value: no
    /// edge whitespace, within the limit, and normalizing it again changes nothing
    /// (otherwise a saved label would drift every time it is re-saved).
    func testNormalizedLabelResultIsAlwaysSettled() {
        let awkward = String(repeating: "a", count: 59) + " " + String(repeating: "b", count: 10)
        let inputs = [awkward, "  Hotfix  ", String(repeating: "z", count: 200), "x"]
        for raw in inputs {
            guard let once = Focus.normalizedLabel(raw) else {
                XCTFail("\(raw.debugDescription) should normalize to a label"); continue
            }
            XCTAssertLessThanOrEqual(once.count, Focus.maxLabelLength)
            XCTAssertEqual(once, once.trimmingCharacters(in: .whitespacesAndNewlines),
                           "no leading/trailing whitespace in \(once.debugDescription)")
            XCTAssertEqual(Focus.normalizedLabel(once), once, "normalization is idempotent")
        }
    }

    // MARK: - displayName

    func testDisplayNameWithoutLabelIsTheDefaultName() {
        XCTAssertEqual(makeFocus(agent: "claudia").displayName, "Claudia in Admin Portal")
        XCTAssertEqual(makeFocus(agent: "cody").displayName, "Cody in Admin Portal")
    }

    func testDisplayNameUsesTheLabelWhenSet() {
        XCTAssertEqual(makeFocus(label: "Hotfix").displayName, "Hotfix")
    }

    func testDisplayNameUsesTheNormalizedLabel() {
        XCTAssertEqual(makeFocus(label: "  Hotfix  ").displayName, "Hotfix")
    }

    func testDisplayNameWithWhitespaceOnlyLabelFallsBackToTheDefault() {
        XCTAssertEqual(makeFocus(label: "   ").displayName, "Claudia in Admin Portal")
        XCTAssertEqual(makeFocus(label: "\n").displayName, "Claudia in Admin Portal")
        XCTAssertEqual(makeFocus(label: "").displayName, "Claudia in Admin Portal")
    }

    func testDisplayNameCapsAnOverlongLabel() {
        let name = makeFocus(label: String(repeating: "q", count: 100)).displayName
        XCTAssertEqual(name, String(repeating: "q", count: 60))
    }

    func testDisplayNameLabelAppliesToPathlessDynamicFocusToo() {
        XCTAssertEqual(makeFocus(agent: "claudia", path: nil, label: "Scratch").displayName, "Scratch")
        XCTAssertEqual(makeFocus(agent: "claudia", path: nil).displayName, "Claudia")
    }

    // MARK: - sessionTag is an address, not a name

    func testSessionTagIsUnaffectedByLabel() {
        let id = "9F2A4C1E-8B3D-4A76-9C21-0D5E6F7A8B90"
        let plain = makeFocus(id: id, agent: "claudia")
        XCTAssertEqual(plain.sessionTag, "claudia-9F2A4C1E")
        XCTAssertEqual(makeFocus(id: id, agent: "claudia", label: "Hotfix").sessionTag, plain.sessionTag)
        XCTAssertEqual(makeFocus(id: id, agent: "claudia", label: "   ").sessionTag, plain.sessionTag)
    }

    func testSessionTagOfDaemonCreatedFocusIsUnaffectedByLabel() {
        var f = makeFocus(id: "cody-core-1234", agent: "cody")
        f.daemonTag = "cody-core-1234"
        let before = f.sessionTag
        f.label = "Renamed"
        XCTAssertEqual(f.sessionTag, "cody-core-1234")
        XCTAssertEqual(f.sessionTag, before)
    }

    // MARK: - Codable

    func testLabelRoundTripsThroughCodable() throws {
        let original = makeFocus(label: "Hotfix")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Focus.self, from: data)
        XCTAssertEqual(decoded.label, "Hotfix")
        XCTAssertEqual(decoded, original)
    }

    func testNilLabelRoundTripsAsNil() throws {
        let original = makeFocus(label: nil)
        let decoded = try JSONDecoder().decode(Focus.self, from: JSONEncoder().encode(original))
        XCTAssertNil(decoded.label)
    }

    func testJsonWithoutLabelKeyDecodesAsNil() throws {
        // A focuses.json written before labels existed.
        let json = """
        {"id":"9F2A4C1E-8B3D-4A76-9C21-0D5E6F7A8B90","agentTag":"claudia",
         "projectPath":"/Users/hammer/Code/admin-portal","isBuiltIn":false,
         "quickActions":[],"org":"Carefeed"}
        """
        let focus = try JSONDecoder().decode(Focus.self, from: Data(json.utf8))
        XCTAssertNil(focus.label)
        XCTAssertEqual(focus.displayName, "Claudia in Admin Portal")
        XCTAssertEqual(focus.sessionTag, "claudia-9F2A4C1E", "old focuses keep the tag they had")
    }

    func testJsonWithLabelKeyDecodesTheLabel() throws {
        let json = """
        {"id":"9F2A4C1E-8B3D-4A76-9C21-0D5E6F7A8B90","agentTag":"claudia",
         "projectPath":"/Users/hammer/Code/admin-portal","isBuiltIn":false,
         "quickActions":[],"org":"Carefeed","label":"Hotfix"}
        """
        let focus = try JSONDecoder().decode(Focus.self, from: Data(json.utf8))
        XCTAssertEqual(focus.label, "Hotfix")
        XCTAssertEqual(focus.displayName, "Hotfix")
    }

    // MARK: - FocusCreation.commit

    func testCommittingASecondFocusForTheSameAgentAndRepoKeepsBothAndSwitchesToTheNewOne() throws {
        let store = FocusStore(storageURL: try makeStorageURL())
        let existing = makeFocus()
        store.add(existing)
        let created = makeFocus()   // same agent + repo, new id

        var switchedTo: [Focus] = []
        FocusCreation.commit(created, store: store) { switchedTo.append($0) }

        XCTAssertEqual(dynamicFocuses(store).map(\.id), [existing.id, created.id])
        XCTAssertEqual(switchedTo.map(\.id), [created.id], "switches to the NEW focus, not the existing match")
    }

    // MARK: - FocusStore.rename

    func testRenameSetsTheLabelOnADynamicFocus() throws {
        let store = FocusStore(storageURL: try makeStorageURL())
        let f = makeFocus()
        store.add(f)

        XCTAssertTrue(store.rename(id: f.id, label: "Hotfix"))

        let renamed = try XCTUnwrap(store.focuses.first { $0.id == f.id })
        XCTAssertEqual(renamed.label, "Hotfix")
        XCTAssertEqual(renamed.displayName, "Hotfix")
    }

    func testRenameNormalizesTheLabel() throws {
        let store = FocusStore(storageURL: try makeStorageURL())
        let f = makeFocus()
        store.add(f)

        store.rename(id: f.id, label: "  Hotfix \n")
        XCTAssertEqual(store.focuses.first { $0.id == f.id }?.label, "Hotfix")

        store.rename(id: f.id, label: String(repeating: "n", count: 200))
        XCTAssertEqual(store.focuses.first { $0.id == f.id }?.label?.count, 60)
    }

    func testRenamePersistsSoANewStoreOverTheSameFileSeesIt() throws {
        let url = try makeStorageURL()
        let store = FocusStore(storageURL: url)
        let f = makeFocus()
        store.add(f)
        store.rename(id: f.id, label: "Hotfix")

        let reloaded = FocusStore(storageURL: url)
        let match = try XCTUnwrap(reloaded.focuses.first { $0.id == f.id })
        XCTAssertEqual(match.label, "Hotfix")
        XCTAssertEqual(match.displayName, "Hotfix")
    }

    func testRenameWithBlankOrNilClearsTheLabel() throws {
        let url = try makeStorageURL()
        for blank in [nil, "", "   ", "\n\t"] as [String?] {
            let store = FocusStore(storageURL: url)
            let f = makeFocus(label: "Hotfix")
            store.add(f)
            XCTAssertEqual(store.focuses.first { $0.id == f.id }?.label, "Hotfix")

            XCTAssertTrue(store.rename(id: f.id, label: blank), "clearing is a successful rename")
            XCTAssertNil(store.focuses.first { $0.id == f.id }?.label, "\(String(describing: blank)) clears")
            XCTAssertEqual(store.focuses.first { $0.id == f.id }?.displayName, "Claudia in Admin Portal")

            let reloaded = FocusStore(storageURL: url)
            XCTAssertNil(reloaded.focuses.first { $0.id == f.id }?.label, "clearing persists")
            store.remove(f)
        }
    }

    func testRenameDoesNotChangeIdOrSessionTag() throws {
        let store = FocusStore(storageURL: try makeStorageURL())
        let f = makeFocus(id: "9F2A4C1E-8B3D-4A76-9C21-0D5E6F7A8B90")
        store.add(f)
        let tagBefore = f.sessionTag

        XCTAssertTrue(store.rename(id: f.id, label: "Hotfix"))
        let after = try XCTUnwrap(store.focuses.first { $0.id == f.id })
        XCTAssertEqual(after.label, "Hotfix", "sanity: the rename really happened")
        XCTAssertEqual(after.id, f.id)
        XCTAssertEqual(after.sessionTag, tagBefore)

        XCTAssertTrue(store.rename(id: f.id, label: nil))
        let cleared = try XCTUnwrap(store.focuses.first { $0.id == f.id })
        XCTAssertNil(cleared.label)
        XCTAssertEqual(cleared.sessionTag, tagBefore)
    }

    func testRenameOfDaemonCreatedFocusKeepsItsDaemonTag() throws {
        let url = try makeStorageURL()
        let store = FocusStore(storageURL: url)
        var f = makeFocus(id: "cody-core-1234", agent: "cody")
        f.daemonTag = "cody-core-1234"
        store.add(f)

        XCTAssertTrue(store.rename(id: f.id, label: "Core spike"))

        XCTAssertEqual(store.focuses.first { $0.id == f.id }?.sessionTag, "cody-core-1234")
        let reloaded = FocusStore(storageURL: url)
        XCTAssertEqual(reloaded.focuses.first { $0.id == f.id }?.sessionTag, "cody-core-1234")
        XCTAssertEqual(reloaded.focuses.first { $0.id == f.id }?.label, "Core spike")
    }

    func testRenameOnlyTouchesTheTargetFocus() throws {
        let store = FocusStore(storageURL: try makeStorageURL())
        let a = makeFocus(id: UUID().uuidString)
        let b = makeFocus(id: UUID().uuidString)
        store.add(a)
        store.add(b)

        store.rename(id: a.id, label: "Hotfix")

        XCTAssertEqual(store.focuses.first { $0.id == a.id }?.label, "Hotfix")
        XCTAssertNil(store.focuses.first { $0.id == b.id }?.label)
    }

    func testRenameRefusesBuiltInsAndChangesNothing() throws {
        let url = try makeStorageURL()
        let store = FocusStore(storageURL: url)
        let before = store.focuses

        XCTAssertFalse(store.rename(id: "perri", label: "Reviewer"))

        XCTAssertEqual(store.focuses, before)
        XCTAssertEqual(store.focuses.first { $0.id == "perri" }?.displayName, "Perri")
        XCTAssertNil(store.focuses.first { $0.id == "perri" }?.label)
        for builtIn in Focus.builtIns {
            XCTAssertFalse(store.rename(id: builtIn.id, label: "Nope"), builtIn.id)
        }
        XCTAssertEqual(store.focuses, before)
    }

    func testRenameOfUnknownIdReturnsFalseAndChangesNothing() throws {
        let store = FocusStore(storageURL: try makeStorageURL())
        let f = makeFocus()
        store.add(f)
        let before = store.focuses

        XCTAssertFalse(store.rename(id: "no-such-focus", label: "Ghost"))

        XCTAssertEqual(store.focuses, before)
    }

    func testRenamePublishesTheChangeOnFocuses() throws {
        let store = FocusStore(storageURL: try makeStorageURL())
        let f = makeFocus()
        store.add(f)

        var latest: [Focus] = []
        let cancellable = store.$focuses.sink { latest = $0 }
        defer { cancellable.cancel() }
        XCTAssertNil(latest.first { $0.id == f.id }?.label)

        store.rename(id: f.id, label: "Hotfix")
        XCTAssertEqual(latest.first { $0.id == f.id }?.label, "Hotfix")

        store.rename(id: f.id, label: nil)
        XCTAssertNil(latest.first { $0.id == f.id }?.label)
    }

    func testRenameIsReflectedInTheWireProjectionDisplayName() throws {
        let store = FocusStore(storageURL: try makeStorageURL())
        let f = makeFocus(id: "9F2A4C1E-8B3D-4A76-9C21-0D5E6F7A8B90")
        store.add(f)

        func wireName() -> String? {
            store.wireProjection().first { $0.tag == f.sessionTag }?.display_name
        }
        XCTAssertEqual(wireName(), "Claudia in Admin Portal")

        store.rename(id: f.id, label: "Hotfix")
        XCTAssertEqual(wireName(), "Hotfix")
        XCTAssertEqual(store.wireProjection().filter { $0.tag == f.sessionTag }.count, 1,
                       "the focus keeps its tag: it is renamed, not replaced")

        store.rename(id: f.id, label: "")
        XCTAssertEqual(wireName(), "Claudia in Admin Portal")
    }

    // MARK: - Many sessions per agent + repo

    func testAddingTwoFocusesForTheSameAgentAndRepoKeepsBoth() throws {
        let store = FocusStore(storageURL: try makeStorageURL())
        let a = makeFocus(id: UUID().uuidString, agent: "claudia", path: adminPortal)
        let b = makeFocus(id: UUID().uuidString, agent: "claudia", path: adminPortal)

        store.add(a)
        store.add(b)

        let dynamic = dynamicFocuses(store)
        XCTAssertEqual(dynamic.count, 2, "no dedup: a second session for the same agent + repo is allowed")
        XCTAssertEqual(Set(dynamic.map(\.id)).count, 2)
        XCTAssertEqual(Set(dynamic.map(\.sessionTag)).count, 2,
                       "each session is addressed by its own tag, or their panes would collide")
    }

    func testBothSameAgentAndRepoFocusesSurviveReloadWithTheirOwnLabels() throws {
        let url = try makeStorageURL()
        let store = FocusStore(storageURL: url)
        let a = makeFocus(id: UUID().uuidString, agent: "claudia", path: adminPortal, label: "Hotfix")
        let b = makeFocus(id: UUID().uuidString, agent: "claudia", path: adminPortal, label: "Refactor")
        store.add(a)
        store.add(b)

        let reloaded = FocusStore(storageURL: url)
        let dynamic = dynamicFocuses(reloaded)
        XCTAssertEqual(dynamic.count, 2)
        XCTAssertEqual(reloaded.focuses.first { $0.id == a.id }?.label, "Hotfix")
        XCTAssertEqual(reloaded.focuses.first { $0.id == b.id }?.label, "Refactor")
        XCTAssertEqual(Set(dynamic.map(\.sessionTag)).count, 2)
    }

    func testAFocusAddedWithALabelKeepsItAcrossReload() throws {
        let url = try makeStorageURL()
        let store = FocusStore(storageURL: url)
        let f = makeFocus(label: "Hotfix")
        store.add(f)

        let reloaded = FocusStore(storageURL: url)
        XCTAssertEqual(reloaded.focuses.first { $0.id == f.id }?.label, "Hotfix")
    }
}
