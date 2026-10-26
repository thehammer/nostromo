import XCTest
import Darwin

// MemorySummary is compiled into this target directly (logic test, no host app).

/// Behavioural tests for `MemorySummary`: a cheap, content-free answer to "where is the memory?".
///
/// The incident this exists for: the app's footprint sat at about 1.8 GB for hours while every
/// transcript-level counter said the transcript was small (sixteen million malloc blocks, 1.7 GB
/// of them in the malloc "small" zone, and nothing in the diagnostics that said so). The only way
/// to find that out was to run `heap` by hand, which takes minutes and stops the app. `MemorySummary`
/// is the in-process, millisecond answer: the physical footprint, what malloc itself says is in
/// use, and the largest dirty VM categories by name.
///
/// It is read in three places (the watchdog's toast, the pane-blank capture, the transcript
/// diagnostics), so what is tested here is the contract those readers rely on:
///
///  1. The aggregation is right: dirty bytes are summed per VM tag, largest first, ties broken by
///     name, empty categories dropped, at most `limit` of them.
///  2. Tags have stable, human names (and an unknown tag still has one).
///  3. `capture()` on a real process returns real numbers, and notices memory this test allocates.
///  4. The JSON form has exactly the documented keys and nothing that is free text.
///  5. The one-line form carries the footprint, the malloc figures and the largest categories.
final class MemorySummaryTests: XCTestCase {

    private static let mb = 1_048_576

    private func region(_ tag: Int32, _ dirty: Int) -> MemorySummary.Region {
        MemorySummary.Region(tag: UInt32(tag), dirtyBytes: dirty)
    }

    // MARK: - Aggregation (pure)

    func testDirtyBytesAreSummedPerVMTagAndSortedLargestFirst() {
        let regions = [
            region(VM_MEMORY_MALLOC_SMALL, 100),
            region(VM_MEMORY_MALLOC_LARGE, 300),
            region(VM_MEMORY_MALLOC_SMALL, 250),     // second Malloc Small region: summed with the first
            region(VM_MEMORY_MALLOC_TINY, 50),
        ]

        let categories = MemorySummary.categories(from: regions, limit: 10)

        XCTAssertEqual(categories.map(\.name), ["Malloc Small", "Malloc Large", "Malloc Tiny"],
                       "350, 300, 50: largest dirty first")
        XCTAssertEqual(categories.map(\.dirtyBytes), [350, 300, 50])
    }

    func testEqualCategoriesAreOrderedByName() {
        let regions = [
            region(VM_MEMORY_MALLOC_SMALL, 200),
            region(VM_MEMORY_MALLOC_LARGE, 200),
            region(VM_MEMORY_MALLOC_TINY, 200),
        ]

        let categories = MemorySummary.categories(from: regions, limit: 10)

        XCTAssertEqual(categories.map(\.name), ["Malloc Large", "Malloc Small", "Malloc Tiny"],
                       "ties break by name so the report is stable from one capture to the next")
        // And the order does not depend on the order the regions arrived in.
        XCTAssertEqual(MemorySummary.categories(from: Array(regions.reversed()), limit: 10), categories)
    }

    func testCategoriesWithNoDirtyBytesAreDropped() {
        let regions = [
            region(VM_MEMORY_MALLOC_SMALL, 10),
            region(VM_MEMORY_MALLOC_LARGE, 0),
            region(VM_MEMORY_MALLOC_TINY, 0),
            region(VM_MEMORY_MALLOC_TINY, 0),
        ]

        let categories = MemorySummary.categories(from: regions, limit: 10)

        XCTAssertEqual(categories.map(\.name), ["Malloc Small"],
                       "a clean mapping is not memory the app is holding")
    }

    func testAtMostLimitCategoriesAreReturnedAndTheyAreTheLargest() {
        let regions = [
            region(VM_MEMORY_MALLOC_SMALL, 500),
            region(VM_MEMORY_MALLOC_LARGE, 400),
            region(VM_MEMORY_MALLOC_TINY, 300),
            region(VM_MEMORY_STACK, 200),
            region(VM_MEMORY_GUARD, 100),
        ]

        XCTAssertEqual(MemorySummary.categories(from: regions, limit: 2).map(\.name),
                       ["Malloc Small", "Malloc Large"])
        XCTAssertEqual(MemorySummary.categories(from: regions, limit: 1).count, 1)
        XCTAssertEqual(MemorySummary.categories(from: regions, limit: 5).count, 5)
        XCTAssertEqual(MemorySummary.categories(from: regions, limit: 50).count, 5,
                       "a limit above the number of categories returns them all")
        XCTAssertTrue(MemorySummary.categories(from: regions, limit: 0).isEmpty)
    }

