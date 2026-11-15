import AppKit
import XCTest

/// How a "No codebase" focus lives in the app's model and sidebar: it groups under Personal, says "No
/// codebase" on its second line (or its summary), is never given a branch, a PR or a repo, and survives a
/// relaunch. Everything that means "the repo" keys off `projectPath`, which stays nil for it; the folder it
/// runs in is `workingDirectory`.
final class NoCodebaseSidebarTests: XCTestCase {

    // MARK: Fixtures

    private func noCodebase(id: String = "11111111-0000-0000-0000-000000000001", agent: String = "claudia",
                            folder: String? = "/spaces/AAAA", label: String? = nil, org: String? = "Personal",
                            summary: String? = nil) -> Focus {
        var f = Focus(id: id, agentTag: agent, projectPath: nil, isBuiltIn: false, org: org, sessionSummary: summary)
        f.label = label
        f.noCodebase = true
        f.workingDirectory = folder
        return f
    }

    private func repoFocus(id: String = "22222222-0000-0000-0000-000000000002", agent: String = "cody",
                           path: String = "/Users/x/Code/nostromo", org: String? = "Carefeed") -> Focus {
        Focus(id: id, agentTag: agent, projectPath: path, isBuiltIn: false, org: org)
    }

    private struct Row { let focus: Focus; let label: String; let secondary: String?; let indented: Bool }

    private func focusRows(_ rows: [NavRow]) -> [Row] {
        rows.compactMap {
            if case .focus(let f, let label, let secondary, let indented) = $0 {
                return Row(focus: f, label: label, secondary: secondary, indented: indented)
            }
            return nil
        }
    }

    private func row(for focus: Focus, in rows: [NavRow]) throws -> Row {
        try XCTUnwrap(focusRows(rows).first { $0.focus.id == focus.id })
    }

    // MARK: Grouping

    func testANoCodebaseFocusGroupsUnderPersonalNotUnderTheRepos() throws {
        let nc = noCodebase()
        let repo = repoFocus()
        let rows = buildNavRows([repo, nc])

        let carefeed = try XCTUnwrap(rows.firstIndex(of: .orgHeader("CAREFEED")))
        let personal = try XCTUnwrap(rows.firstIndex(of: .orgHeader("PERSONAL")))
        XCTAssertLessThan(carefeed, personal)
        let ncIndex = try XCTUnwrap(rows.firstIndex { if case .focus(let f, _, _, _) = $0 { return f.id == nc.id } else { return false } })
        let repoIndex = try XCTUnwrap(rows.firstIndex { if case .focus(let f, _, _, _) = $0 { return f.id == repo.id } else { return false } })
        XCTAssertGreaterThan(ncIndex, personal, "under Personal")
        XCTAssertTrue(repoIndex > carefeed && repoIndex < personal, "the repo stays under Carefeed")
        XCTAssertFalse(rows.contains { if case .repoHeader = $0 { return true } else { return false } },
                       "no repo header for something with no repo")
        XCTAssertFalse(try row(for: nc, in: rows).indented)
    }

    func testAStaleCarefeedOrgOnANoCodebaseFocusStillGroupsUnderPersonal() throws {
        let rows = buildNavRows([noCodebase(org: "Carefeed"), noCodebase(id: "11111111-0000-0000-0000-000000000009", org: nil)])
        XCTAssertFalse(rows.contains(.orgHeader("CAREFEED")))
        XCTAssertTrue(rows.contains(.orgHeader("PERSONAL")))
    }

    func testSeveralNoCodebaseFocusesEachGetTheirOwnRowAndNeverAGroup() {
        let a = noCodebase(id: "11111111-0000-0000-0000-00000000000A", folder: "/spaces/A")
        let b = noCodebase(id: "11111111-0000-0000-0000-00000000000B", agent: "cody", folder: "/spaces/B")
        let rows = buildNavRows([a, b])
        XCTAssertEqual(focusRows(rows).count, 2)
        XCTAssertFalse(rows.contains { if case .repoHeader = $0 { return true } else { return false } })
    }

    // MARK: The row's words

    func testTheRowNamesTheFocusWithNoCodebaseAndSaysSoOnItsSecondLine() throws {
        let nc = noCodebase()
        let r = try row(for: nc, in: buildNavRows([nc]))
        XCTAssertEqual(r.label, "Claudia (no codebase)")
        XCTAssertEqual(r.secondary, "No codebase")
        XCTAssertEqual(FocusRowText.noCodebase, "No codebase")
    }

