import AppKit
import os

private let ctlLog = Logger(subsystem: "com.hammer.nostromo.mac", category: "AppControl")

/// A local control socket that lets a script (or an agent) drive the real app —
/// click, type, press keys, drop files, dump the view tree, take a window
/// screenshot — so UI behaviour can be QA'd without a human in the loop.
///
/// **Opt-in.** The socket can click anything in the app, so it only starts when
/// `NOSTROMO_APP_CONTROL=1` is in the environment or the `AppControlEnabled`
/// default is true:
///
///     defaults write com.hammer.nostromo.mac AppControlEnabled -bool true
///
/// The socket lives at `~/.nostromo/app-control.sock`, mode 0600 (owner only).
/// Events are *synthesised and sent through `NSWindow.sendEvent`*, so they take
/// the same hit-testing and responder path a real click does — a bug like a
/// sibling overlay swallowing clicks reproduces here, which a direct
/// `button.performClick` would hide.
final class AppControlServer {

    static let shared = AppControlServer()
    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nostromo/app-control.sock").path
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["NOSTROMO_APP_CONTROL"] == "1"
            || UserDefaults.standard.bool(forKey: "AppControlEnabled")
    }

    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.hammer.nostromo.appcontrol", attributes: .concurrent)
    private weak var appDelegate: AppDelegate?

    func startIfEnabled(appDelegate: AppDelegate) {
        guard Self.isEnabled, listenFD < 0 else { return }
        self.appDelegate = appDelegate
        let path = Self.socketPath
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        // Owner-only from the instant the socket exists (chmod after bind leaves
        // a window), and the parent directory too.
        chmod((path as NSString).deletingLastPathComponent, 0o700)
        let oldMask = umask(0o177)
        defer { umask(oldMask) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { ctlLog.error("socket() failed errno=\(errno)"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < cap else { ctlLog.error("socket path too long"); close(fd); return }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: cap) { _ = strcpy($0, path) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            ctlLog.error("bind/listen failed errno=\(errno)"); close(fd); return
        }
        chmod(path, 0o600)
        listenFD = fd
        ctlLog.notice("app control listening at \(path, privacy: .public)")
        queue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            if client < 0 { if errno == EINTR { continue } else { return } }
            queue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        // Defence in depth beyond the 0600 file mode: only our own user may drive the app.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
            ctlLog.error("rejected app-control connection from another uid")
            return
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(chunk, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(data: buffer[..<nl], encoding: .utf8) ?? ""
                buffer.removeSubrange(...nl)
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                var reply = ""
                DispatchQueue.main.sync { reply = self.handle(line) }
                let out = Array((reply + "\n").utf8)
                _ = out.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            }
        }
    }

    // MARK: - Dispatch (main thread)

    private func handle(_ line: String) -> String {
        switch AppControlRequest.parse(line) {
        case .failure(let e): return AppControlWire.fail(e)
        case .success(let req):
            do { return AppControlWire.ok(try run(req)) }
            catch let e as AppControlError { return AppControlWire.fail(e) }
            catch { return AppControlWire.fail(.failed("\(error)")) }
        }
    }

    private func run(_ req: AppControlRequest) throws -> Any {
        switch req.cmd {
        case "ping":        return ["pid": ProcessInfo.processInfo.processIdentifier]
        case "windows":     return windowsInfo()
        case "tree":        return try tree(req)
        case "find":        return try find(req)
        case "click":       return try click(req)
        case "key":         return try key(req)
        case "type":        return try typeText(req)
        case "paste":       return try paste(req)
        case "drop":        return try drop(req)
        case "screenshot":  return try screenshot(req)
        default: throw AppControlError.badRequest("unknown cmd \"\(req.cmd)\"")
        }
    }

    // MARK: - Windows

    private func window(_ req: AppControlRequest) throws -> NSWindow {
        let i = req.int("window") ?? 0
        guard let wins = appDelegate?.windows, wins.indices.contains(i) else {
            throw AppControlError.noSuchWindow(i)
        }
        return wins[i]
    }

    private func contentHeight(_ w: NSWindow) -> Double { Double(w.contentView?.bounds.height ?? 0) }

    private func windowsInfo() -> [[String: Any]] {
        (appDelegate?.windows ?? []).enumerated().map { i, w in
            ["index": i, "title": w.title,
             "frame": ["x": w.frame.minX, "y": w.frame.minY, "w": w.frame.width, "h": w.frame.height],
             "fullscreen": w.styleMask.contains(.fullScreen),
             "key": w.isKeyWindow,
             "firstResponder": w.firstResponder.map { String(describing: type(of: $0)) } ?? "none"]
        }
    }

    // MARK: - Tree / find

    private func text(of v: NSView) -> String? {
        var s: String?
        if let f = v as? NSTextField { s = f.stringValue }
        else if let b = v as? NSButton { s = b.title }
        else if let t = v as? NSTextView { s = t.string }
        guard var out = s, !out.isEmpty else { return nil }
        if out.count > 160 { out = String(out.prefix(160)) + "…" }
        return out
    }

    private func node(_ v: NSView, in w: NSWindow, depth: Int, maxDepth: Int, visibleOnly: Bool) -> [String: Any]? {
        if visibleOnly && v.isHidden { return nil }
        let frameInWindow = v.convert(v.bounds, to: nil)
        var n: [String: Any] = [
            "class": String(describing: type(of: v)),
            "frame": AppControlGeometry.topLeftRect(viewFrameInWindow: frameInWindow, contentHeight: contentHeight(w)),
        ]
        if v.isHidden { n["hidden"] = true }
        if let t = text(of: v) { n["text"] = t }
        if let tip = v.toolTip { n["tooltip"] = tip }
        if let l = v.accessibilityLabel(), !l.isEmpty { n["label"] = l }
        if depth < maxDepth {
            let kids = v.subviews.compactMap { node($0, in: w, depth: depth + 1, maxDepth: maxDepth, visibleOnly: visibleOnly) }
            if !kids.isEmpty { n["children"] = kids }
        }
        return n
    }

    private func tree(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        guard let cv = w.contentView else { throw AppControlError.failed("window has no content view") }
        return node(cv, in: w, depth: 0, maxDepth: req.int("depth") ?? 12, visibleOnly: true) ?? [:]
    }

    /// Views whose text, tooltip, label or class name contains `text` (case-insensitive).
    private func find(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        guard let needle = req.string("text")?.lowercased(), !needle.isEmpty else {
            throw AppControlError.badRequest("find needs \"text\"")
        }
        return matches(needle, in: w).map { v in
            let r = AppControlGeometry.topLeftRect(viewFrameInWindow: v.convert(v.bounds, to: nil),
                                                   contentHeight: contentHeight(w))
            var d: [String: Any] = ["class": String(describing: type(of: v)), "frame": r,
                                    "center": ["x": r["x"]! + r["w"]! / 2, "y": r["y"]! + r["h"]! / 2]]
            if let t = text(of: v) { d["text"] = t }
            return d
        }
    }

    private func matches(_ needle: String, in w: NSWindow) -> [NSView] {
        var out: [NSView] = []
        func walk(_ v: NSView) {
            if v.isHidden { return }
            let hay = [text(of: v), v.toolTip, v.accessibilityLabel(), String(describing: type(of: v))]
                .compactMap { $0?.lowercased() }
            if v.window != nil, hay.contains(where: { $0.contains(needle) }) { out.append(v) }
            v.subviews.forEach(walk)
        }
        if let cv = w.contentView { walk(cv) }
        return out
    }

    // MARK: - Mouse

    private func point(_ req: AppControlRequest, _ w: NSWindow) throws -> NSPoint {
        if let x = req.double("x"), let y = req.double("y") {
            return AppControlGeometry.windowPoint(x: x, y: y, contentHeight: contentHeight(w))
        }
        if let t = req.string("text")?.lowercased() {
            let hits = matches(t, in: w).filter { $0.bounds.width > 0 && $0.bounds.height > 0 }
            let i = req.int("index") ?? 0
            guard hits.indices.contains(i) else { throw AppControlError.notFound("no view matching \"\(t)\"") }
            let r = hits[i].convert(hits[i].bounds, to: nil)
            return NSPoint(x: r.midX, y: r.midY)
        }
        throw AppControlError.badRequest("need x/y or text")
    }

    private func click(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        let p = try point(req, w)
        let flags = AppControlGeometry.modifiers(req.strings("modifiers") ?? [])
        let hit = w.contentView?.hitTest(w.contentView!.convert(p, from: nil))
        let n = req.int("count") ?? 1
        for i in 1...n {
            func ev(_ t: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: t, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: i, pressure: 1)
            }
            guard let down = ev(.leftMouseDown), let up = ev(.leftMouseUp) else {
                throw AppControlError.failed("could not synthesise mouse events")
            }
            // Controls run a tracking loop on mouseDown that waits for the
            // matching mouseUp in the queue, so queue the up first.
            w.postEvent(up, atStart: false)
            w.sendEvent(down)
        }
        // Let the run loop drain the queued mouseUp and any resulting work.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        return ["hit": hit.map { String(describing: type(of: $0)) } ?? "none"]
    }

    // MARK: - Keyboard

    private func key(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        guard let chars = req.string("chars"), !chars.isEmpty else { throw AppControlError.badRequest("key needs \"chars\"") }
        let flags = AppControlGeometry.modifiers(req.strings("modifiers") ?? [])
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars.lowercased(),
                                           isARepeat: false, keyCode: UInt16(req.int("keyCode") ?? 0))
            else { throw AppControlError.failed("could not synthesise key event") }
            NSApp.sendEvent(e)   // app-level so menu key equivalents (⌘., ⌘V) fire
        }
        return ["sent": chars]
    }

    private func typeText(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        guard let text = req.string("text") else { throw AppControlError.badRequest("type needs \"text\"") }
        guard let client = w.firstResponder as? NSTextInputClient else {
            throw AppControlError.failed("first responder is not a text input: \(String(describing: w.firstResponder))")
        }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return ["typed": text.count]
    }

    // MARK: - Clipboard / drag

    private func paste(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let path = req.string("image"), let img = NSImage(contentsOfFile: path) {
            pb.writeObjects([img])
        } else if let t = req.string("text") {
            pb.setString(t, forType: .string)
        } else { throw AppControlError.badRequest("paste needs \"image\" (path) or \"text\"") }
        w.makeKeyAndOrderFront(nil)
        guard NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) else {
            throw AppControlError.failed("nothing in the responder chain handled paste")
        }
        return ["pasted": true]
    }

    private func drop(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        guard let files = req.strings("files"), !files.isEmpty else { throw AppControlError.badRequest("drop needs \"files\"") }
        let p = try point(req, w)
        guard let cv = w.contentView else { throw AppControlError.failed("no content view") }
        var target = cv.hitTest(cv.convert(p, from: nil))
        while let t = target, t.registeredDraggedTypes.isEmpty { target = t.superview }
        guard let dest = target else { throw AppControlError.notFound("no drop target at that point") }
        let pb = NSPasteboard(name: NSPasteboard.Name("nostromo.appcontrol.\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL })
        let info = FakeDraggingInfo(pasteboard: pb, window: w, location: p)
        let op = dest.draggingEntered(info)
        guard !op.isEmpty else { throw AppControlError.failed("\(type(of: dest)) refused the drag") }
        let accepted = dest.performDragOperation(info)
        dest.concludeDragOperation(info)
        return ["target": String(describing: type(of: dest)), "accepted": accepted]
    }

    // MARK: - Screenshot

    private func screenshot(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        guard let cv = w.contentView, let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else {
            throw AppControlError.failed("cannot capture window")
        }
        cv.cacheDisplay(in: cv.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw AppControlError.failed("png encode failed") }
        let path = req.string("path") ?? NSTemporaryDirectory() + "nostromo-window-\(req.int("window") ?? 0).png"
        try png.write(to: URL(fileURLWithPath: path))
        return ["path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh]
    }
}

/// Minimal `NSDraggingInfo` so a drop can be delivered to a real destination view.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let window: NSWindow
    let location: NSPoint
    init(pasteboard: NSPasteboard, window: NSWindow, location: NSPoint) {
        self.pasteboard = pasteboard; self.window = window; self.location = location
    }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
