import XCTest

/// A fitness function, not a unit test.
///
/// The PRD states a forward-looking constraint: *"If a turn ever displays an
/// image inline, decoded bitmaps are sized to display size rather than source
/// size… Stated now so the eventual inline-image feature cannot reintroduce this
/// bug."* A constraint nothing checks is a comment. This checks it.
///
/// The transcript renders no images today — the input tray was the only decode
/// site, and it decoded 4K screenshots at full resolution to fill 36×36 chips.
/// That is now routed through `ThumbnailLoader`, which decodes to display size
/// via ImageIO and never instantiates a full-size bitmap. This test fails if any
/// chat-surface source reintroduces a full-resolution decode.
final class ImageDecodePolicyTests: XCTestCase {

    /// Initialisers that decode at the source's own resolution.
    private static let bannedPatterns = [
        "NSImage(contentsOf:",
        "NSImage(contentsOfFile:",
        "NSImage(byReferencing:",
        "NSImage(byReferencingFile:",
        "NSImage(data:",
    ]

    /// `ThumbnailLoader` is the sanctioned decode site. `NSImage(cgImage:size:)`
    /// — which wraps an already-sized bitmap — is not banned and does not appear
    /// in the list above.
    private static let allowedFiles: Set<String> = ["ThumbnailLoader.swift"]

    /// ## Floors, because a scan that reads nothing satisfies every rule
    ///
    /// `swiftFiles(under:)` used to answer `[]` for a root it could not read, and
    /// the policy then reported "no offenders" having opened no files — the same
    /// vacuous pass this check exists to remove. The root stops resolving whenever
    /// this test file moves, `UI/` or `Data/` is renamed, or the target is built
    /// from a different layout.
    ///
    /// Note what a nil-enumerator check alone would have missed:
    /// `FileManager.enumerator(at:)` returns a **non-nil** enumerator for a
    /// directory that does not exist and simply yields nothing (verified, not
    /// assumed). So "throw when the enumerator is nil" never fires on the failure
    /// it was meant to catch. The floors below are what actually catch it, and
    /// they exist to say the thing out loud: **an empty or near-empty scan is a
    /// broken test, not a clean codebase.**
    ///
    /// `UI/` holds 23 `.swift` files today and `Data/` 16. The floors sit well
    /// below both so they fire on "the root vanished" and stay quiet when the
    /// tree is merely reorganised or thinned — they are not a file census.
    private static let minimumSwiftFilesPerRoot = 8
    private static let minimumSwiftFilesAcrossRoots = 24

    /// The largest view in the chat surface. If the scan cannot see this file it
    /// is not looking at the app, whatever count it reports.
    private static let scanSentinel = "UI/Views/ReplView.swift"