    func testAUserLabelWinsTheNameButTheSecondLineStillSaysNoCodebase() throws {
        let nc = noCodebase(label: "Scratch")
        let r = try row(for: nc, in: buildNavRows([nc]))
        XCTAssertEqual(r.label, "Scratch")
        XCTAssertEqual(r.secondary, "No codebase")
    }

    func testASessionSummaryTakesTheSecondLineInsteadOfNoCodebase() throws {
        let nc = noCodebase(summary: "Drafting the\nquarterly memo")
        let r = try row(for: nc, in: buildNavRows([nc]))
        XCTAssertEqual(r.secondary, "Drafting the quarterly memo", "one line, summary only")
        XCTAssertEqual(r.label, "Claudia (no codebase)", "the name still says it")
    }

    func testAResumedNoCodebaseFocusSaysResumedThenNoCodebase() throws {
        var nc = noCodebase()
        nc.resumedAt = Date(timeIntervalSince1970: 1_794_668_400)
        let r = try row(for: nc, in: buildNavRows([nc]))
        let secondary = try XCTUnwrap(r.secondary)
        XCTAssertTrue(secondary.hasPrefix("resumed \u{00B7} "), secondary)
        XCTAssertTrue(secondary.hasSuffix(" \u{00B7} No codebase"), secondary)
    }

    // MARK: Never a branch or a PR

    func testANoCodebaseRowNeverShowsABranchEvenWhenOneIsKnownForItsFolder() throws {
        let nc = noCodebase()
        let repo = repoFocus()
        let branches = ["/spaces/AAAA": "feature/leaked", "/Users/x/Code/nostromo": "main"]
        // A provider keyed by wherever the session runs would answer for the no-codebase folder.
        let rows = buildNavRows([repo, nc], branchFor: { f in f.sessionWorkingDirectory.flatMap { branches[$0] } })

        let ncRow = try row(for: nc, in: rows)
        XCTAssertEqual(ncRow.secondary, "No codebase")
        XCTAssertFalse(ncRow.secondary?.contains("feature") ?? false)
        XCTAssertEqual(try row(for: repo, in: rows).secondary, "main", "a repo row still shows its branch")
    }

    func testANoCodebaseRowNeverShowsABranchWhateverTheProviderAnswers() throws {
        let nc = noCodebase()
        let rows = buildNavRows([nc], branchFor: { _ in "feature/any" })
        XCTAssertEqual(try row(for: nc, in: rows).secondary, "No codebase")
    }

    func testANoCodebaseRowNeverShowsAPRNotEvenForPerri() throws {
        for agent in ["claudia", "perri"] {
            let nc = noCodebase(agent: agent)
            let rows = buildNavRows([nc], prFor: { _ in (repo: "nostromo", number: 12) })
            let r = try row(for: nc, in: rows)
            XCTAssertEqual(r.secondary, "No codebase", agent)
            XCTAssertFalse(r.secondary?.contains("12") ?? false, agent)
        }
    }

    // MARK: Nothing that means "the repo" is on

    func testANoCodebaseFocusHasNoRepoName() {
        let nc = noCodebase()
        XCTAssertNil(nc.projectPath)
        XCTAssertNil(nc.repoName)
        XCTAssertFalse(nc.isBuiltIn)
    }

    func testTheOrgOfANoCodebaseFocusIsAlwaysPersonal() {
        XCTAssertEqual(noCodebase(org: nil).effectiveOrg, "Personal")
        XCTAssertEqual(noCodebase(org: "Carefeed").effectiveOrg, "Personal", "even a stale org")
        XCTAssertEqual(repoFocus(org: nil).effectiveOrg, "Carefeed", "a repo focus keeps its rule")
        XCTAssertEqual(Focus(id: "p", agentTag: "huey", projectPath: nil, isBuiltIn: false).effectiveOrg, "Personal")
    }

    func testTheDefaultNameSaysNoCodebaseAndALabelReplacesIt() {
        XCTAssertEqual(noCodebase().displayName, "Claudia (no codebase)")
        XCTAssertEqual(noCodebase(agent: "cody").displayName, "Cody (no codebase)")
        XCTAssertEqual(noCodebase(label: "Scratch").displayName, "Scratch")
        XCTAssertEqual(repoFocus().displayName, "Cody in Nostromo", "a repo focus is named as before")
    }

