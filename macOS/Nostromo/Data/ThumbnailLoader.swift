import AppKit
import ImageIO

/// The only sanctioned way this app turns a file URL into an `NSImage`.
///
/// `NSImage(contentsOf:)` decodes at the source's full resolution. The input
/// tray's chips are 36×36, so a 4K screenshot cost 3840 × 2160 × 4 ≈ 33 MB to
/// fill 1,296 points — twenty of them, 663 MB, against a criterion of 60 MB.
///
/// ImageIO's thumbnail path decodes straight to the requested size and never
/// instantiates the full-size image at all. Twenty thumbnails come to under a
/// megabyte.
///
/// `ImageDecodePolicyTests` fails the build if any transcript-surface code
/// decodes an image outside this type. That is deliberate: the transcript
/// renders no images *today*, and the PRD's forward-looking constraint — inline
/// images must be sized to display, not to source — is only worth writing down
/// if something enforces it when that feature arrives.
enum ThumbnailLoader {

    /// Points of the chip this thumbnail fills.
    static let chipSize: CGFloat = 36

    private static let queue = DispatchQueue(label: "com.hammer.nostromo.thumbnail",
                                             qos: .userInitiated)

    /// Decode `url` to a thumbnail no larger than `size` points at `scale`, off
    /// the main thread, and deliver it on the main thread.
    ///
    /// `completion` is not called if decoding fails — the caller's placeholder
    /// chip simply stays as it is.
    static func load(_ url: URL,
                     size: CGFloat = chipSize,
                     scale: CGFloat = 2,
                     completion: @escaping (NSImage) -> Void) {
        let pixels = Int((size * max(scale, 1)).rounded())
        queue.async {
            guard let image = decode(url, maxPixelSize: pixels) else { return }
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Synchronous decode. Exposed for tests and for callers already off-main.
    static func decode(_ url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // Always generate: an embedded EXIF thumbnail may be far larger than
            // we asked for, and honouring it would reintroduce the problem.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
