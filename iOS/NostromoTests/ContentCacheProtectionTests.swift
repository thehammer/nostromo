// L5: needs the iOS build of NostromoKit and iOS file attributes in the app process: the content
// cache must be written with the `complete` data-protection class (the iOS-only branch of its write
// options), the file must be excluded from backup, and wiping it must remove the file. The Simulator
// does not report a protection class back, so the class itself is asserted only where the platform
// reports one (a device); on the Simulator the write options are the evidence.

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

    func testTheIOSBuildWritesTheCacheWithTheCompleteProtectionClass() throws {
        XCTAssertTrue(ContentCache.writeOptions.contains(.completeFileProtection))
        XCTAssertTrue(ContentCache.writeOptions.contains(.atomic))
        _ = writtenCache()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let reported = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(reported, .complete, "a platform that reports a class must report `complete`")
        }
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
