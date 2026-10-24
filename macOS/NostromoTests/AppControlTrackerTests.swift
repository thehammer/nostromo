import XCTest
import AppKit
import NostromoKit

// `nostromo-app tracker show | file` and `tracker-anchor` (T1): read-only probes whose answers must
// equal what the pane on screen shows. `pane.showReport()` is what `AppControlServer` returns for
// `tracker show`; the tests read the report back and compare it, field by field, with the pane's own
// row views, strip and banner. `AppControlTracker.file` and `TrackerAnchorProbe` are pure formatters.
//
// Boards and rigs come from `TrackerPaneFx` (TrackerPaneViewTests.swift).

final class AppControlTrackerTests: XCTestCase {

    private typealias Fx = TrackerPaneFx
    private typealias Obj = [String: Any]

    private func goldenRig(window: NSWindow? = nil, file: StaticString = #filePath, line: UInt = #line)
        throws -> (rig: TrackerPaneRig, script: TrackerBoardScript) {
        let tag = Fx.uniqueTag()
        let rig = Fx.makeRig(self, tag: tag, window: window)
        let script = try TrackerBoardScript(tag: tag, file: file)
        rig.push(script, file: file, line: line)
        return (rig, script)
    }

    private func object(_ value: Any?, _ what: String, file: StaticString = #filePath, line: UInt = #line) -> Obj {
        guard let object = value as? Obj else {
            XCTFail("\(what) is not an object: \(String(describing: value))", file: file, line: line)
            return [:]
        }
        return object
    }

    private func list(_ value: Any?, _ what: String, file: StaticString = #filePath, line: UInt = #line) -> [Obj] {
        guard let list = value as? [Obj] else {
            XCTFail("\(what) is not a list of objects: \(String(describing: value))", file: file, line: line)
            return []
        }
        return list
    }

    private func sections(_ report: Obj) -> [Obj] { list(report["sections"], "sections") }

    private func items(_ report: Obj, section id: String) -> [Obj] {
        list(sections(report).first { ($0["id"] as? String) == id }?["items"], "items of \(id)")
    }

    private func assertValidJSON(_ report: Obj, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(report), "\(what) is not valid JSON", file: file, line: line)
        guard let data = try? JSONSerialization.data(withJSONObject: report),
              let back = try? JSONSerialization.jsonObject(with: data) as? Obj
        else { return XCTFail("\(what) does not round-trip through JSON", file: file, line: line) }
        XCTAssertEqual(Set(back.keys), Set(report.keys), file: file, line: line)
    }

    // MARK: - tracker show equals the pane

    func testShowReportsTheBoardsTitlePathAndHeaderAsThePaneShowsThem() throws {
        let (rig, _) = try goldenRig()
        let report = rig.pane.showReport()
        XCTAssertEqual(report["tag"] as? String, rig.tag)
        XCTAssertEqual(report["waiting"] as? Bool, false)
        XCTAssertEqual(report["title"] as? String, rig.pane.header.titleLabel.stringValue)
        XCTAssertEqual(report["title"] as? String, "Synthetic release triage")
        XCTAssertEqual(report["path"] as? String, "/repo/.claude/wip/sentry-triage/index.md")
        XCTAssertEqual(report["updated"] as? String, rig.pane.header.updatedLabel.stringValue)
        XCTAssertTrue(report["committable"] is NSNull, "no remote, no badge")
        assertValidJSON(report, "the report")
    }

    func testShowListsTheSectionsInDisplayOrderWithTheTitlesAndCountsTheRowViewsShow() throws {
        let (rig, _) = try goldenRig()
        let reported = sections(rig.pane.showReport())

        var shown: [(id: String, title: String, count: Int, text: String)] = []
        for key in Fx.sectionKeys(rig.pane) {
            guard let view = rig.pane.rowViews[key], case .section(let section) = view.row.content else {
                XCTFail("no section row view \(key)"); continue
            }
            shown.append((section.id, section.title, section.count, view.visibleText))
        }
        XCTAssertEqual(reported.count, 6)
        XCTAssertEqual(reported.count, shown.count)
        for (r, s) in zip(reported, shown) {
            XCTAssertEqual(r["id"] as? String, s.id)
            XCTAssertEqual(r["title"] as? String, s.title)
            XCTAssertEqual(r["count"] as? Int, s.count)
            XCTAssertTrue(s.text.contains(s.title) && s.text.contains("\(s.count)"), "the row shows what the report says: \(s.text)")
        }
    }

