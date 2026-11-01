import AppKit
import os
import NostromoKit

private let ctlLog = Logger(subsystem: "com.hammer.nostromo.mac", category: "AppControl")

/// A local control socket that lets a script (or an agent) drive the real app —
/// click, type, press keys, drop files, dump the view tree, take a window
/// screenshot — so UI behaviour can be QA'd without a human in the loop.
///
/// **Opt-in.** The socket can click anything in the app, so it only starts when
/// `NOSTROMO_APP_CONTROL=1` is in the environment or the `AppControlEnabled`
/// default is true:
///
///     defaults write com.hammer.nostromo AppControlEnabled -bool true
///
/// The socket lives at `~/.nostromo/app-control.sock`, mode 0600 (owner only).
/// Events are *synthesised and sent through `NSWindow.sendEvent`*, so they take
/// the same hit-testing and responder path a real click does — a bug like a
/// sibling overlay swallowing clicks reproduces here, which a direct
/// `button.performClick` would hide.
final class AppControlServer {

    static let shared = AppControlServer()
    /// `NOSTROMO_APP_CONTROL_SOCKET` (set by the isolated QA instance so it never touches the
    /// user's socket), else `~/.nostromo/app-control.sock`.
    static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["NOSTROMO_APP_CONTROL_SOCKET"], !override.isEmpty {
            return override
        }
        return NostromoHome.current
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
        // SwiftUI only builds its accessibility tree when an assistive client is
        // present; this is what an AX client sets, and it lets `find`/`tree` see
        // text SwiftUI draws itself (e.g. the Mother job list).
        NSApp.accessibilitySetValue(true as NSNumber, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true as NSNumber, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
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
                // Everything a request does happens inside the gate, so a control
                // that answers an agent refuses it (`HumanGesture`).
                DispatchQueue.main.sync {
                    SyntheticInputGate.begin()
                    defer { SyntheticInputGate.end() }
                    reply = self.handle(line)
                }
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
        case "layout-issues": return try layoutIssues(req)
        case "ax":          return try axDump(req)
        case "activate":    return try activate(req)
        case "restore":     return restoreFocus()
        case "click":       return try click(req)
        case "drag":        return try drag(req)
        case "hittest":     return try hitTest(req)
        case "transcript-anchor": return try transcriptAnchor(req)
        case "tracker":     return try tracker(req)
        case "tracker-anchor": return try trackerAnchor(req)
        case "tasks":       return try tasks(req)
        case "capture-render-state": return captureRenderState()
        case "approvals":   return try approvals(req)
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
        // `"screen": "Sceptre"` picks the window on the display whose name contains
        // that text. Window *indices* are assigned at launch and can map to a
        // different display after a relaunch, so scripts that must not touch the
        // operator's own display select by screen.
        var i = req.int("window") ?? 0
        if let screenName = req.string("screen")?.lowercased() {
            guard let found = appDelegate?.windows.firstIndex(where: {
                $0.screen?.localizedName.lowercased().contains(screenName) == true
            }) else { throw AppControlError.notFound("no window on a display named like \"\(screenName)\"") }
            i = found
        }
        guard let wins = appDelegate?.windows, wins.indices.contains(i) else {
            throw AppControlError.noSuchWindow(i)
        }
        // `"sheet": true` targets the sheet attached to that window (New Focus,
        // decision prompts…), which is a separate NSWindow.
        if (req.args["sheet"] as? Bool) == true {
            guard let sheet = wins[i].attachedSheet else { throw AppControlError.notFound("window \(i) has no sheet") }
            return sheet
        }
        return wins[i]
    }

    private func contentHeight(_ w: NSWindow) -> Double { Double(w.contentView?.bounds.height ?? 0) }