    func testTheSessionRunsInTheFolderForNoCodebaseAndInTheRepoOtherwise() {
        XCTAssertEqual(noCodebase(folder: "/spaces/AAAA").sessionWorkingDirectory, "/spaces/AAAA")
        XCTAssertEqual(repoFocus(path: "/Users/x/Code/nostromo").sessionWorkingDirectory, "/Users/x/Code/nostromo")
        XCTAssertNil(Focus(id: "p", agentTag: "huey", projectPath: nil, isBuiltIn: false).sessionWorkingDirectory,
                     "a plain pathless focus still runs in the daemon's home")
        XCTAssertNil(noCodebase(folder: nil).sessionWorkingDirectory)
    }

    func testAWorkingDirectoryWithoutTheNoCodebaseFlagIsNotWhereTheSessionRuns() {
        var f = Focus(id: "p", agentTag: "huey", projectPath: nil, isBuiltIn: false)
        f.workingDirectory = "/spaces/AAAA"
        XCTAssertNil(f.sessionWorkingDirectory, "only a no-codebase focus has a folder of its own")
    }

    func testARepoPathAlwaysWinsAsTheWorkingDirectory() {
        var f = repoFocus(path: "/Users/x/Code/nostromo")
        f.workingDirectory = "/spaces/AAAA"
        f.noCodebase = true
        XCTAssertEqual(f.sessionWorkingDirectory, "/Users/x/Code/nostromo")
    }

    // MARK: Surviving a relaunch and reaching the daemon

    private func tempStoreURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("focuses-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testANoCodebaseFocusRoundTripsThroughJSON() throws {
        let nc = noCodebase(label: "Scratch")
        let back = try JSONDecoder().decode(Focus.self, from: JSONEncoder().encode(nc))
        XCTAssertEqual(back, nc)
        XCTAssertTrue(back.noCodebase)
        XCTAssertEqual(back.workingDirectory, "/spaces/AAAA")
        XCTAssertNil(back.projectPath)
    }

    func testAFocusFileWrittenBeforeNoCodebaseStillDecodes() throws {
        let old = #"[{"id":"u","agentTag":"cody","isBuiltIn":false,"projectPath":"/p"}]"#
        let decoded = try JSONDecoder().decode([Focus].self, from: Data(old.utf8))
        XCTAssertFalse(decoded[0].noCodebase)
        XCTAssertNil(decoded[0].workingDirectory)
        XCTAssertEqual(decoded[0].projectPath, "/p")
    }

    func testANoCodebaseFocusIsStillThereAfterARelaunch() throws {
        let url = tempStoreURL()
        let nc = noCodebase()
        FocusStore(storageURL: url).add(nc)
        let reloaded = try XCTUnwrap(FocusStore(storageURL: url).focuses.first { $0.id == nc.id })
        XCTAssertTrue(reloaded.noCodebase)
        XCTAssertEqual(reloaded.workingDirectory, "/spaces/AAAA")
        XCTAssertNil(reloaded.projectPath)
        XCTAssertEqual(reloaded.effectiveOrg, "Personal")
    }

