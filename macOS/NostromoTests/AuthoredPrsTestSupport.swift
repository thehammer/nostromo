import XCTest
import AppKit
import NostromoKit

// Shared fixtures and measuring tools for the My open PRs tests (AuthoredPrsOverviewTests,
// AuthoredPrsRowHoldTests, AuthoredPrsKeyboardTests, AuthoredPrsAccessibilityTests, AuthoredPrsDemandTests,
// AuthoredPrRowAppearanceTests, AuthoredPrsHeaderAppearanceTests). No test of its own lives here.
//
// The rendering helpers measure INK: the pixels of a real render that differ from the background. A frame
// check cannot see a clipped digit (#456 and #457 shipped one); a render can.

/// The host the appearance tests draw over: `AuthoredPrsPalette.background`, top-left origin, so a pixel row
/// is the view's y.
final class AuthoredPrsInkHost: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        AuthoredPrsPalette.background.setFill()
        bounds.fill()
    }
}

enum APT {

    // MARK: Time

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let utc = TimeZone(identifier: "UTC")!

    /// A clock the test moves by hand.
    final class FakeClock {
        var now: Date
        init(_ now: Date = APT.t0) { self.now = now }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
        var read: () -> Date { { [self] in self.now } }
    }

    // MARK: Fixtures

    static func pr(_ number: Int, repo: String = "carefeed/portal", title: String? = nil, url: String? = nil,
                   group: AuthoredPrGroup = .waiting, lifecycle: AuthoredPrLifecycle = .open, endedAt: Date? = nil,
                   draft: Bool = false, updatedAt: Date? = nil, baseRef: String? = nil,
                   checks: AuthoredPrChecks = AuthoredPrChecks(state: .passing, passed: 3),
                   review: AuthoredPrReview = AuthoredPrReview(state: .none),
                   newComments: Int = 0, unresolvedThreads: Int = 0,
                   owner: AuthoredPrOwner = .unknown) -> AuthoredPr {
        AuthoredPr(repo: repo, number: number, url: url ?? "https://github.com/\(repo)/pull/\(number)",
                   title: title ?? "Title of PR \(number)", draft: draft, updatedAt: updatedAt ?? t0.addingTimeInterval(-7200),
                   group: group, lifecycle: lifecycle, endedAt: endedAt, baseRef: baseRef,
                   checks: checks, review: review, newComments: newComments, unresolvedThreads: unresolvedThreads,
                   owner: owner)
    }

    static func motherOwner(job: String = "a1b2c3", name: String = "Cody (nostromo)") -> AuthoredPrOwner {
        AuthoredPrOwner(kind: .motherJob, tag: "cody-nostromo", name: name, jobId: job)
    }

    static func snapshot(_ prs: [AuthoredPr], token: AuthoredPrsTokenState = .connected,
                         relay: AuthoredPrsRelay = AuthoredPrsRelay(state: .live),
                         poll: AuthoredPrsPoll? = nil, refreshBlocked: AuthoredPrsRefreshBlocked? = nil,
                         hiddenOrgs: [String] = [], usage: AuthoredPrsUsage = AuthoredPrsUsage()) -> AuthoredPrsSnapshot {
        AuthoredPrsSnapshot(generatedAt: t0, token: token, relay: relay,
                            poll: poll ?? AuthoredPrsPoll(state: .ok, checkedAt: t0.addingTimeInterval(-40)),
                            refreshBlocked: refreshBlocked, hiddenOrgs: hiddenOrgs, prs: prs, usage: usage)
    }

    /// A snapshot as the wire delivers it, so Kit's text cleaning has run on every string.
    static func decodedSnapshot(prs: [[String: Any]]) throws -> AuthoredPrsSnapshot {
        let object: [String: Any] = ["token": "connected", "relay": ["state": "live"], "poll": ["state": "ok"], "prs": prs]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(AuthoredPrsSnapshot.self, from: data)
    }

    // MARK: Views and windows

    static func window(size: NSSize) -> NSWindow {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    static func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { descendants(of: $0) } }