    private func windowsInfo() -> [[String: Any]] {
        (appDelegate?.windows ?? []).enumerated().map { i, w in
            let layout = w.contentView as? MainLayout
            let overflow = layout?.contentOverflow ?? .zero
            return ["index": i, "title": w.title,
             "frame": ["x": w.frame.minX, "y": w.frame.minY, "w": w.frame.width, "h": w.frame.height],
             "fullscreen": w.styleMask.contains(.fullScreen),
             "key": w.isKeyWindow,
             "screen": w.screen?.localizedName ?? "none",
             "alpha": w.alphaValue,
             "visible": w.occlusionState.contains(.visible),
             "windowNumber": w.windowNumber,
             "sheet": w.attachedSheet.map { $0.title.isEmpty ? String(describing: type(of: $0)) : $0.title } as Any,
             "firstResponder": w.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
             // How far the content view pokes past the window, in points; 0 on an axis that
             // fits. A QA script asserts both are 0 (the 2026-10-21 overflow was 795 x 70).
             "contentOverflow": ["w": overflow.width, "h": overflow.height],
             // The newest structured capture of this window's overflow (`layout-overflow-<index>-<UTC>.json`,
             // content-free), or null. If `contentOverflow` is non-zero, do not relaunch: send this file.
             "overflowCapture": layout?.latestOverflowCapturePath.map { $0 as Any } ?? NSNull(),
             // The newest content-free capture of a transcript pane in this window going blank
             // (`pane-blank-<tag hash>-<UTC>.json`), or null. When a pane blanks, send this path.
             "blankCapture": latestBlankCapturePath(in: w).map { $0 as Any } ?? NSNull()]
        }
    }

    /// The newest `pane-blank-*.json` of any transcript pane in `window`, visible or not.
    private func latestBlankCapturePath(in window: NSWindow) -> String? {
        var paths: [String] = []
        // A transcript pane sits a few levels below the content view; the cap only guards a pathological tree.
        func walk(_ v: NSView, depth: Int) {
            if let pane = v as? ReplView, let path = pane.renderWatch.latestCapturePath { paths.append(path) }
            guard depth < 32 else { return }
            v.subviews.forEach { walk($0, depth: depth + 1) }
        }
        if let content = window.contentView { walk(content, depth: 0) }
        return PaneBlankCapture.newest(of: paths)
    }

    /// `capture-render-state`: Debug ▸ Capture render state now, for scripts. Writes a capture for
    /// every transcript pane on screen right away (no rate limit) and returns the paths.
    private func captureRenderState() -> Any {
        ["files": PaneRenderWatch.captureAllVisible().map(\.path)]
    }

    // MARK: - Tree / find

    private func text(of v: NSView) -> String? {
        AppControlAX.text(of: v)
    }

    private func node(_ v: NSView, in w: NSWindow, depth: Int, maxDepth: Int, visibleOnly: Bool) -> [String: Any]? {
        if visibleOnly && v.isHidden { return nil }
        let frameInWindow = v.convert(v.bounds, to: nil)
        if v is StagingDrawerView, AppControlAX.isWithheld(v) {
            // Staged commands are the user's to read on screen, not app-control's: one fixed entry, no children.
            return ["class": "StagingDrawerView", "text": AppControlAX.stagedHiddenText,
                    "frame": AppControlGeometry.topLeftRect(viewFrameInWindow: frameInWindow, contentHeight: contentHeight(w))]
        }
        var n: [String: Any] = [
            "class": String(describing: type(of: v)),
            "frame": AppControlGeometry.topLeftRect(viewFrameInWindow: frameInWindow, contentHeight: contentHeight(w)),
        ]
        if v.isHidden { n["hidden"] = true }
        if let t = text(of: v) { n["text"] = t }
        if let tip = v.toolTip { n["tooltip"] = tip }
        if let l = v.accessibilityLabel(), !l.isEmpty { n["label"] = l }
        if depth < maxDepth {
            var kids = v.subviews.compactMap { node($0, in: w, depth: depth + 1, maxDepth: maxDepth, visibleOnly: visibleOnly) }
            if isHostingView(v) {
                // SwiftUI content: surface its accessibility elements as leaf nodes.
                kids += AppControlAX.hits(under: v, in: w).map { h in
                    ["class": h.cls, "text": h.text ?? "",
                     "frame": AppControlGeometry.topLeftRect(viewFrameInWindow: h.rectInWindow, contentHeight: contentHeight(w))]
                }
            }
            if !kids.isEmpty { n["children"] = kids }
        }
        return n
    }