    func testNoRegionsMeansNoCategories() {
        XCTAssertTrue(MemorySummary.categories(from: [], limit: 5).isEmpty)
    }

    func testRegionsWithTheSameUnknownTagAreOneCategory() {
        let unknown: Int32 = 9_999
        let categories = MemorySummary.categories(
            from: [region(unknown, 70), region(unknown, 30), region(VM_MEMORY_MALLOC_SMALL, 80)], limit: 10)

        XCTAssertEqual(categories.map(\.name), ["VM tag 9999", "Malloc Small"])
        XCTAssertEqual(categories.map(\.dirtyBytes), [100, 80])
    }

    // MARK: - Names

    func testMallocTagsHaveHumanNames() {
        XCTAssertEqual(MemorySummary.categoryName(forVMTag: UInt32(VM_MEMORY_MALLOC_SMALL)), "Malloc Small")
        XCTAssertEqual(MemorySummary.categoryName(forVMTag: UInt32(VM_MEMORY_MALLOC_LARGE)), "Malloc Large")
        XCTAssertEqual(MemorySummary.categoryName(forVMTag: UInt32(VM_MEMORY_MALLOC_TINY)), "Malloc Tiny")
    }

    func testAnUnknownTagIsNamedByItsNumber() {
        XCTAssertEqual(MemorySummary.categoryName(forVMTag: 9_999), "VM tag 9999")
        XCTAssertEqual(MemorySummary.categoryName(forVMTag: 254), "VM tag 254")
    }

    // MARK: - capture() on this process

    func testCaptureOfARunningProcessReturnsRealNumbers() {
        let summary = MemorySummary.capture()

        XCTAssertGreaterThan(summary.physicalFootprintBytes, 0)
        XCTAssertGreaterThan(summary.mallocBlocksInUse, 0)
        XCTAssertGreaterThan(summary.mallocBytesInUse, 0)
        XCTAssertFalse(summary.categories.isEmpty, "a running test process has dirty memory")
        XCTAssertLessThanOrEqual(summary.categories.count, 5, "the default limit is five")
        XCTAssertTrue(summary.categories.allSatisfy { $0.dirtyBytes > 0 }, "empty categories are never reported")
        XCTAssertTrue(summary.categories.allSatisfy { !$0.name.isEmpty })
    }

    func testCaptureReportsCategoriesLargestFirst() {
        let sizes = MemorySummary.capture(limit: 100).categories.map(\.dirtyBytes)
        XCTAssertEqual(sizes, sizes.sorted(by: >), "largest dirty first")
    }

    func testCaptureHonoursItsLimit() {
        XCTAssertLessThanOrEqual(MemorySummary.capture(limit: 2).categories.count, 2)
        XCTAssertEqual(MemorySummary.capture(limit: 1).categories.count, 1)
    }

    /// Every Swift process allocates through malloc, so a capture with room for every category
    /// must name at least one malloc zone. (Asked with a large limit: whether malloc is in the top
    /// five depends on what else the test host has mapped.)
    func testCaptureNamesTheMallocCategoriesOfTheProcess() {
        let names = MemorySummary.capture(limit: 200).categories.map(\.name)
        XCTAssertTrue(names.contains { $0.hasPrefix("Malloc") },
                      "no Malloc category among \(names)")
    }

    /// The point of the type: it sees small-block malloc growth, the incident's shape. Twenty
    /// thousand live 1 KB blocks must show up as at least fifteen thousand more blocks in use
    /// (the slack is for other threads allocating and freeing during the test, not for the
    /// implementation to under-count).
    func testCaptureSeesLiveMallocBlocksThisTestAllocates() {
        let count = 20_000
        let size = 1_024
        let before = MemorySummary.capture().mallocBlocksInUse
        let bytesBefore = MemorySummary.capture().mallocBytesInUse

        var blocks: [UnsafeMutableRawPointer] = []
        blocks.reserveCapacity(count)
        defer { blocks.forEach { free($0) } }
        for _ in 0 ..< count {
            guard let block = malloc(size) else { return XCTFail("malloc failed") }
            memset(block, 0xA5, size)       // dirty it: an untouched block is not memory held
            blocks.append(block)
        }

        let after = MemorySummary.capture()
        XCTAssertGreaterThanOrEqual(after.mallocBlocksInUse - before, 15_000,
                                    "20,000 live blocks must be visible in mallocBlocksInUse")
        XCTAssertGreaterThanOrEqual(after.mallocBytesInUse - bytesBefore, 15_000 * size,
                                    "and in mallocBytesInUse")
    }

    // MARK: - jsonObject

