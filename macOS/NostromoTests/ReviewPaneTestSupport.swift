import XCTest
import AppKit
import SwiftUI
import WebKit
import NostromoKit

// Shared rigs for the Perri side pane tests (slice 2).
//
// Nothing here touches the network, the real `Work` browser profile, `WKWebsiteDataStore.default()` for
// writing, or the real preferences:
//
//   * pages are served by `ReviewFixtureHandler`, a `WKURLSchemeHandler` on `nostromo-fixture:`. WebKit
//     refuses a handler for https, so `ReviewPaneHosts(jiraSite:fixtureScheme:)` (DEBUG only) lets
//     `nostromo-fixture://github.com/...` count as `https://github.com/...` and
//     `nostromo-fixture://evil.example/...` as outside the hosts.
//   * the web views' data store is a throwaway `WKWebsiteDataStore(forIdentifier: UUID())`, removed at the end.
//   * every window is borderless and parked far off screen (like AppControlMouseTests / HumanGestureTests).

let reviewFixtureScheme = "nostromo-fixture"

func reviewFixtureURL(_ hostAndPath: String) -> URL { URL(string: "\(reviewFixtureScheme)://\(hostAndPath)")! }

/// Runs the main run loop until `condition` holds or `timeout` passes. True when it held.
@MainActor
@discardableResult
func spinUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return condition()
}

/// `spinUntil` for async tests. An async test body runs inside a main-queue block, so a nested run loop
/// cannot run the main-queue blocks WebKit's callbacks and completion handlers need; sleeping yields instead.
@MainActor
func spinUntilA(_ timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    return condition()
}

/// `XCTAssertTrue` whose condition may await (the XCTest autoclosure cannot).
@MainActor
func assertTrueA(_ value: @autoclosure () async -> Bool, _ message: @autoclosure () -> String = "",
                 file: StaticString = #filePath, line: UInt = #line) async {
    let ok = await value()
    XCTAssertTrue(ok, message(), file: file, line: line)
}

