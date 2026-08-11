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

    func testChatSurfacesDecodeImagesOnlyThroughThumbnailLoader() throws {
        let roots = [Self.sourceRoot.appendingPathComponent("UI"),
                     Self.sourceRoot.appendingPathComponent("Data")]

        var offenders: [String] = []
        for root in roots {
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

    private static func swiftFiles(under root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