    func testShowListsEachItemWithWhatItsRowViewShows() throws {
        let (rig, _) = try goldenRig()
        let report = rig.pane.showReport()
        var seen = 0
        for section in sections(report) {
            for item in list(section["items"], "items") where (item["folded"] as? Bool) == false {
                seen += 1
                let id = try XCTUnwrap(item["id"] as? String)
                let view = try XCTUnwrap(rig.pane.rowViews["item:\(id)"], "no row view for reported item \(id)")
                let row = try XCTUnwrap(view.row.item)
                XCTAssertEqual(item["text"] as? String, row.text)
                XCTAssertTrue(view.visibleText.contains(row.text), "\(id): \(view.visibleText)")
                XCTAssertEqual(item["status"] as? String, row.status.wireName)
                XCTAssertTrue(view.visibleText.contains(Fx.marks[row.status.wireName] ?? "?"), "\(id) shows the mark for \(row.status.wireName)")
                if let owner = row.owner {
                    XCTAssertEqual(item["owner"] as? String, owner)
                    XCTAssertTrue(view.visibleText.contains(owner))
                } else {
                    XCTAssertTrue(item["owner"] is NSNull, "\(id) has no owner: \(String(describing: item["owner"]))")
                }
                XCTAssertEqual(item["updated"] as? String, view.timeLabel?.stringValue, "\(id) reports the time the row shows")
                XCTAssertEqual(item["folded"] as? Bool, false)
                XCTAssertTrue(item["held"] is NSNull)
                XCTAssertTrue(item["stub"] is NSNull)
                XCTAssertTrue(item["conflict"] is NSNull, "no conflict is reported until the daemon sends one")
                XCTAssertTrue(item["badge"] is NSNull)
            }
        }
        XCTAssertEqual(seen, rig.pane.rowViews.values.filter { $0.row.item != nil }.count, "every item row is reported, none twice")
        XCTAssertEqual(seen, 43)
    }

    func testShowListsTheFoldedDoneItemsAsFoldedAndGivesEachDoneGroupItsCount() throws {
        let (rig, script) = try goldenRig()
        let report = rig.pane.showReport()
        var folded: [String] = []
        for section in sections(report) {
            for item in list(section["items"], "items") where (item["folded"] as? Bool) == true {
                folded.append(try XCTUnwrap(item["id"] as? String))
                XCTAssertEqual(item["status"] as? String, "done")
            }
        }
        XCTAssertEqual(Set(folded), Set(script.itemIDs(status: "done")))
        XCTAssertEqual(folded.count, 17)
        for id in folded { XCTAssertNil(rig.pane.rowViews["item:\(id)"], "\(id) is folded: it has no row on screen") }

        let done = object(sections(report).first { ($0["id"] as? String) == "done" }?["done"], "the Done group of Done")
        XCTAssertEqual(done["count"] as? Int, 12)
        XCTAssertEqual(done["expanded"] as? Bool, false)
        XCTAssertEqual(done["title"] as? String, "Done (12)")
        XCTAssertTrue(rig.pane.rowViews["done:done"]?.visibleText.contains("Done (12)") ?? false, "what the row shows")
        XCTAssertTrue(sections(report).first { ($0["id"] as? String) == "now" }?["done"] is NSNull, "a section with nothing done has no group")
    }