    private func tree(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        guard let cv = w.contentView else { throw AppControlError.failed("window has no content view") }
        // A display that is asleep/locked suspends the display cycle, so pending
        // layout may not have run; make the dump reflect the real layout.
        cv.layoutSubtreeIfNeeded()
        return node(cv, in: w, depth: 0, maxDepth: req.int("depth") ?? 12, visibleOnly: true) ?? [:]
    }

    private typealias Hit = AppControlHit

    private func isHostingView(_ v: NSView) -> Bool {
        String(describing: type(of: v)).contains("HostingView")
    }

    private func hit(for v: NSView) -> Hit {
        Hit(cls: String(describing: type(of: v)), text: text(of: v), rectInWindow: v.convert(v.bounds, to: nil))
    }

    /// Views and accessibility elements whose text, tooltip, label or class name
    /// contains `needle` (case-insensitive).
    private func matches(_ needle: String, in w: NSWindow) -> [Hit] {
        var out: [Hit] = []
        func walk(_ v: NSView) {
            if v.isHidden { return }
            if v is StagingDrawerView, AppControlAX.isWithheld(v) {
                if v.window != nil, AppControlAX.stagedHiddenText.contains(needle) { out.append(Hit(cls: "StagingDrawerView", text: AppControlAX.stagedHiddenText, rectInWindow: v.convert(v.bounds, to: nil))) }
                return
            }
            let hay = [text(of: v), v.toolTip, v.accessibilityLabel(), String(describing: type(of: v))]
                .compactMap { $0?.lowercased() }
            if v.window != nil, hay.contains(where: { $0.contains(needle) }) { out.append(hit(for: v)) }
            if isHostingView(v) {
                out += AppControlAX.hits(under: v, in: w).filter { $0.text?.lowercased().contains(needle) == true }
            }
            v.subviews.forEach(walk)
        }
        if let cv = w.contentView { walk(cv) }
        return out
    }

    private func find(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        w.contentView?.layoutSubtreeIfNeeded()
        guard let needle = req.string("text")?.lowercased(), !needle.isEmpty else {
            throw AppControlError.badRequest("find needs \"text\"")
        }
        return matches(needle, in: w).map { h in
            let r = AppControlGeometry.topLeftRect(viewFrameInWindow: h.rectInWindow, contentHeight: contentHeight(w))
            var d: [String: Any] = ["class": h.cls, "frame": r,
                                    "center": ["x": r["x"]! + r["w"]! / 2, "y": r["y"]! + r["h"]! / 2]]
            if let t = h.text { d["text"] = t }
            return d
        }
    }

    /// Auto Layout audit: views whose layout is ambiguous, or that ended up
    /// zero-sized while holding constraints that should have sized them.
    private func layoutIssues(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        guard let cv = w.contentView else { throw AppControlError.failed("no content view") }
        cv.layoutSubtreeIfNeeded()
        var out: [[String: Any]] = []
        func walk(_ v: NSView) {
            if v.isHidden { return }
            let h = v.constraintsAffectingLayout(for: .horizontal).count
            let vt = v.constraintsAffectingLayout(for: .vertical).count
            let zero = v.bounds.width == 0 || v.bounds.height == 0
            if v.hasAmbiguousLayout || (zero && (h > 0 || vt > 0) && !v.translatesAutoresizingMaskIntoConstraints) {
                var d: [String: Any] = ["class": String(describing: type(of: v)),
                                        "ambiguous": v.hasAmbiguousLayout, "zeroSized": zero,
                                        "frame": AppControlGeometry.topLeftRect(viewFrameInWindow: v.convert(v.bounds, to: nil),
                                                                                 contentHeight: contentHeight(w)),
                                        "constraints": v.constraints.map { "\($0)" }.prefix(8).map { $0 }]
                if let t = text(of: v) { d["text"] = t }
                out.append(d)
            }
            v.subviews.forEach(walk)
        }
        walk(cv)
        return out
    }