    /// A summary with known, distinguishable numbers, so the JSON's values are assertable.
    private let sample = MemorySummary(
        physicalFootprintBytes: 1_797 * MemorySummaryTests.mb,
        mallocBlocksInUse: 16_046_602,
        mallocBytesInUse: 1_585 * MemorySummaryTests.mb,
        categories: [MemorySummary.Category(name: "Malloc Small", dirtyBytes: 1_678 * MemorySummaryTests.mb),
                     MemorySummary.Category(name: "Malloc Large", dirtyBytes: 39 * MemorySummaryTests.mb)])

    func testTheJSONFormHasExactlyTheDocumentedKeys() throws {
        let json = sample.jsonObject

        XCTAssertEqual(Set(json.keys),
                       ["physicalFootprintBytes", "mallocBlocksInUse", "mallocBytesInUse", "categories"])
        XCTAssertEqual(json["physicalFootprintBytes"] as? Int, 1_797 * Self.mb)
        XCTAssertEqual(json["mallocBlocksInUse"] as? Int, 16_046_602)
        XCTAssertEqual(json["mallocBytesInUse"] as? Int, 1_585 * Self.mb)

        let categories = try XCTUnwrap(json["categories"] as? [[String: Any]])
        XCTAssertEqual(categories.count, 2)
        for category in categories {
            XCTAssertEqual(Set(category.keys), ["name", "dirtyBytes"])
        }
        XCTAssertEqual(categories[0]["name"] as? String, "Malloc Small")
        XCTAssertEqual(categories[0]["dirtyBytes"] as? Int, 1_678 * Self.mb)
        XCTAssertEqual(categories[1]["name"] as? String, "Malloc Large")
    }

    func testTheJSONFormIsSerialisable() throws {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(sample.jsonObject))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(MemorySummary.capture().jsonObject),
                      "a live capture must serialise too: no NaN, no non-JSON types")

        let data = try JSONSerialization.data(withJSONObject: MemorySummary.capture().jsonObject)
        let roundTripped = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(roundTripped.keys),
                       ["physicalFootprintBytes", "mallocBlocksInUse", "mallocBytesInUse", "categories"])
    }

    /// Content-free: the only strings anywhere in the JSON are category names, and those come from
    /// a fixed vocabulary (a Malloc zone, a named VM tag, or "VM tag <n>"), never from anything the user, the OS
    /// or a file named.
    func testTheJSONFormHoldsNoFreeText() throws {
        let json = MemorySummary.capture(limit: 200).jsonObject
        let categories = try XCTUnwrap(json["categories"] as? [[String: Any]])
        for category in categories {
            let name = try XCTUnwrap(category["name"] as? String)
            XCTAssertFalse(name.isEmpty)
            XCTAssertLessThan(name.count, 40, "a category name is a short fixed label, not free text: '\(name)'")
            XCTAssertFalse(name.contains("\n"), "'\(name)'")
            XCTAssertFalse(name.contains("/"), "a path must never reach the summary: '\(name)'")
        }
        for (key, value) in json where key != "categories" {
            XCTAssertTrue(value is Int || value is NSNumber, "\(key) must be a number")
        }
    }

    // MARK: - oneLine

    func testTheOneLineFormCarriesTheFootprintTheMallocFiguresAndTheLargestCategories() {
        let line = sample.oneLine

        XCTAssertTrue(line.contains("footprint 1797 MB"), line)
        XCTAssertTrue(line.contains("16046602 malloc blocks (1585 MB)"), line)
        XCTAssertTrue(line.contains("largest: Malloc Small 1678 MB, Malloc Large 39 MB"), line)
        XCTAssertFalse(line.contains("\n"), "one line means one line")
    }

    func testTheOneLineFormListsCategoriesLargestFirstInTheOrderGiven() throws {
        let line = sample.oneLine
        let small = try XCTUnwrap(line.range(of: "Malloc Small"))
        let large = try XCTUnwrap(line.range(of: "Malloc Large"))
        XCTAssertLessThan(small.lowerBound, large.lowerBound)
    }

    func testTheOneLineFormOfAnEmptySummaryDoesNotCrashAndStillStatesTheFootprint() {
        let empty = MemorySummary(physicalFootprintBytes: 5 * Self.mb, mallocBlocksInUse: 0,
                                  mallocBytesInUse: 0, categories: [])
        XCTAssertTrue(empty.oneLine.contains("footprint 5 MB"), empty.oneLine)
        XCTAssertFalse(empty.oneLine.contains("\n"))
    }

    func testTheOneLineFormOfALiveCaptureIsNonEmptyAndNamesTheFootprint() {
        let line = MemorySummary.capture().oneLine
        XCTAssertTrue(line.hasPrefix("footprint "), line)
        XCTAssertTrue(line.contains("malloc blocks"), line)
    }
}
