import AppKit
import UniformTypeIdentifiers

/// Turns whatever is on a drag or paste pasteboard into image files the chat can attach.
///
/// Two shapes arrive in practice:
///  - **File URLs** (Finder drags, saved screenshots) — used as-is.
///  - **Raw image data** (a screenshot copied with ⌃⌘⇧4, an image dragged from a
///    browser, the floating screenshot thumbnail) — written to a temp PNG so it
///    can ride the same path-based attachment flow.
enum ImagePasteboard {

    /// Pasteboard types a drop target must register to be offered images.
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    /// True when the pasteboard holds something `imageURLs(from:)` would attach.
    static func hasImages(_ pb: NSPasteboard) -> Bool {
        !fileImageURLs(from: pb).isEmpty || rawImageData(from: pb) != nil
    }

    /// Image files for `pb`. File URLs win; raw image data is materialised to `tempDir`.
    static func imageURLs(from pb: NSPasteboard,
                          tempDir: URL = FileManager.default.temporaryDirectory
                              .appendingPathComponent("nostromo-attachments", isDirectory: true)) -> [URL] {
        let files = fileImageURLs(from: pb)
        if !files.isEmpty { return files }
        guard let data = rawImageData(from: pb), let png = pngData(from: data) else { return [] }
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let url = tempDir.appendingPathComponent("image-\(UUID().uuidString.prefix(8)).png")
            try png.write(to: url, options: .atomic)
            return [url]
        } catch {
            return []
        }
    }

    // MARK: Internals

    static func fileImageURLs(from pb: NSPasteboard) -> [URL] {
        guard let items = pb.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return [] }
        return items.filter { url in
            guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            else { return false }
            return type.conforms(to: .image)
        }
    }

    private static func rawImageData(from pb: NSPasteboard) -> Data? {
        pb.data(forType: .png) ?? pb.data(forType: .tiff)
    }

    private static func pngData(from data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