    /// Raw accessibility tree of the first view whose class name contains `class`
    /// (debugging aid for SwiftUI content).
    private func axDump(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        let needle = (req.string("class") ?? "HostingView").lowercased()
        var target: NSView?
        func walk(_ v: NSView) { if target == nil, String(describing: type(of: v)).lowercased().contains(needle) { target = v }; v.subviews.forEach(walk) }
        if let cv = w.contentView { walk(cv) }
        guard let t = target else { throw AppControlError.notFound("no view with class containing \(needle)") }
        var o = AppControlAX.dump(t, 0)
        if AppControlAX.isWithheld(t) { return o }
        o["isAccessibilityElement"] = t.isAccessibilityElement()
        o["enhancedUI"] = NSApp.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")) as Any
        o["cellRows"] = (t.accessibilityRows() ?? []).count
        return o
    }

    // MARK: - Focus

    /// The app that was frontmost before `activate`, so `restore` can hand focus back.
    private var previousFrontmost: NSRunningApplication?

    /// Make the app active and a window key. Needed because AppKit ignores the
    /// first click on a non-key window in an inactive app, so table selection and
    /// other first-mouse-sensitive controls do nothing until then. This takes
    /// keyboard focus from whatever the operator is using — scenarios call it
    /// on purpose, run `restore` when done, and should only run while nobody is
    /// typing elsewhere.
    private func activate(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        if !NSApp.isActive { previousFrontmost = NSWorkspace.shared.frontmostApplication }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        return ["active": NSApp.isActive, "key": w.isKeyWindow,
                "previous": previousFrontmost?.bundleIdentifier as Any]
    }