    func testChatSurfacesDecodeImagesOnlyThroughThumbnailLoader() throws {
        var offenders: [String] = []
        for root in Self.policyRoots {
            for url in try Self.swiftFiles(under: root) {
                guard !Self.allowedFiles.contains(url.lastPathComponent) else { continue }
                let source = try String(contentsOf: url, encoding: .utf8)
                for (offset, line) in source.components(separatedBy: "\n").enumerated() {
                    for pattern in Self.bannedPatterns where line.contains(pattern) {
                        offenders.append("\(url.lastPathComponent):\(offset + 1): \(pattern)")
                    }
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            Full-resolution image decode outside ThumbnailLoader:

            \(offenders.joined(separator: "\n"))

            NSImage(contentsOf:) and friends decode at the source's resolution. A
            4K screenshot costs ~33 MB decoded; twenty of them blow a 60 MB
            budget on their own. Route the decode through ThumbnailLoader, which
            asks ImageIO for the display size and never materialises the full
            bitmap. If a new call site genuinely needs full resolution, add it to
            `allowedFiles` with a comment saying why it is bounded.
            """)
    }

    func testThumbnailLoaderIsPresentAndIsTheOnlyAllowedSite() throws {
        let loader = Self.sourceRoot
            .appendingPathComponent("Data/ThumbnailLoader.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: loader.path),
                      "ThumbnailLoader.swift is missing — the policy has nothing to point at.")
        let source = try String(contentsOf: loader, encoding: .utf8)
        XCTAssertTrue(source.contains("kCGImageSourceThumbnailMaxPixelSize"),
                      "ThumbnailLoader must bound the decode by max pixel size.")
        XCTAssertTrue(source.contains("kCGImageSourceCreateThumbnailFromImageAlways"),
                      """
                      ThumbnailLoader must always generate the thumbnail: an embedded \
                      EXIF thumbnail can be far larger than the requested size.
                      """)
    }

    /// The policy assertions above are only as good as the scan under them, and
    /// the scan is silent about its own reach. This states the reach: enough
    /// files to be the real tree, and one named file that must be in it.
    func testSourceScanActuallyFindsTheSources() throws {
        var scanned: [URL] = []
        for root in Self.policyRoots {
            scanned += try Self.swiftFiles(under: root)
        }

        XCTAssertGreaterThanOrEqual(scanned.count, Self.minimumSwiftFilesAcrossRoots, """
            The policy scan reached only \(scanned.count) Swift files under
            \(Self.sourceRoot.path). Every assertion in this class passes against
            an empty scan, so read this as a broken test rather than a clean
            codebase: check that #filePath still resolves into macOS/NostromoTests
            and that UI/ and Data/ are still where sourceRoot expects them.
            """)

        XCTAssertTrue(scanned.contains { $0.path.hasSuffix(Self.scanSentinel) }, """
            \(Self.scanSentinel) was not among the \(scanned.count) files scanned
            under \(Self.sourceRoot.path). A count alone can be met by the wrong
            directory tree; the sentinel is what pins the scan to the chat surface
            the policy is about. If the file was legitimately renamed, update
            `scanSentinel` to another file that cannot plausibly disappear.
            """)
    }

    // MARK: - Helpers

    /// Walks up from this file to `macOS/Nostromo`. Uses `#filePath` rather than
    /// a bundle resource because the test target has no host app and no bundle
    /// to carry sources in.
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/macOS/NostromoTests/ImageDecodePolicyTests.swift
            .deletingLastPathComponent()          // …/macOS/NostromoTests
            .deletingLastPathComponent()          // …/macOS
            .appendingPathComponent("Nostromo")
    }

    /// The two chat-surface trees the policy governs.
    private static var policyRoots: [URL] {
        [sourceRoot.appendingPathComponent("UI"),
         sourceRoot.appendingPathComponent("Data")]
    }

    /// Throws rather than returning a suspiciously short list, so the floor is
    /// inherited by every caller instead of depending on
    /// `testSourceScanActuallyFindsTheSources` happening to run first — XCTest
    /// gives no ordering guarantee, and a guarantee one test provides for the
    /// others is not a guarantee.
    private static func swiftFiles(under root: URL) throws -> [URL] {
        // The existence check is not redundant with the nil check below: a
        // missing directory yields a non-nil enumerator over nothing, so nil is
        // the rare failure and this is the likely one.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PolicyScanFailure.rootDidNotResolve(root)
        }
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else {
            throw PolicyScanFailure.rootDidNotResolve(root)
        }
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        guard files.count >= minimumSwiftFilesPerRoot else {
            throw PolicyScanFailure.implausiblyFewFiles(
                root: root, found: files.count, expected: minimumSwiftFilesPerRoot)
        }
        return files
    }
}

// MARK: - Scan failures

/// These two cases are the difference between a policy that found nothing
/// wrong and a policy that looked at nothing. Both used to surface as a pass.
private enum PolicyScanFailure: Error, CustomStringConvertible {
    case rootDidNotResolve(URL)
    case implausiblyFewFiles(root: URL, found: Int, expected: Int)

    var description: String {
        switch self {
        case .rootDidNotResolve(let root):
            return "image-decode policy root is not a readable directory: \(root.path) — "
                 + "the scan would have read no files, so the policy would have checked nothing"
        case .implausiblyFewFiles(let root, let found, let expected):
            return "image-decode policy scanned \(found) Swift files under \(root.path), "
                 + "expected at least \(expected) — a near-empty scan means the root moved, "
                 + "not that the codebase is clean"
        }
    }
}