/// `spin` for async tests (see `spinUntilA`).
@MainActor
func spinA(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// Runs the main run loop for `seconds` (to let something that must NOT happen have its chance).
@MainActor
func spin(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

/// A borderless window that can be key, parked outside every screen.
final class ReviewTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    @MainActor
    static func make(size: NSSize = NSSize(width: 1000, height: 700)) -> ReviewTestWindow {
        _ = NSApplication.shared
        let w = ReviewTestWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                 backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        w.orderFrontRegardless()
        w.makeKey()
        spin(0.1)       // let AppKit settle: an event queued for an unsettled window comes back displaced
        return w
    }
}

/// Pages for the fixture scheme, and a record of every request WebKit made.
final class ReviewFixtureHandler: NSObject, WKURLSchemeHandler {

    struct Response {
        var body = "<html><head><title>fixture</title></head><body>fixture</body></html>"
        var mime = "text/html"
        var headers: [String: String] = [:]
        var failure: Error?
    }

    /// Every URL WebKit asked this handler for, in order.
    private(set) var requested: [URL] = []
    /// Decides the response for a URL. Replace it per test.
    var respond: (URL) -> Response = { _ in Response() }

    func requestCount(host: String, pathPrefix: String = "") -> Int {
        requested.filter { $0.host == host && $0.path.hasPrefix(pathPrefix) }.count
    }

    func requests(toHost host: String) -> [URL] { requested.filter { $0.host == host } }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        requested.append(url)
        let r = respond(url)
        if let failure = r.failure {
            urlSchemeTask.didFailWithError(failure)
            return
        }
        let data = Data(r.body.utf8)
        let response: URLResponse
        if r.headers.isEmpty {
            response = URLResponse(url: url, mimeType: r.mime, expectedContentLength: data.count, textEncodingName: "utf-8")
        } else {
            var headers = r.headers
            headers["Content-Type"] = r.mime
            response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    static func html(_ body: String, title: String = "fixture", head: String = "") -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(title)</title>\(head)</head><body style=\"margin:0\">\(body)</body></html>"
    }
}

/// A fixture environment: its own throwaway data store, the fixture handler, hosts that accept the
/// fixture scheme, and a spy for "open in the default browser".
@MainActor
final class ReviewFixtureWorld {
    let handler = ReviewFixtureHandler()
    let storeID = UUID()
    let dataStore: WKWebsiteDataStore
    private(set) var openedExternally: [URL] = []
    var jiraSite: String?

    init() {
        dataStore = WKWebsiteDataStore(forIdentifier: storeID)
    }

    var environment: ReviewPaneEnvironment {
        var env = ReviewPaneEnvironment()
        env.hosts = { [unowned self] in
            ReviewPaneHosts(jiraSite: self.jiraSite, fixtureScheme: reviewFixtureScheme)
        }
        env.openExternal = { [unowned self] url in self.openedExternally.append(url) }
        env.makeConfiguration = { [unowned self] in
            let config = ReviewWebViewFactory.makeConfiguration(dataStore: self.dataStore)
            config.setURLSchemeHandler(self.handler, forURLScheme: reviewFixtureScheme)
            return config
        }
        return env
    }

    /// Removes the throwaway data store. Call once every web view using it has been released.
    func removeDataStore() async {
        for _ in 0..<10 {
            do { try await WKWebsiteDataStore.remove(forIdentifier: storeID); return }
            catch { spin(0.3) }
        }
    }
}

// MARK: - Events

enum ReviewEvents {

    static func mouse(_ type: NSEvent.EventType, at windowPoint: NSPoint, in window: NSWindow,
                      number: Int = 1, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: number, clickCount: clickCount,
                           pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// A complete click, as the window server would deliver it. No CGEvent: nothing marks it synthetic.
    @MainActor
    static func click(at windowPoint: NSPoint, in window: NSWindow) {
        window.sendEvent(mouse(.leftMouseDown, at: windowPoint, in: window))
        window.sendEvent(mouse(.leftMouseUp, at: windowPoint, in: window))
    }

    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46,
    ]

    @MainActor
    static func backspace(_ count: Int, in window: NSWindow) {
        for _ in 0..<count {
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
                                             charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
                window.sendEvent(event)
            }
        }
    }

    @MainActor
    static func type(_ text: String, in window: NSWindow) {
        for ch in text {
            let s = String(ch)
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: s,
                                             charactersIgnoringModifiers: s, isARepeat: false,
                                             keyCode: keyCodes[ch] ?? 0)!
                window.sendEvent(event)
            }
        }
    }
}

// MARK: - Pixels

/// A decoded bitmap, top-down, read as sRGB bytes (drawn into an sRGB context, so colours are not shifted by
/// the display's profile).
struct ReviewPixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(rep: NSBitmapImageRep) {
        guard let cg = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        bytes = data
    }

    init?(png: Data) {
        guard let rep = NSBitmapImageRep(data: png) else { return nil }
        self.init(rep: rep)
    }

    struct RGB: Equatable { var r: Int, g: Int, b: Int
        var luminance: Int { (r * 299 + g * 587 + b * 114) / 1000 }
        func distance(to o: RGB) -> Int { max(abs(r - o.r), abs(g - o.g), abs(b - o.b)) }
    }

    /// Out of range reads as an impossible colour, so a wrong coordinate fails a comparison loudly.
    func rgb(_ x: Int, _ y: Int) -> RGB {
        guard x >= 0, y >= 0, x < width, y < height else { return RGB(r: -1000, g: -1000, b: -1000) }
        let i = (y * width + x) * 4
        return RGB(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]))
    }

    /// The most common colours (quantised to 8 levels), for failure messages.
    func summary(top: Int = 8) -> String {
        var counts: [Int: Int] = [:]
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let c = rgb(x, y)
                counts[(c.r / 8) << 16 | (c.g / 8) << 8 | (c.b / 8), default: 0] += 1
                x += 2
            }
            y += 2
        }
        return counts.sorted { $0.value > $1.value }.prefix(top)
            .map { "(\(($0.key >> 16) * 8),\((($0.key >> 8) & 255) * 8),\(($0.key & 255) * 8))x\($0.value)" }.joined(separator: " ")
    }
}

/// A view that accepts the first click, so a click through `window.sendEvent` reaches it in a window that
/// was never activated.
final class ReviewFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - The queue rows with the side-pane controls