    /// Hand keyboard focus back to the app that had it before `activate`.
    private func restoreFocus() -> Any {
        let prev = previousFrontmost
        previousFrontmost = nil
        if let prev, prev.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            prev.activate(options: [])
            return ["restored": prev.bundleIdentifier as Any]
        }
        return ["restored": NSNull()]
    }

    // MARK: - Mouse

    private func point(_ req: AppControlRequest, _ w: NSWindow) throws -> NSPoint {
        if let x = req.double("x"), let y = req.double("y") {
            return AppControlGeometry.windowPoint(x: x, y: y, contentHeight: contentHeight(w))
        }
        if let t = req.string("text")?.lowercased() {
            let hits = matches(t, in: w).filter { $0.rectInWindow.width > 0 && $0.rectInWindow.height > 0 }
            let i = req.int("index") ?? 0
            guard hits.indices.contains(i) else { throw AppControlError.notFound("no view matching \"\(t)\"") }
            let r = hits[i].rectInWindow
            return NSPoint(x: r.midX, y: r.midY)
        }
        throw AppControlError.badRequest("need x/y or text")
    }

    private func click(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        let p = try point(req, w)
        let flags = AppControlGeometry.modifiers(req.strings("modifiers") ?? [])
        let hit = w.contentView?.hitTest(w.contentView!.convert(p, from: nil))
        try AppControlMouse.click(in: w, at: p, flags: flags, count: req.int("count") ?? 1)
        // Let the run loop drain any resulting work.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        return ["hit": hit.map { String(describing: type(of: $0)) } ?? "none"]
    }

    /// Which view a click at x/y would land on, and the focus state around it.
    /// Read-only: no event is sent.
    private func hitTest(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        guard req.double("x") != nil, req.double("y") != nil else {
            throw AppControlError.badRequest("hittest needs x and y")
        }
        return AppControlHitTest.report(in: w, at: try point(req, w))
    }

    /// READ-ONLY scroll-safety probe: the transcript's first visible block and viewport offsets
    /// (`TranscriptAnchorProbe`). Sends no event, changes no focus, forces no layout.
    /// The pane: the `ReplView` whose tag is `focus`, else the one holding the first responder,
    /// else the window's only visible one.
    private func transcriptAnchor(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        let pane = try pickPane(req, in: w)
        let index = appDelegate?.windows.firstIndex(where: { $0 === w }) ?? req.int("window") ?? 0
        let data = try JSONEncoder().encode(pane.anchorSnapshot(windowIndex: index))
        return try JSONSerialization.jsonObject(with: data)
    }

    /// The transcript pane a request means: the visible `ReplView` tagged `focus`, else the one
    /// holding the first responder, else the window's only visible one.
    private func pickPane(_ req: AppControlRequest, in w: NSWindow) throws -> ReplView {
        var panes: [ReplView] = []
        func walk(_ v: NSView) {
            if let pane = v as? ReplView, !pane.isHiddenOrHasHiddenAncestor { panes.append(pane) }
            v.subviews.forEach(walk)
        }
        if let content = w.contentView { walk(content) }
        let tags = panes.map { $0.diagnosticsTag }
        if let tag = req.string("focus") {
            guard let found = panes.first(where: { $0.diagnosticsTag == tag }) else {
                throw AppControlError.notFound("no visible pane tagged \"\(tag)\" in window; visible tags: \(tags)")
            }
            return found
        } else if let responder = w.firstResponder as? NSView,
                  let found = panes.first(where: { responder === $0 || responder.isDescendant(of: $0) }) {
            return found
        } else if panes.count == 1 {
            return panes[0]
        }
        throw AppControlError.notFound("no pane to pick (\(panes.count) visible); pass focus=TAG; visible tags: \(tags)")
    }

    /// READ-ONLY (`tasks list [--all] | chip | output TASK_ID [--focus TAG]`): what the Background activity
    /// popover lists and what the chip shows, from the same model they render (`AppControlTasks`), and a
    /// task's output from the model its window reads (`output`; withheld in the real app). With `focus`,
    /// that focus's tasks whether or not a pane shows it. Sends no event, changes no focus, stops nothing,
    /// marks nothing seen, opens no window.
    private func tasks(_ req: AppControlRequest) throws -> Any {
        let sub = req.string("sub") ?? "list"
        guard sub == "list" || sub == "chip" || sub == "output" else {
            throw AppControlError.badRequest("tasks: only `list`, `chip` and `output` exist (all read-only)")
        }
        let tag: String
        if let focus = req.string("focus") {
            try AppControlTasks.requireKnownFocus(focus, known: knownFocusTags())
            tag = focus
        } else {
            tag = try pickPane(req, in: try window(req)).diagnosticsTag
        }
        if sub == "output" {
            guard let taskId = req.string("task") else {
                throw AppControlError.badRequest("tasks output: needs a task id")
            }
            guard BackgroundTaskStore.shared.state(for: tag)?.allTasks.contains(where: { $0.id == taskId }) == true else {
                throw AppControlError.notFound("no task \"\(taskId)\" in focus \"\(tag)\"")
            }
            // A first ask starts the read and answers `loading`; ask again.
            let model = TaskOutputRegistry.shared.model(tag: tag, taskId: taskId)
            // Held a few seconds past this answer: acquiring refreshes a model already ready, and the
            // hold lets that read (and the next polls) land before the next ask.
            model.acquire()
            DispatchQueue.main.asyncAfter(deadline: .now() + AppControlTasks.outputHoldSeconds) { model.release() }
            return AppControlTasks.output(tag: tag, taskId: taskId, model: model,
                                          allowsText: SyntheticInputGate.allowsSynthetic)
        }
        let list = BackgroundTaskStore.shared.list(for: tag)
        if sub == "chip" { return AppControlTasks.chip(tag: tag, list: list) }
        return AppControlTasks.list(tag: tag, list: list, all: (req.args["all"] as? Bool) == true,
                                    windowOpen: { TaskWindowManager.shared.isOpen(tag: tag, taskId: $0) })
    }

    /// Every focus tag the app knows: each pane in every window (visible or not) and each the task store
    /// holds tasks for.
    private func knownFocusTags() -> Set<String> {
        var tags = Set(BackgroundTaskStore.shared.states.keys)
        func walk(_ v: NSView) {
            if let pane = v as? ReplView { tags.insert(pane.diagnosticsTag) }
            v.subviews.forEach(walk)
        }
        for w in appDelegate?.windows ?? [] { if let content = w.contentView { walk(content) } }
        return tags
    }

    /// The visible tracker panes of `w`, and the one a tracker request means: the pane tagged `focus`,
    /// else the one beside the transcript holding the first responder, else the window's only one.
    private func trackerPanes(in w: NSWindow) -> [TrackerPaneView] {
        var panes: [TrackerPaneView] = []
        func walk(_ v: NSView) {
            if let pane = v as? TrackerPaneView, !pane.isHiddenOrHasHiddenAncestor { panes.append(pane) }
            v.subviews.forEach(walk)
        }
        if let content = w.contentView { walk(content) }
        return panes
    }

    private func pickTrackerPane(_ req: AppControlRequest, in w: NSWindow) throws -> TrackerPaneView? {
        let panes = trackerPanes(in: w)
        if let tag = req.string("focus") { return panes.first { $0.focusTag == tag } }
        if let responder = w.firstResponder as? NSView {
            var v: NSView? = responder
            while let view = v {
                if let pane = view as? TrackerPaneView { return pane }
                if let repl = view as? ReplView, let pane = panes.first(where: { $0.focusTag == repl.diagnosticsTag }) { return pane }
                v = view.superview
            }
        }
        if panes.count == 1 { return panes[0] }
        throw AppControlError.notFound("no tracker pane to pick (\(panes.count) visible); pass focus=TAG; visible tags: \(panes.map(\.focusTag))")
    }

    /// READ-ONLY (`tracker show|file [--focus TAG]`): what the tracker pane shows, or the board's file.
    /// With no pane on screen for `focus`, `show` reports what the store's board would show
    /// (`visible: false`). Sends no event, changes no focus, writes nothing.
    private func tracker(_ req: AppControlRequest) throws -> Any {
        let sub = req.string("sub") ?? "show"
        guard sub == "show" || sub == "file" else {
            throw AppControlError.badRequest("tracker: only `show` and `file` exist (both read-only)")
        }
        let w = try window(req)
        let pane = try pickTrackerPane(req, in: w)
        guard let tag = pane?.focusTag ?? req.string("focus") else {
            throw AppControlError.notFound("no tracker pane in window; pass focus=TAG")
        }
        let board = pane?.board ?? TrackerStore.shared.board(for: tag)
        if sub == "file" {
            return AppControlTracker.file(tag: tag, board: board,
                                          fileSize: board.flatMap { AppControlTracker.fileSize(atPath: $0.path) })
        }
        if let pane { return pane.showReport() }
        let presentation = board.map { TrackerPresenter.present(board: $0, now: Date()) }
        return AppControlTracker.show(tag: tag, presentation: presentation, displayedRows: nil, visible: false)
    }

    /// READ-ONLY tracker scroll-safety probe: the first visible row, the offset of the viewport top
    /// into it, the scroll position and the held (deferred) changes. Forces no layout.
    private func trackerAnchor(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        guard let pane = try pickTrackerPane(req, in: w) else {
            throw AppControlError.notFound("no visible tracker pane tagged \"\(req.string("focus") ?? "")\" in window")
        }
        let index = appDelegate?.windows.firstIndex(where: { $0 === w }) ?? req.int("window") ?? 0
        let data = try JSONEncoder().encode(pane.anchorSnapshot(windowIndex: index))
        return try JSONSerialization.jsonObject(with: data)
    }

    /// READ-ONLY: the approval cards on screen right now (`approvals list [--focus TAG] [-w N]`), read from
    /// the cards' own views. Sends no event, changes no focus, answers nothing. One entry per request,
    /// with the indexes of every window showing it (`windows`) and, per window, where that window's card
    /// is (`window_cards`: `window`, `page`, `of`, `state`). `page` and `of` (`1 of 3`) are the first
    /// window's. `guard_bars` lists the production-shell guard bars on screen. With `only_window` (the
    /// CLI's explicit `-w`), only that window's hosts are read.
    private func approvals(_ req: AppControlRequest) throws -> Any {
        let sub = req.string("sub") ?? "list"
        if sub == "badges" { return approvalBadges() }
        if sub == "session-rules" { return approvalSessionRules(focus: req.string("focus")) }
        guard sub == "list" else {
            throw AppControlError.badRequest("approvals: only `list`, `badges` and `session-rules` exist (all read-only)")
        }
        let focus = req.string("focus")
        let onlyWindow = req.int("only_window")
        var byRequest: [String: [String: Any]] = [:]
        var order: [String] = []
        var guardBars: [[String: Any]] = []
        for (index, window) in (appDelegate?.windows ?? []).enumerated() where onlyWindow == nil || onlyWindow == index {
            var hosts: [ApprovalOverlayHost] = []
            func walk(_ v: NSView) {
                if let host = v as? ApprovalOverlayHost, !host.isHiddenOrHasHiddenAncestor { hosts.append(host) }
                v.subviews.forEach(walk)
            }
            if let content = window.contentView { walk(content) }
            for host in hosts where focus == nil || host.focusTag == focus {
                if let text = host.guardBarText {
                    guardBars.append(["window": index, "focus": host.focusTag, "text": text])
                }
                for listing in host.listings {
                    var entry = byRequest[listing.requestID] ?? listing.jsonObject
                    if byRequest[listing.requestID] == nil {
                        order.append(listing.requestID)
                        entry["collapsed"] = host.isCollapsed   // the first window's; each window's own is in `window_cards`
                    }
                    entry["windows"] = ((entry["windows"] as? [Int]) ?? []) + [index]
                    var card: [String: Any] = ["window": index, "page": listing.page, "of": listing.of, "state": listing.state,
                                               "collapsed": host.isCollapsed]
                    if let bar = host.collapsedBar { card["bar_text"] = bar.text; card["bar_countdown"] = bar.countdownText }
                    entry["window_cards"] = ((entry["window_cards"] as? [[String: Any]]) ?? []) + [card]
                    byRequest[listing.requestID] = entry
                }
            }
        }
        return ["approvals": order.compactMap { byRequest[$0] }, "guard_bars": guardBars]
    }

    /// READ-ONLY: the active "Allow for this session" rules (`approvals session-rules [--focus TAG]`), as the
    /// store holds them: `focuses: [{tag, rules: [{id, rule_text, summary, kind, created_at_ms, uses, agent_id}]}]`.
    /// Presses, selects and revokes nothing: no app-control command can complete either step of the gate.
    private func approvalSessionRules(focus: String?) -> Any {
        let store = ApprovalStore.shared
        let tags = store.sessionRuleTags.filter { focus == nil || $0 == focus }.sorted()
        let focuses: [[String: Any]] = tags.map { tag in
            ["tag": tag,
             "rules": store.sessionRules(tag: tag).map { rule -> [String: Any] in
                 ["id": rule.id, "rule_text": rule.ruleText, "summary": rule.summary, "kind": rule.kind.rawValue,
                  "created_at_ms": rule.createdAtMs, "uses": rule.uses, "agent_id": rule.agentId ?? NSNull()]
             }]
        }
        return ["focuses": focuses]
    }

    /// READ-ONLY: what the approvals surfaces outside the card show (`approvals badges`): the red "needs
    /// you now" pill on each sidebar row that has one (`focuses: [{tag, pill}]`, from the rows' own views in
    /// the first window that has any) and the Dock badge (`dock`, the label the one coordinator last wrote to the Dock tile, null
    /// when clear). Sends no event, changes no focus.
    private func approvalBadges() -> Any {
        var focuses: [[String: Any]] = []
        for window in appDelegate?.windows ?? [] {
            var found: [[String: Any]] = []
            func walk(_ v: NSView) {
                if let item = v as? NavTabItem, item.showsNeedsYouNow, let pill = item.pillText {
                    found.append(["tag": item.focus.sessionTag, "pill": pill])
                }
                v.subviews.forEach(walk)
            }
            if let content = window.contentView { walk(content) }
            if !found.isEmpty { focuses = found; break }
        }
        return ["focuses": focuses, "dock": AppStore.shared.needsYouCoordinator.dockLabel.map { $0 as Any } ?? NSNull()]
    }

    /// Press at one point, drag to another, release — for selecting text.
    /// `fromX/fromY` and `toX/toY`, or `text` (+ `index`) for the start and
    /// `toX/toY` for the end.
    private func drag(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        let from: NSPoint
        if let fx = req.double("fromX"), let fy = req.double("fromY") {
            from = AppControlGeometry.windowPoint(x: fx, y: fy, contentHeight: contentHeight(w))
        } else {
            from = try point(req, w)
        }
        guard let tx = req.double("toX"), let ty = req.double("toY") else {
            throw AppControlError.badRequest("drag needs toX/toY")
        }
        let to = AppControlGeometry.windowPoint(x: tx, y: ty, contentHeight: contentHeight(w))
        let flags = AppControlGeometry.modifiers(req.strings("modifiers") ?? [])
        let hit = w.contentView?.hitTest(w.contentView!.convert(from, from: nil))
        try AppControlMouse.drag(in: w, from: from, to: to, steps: req.int("steps") ?? 8, flags: flags)
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
                    .map(SyntheticInputGate.stamped)
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

    /// Window screenshot. Preferred path asks the window server for this app's
    /// own window (needs no Screen Recording permission for one's own windows)
    /// via `CGWindowListCreateImage`, looked up dynamically because newer SDKs
    /// mark it unavailable. Fallback is `cacheDisplay`, which is faithful for
    /// ordinary views but paints layer-backed content (e.g. sheets) as blank.
    private static func isUniform(_ rep: NSBitmapImageRep) -> Bool {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 1, h > 1, let first = rep.colorAt(x: 0, y: 0) else { return true }
        for i in 0..<64 {
            let x = (w - 1) * (i % 8) / 7, y = (h - 1) * (i / 8) / 7
            if let c = rep.colorAt(x: x, y: y),
               abs(c.redComponent - first.redComponent) > 0.02 || abs(c.greenComponent - first.greenComponent) > 0.02
                || abs(c.blueComponent - first.blueComponent) > 0.02 { return false }
        }
        return true
    }

    /// In the real app every terminal pane is painted over before the PNG exists (`ScreenshotRedaction`):
    /// a picture of a terminal would bypass `nostromo_read_terminal_screen`'s follow and redaction. The
    /// capture lives only in memory until then; a terminal that can't be placed in it refuses the
    /// screenshot. A QA build that allows synthetic input (`SyntheticInputGate.allowsSynthetic`) gets the
    /// unchanged picture. Nothing else in app-control returns pixels.
    private func screenshot(_ req: AppControlRequest) throws -> Any {
        let w = try window(req)
        guard let cv = w.contentView else { throw AppControlError.failed("no content view") }
        // The terminal areas are read from the view tree, the picture from the window server: commit
        // layout and drawing first so both describe the same frame (a pane resized a moment ago must not
        // sit at its old place in the picture while its block is painted at the new one).
        cv.layoutSubtreeIfNeeded()
        w.displayIfNeeded()
        CATransaction.flush()
        let path = req.string("path") ?? NSTemporaryDirectory() + "nostromo-window-\(req.int("window") ?? 0).png"

        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        var method = "cgwindow"
        var rep: NSBitmapImageRep?
        // Where the image sits in window base coordinates: the whole frame for a window-server capture.
        var captureRect = NSRect(origin: .zero, size: w.frame.size)
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {   // RTLD_DEFAULT
            let create = unsafeBitCast(sym, to: CreateImage.self)
            // .optionIncludingWindow = 1<<3, boundsIgnoreFraming = 1<<0
            if req.string("method") != "cache",
               let cg = create(.null, 1 << 3, UInt32(w.windowNumber), 1 << 0)?.takeRetainedValue() {
                let candidate = NSBitmapImageRep(cgImage: cg)
                // A locked / asleep display is not composited, so the window
                // server hands back a flat image. Treat that as "no capture".
                if !Self.isUniform(candidate) { rep = candidate }
            }
        }
        if rep == nil {
            method = "cacheDisplay"
            guard let r = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else { throw AppControlError.failed("cannot capture window") }
            cv.cacheDisplay(in: cv.bounds, to: r)
            rep = r
            captureRect = cv.convert(cv.bounds, to: nil)
        }
        guard let out = rep else { throw AppControlError.failed("png encode failed") }
        let png: Data
        do {
            png = try ScreenshotRedaction.pngData(of: out, window: w, captureRect: captureRect)
        } catch let e as ScreenshotRedactionError {
            throw AppControlError.failed("screenshot refused: \(e.description)")
        }
        try png.write(to: URL(fileURLWithPath: path))
        return ["path": path, "width": out.pixelsWide, "height": out.pixelsHigh, "windowNumber": w.windowNumber, "method": method,
                "terminalsHidden": !SyntheticInputGate.allowsSynthetic]
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