    /// Every text field's string under `view`.
    static func texts(in view: NSView) -> [String] {
        descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    static func hasLink(_ string: NSAttributedString) -> Bool {
        var found = false
        string.enumerateAttribute(.link, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if value != nil { found = true }
        }
        return found
    }

    /// Run everything already queued on the main queue, and what that queues in turn.
    static func flushMain(turns: Int = 3) {
        for _ in 0..<turns {
            var ran = false
            DispatchQueue.main.async { ran = true }
            while !ran { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        }
    }

    // MARK: Events

    static let keyUp: UInt16 = 126, keyDown: UInt16 = 125, keyLeft: UInt16 = 123, keyRight: UInt16 = 124
    static let keyReturn: UInt16 = 36, keyEnter: UInt16 = 76

    static func arrow(_ function: Int) -> String { String(UnicodeScalar(UInt32(function))!) }

    static func key(_ keyCode: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = [], window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    /// An arrow key as the keyboard sends it.
    static func arrowKey(_ keyCode: UInt16, window: NSWindow? = nil) -> NSEvent {
        let function: Int
        switch keyCode {
        case keyUp: function = NSUpArrowFunctionKey
        case keyDown: function = NSDownArrowFunctionKey
        case keyLeft: function = NSLeftArrowFunctionKey
        default: function = NSRightArrowFunctionKey
        }
        return key(keyCode, arrow(function), flags: [.numericPad, .function], window: window)
    }

    static func command(_ character: String, extra: NSEvent.ModifierFlags = [], window: NSWindow? = nil) -> NSEvent {
        let code: UInt16 = character == "o" ? 31 : (character == "r" ? 15 : 0)
        return key(code, character, flags: NSEvent.ModifierFlags.command.union(extra), window: window)
    }

    // MARK: Rendering and ink

    /// Draws `host` (laid out) and keeps the pixels.
    struct Bitmap {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        let background: (r: CGFloat, g: CGFloat, b: CGFloat)

        var size: NSSize { NSSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale) }
        /// One pixel's worth of slack, or half a point: what a measured edge can be off by.
        var tolerance: CGFloat { max(0.5, 1 / scale) }

        init(rep: NSBitmapImageRep, scale: CGFloat) {
            self.rep = rep
            self.scale = scale
            let c = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)
            background = (c?.redComponent ?? 0, c?.greenComponent ?? 0, c?.blueComponent ?? 0)
        }

        /// The bounding box, in points from the top-left, of the pixels in `rect` that differ from the
        /// background by more than `threshold`; nil when there are none.
        func ink(in rect: NSRect, threshold: CGFloat = 0.25) -> NSRect? {
            let r = rect.intersection(NSRect(origin: .zero, size: size))
            guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
            let x0 = max(0, Int((r.minX * scale).rounded(.down)))
            let x1 = min(rep.pixelsWide, Int((r.maxX * scale).rounded(.up)))
            let y0 = max(0, Int((r.minY * scale).rounded(.down)))
            let y1 = min(rep.pixelsHigh, Int((r.maxY * scale).rounded(.up)))
            guard x0 < x1, y0 < y1 else { return nil }
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
            for y in y0..<y1 {
                for x in x0..<x1 {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let d = max(abs(c.redComponent - background.r), abs(c.greenComponent - background.g), abs(c.blueComponent - background.b))
                    if d > threshold {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            guard maxX >= 0 else { return nil }
            return NSRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                          width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        }

        /// The height of the ink in the last `within` points of the ink in `rect`: a tail-truncated line ends
        /// in the short dots of an ellipsis, a clipped one in a slice of a tall glyph.
        func trailingInkHeight(in rect: NSRect, within: CGFloat = 1.5, threshold: CGFloat = 0.15) -> CGFloat? {
            guard let all = ink(in: rect, threshold: threshold) else { return nil }
            let tail = NSRect(x: all.maxX - within, y: rect.minY, width: within, height: rect.height)
            return ink(in: tail, threshold: threshold)?.height
        }
    }

    /// A host (and the off-screen window that makes it draw) in `appearance`, over the palette background.
    static func inkHost(size: NSSize, appearance: NSAppearance.Name) -> (host: AuthoredPrsInkHost, window: NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let host = AuthoredPrsInkHost(frame: NSRect(origin: .zero, size: size))
        window.contentView = host
        return (host, window)
    }

    static func render(_ host: NSView, file: StaticString = #filePath, line: UInt = #line) -> Bitmap? {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("could not render the view", file: file, line: line)
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return Bitmap(rep: rep, scale: CGFloat(rep.pixelsWide) / host.bounds.width)
    }

    /// `view`'s bounds in `host`'s top-left coordinates.
    static func rect(of view: NSView, in host: NSView) -> NSRect { view.convert(view.bounds, to: host) }

    /// The ink of `text` drawn whole and alone over the palette background in `appearance`: what a label showing
    /// all of it must put on screen.
    static func referenceInk(_ text: NSAttributedString, appearance: NSAppearance.Name, scale: CGFloat) -> NSRect? {
        let size = NSSize(width: ceil(text.size().width) + 16, height: ceil(text.size().height) + 10)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            AuthoredPrsPalette.background.setFill()
            NSRect(origin: .zero, size: size).fill()
            text.draw(at: NSPoint(x: 8, y: 5))
        }
        NSGraphicsContext.restoreGraphicsState()
        return Bitmap(rep: rep, scale: scale).ink(in: NSRect(origin: .zero, size: size))
    }

    static func attributed(_ string: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }
}