/// Five `pr_list` rows in one bucket rendered by the real `PaneContentView` inside a real window, with
/// spies for what the row controls and the row itself do.
@MainActor
final class PerriRowsRig {
    static let repo = "acme/web"
    static let numbers = [4519, 4520, 4521, 4522, 4523]

    let window: ReviewTestWindow
    let hosting: ReviewFirstMouseHostingView<PaneContentView>
    let width: CGFloat
    let height: CGFloat

    /// `selected`: the pinned PR (its row is marked). `withActions`: a Perri focus's row controls; false is
    /// the plain queue every other pane shows.
    init(width: CGFloat, height: CGFloat = 480, selected: Int? = 4520, withActions: Bool = true,
         reviewing: ReviewingPR? = nil) {
        self.width = width
        self.height = height
        let items = Self.numbers.map { n in
            PrListItemModel(repo: Self.repo, number: n, title: "Row title \(n - 4518)", author: "dev",
                            bucket: "needs_review", ciState: .success, newActivity: false,
                            url: "https://github.com/\(Self.repo)/pull/\(n)", headSha: "abc")
        }
        // Built before `self` is usable by the closures: they reach the spies through this box.
        let box = SpyBox()
        let makeRoot: (Int?) -> PaneContentView = { hovered in
            var actions = PerriRowActions(openConversation: { _, n in box.conversations.append(n) },
                                          openDiff: { _, n in box.diffs.append(n) })
            actions.hoverOverride = hovered
            return PaneContentView(
                content: .prList(items), selectedPR: selected.map { PRRef(repo: Self.repo, number: $0) },
                onLoadPR: { _, n in box.loads.append(n) }, isPerriFocus: true,
                rowActions: withActions ? actions : nil, reviewing: reviewing)
        }
        self.makeRoot = makeRoot
        self.box = box
        let host = ReviewFirstMouseHostingView(rootView: makeRoot(nil))
        let win = ReviewTestWindow.make(size: NSSize(width: width, height: height))
        hosting = host
        window = win
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        win.acceptsMouseMovedEvents = true
        NSApp.accessibilitySetOverrideValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        settle()
    }

    private final class SpyBox {
        var loads: [Int] = []
        var conversations: [Int] = []
        var diffs: [Int] = []
    }
    private let box: SpyBox
    private let makeRoot: (Int?) -> PaneContentView

    var recordedLoads: [Int] { box.loads }
    var recordedConversations: [Int] { box.conversations }
    var recordedDiffs: [Int] { box.diffs }

    func settle(_ seconds: TimeInterval = 0.4) {
        hosting.layoutSubtreeIfNeeded()
        spin(seconds)
        hosting.layoutSubtreeIfNeeded()
    }

    func close() {
        window.contentView = NSView()
        window.close()
    }

    /// A render of the whole list: pixels, top-down, and pixels per point.
    func render() throws -> (pixels: ReviewPixels, scale: CGFloat) {
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "PerriRowsRig", code: 1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let pixels = ReviewPixels(rep: rep) else { throw NSError(domain: "PerriRowsRig", code: 2) }
        return (pixels, CGFloat(rep.pixelsWide) / hosting.bounds.width)
    }

    /// Vertical extent (pixels) of each row's title: the bright text of the `.headline` line.
    func titleBands(_ pixels: ReviewPixels, regionWidthFraction: CGFloat = 0.4) -> [ClosedRange<Int>] {
        let xEnd = Int(CGFloat(pixels.width) * regionWidthFraction)
        var bands: [ClosedRange<Int>] = []
        var start: Int?
        for y in 0..<pixels.height {
            var bright = false
            var x = 0
            while x < xEnd { if pixels.rgb(x, y).luminance > 180 { bright = true; break }; x += 1 }
            if bright { if start == nil { start = y } }
            else if let s = start { bands.append(s...(y - 1)); start = nil }
        }
        if let s = start { bands.append(s...(pixels.height - 1)) }
        return bands
    }

    struct Box: Equatable { var x0: Int, y0: Int, x1: Int, y1: Int
        var centre: (x: Int, y: Int) { ((x0 + x1) / 2, (y0 + y1) / 2) }
        static func == (a: Box, b: Box) -> Bool { a.x0 == b.x0 && a.y0 == b.y0 && a.x1 == b.x1 && a.y1 == b.y1 }
    }