    func testAnOpenedDoneGroupReportsItsItemsAsRowsNotFolded() throws {
        let (rig, script) = try goldenRig()
        rig.pane.toggleDoneGroup(section: "done")
        rig.settle()
        let report = rig.pane.showReport()
        let doneItems = items(report, section: "done")
        XCTAssertEqual(doneItems.count, 12)
        XCTAssertTrue(doneItems.allSatisfy { ($0["folded"] as? Bool) == false })
        XCTAssertEqual(Set(doneItems.compactMap { $0["id"] as? String }), Set(script.itemIDs(status: "done", section: "done")))
        XCTAssertEqual(object(sections(report).first { ($0["id"] as? String) == "done" }?["done"], "group")["expanded"] as? Bool, true)
        for item in doneItems {
            let id = item["id"] as? String ?? ""
            XCTAssertNotNil(rig.pane.rowViews["item:\(id)"], "\(id) has its row on screen now")
        }
    }

    func testShowReportsTheWaitingStripAsThePaneShowsIt() throws {
        let (rig, script) = try goldenRig()
        let strip = object(rig.pane.showReport()["strip"], "strip")
        XCTAssertEqual(strip["count"] as? Int, 10)
        XCTAssertEqual(strip["title"] as? String, "Waiting on you (10)")
        XCTAssertTrue(rig.pane.strip.text.contains(strip["title"] as? String ?? "?"), rig.pane.strip.text)

        let entries = list(strip["items"], "strip items")
        XCTAssertEqual(entries.compactMap { $0["text"] as? String }, rig.pane.strip.strip.entries.map(\.text))
        XCTAssertEqual(entries.compactMap { $0["key"] as? String }, rig.pane.strip.strip.entries.map(\.key))
        XCTAssertEqual(Set(entries.compactMap { $0["key"] as? String }),
                       Set(script.itemIDs(status: "needs-you").map { "item:\($0)" }))
        for entry in entries { XCTAssertTrue(rig.pane.strip.text.contains(entry["text"] as? String ?? "?")) }
        XCTAssertEqual(entries.first?["detail"] as? String, "Waiting on you", "each entry says which section it is from")
    }

    func testAnEmptyStripReportsZero() throws {
        let tag = Fx.uniqueTag()
        let rig = Fx.makeRig(self, tag: tag)
        var script = try TrackerBoardScript(tag: tag)
        for id in script.itemIDs(status: "needs-you") { try script.setStatus(id, "todo") }
        rig.push(script)
        let strip = object(rig.pane.showReport()["strip"], "strip")
        XCTAssertEqual(strip["count"] as? Int, 0)
        XCTAssertEqual(strip["title"] as? String, "Waiting on you (0)")
        XCTAssertEqual(list(strip["items"], "items").count, 0)
        XCTAssertEqual(rig.pane.strip.preferredHeight, 0, "an empty strip takes no room")
        XCTAssertEqual(rig.pane.strip.frame.height, 0, accuracy: 0.01)
    }

    func testShowReportsAnUnreadableBannerAndAMissingOneAsThePaneShowsThem() throws {
        let (rig, script) = try goldenRig()
        XCTAssertEqual(list(rig.pane.showReport()["banners"], "banners").count, 0)
        XCTAssertTrue(rig.pane.banner.isHidden)

        var unreadable = script
        unreadable.setBanner(["type": "unreadable", "line": 42, "reason": "duplicate_id", "last_good_at": Fx.iso(1_760_547_000)])
        rig.push(unreadable)
        var banners = list(rig.pane.showReport()["banners"], "banners")
        XCTAssertEqual(banners.count, 1)
        XCTAssertEqual(banners.first?["kind"] as? String, "unreadable")
        var text = banners.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("index.md") && text.contains("line 42") && text.contains("duplicate item id"), text)
        XCTAssertEqual(rig.pane.banner.label.stringValue, text, "the banner on screen says what the report says")
        XCTAssertFalse(rig.pane.banner.isHidden)

