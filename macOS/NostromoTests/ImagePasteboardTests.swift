import XCTest
import AppKit

// ImagePasteboard is compiled into this target directly (logic test).

final class ImagePasteboardTests: XCTestCase {

    private func pngBytes() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ipt-\(UUID().uuidString)")
    }

    func testRawPNGDataBecomesATempPNGFile() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("ipt-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setData(pngBytes(), forType: .png)
        let dir = tempDir()
        XCTAssertTrue(ImagePasteboard.hasImages(pb))
        let urls = ImagePasteboard.imageURLs(from: pb, tempDir: dir)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls[0].pathExtension, "png")
        XCTAssertNotNil(NSImage(contentsOf: urls[0]))
    }

    func testImageFileIsCopiedIntoTheStagingDirForTheDaemon() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("shot.png")
        try pngBytes().write(to: file)
        let pb = NSPasteboard(name: NSPasteboard.Name("ipt-\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        let staging = tempDir()
        let urls = ImagePasteboard.imageURLs(from: pb, tempDir: staging)
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls[0].path.hasPrefix(staging.path), "staged copy, not the original")
        XCTAssertTrue(urls[0].lastPathComponent.hasSuffix("shot.png"))
        XCTAssertEqual(try Data(contentsOf: urls[0]), try Data(contentsOf: file))
    }

    func testNonImageFileAndPlainTextAreIgnored() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("notes.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)
        let pb = NSPasteboard(name: NSPasteboard.Name("ipt-\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        XCTAssertFalse(ImagePasteboard.hasImages(pb))
        pb.clearContents()
        pb.setString("just text", forType: .string)
        XCTAssertTrue(ImagePasteboard.imageURLs(from: pb, tempDir: tempDir()).isEmpty)
    }
}