    /// The control buttons: large, mostly filled connected regions of the buttons' fill grey (about 0.24).
    /// Text anti-aliasing passes through that grey now and then, but only as thin, sparse outlines.
    func buttonBoxes(_ pixels: ReviewPixels, scale: CGFloat) -> [Box] {
        let w = pixels.width, h = pixels.height
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let c = pixels.rgb(x, y)
                if abs(c.r - c.g) <= 4, abs(c.g - c.b) <= 4, (48...82).contains(c.luminance) { mask[y * w + x] = true }
            }
        }
        var seen = [Bool](repeating: false, count: w * h)
        var boxes: [Box] = []
        let minArea = Int(150 * scale * scale)
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] && !seen[y * w + x] {
                var stack = [(x, y)]
                seen[y * w + x] = true
                var box = Box(x0: x, y0: y, x1: x, y1: y)
                var area = 0
                while let (cx, cy) = stack.popLast() {
                    area += 1
                    box.x0 = min(box.x0, cx); box.x1 = max(box.x1, cx); box.y0 = min(box.y0, cy); box.y1 = max(box.y1, cy)
                    for (nx, ny) in [(cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)]
                    where nx >= 0 && ny >= 0 && nx < w && ny < h && mask[ny * w + nx] && !seen[ny * w + nx] {
                        seen[ny * w + nx] = true
                        stack.append((nx, ny))
                    }
                }
                let boxArea = (box.x1 - box.x0 + 1) * (box.y1 - box.y0 + 1)
                if area >= minArea, Double(area) / Double(boxArea) >= 0.4 { boxes.append(box) }
            }
        }
        return boxes.sorted { ($0.y0, $0.x0) < ($1.y0, $1.x0) }
    }

    /// The window point for a pixel position of `render()`.
    func windowPoint(px: Int, py: Int, scale: CGFloat) -> NSPoint {
        let x = CGFloat(px) / scale
        let yTop = CGFloat(py) / scale
        let viewY = hosting.isFlipped ? yTop : hosting.bounds.height - yTop
        return hosting.convert(NSPoint(x: x, y: viewY), to: nil)
    }

    func click(px: Int, py: Int, scale: CGFloat) {
        ReviewEvents.click(at: windowPoint(px: px, py: py, scale: scale), in: window)
    }

    /// Puts the pointer over the row at a pixel position. The row's hover state is driven through
    /// `PerriRowActions.hoverOverride`: a real pointer cannot reach a window parked off screen in CI.
    func hover(px: Int, py: Int, scale: CGFloat) {
        let point = windowPoint(px: px, py: py, scale: scale)
        let local = hosting.convert(point, from: nil)
        let rowIndex = rowIndexAt(viewY: hosting.isFlipped ? local.y : hosting.bounds.height - local.y)
        hosting.rootView = makeRoot(rowIndex.map { Self.numbers[$0] })
        settle(0.3)
    }

    /// Rows are laid out top to bottom; rows are found by their title bands in the last render.
    private func rowIndexAt(viewY: CGFloat) -> Int? {
        guard let (pixels, scale) = try? render() else { return nil }
        let bands = titleBands(pixels)
        let py = Int(viewY * scale)
        for (i, band) in bands.enumerated() {
            let next = i + 1 < bands.count ? bands[i + 1].lowerBound : pixels.height
            if py >= band.lowerBound - 4 && py < next - 4 { return i }
        }
        return nil
    }
}

/// Walks an accessibility tree (views or SwiftUI nodes) through KVC, as app-control does.
func reviewAXNodes(under root: Any, depth: Int = 0) -> [AnyObject] {
    guard depth < 14 else { return [] }
    var out: [AnyObject] = []
    for child in (AppControlAX.value(root as AnyObject, "accessibilityChildren") as? [AnyObject]) ?? [] {
        out.append(child)
        out += reviewAXNodes(under: child, depth: depth + 1)
    }
    return out
}

func reviewAXLabel(_ node: AnyObject) -> String? { AppControlAX.value(node, "accessibilityLabel") as? String }
