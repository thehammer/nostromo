import XCTest
import Darwin

// MemorySummary (and TranscriptDiagnostics, which it reads the footprint from) is compiled into
// this test target directly (logic test, no host app).

/// What `MemorySummary.capture()` costs in a process shaped like the 2026-10-25 incident: ten
/// thousand VM regions and millions of live malloc blocks.
///
/// `capture()` runs inside the memory watchdog, which runs when the app is already in trouble, and
/// its header promises "well under ten milliseconds" for the region walk. The incident heap had 16
/// million live blocks; if `malloc_zone_statistics` or the region walk scales badly with that, the
/// diagnostic that is meant to explain a bloated heap would freeze the app that holds it. The
/// bound here is deliberately generous (an order of magnitude over what a healthy machine does):
/// it is there to catch a walk that turns out to cost seconds, not to police milliseconds.
///
/// The synthetic address space is real, not mocked: anonymous pages in an alternating
/// read-write / no-access pattern (adjacent regions with different protection never coalesce, so
/// each is its own VM region), and a couple of million small malloc blocks kept alive. Everything
/// is released when the test ends.
final class MemorySummaryCostTests: XCTestCase {

    /// Read-write pages, each followed by a no-access guard page: twice this many VM regions.
    private static let mappedPages = 5_000
    private static let liveBlocks = 2_000_000
    /// `VM_MEMORY_APPLICATION_SPECIFIC_1`, so the synthetic pages show up under their own category.
    private static let syntheticTag: UInt32 = 240

    private static let medianBoundMs = 250.0
    private static let maxBoundMs = 1_000.0
    private static let timedRuns = 5

    /// The synthetic process state. `release()` is idempotent; `deinit` calls it too.
    private final class SyntheticAddressSpace {
        let pageSize = Int(getpagesize())
        private(set) var region: UnsafeMutableRawPointer?
        private(set) var regionLength = 0
        private var blocks: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
        private(set) var blockCount = 0
        /// Bytes of read-write pages that were written, so are dirty.
        private(set) var touchedBytes = 0

        init(mappedPages: Int, liveBlocks: Int) throws {
            // A failed init never runs `deinit`: undo whatever was built before rethrowing.
            do {
                try build(mappedPages: mappedPages, liveBlocks: liveBlocks)
            } catch {
                release()
                throw error
            }
        }

        private func build(mappedPages: Int, liveBlocks: Int) throws {
            // Regions: page 2i is read-write and written; page 2i+1 is a no-access guard.
            let length = mappedPages * 2 * pageSize
            let tag = Int32(bitPattern: UInt32(MemorySummaryCostTests.syntheticTag) << 24)
            let failed = UnsafeMutableRawPointer(bitPattern: -1)
            guard let base = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, tag, 0),
                  base != failed else {
                throw SyntheticFailure.mmap(errno)
            }
            region = base
            regionLength = length
            for page in 0 ..< mappedPages {
                base.advanced(by: page * 2 * pageSize).storeBytes(of: 1, as: UInt8.self)
                touchedBytes += pageSize
                if mprotect(base.advanced(by: (page * 2 + 1) * pageSize), pageSize, PROT_NONE) != 0 {
                    throw SyntheticFailure.mprotect(errno)
                }
            }

            // 64...128 bytes, the size of a small Swift object or dictionary node.
            let table = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: liveBlocks)
            table.initialize(repeating: nil, count: liveBlocks)
            blocks = table
            for i in 0 ..< liveBlocks {
                guard let block = malloc(64 + (i % 5) * 16) else { throw SyntheticFailure.malloc }
                block.storeBytes(of: UInt8(truncatingIfNeeded: i), as: UInt8.self)
                table[i] = block
                blockCount += 1
            }
        }

        func release() {
            if let table = blocks {
                for i in 0 ..< blockCount { free(table[i]) }
                table.deallocate()
                blocks = nil
                blockCount = 0
            }
            if let base = region {
                munmap(base, regionLength)
                region = nil
            }
        }

        deinit { release() }
    }

    private enum SyntheticFailure: Error {
        case mmap(Int32), mprotect(Int32), malloc
    }

    private static func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    // MARK: - Tests

    func testCapturingASummaryOfAHugeAddressSpaceStaysCheap() throws {
        let space: SyntheticAddressSpace
        do {
            space = try SyntheticAddressSpace(mappedPages: Self.mappedPages, liveBlocks: Self.liveBlocks)
        } catch {
            return XCTFail("could not build the synthetic address space: \(error)")
        }
        defer { space.release() }
        addTeardownBlock { space.release() }

        // The synthetic state is real, or this test says nothing about cost.
        let sanity = MemorySummary.capture(limit: 1_000)
        XCTAssertGreaterThanOrEqual(sanity.mallocBlocksInUse, 1_500_000,
                                    "the synthetic heap did not register: \(sanity.oneLine)")
        XCTAssertFalse(sanity.categories.isEmpty, "capture found no dirty VM categories at all")
        let synthetic = sanity.categories.first { $0.name == "VM tag \(Self.syntheticTag)" }
        XCTAssertGreaterThanOrEqual(synthetic?.dirtyBytes ?? 0, space.touchedBytes / 2,
                                    "the \(Self.mappedPages) touched pages were not reported as dirty")

        // One warm-up so first-touch costs of the code and its tables are not counted, then timed runs.
        var last = MemorySummary.capture()
        var samples: [Double] = []
        for _ in 0 ..< Self.timedRuns {
            samples.append(Self.milliseconds { last = MemorySummary.capture() })
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let worst = sorted[sorted.count - 1]

        let report = String(format: "median %.1f ms, max %.1f ms over %ld runs (%@); "
                                    + "%ld mapped pages (%ld regions), %ld live blocks",
                            median, worst, Self.timedRuns,
                            samples.map { String(format: "%.1f", $0) }.joined(separator: ", "),
                            Self.mappedPages, Self.mappedPages * 2, last.mallocBlocksInUse)
        print("MEMORY-CAPTURE-COST \(report)")

        XCTAssertGreaterThanOrEqual(last.mallocBlocksInUse, 1_500_000, "capture() missed the synthetic heap: \(report)")
        XCTAssertFalse(last.categories.isEmpty, report)
        XCTAssertLessThan(median, Self.medianBoundMs, "MemorySummary.capture() is too slow: \(report)")
        XCTAssertLessThan(worst, Self.maxBoundMs, "MemorySummary.capture() has a slow outlier: \(report)")
    }
}