        var missing = script
        missing.setBanner(["type": "missing", "last_seen": Fx.iso(1_760_547_000)])
        rig.push(missing)
        banners = list(rig.pane.showReport()["banners"], "banners")
        XCTAssertEqual(banners.count, 1)
        XCTAssertEqual(banners.first?["kind"] as? String, "missing")
        text = banners.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("index.md is gone"), text)
        XCTAssertEqual(rig.pane.banner.label.stringValue, text)

        rig.push(script)
        XCTAssertEqual(list(rig.pane.showReport()["banners"], "banners").count, 0, "the banner clears when the file is readable again")
        XCTAssertTrue(rig.pane.banner.isHidden)
        assertValidJSON(rig.pane.showReport(), "the report")
    }

    func testShowReportsWhetherThePaneIsOnScreen() throws {
        let (rig, _) = try goldenRig()
        XCTAssertEqual(rig.pane.showReport()["visible"] as? Bool, true)
        rig.pane.isHidden = true
        XCTAssertEqual(rig.pane.showReport()["visible"] as? Bool, false, "a hidden pane is not visible")
        rig.pane.isHidden = false
        XCTAssertEqual(rig.pane.showReport()["visible"] as? Bool, true)

        let detached = TrackerPaneView(tag: Fx.uniqueTag(), store: Fx.makeImmediateStore(), tickInterval: nil)
        XCTAssertEqual(detached.showReport()["visible"] as? Bool, false, "a pane with no window is not visible")
    }

    func testShowReportsTheFilterAndOnlyTheRowsItShows() throws {
        let (rig, script) = try goldenRig()
        XCTAssertEqual(rig.pane.showReport()["filter"] as? String, "all")
        for (filter, name) in [(TrackerFilter.open, "open"), (.waiting, "waiting"), (.done, "done"), (.all, "all")] {
            rig.pane.setFilter(filter)
            rig.settle()
            let report = rig.pane.showReport()
            XCTAssertEqual(report["filter"] as? String, name)
            let reported = sections(report).flatMap { list($0["items"], "items") }
                .filter { ($0["folded"] as? Bool) == false }.compactMap { $0["id"] as? String }
            XCTAssertEqual(Set(reported), Set(Fx.itemKeys(rig.pane).map { String($0.dropFirst("item:".count)) }), "filter \(name)")
        }
        rig.pane.setFilter(.waiting)
        rig.settle()
        let waiting = sections(rig.pane.showReport())
        XCTAssertEqual(waiting.compactMap { $0["id"] as? String }, ["waiting-on-you"])
        XCTAssertEqual(items(rig.pane.showReport(), section: "waiting-on-you").count, script.itemIDs(status: "needs-you").count)
    }

    func testShowReportsTheRenderProbeThePaneKeeps() throws {
        let (rig, script) = try goldenRig()
        var report = rig.pane.showReport()
        XCTAssertEqual(report["render_generation"] as? Int, rig.pane.renderGeneration)
        XCTAssertEqual(report["rows_updated_last"] as? Int, rig.pane.rowsUpdatedLast)
        XCTAssertGreaterThan(rig.pane.renderGeneration, 0)

        var edited = script
        try edited.setStatus("verif-1037", "blocked")
        rig.push(edited)
        report = rig.pane.showReport()
        XCTAssertEqual(report["render_generation"] as? Int, rig.pane.renderGeneration)
        XCTAssertEqual(report["rows_updated_last"] as? Int, rig.pane.rowsUpdatedLast)
        XCTAssertLessThanOrEqual(report["rows_updated_last"] as? Int ?? 99, 2, "one item changed")
    }

    func testShowReportsAHeldDoneAndAMovedAndARemovedItemAsThePaneShowsThem() throws {
        let (rig, script) = try goldenRig()
        var edited = script
        try edited.setStatus("check-1000", "done")          // on screen: stays, struck through
        try edited.moveItem("verif-1037", toSection: "next")  // on screen: leaves a stub
        try edited.removeItem("revie-1111")                  // on screen: leaves a stub
        rig.push(edited)
        let report = rig.pane.showReport()
        let now = items(report, section: "now")

        let held = try XCTUnwrap(now.first { ($0["id"] as? String) == "check-1000" })
        XCTAssertEqual(held["status"] as? String, "done")
        XCTAssertEqual(held["held"] as? String, "done_in_place")
        XCTAssertEqual(held["folded"] as? Bool, false)
        XCTAssertTrue(rig.rowView("item:check-1000")?.isStrikethrough ?? false, "the row on screen is struck through")

        let moved = try XCTUnwrap(now.first { ($0["id"] as? String) == "verif-1037" })
        XCTAssertEqual(moved["stub"] as? String, "moved to Next")
        XCTAssertEqual(moved["held"] as? String, "moved")
        XCTAssertTrue(rig.rowView("item:verif-1037")?.visibleText.contains("moved to Next") ?? false)
        let arrived = try XCTUnwrap(items(report, section: "next").first { ($0["id"] as? String) == "verif-1037" })
        XCTAssertEqual(arrived["held"] as? String, "moving", "its new copy is already in the new section")
        XCTAssertTrue(arrived["stub"] is NSNull)

        let removed = try XCTUnwrap(now.first { ($0["id"] as? String) == "revie-1111" })
        XCTAssertEqual(removed["stub"] as? String, "removed")
        XCTAssertEqual(removed["held"] as? String, "removed")
        XCTAssertTrue(rig.rowView("item:revie-1111")?.visibleText.contains("removed") ?? false)
        assertValidJSON(report, "a report with held changes")
    }

    func testShowReportsALogWithItsShownAndTotalLines() throws {
        let (rig, _) = try goldenRig()
        var log = object(rig.pane.showReport()["log"], "log")
        XCTAssertEqual(log["title"] as? String, "Log")
        XCTAssertEqual(log["count"] as? Int, 12)
        XCTAssertEqual(log["shown"] as? Int, 5)
        XCTAssertEqual(log["expanded"] as? Bool, false)
        rig.pane.toggleLog()
        rig.settle()
        log = object(rig.pane.showReport()["log"], "log")
        XCTAssertEqual(log["shown"] as? Int, 12)
        XCTAssertEqual(log["expanded"] as? Bool, true)
    }

    func testBeforeAnyBoardShowSaysItIsWaiting() throws {
        let rig = Fx.makeRig(self)
        let report = rig.pane.showReport()
        XCTAssertEqual(report["waiting"] as? Bool, true)
        XCTAssertEqual(report["tag"] as? String, rig.tag)
        XCTAssertTrue(report["title"] is NSNull)
        XCTAssertTrue(report["path"] is NSNull)
        XCTAssertEqual(sections(report).count, 0)
        XCTAssertEqual(object(report["strip"], "strip")["count"] as? Int, 0)
        XCTAssertEqual(list(report["banners"], "banners").count, 0)
        assertValidJSON(report, "the waiting report")
    }

    func testShowWithNoPresentationReportsWaiting() {
        let report = AppControlTracker.show(tag: "kate", presentation: nil, displayedRows: nil, visible: false)
        XCTAssertEqual(report["waiting"] as? Bool, true)
        XCTAssertEqual(report["visible"] as? Bool, false)
        XCTAssertEqual(report["tag"] as? String, "kate")
        XCTAssertEqual(report["filter"] as? String, "all")
        assertValidJSON(report, "the waiting report")
    }

    func testShowForABoardNoPaneIsShowingReportsWhatItWouldShowAsNotVisible() throws {
        let tag = Fx.uniqueTag()
        let script = try TrackerBoardScript(tag: tag)
        let presentation = TrackerPresenter.present(board: try script.decodedBoard(), now: Fx.now, timeZone: Fx.utc)
        let report = AppControlTracker.show(tag: tag, presentation: presentation, displayedRows: nil, visible: false)
        XCTAssertEqual(report["visible"] as? Bool, false)
        XCTAssertEqual(report["waiting"] as? Bool, false)
        XCTAssertEqual(sections(report).count, 6)
        XCTAssertEqual(object(report["strip"], "strip")["count"] as? Int, 10)
        assertValidJSON(report, "the report")
    }

    func testTheReportsOfEveryScenarioAreValidJSON() throws {
        let (rig, script) = try goldenRig()
        assertValidJSON(rig.pane.showReport(), "golden")
        var edited = script
        edited.setBanner(["type": "missing"])
        try edited.setStatus("check-1000", "done")
        rig.push(edited)
        assertValidJSON(rig.pane.showReport(), "with a banner and a held item")
        rig.pane.setFilter(.done)
        assertValidJSON(rig.pane.showReport(), "under the Done filter")
    }

    // MARK: - tracker file

    private func temporaryFile(_ contents: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-probe-\(UUID().uuidString).md")
        try contents.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func testFileReportsThePathAndTheSizeOnDisk() throws {
        let tag = Fx.uniqueTag()
        let board = try TrackerBoardScript(tag: tag).decodedBoard()
        let bytes = try Fx.fixtureData("board-60.md")
        let path = try temporaryFile(bytes)
        let size = try XCTUnwrap(AppControlTracker.fileSize(atPath: path))
        XCTAssertEqual(size, bytes.count)

        let report = AppControlTracker.file(tag: tag, board: board, fileSize: size)
        XCTAssertEqual(report["tag"] as? String, tag)
        XCTAssertEqual(report["path"] as? String, board.path)
        XCTAssertEqual(report["exists"] as? Bool, true)
        XCTAssertEqual(report["size"] as? Int, bytes.count)
        XCTAssertEqual(report["committable"] as? Bool, false)
        XCTAssertTrue(report["remote"] is NSNull)
        XCTAssertTrue(report["banner"] is NSNull)
        assertValidJSON(report, "the file report")
    }

    func testFileReportsWhetherACommitWouldPickTheBoardUpAndTheRemote() throws {
        let tag = Fx.uniqueTag()
        var script = try TrackerBoardScript(tag: tag)
        script.setCommittable(remote: "github.com/example/repo")
        var report = AppControlTracker.file(tag: tag, board: try script.decodedBoard(), fileSize: 100)
        XCTAssertEqual(report["committable"] as? Bool, true)
        XCTAssertEqual(report["remote"] as? String, "github.com/example/repo")

        script.setCommittable(remote: nil)
        report = AppControlTracker.file(tag: tag, board: try script.decodedBoard(), fileSize: 100)
        XCTAssertEqual(report["committable"] as? Bool, true, "committable without a known remote")
        XCTAssertTrue(report["remote"] is NSNull)
        assertValidJSON(report, "the file report")
    }

    func testFileReportsAMissingOrUnreadableFile() throws {
        let tag = Fx.uniqueTag()
        let board = try TrackerBoardScript(tag: tag).decodedBoard()
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-probe-missing-\(UUID().uuidString).md").path
        XCTAssertNil(AppControlTracker.fileSize(atPath: gone))
        XCTAssertNil(AppControlTracker.fileSize(atPath: NSTemporaryDirectory()), "a directory is not a board file")

        let report = AppControlTracker.file(tag: tag, board: board, fileSize: AppControlTracker.fileSize(atPath: gone))
        XCTAssertEqual(report["exists"] as? Bool, false)
        XCTAssertTrue(report["size"] is NSNull)
        XCTAssertEqual(report["path"] as? String, board.path, "the path is still the board's")

        var unreadable = try TrackerBoardScript(tag: tag)
        unreadable.setBanner(["type": "unreadable", "line": 3, "reason": "garbled_marker"])
        XCTAssertEqual(AppControlTracker.file(tag: tag, board: try unreadable.decodedBoard(), fileSize: 10)["banner"] as? String, "unreadable")
        var missing = try TrackerBoardScript(tag: tag)
        missing.setBanner(["type": "missing"])
        XCTAssertEqual(AppControlTracker.file(tag: tag, board: try missing.decodedBoard(), fileSize: nil)["banner"] as? String, "missing")
    }

    func testFileForAFocusWithNoBoardSaysSo() {
        let report = AppControlTracker.file(tag: "kate", board: nil, fileSize: nil)
        XCTAssertEqual(report["tag"] as? String, "kate")
        XCTAssertTrue(report["path"] is NSNull)
        XCTAssertEqual(report["exists"] as? Bool, false)
        XCTAssertEqual(report["committable"] as? Bool, false)
        XCTAssertTrue(report["remote"] is NSNull)
        XCTAssertTrue(report["size"] is NSNull)
        assertValidJSON(report, "the file report")
    }

    // MARK: - tracker-anchor

    func testAnchorReportsTheFirstVisibleRowItsOffsetAndTheScrollGeometry() throws {
        let (rig, _) = try goldenRig()
        let target = try XCTUnwrap(rig.pane.rowViews["item:rotat-1370"])
        rig.scroll(to: target.frame.minY + 7)

        let snapshot = rig.pane.anchorSnapshot(windowIndex: 3)
        let clip = rig.pane.clipView.bounds
        XCTAssertEqual(snapshot.tag, rig.tag)
        XCTAssertEqual(snapshot.window, 3)
        let first = try XCTUnwrap(snapshot.firstVisible)
        let expectedKey = rig.pane.displayedRows.map(\.key).first { key in
            guard let frame = rig.pane.rowViews[key]?.frame else { return false }
            return frame.maxY > clip.minY && frame.height > 0
        }
        XCTAssertEqual(first.rowKey, expectedKey)
        XCTAssertEqual(first.rowKey, "item:rotat-1370")
        XCTAssertEqual(first.offsetPt, 7, accuracy: 0.6, "the viewport top is 7 pt into that row")
        XCTAssertEqual(snapshot.scrollY, Double(clip.minY), accuracy: 0.01)
        XCTAssertEqual(snapshot.documentHeight, Double(rig.pane.documentView.frame.height), accuracy: 0.01)
        XCTAssertEqual(snapshot.viewportHeight, Double(clip.height), accuracy: 0.01)
        XCTAssertGreaterThan(snapshot.documentHeight, snapshot.viewportHeight, "the board is longer than the pane")
        XCTAssertFalse(snapshot.deferredPending)
        XCTAssertEqual(snapshot.pending, [])
    }

    func testAnchorAtTheTopNamesTheFirstRowWithNoOffset() throws {
        let (rig, _) = try goldenRig()
        let snapshot = rig.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertEqual(snapshot.firstVisible?.rowKey, rig.pane.displayedRows.first?.key)
        XCTAssertEqual(snapshot.firstVisible?.offsetPt ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(snapshot.scrollY, 0, accuracy: 0.01)
    }

    func testAnchorReportsAChangeHeldBackBecauseItsRowIsOnScreen() throws {
        let (rig, script) = try goldenRig()
        XCTAssertTrue(rig.pane.visibleKeys().contains("item:check-1000"), "the item is on screen")
        var edited = script
        try edited.setStatus("check-1000", "done")
        rig.push(edited)

        let snapshot = rig.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertTrue(snapshot.deferredPending)
        XCTAssertEqual(snapshot.pending, [TrackerAnchorSnapshot.Pending(key: "item:check-1000", kind: "done_in_place")])
    }

    func testAnchorForAnEmptyPaneEncodesFirstVisibleAsNullNotAbsent() throws {
        let rig = Fx.makeRig(self)
        let snapshot = rig.pane.anchorSnapshot(windowIndex: 1)
        XCTAssertNil(snapshot.firstVisible)
        XCTAssertEqual(snapshot.window, 1)
        XCTAssertEqual(snapshot.tag, rig.tag)
        XCTAssertFalse(snapshot.deferredPending)
        XCTAssertEqual(snapshot.pending, [])

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? Obj)
        XCTAssertTrue(object.keys.contains("firstVisible"), "the key is there, so a script can tell 'empty' from 'unknown field'")
        XCTAssertTrue(object["firstVisible"] is NSNull)
        for key in ["tag", "window", "scrollY", "documentHeight", "viewportHeight", "deferredPending", "pending"] {
            XCTAssertTrue(object.keys.contains(key), "\(key) is in the JSON")
        }
    }

    func testAnchorEncodesAsJSONWithTheRowKeyAndOffset() throws {
        let (rig, _) = try goldenRig()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rig.pane.anchorSnapshot(windowIndex: 0))) as? Obj)
        let first = self.object(object["firstVisible"], "firstVisible")
        XCTAssertEqual(first["rowKey"] as? String, rig.pane.displayedRows.first?.key)
        XCTAssertNotNil(first["offsetPt"] as? Double)
        XCTAssertEqual((object["pending"] as? [Obj])?.count, 0)
    }

    // The pure geometry behind it.

    private func rows(_ spans: [(String, CGFloat, CGFloat)]) -> [(key: String, frame: CGRect)] {
        spans.map { (key: $0.0, frame: CGRect(x: 0, y: $0.1, width: 300, height: $0.2)) }
    }

    func testProbeNamesTheRowAtTheTopOfTheViewportAndHowFarIntoItTheViewportIs() {
        let layout = rows([("a", 0, 40), ("b", 40, 60), ("c", 100, 60)])
        let snapshot = TrackerAnchorProbe.snapshot(tag: "kate", window: 2, clipBounds: CGRect(x: 0, y: 50, width: 300, height: 60),
                                                   documentHeight: 160, rows: layout, held: [])
        XCTAssertEqual(snapshot.firstVisible, TrackerAnchorSnapshot.FirstVisible(rowKey: "b", offsetPt: 10))
        XCTAssertEqual(snapshot.scrollY, 50)
        XCTAssertEqual(snapshot.documentHeight, 160)
        XCTAssertEqual(snapshot.viewportHeight, 60)
        XCTAssertEqual(snapshot.window, 2)
        XCTAssertFalse(snapshot.deferredPending)
    }

    func testProbeAtARowBoundaryNamesThatRowAtOffsetZero() {
        let layout = rows([("a", 0, 40), ("b", 40, 60)])
        let snapshot = TrackerAnchorProbe.snapshot(tag: "kate", window: 0, clipBounds: CGRect(x: 0, y: 40, width: 300, height: 50),
                                                   documentHeight: 100, rows: layout, held: [])
        XCTAssertEqual(snapshot.firstVisible?.rowKey, "b")
        XCTAssertEqual(snapshot.firstVisible?.offsetPt ?? -1, 0, accuracy: 0.001)
    }

    func testProbeWithNoRowInTheViewportHasNoFirstVisibleRow() {
        let layout = rows([("a", 0, 40)])
        XCTAssertNil(TrackerAnchorProbe.snapshot(tag: "k", window: 0, clipBounds: CGRect(x: 0, y: 500, width: 300, height: 50),
                                                 documentHeight: 40, rows: layout, held: []).firstVisible)
        XCTAssertNil(TrackerAnchorProbe.snapshot(tag: "k", window: 0, clipBounds: CGRect(x: 0, y: 0, width: 300, height: 50),
                                                 documentHeight: 0, rows: [], held: []).firstVisible)
    }

    func testProbeSkipsRowsWithNoHeightAndNeverReportsANegativeOffset() {
        let layout = rows([("empty", 0, 0), ("a", 0, 40)])
        var snapshot = TrackerAnchorProbe.snapshot(tag: "k", window: 0, clipBounds: CGRect(x: 0, y: 0, width: 300, height: 50),
                                                   documentHeight: 40, rows: layout, held: [])
        XCTAssertEqual(snapshot.firstVisible?.rowKey, "a")

        // Rubber-banding above the top: the viewport is above the first row.
        snapshot = TrackerAnchorProbe.snapshot(tag: "k", window: 0, clipBounds: CGRect(x: 0, y: -20, width: 300, height: 50),
                                               documentHeight: 40, rows: layout, held: [])
        XCTAssertEqual(snapshot.firstVisible?.rowKey, "a")
        XCTAssertEqual(snapshot.firstVisible?.offsetPt ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.scrollY, -20)
    }
}
