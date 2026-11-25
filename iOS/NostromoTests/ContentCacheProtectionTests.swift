// L5: needs iOS file attributes in the app process: the content cache file must carry the
// `complete` data-protection class and be excluded from backup, and wiping it must remove the file.

import XCTest
import NostromoKit

final class ContentCacheProtectionTests: XCTestCase {

    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("l5-cache-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("content-cache.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        super.tearDown()
    }

    private func writtenCache() -> ContentCache {
        let cache = ContentCache(url: url, debounce: 60)
        cache.record(host: nil, raw: Data(#"{"type":"mother_jobs","jobs":[]}"#.utf8))
        cache.flush()
        return cache
    }

    func testTheCacheFileHasTheCompleteProtectionClass() throws {
        _ = writtenCache()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
    }

    func testTheCacheFileIsExcludedFromBackup() throws {
        _ = writtenCache()
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testWipeRemovesTheFile() {
        let cache = writtenCache()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        cache.wipe()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