    func testTheRegistryTellsTheDaemonAFocusHasNoCodebaseAndNamesNoProject() throws {
        let store = FocusStore(storageURL: tempStoreURL())
        let nc = noCodebase()
        let repo = repoFocus()
        store.add(nc); store.add(repo)
        let wire = store.wireProjection()
        let ncWire = try XCTUnwrap(wire.first { $0.tag == nc.sessionTag })
        let repoWire = try XCTUnwrap(wire.first { $0.tag == repo.sessionTag })

        XCTAssertEqual(ncWire.no_codebase, true)
        XCTAssertNil(ncWire.project_name, "no repo name goes to the daemon")
        XCTAssertEqual(ncWire.org, "Personal")
        XCTAssertEqual(ncWire.display_name, "Claudia (no codebase)")
        XCTAssertNil(repoWire.no_codebase)

        let ncJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ncWire)) as? [String: Any])
        XCTAssertEqual(ncJSON["no_codebase"] as? Bool, true)
        let repoJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(repoWire)) as? [String: Any])
        XCTAssertNil(repoJSON["no_codebase"], "absent for an ordinary focus, so an older daemon sees what it always saw")
    }

    // MARK: VoiceOver

    func testTheRowSaysNoCodebaseToVoiceOverEvenWhenALabelReplacedTheName() {
        let plain = NavTabItem(focus: noCodebase(), label: "Claudia (no codebase)", secondary: "No codebase", indented: false)
        XCTAssertEqual(plain.accessibilityLabel(), "Claudia (no codebase)")
        let labelled = NavTabItem(focus: noCodebase(label: "Scratch"), label: "Scratch", secondary: "No codebase", indented: false)
        XCTAssertEqual(labelled.accessibilityLabel(), "Scratch, no codebase")
        let repo = NavTabItem(focus: repoFocus(), label: "Cody in Nostromo", secondary: "", indented: false)
        XCTAssertEqual(repo.accessibilityLabel(), "Cody in Nostromo", "a repo row says nothing extra")
    }

    func testTheNoCodebaseWordsStayWhenTheRowIsRenamedInPlace() {
        let item = NavTabItem(focus: noCodebase(), label: "Claudia (no codebase)", secondary: "No codebase", indented: false)
        item.displayOverride = "Memo"
        XCTAssertEqual(item.accessibilityLabel(), "Memo, no codebase")
    }

    func testTheSecondLineOfANoCodebaseRowIsItsWords() {
        let item = NavTabItem(focus: noCodebase(), label: "Claudia (no codebase)", secondary: "No codebase", indented: false)
        XCTAssertEqual(item.secondaryText, "No codebase")
        let repo = NavTabItem(focus: repoFocus(), label: "Cody in Nostromo", secondary: "main", indented: false)
        XCTAssertEqual(repo.secondaryText, "", "a repo row keeps its second line for the pills")
    }

    // MARK: The real sidebar: rows, and no repo action on them

    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func sidebarItems(for focuses: [Focus]) throws -> [NavTabItem] {
        _ = NSApplication.shared
        let size = NSSize(width: Theme.sidebarWidth, height: 600)
        let tabBar = TabBarView(frame: NSRect(origin: .zero, size: size))
        tabBar.autoresizingMask = [.width, .height]
        let window = FixedWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = tabBar
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock { window.orderOut(nil); window.contentView = nil }
        tabBar.activityStateProvider = { _ in FocusActivityState.none }
        tabBar.setFocuses(focuses)
        for _ in 0 ..< 6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func scroll(in view: NSView) -> NSScrollView? {
            if let s = view as? NSScrollView { return s }
            for sub in view.subviews { if let found = scroll(in: sub) { return found } }
            return nil
        }
        let document = try XCTUnwrap(scroll(in: tabBar)?.documentView, "the sidebar has a document view")
        return document.subviews.compactMap { $0 as? NavTabItem }
    }

    func testTheRealSidebarShowsANoCodebaseRowWithItsMarkAndWordsAndNoRepoActions() throws {
        let nc = noCodebase(folder: "/tmp/nocodebase-sidebar-nonexistent/AAAA")
        let repo = repoFocus(path: "/tmp/nocodebase-sidebar-nonexistent/nostromo")
        let items = try sidebarItems(for: [repo, nc])
        let ncItem = try XCTUnwrap(items.first { $0.focus.id == nc.id })
        let repoItem = try XCTUnwrap(items.first { $0.focus.id == repo.id })

        XCTAssertEqual(ncItem.secondaryText, "No codebase")
        XCTAssertNotNil(ncItem.noCodebaseGlyphFrame, "the speech bubble shows")
        XCTAssertNil(repoItem.noCodebaseGlyphFrame, "a repo row has none")

        let ncMenu = try XCTUnwrap(ncItem.menu).items.map(\.title)
        let repoMenu = try XCTUnwrap(repoItem.menu).items.map(\.title)
        XCTAssertEqual(ncMenu, repoMenu, "the same actions as any dynamic row; nothing repo-shaped added")
        let repoWords = ["repo", "branch", "pull request", "pr ", "finder", "editor", "attach", "open in", "github", "terminal"]
        for title in ncMenu {
            XCTAssertFalse(repoWords.contains { title.lowercased().contains($0) }, "a repo action on a no-codebase row: \(title)")
        }
    }
}
