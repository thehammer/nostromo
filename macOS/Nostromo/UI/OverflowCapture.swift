import AppKit
import Foundation

/// WO2: the structured, content-free capture of a window whose `MainLayout` pokes past its
/// window (`MainLayout.contentOverflow != .zero`).
///
/// 2026-10-20/21/22: the overflow is runtime state that a relaunch clears, and every measurement
/// had to be taken by hand before the relaunch. This writes the measurement the moment the
/// tripwire sees it, to `~/.nostromo/logs/layout-overflow-<window index>-<UTC>.json` (0600), so the
/// next occurrence hands over the constraint that demands the room.
///
/// **Structure only, never content.** The file holds class names, frames, sizes, priorities and
/// constraint attributes. No `stringValue`, title, tooltip, accessibility label, identifier or text of any
/// kind is read, so no transcript, pane, sidebar label or tab text can reach it. Keep it that way:
/// a new field must be a number, a flag or a class name.
enum OverflowCapture {

    /// At most one capture per window per this long.
    static let minInterval: TimeInterval = 600
    /// The newest this many captures (over all windows) are kept.
    static let keepNewest = 5
    /// How deep below `MainLayout` the tree goes.
    static let maxDepth = 14
    /// A hard cap on the nodes in one file.
    static let maxNodes = 600
    /// Constraints at or above this priority are listed for a view that pokes past the window.
    static let constraintPriorityFloor: Float = 750

    static let filePrefix = "layout-overflow-"
    static let fileSuffix = ".json"

    static var defaultDirectory: URL {
        NostromoHome.current.appendingPathComponent(".nostromo/logs", isDirectory: true)
    }

    // MARK: - Files

    /// `layout-overflow-<window index>-<UTC>.json`, the UTC part sortable (`20261022T073100Z`).
    static func fileName(windowIndex: Int, at date: Date) -> String {
        "\(filePrefix)\(windowIndex)-\(utcStamp(date))\(fileSuffix)"
    }

    /// The newest capture of `windowIndex` in `directory`, or nil when there is none.
    static func latestPath(windowIndex: Int, in directory: URL) -> String? {
        let prefix = "\(filePrefix)\(windowIndex)-"
        return captureURLs(in: directory)
            .filter { $0.lastPathComponent.hasPrefix(prefix) && stamp(of: $0) != nil }
            .max { stamp(of: $0)! < stamp(of: $1)! }?
            .path
    }

    /// Writes the capture for `layout` (which must be in a window), then prunes. Returns the file,
    /// or nil when there is nothing to capture or the write failed. Never throws, never alters layout.
    @discardableResult
    static func write(for layout: MainLayout, windowIndex: Int, focusKind: String,
                      directory: URL, now: Date = Date()) -> URL? {
        guard let window = layout.window else { return nil }
        let report = capture(layout: layout, window: window, windowIndex: windowIndex, focusKind: focusKind, now: now)
        guard JSONSerialization.isValidJSONObject(report),
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        let url = directory.appendingPathComponent(fileName(windowIndex: windowIndex, at: now))
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
        // `createFile` honours the umask; the contract is exactly 0600.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        prune(directory: directory)
        return url
    }

    /// Keeps the newest `keepNewest` captures, over every window.
    static func prune(directory: URL) {
        let ordered = captureURLs(in: directory)
            .compactMap { url in stamp(of: url).map { (url, $0, url.lastPathComponent) } }
            .sorted { ($0.1, $0.2) > ($1.1, $1.2) }
        for (url, _, _) in ordered.dropFirst(keepNewest) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - The report

    /// The whole report as a JSON object. Exposed for tests; `write` is the production entry.
    static func capture(layout: MainLayout, window: NSWindow, windowIndex: Int, focusKind: String,
                        now: Date) -> [String: Any] {
        let content = window.contentRect(forFrameRect: window.frame).size
        let over = MainLayout.overflow(layoutSize: layout.frame.size, contentSize: content)
        var budget = maxNodes
        let tree = node(layout, depth: 0, contentSize: content, budget: &budget)
        return [
            "schema": 1,
            "capturedAtUTC": utcStamp(now),
            "windowIndex": windowIndex,
            "screen": window.screen?.localizedName ?? "none",
            "windowFrame": rect(window.frame),
            "contentSize": size(content),
            "layoutFrame": rect(layout.frame),
            "contentOverflow": ["w": number(over.width), "h": number(over.height)],
            "focus": focusKind,
            "isKey": window.isKeyWindow,
            "fullscreen": window.styleMask.contains(.fullScreen),
            "coordinates": "frameInWindow: AppKit window coordinates, origin bottom-left; frame: in the superview",
            "tree": tree,
        ]
    }

    private static func node(_ view: NSView, depth: Int, contentSize: NSSize, budget: inout Int) -> [String: Any] {
        budget -= 1
        let inWindow = view.convert(view.bounds, to: nil)
        let beyond = pokesPastWindow(inWindow, contentSize: contentSize)
        let intrinsic = view.intrinsicContentSize
        let fitting = view.fittingSize
        // A view whose own minimum is bigger than the room it was given is a demander: what pushes
        // the layout past the window is usually not a view that already pokes out of it. (A text
        // field's width is skipped: a truncating label asks for its whole string by design.)
        let slack = MainLayout.overflowTolerance
        let demandsMore = fitting.height > view.frame.height + slack
            || (!(view is NSTextField) && fitting.width > view.frame.width + slack)
        var out: [String: Any] = [
            "class": String(describing: type(of: view)),
            "frame": rect(view.frame),
            "frameInWindow": rect(inWindow),
            "fittingSize": size(fitting),
            "intrinsicContentSize": size(intrinsic),
            "isHidden": view.isHidden,
            "hugging": ["h": Double(view.contentHuggingPriority(for: .horizontal).rawValue),
                        "v": Double(view.contentHuggingPriority(for: .vertical).rawValue)],
            "compressionResistance": ["h": Double(view.contentCompressionResistancePriority(for: .horizontal).rawValue),
                                      "v": Double(view.contentCompressionResistancePriority(for: .vertical).rawValue)],
            "translatesAutoresizingMask": view.translatesAutoresizingMaskIntoConstraints,
            "pokesPastWindow": beyond,
            "demandsMoreThanItHas": demandsMore,
        ]
        if beyond || demandsMore { out["constraints"] = strongConstraints(touching: view) }
        guard depth < maxDepth else { return out }
        // A scroll view's document is as tall as its whole content (and its children are the
        // content): the scroll view and its document are recorded, nothing below the document.
        let isDocument = view.enclosingScrollView?.documentView === view
        guard !isDocument else { return out }
        var kids: [[String: Any]] = []
        for sub in view.subviews where budget > 0 {
            kids.append(node(sub, depth: depth + 1, contentSize: contentSize, budget: &budget))
        }
        if !kids.isEmpty { out["children"] = kids }
        return out
    }

    private static func pokesPastWindow(_ r: NSRect, contentSize: NSSize) -> Bool {
        let slack = MainLayout.overflowTolerance
        return r.maxX > contentSize.width + slack || r.maxY > contentSize.height + slack
            || r.minX < -slack || r.minY < -slack
    }

    /// Active constraints at priority >= 750 with `view` as an item. A constraint lives on the
    /// nearest common ancestor of its items (or the view itself), so the view and its superviews are searched.
    private static func strongConstraints(touching view: NSView) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var holder: NSView? = view
        while let h = holder, out.count < 32 {
            for c in h.constraints where c.isActive && c.priority.rawValue >= constraintPriorityFloor {
                guard c.firstItem === view || c.secondItem === view else { continue }
                out.append([
                    "first": c.firstItem.map { String(describing: type(of: $0)) } ?? "none",
                    "firstAttribute": attributeName(c.firstAttribute),
                    "relation": relationName(c.relation),
                    "second": c.secondItem.map { String(describing: type(of: $0)) } ?? "none",
                    "secondAttribute": attributeName(c.secondAttribute),
                    "constant": number(c.constant),
                    "multiplier": number(c.multiplier),
                    "priority": Double(c.priority.rawValue),
                    "constraintClass": String(describing: type(of: c)),
                ])
            }
            holder = h.superview
        }
        return out
    }

    // MARK: - Encoding helpers

    /// JSON has no NaN or infinity.
    private static func number(_ v: CGFloat) -> Double { v.isFinite ? Double(v) : -1 }

    private static func size(_ s: NSSize) -> [String: Double] { ["w": number(s.width), "h": number(s.height)] }

    private static func rect(_ r: NSRect) -> [String: Double] {
        ["x": number(r.minX), "y": number(r.minY), "w": number(r.width), "h": number(r.height)]
    }

    private static func attributeName(_ a: NSLayoutConstraint.Attribute) -> String {
        switch a {
        case .left: return "left"
        case .right: return "right"
        case .top: return "top"
        case .bottom: return "bottom"
        case .leading: return "leading"
        case .trailing: return "trailing"
        case .width: return "width"
        case .height: return "height"
        case .centerX: return "centerX"
        case .centerY: return "centerY"
        case .lastBaseline: return "lastBaseline"
        case .firstBaseline: return "firstBaseline"
        case .notAnAttribute: return "none"
        @unknown default: return "attribute\(a.rawValue)"
        }
    }

    private static func relationName(_ r: NSLayoutConstraint.Relation) -> String {
        switch r {
        case .lessThanOrEqual: return "<="
        case .equal: return "=="
        case .greaterThanOrEqual: return ">="
        @unknown default: return "relation\(r.rawValue)"
        }
    }

    // MARK: - File names

    private static func utcStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    private static func captureURLs(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(fileSuffix) }
            .map { directory.appendingPathComponent($0) }
    }

    /// The sortable UTC part of a capture's file name, nil for a name that is not one of ours.
    private static func stamp(of url: URL) -> String? {
        var name = url.lastPathComponent
        guard name.hasPrefix(filePrefix), name.hasSuffix(fileSuffix) else { return nil }
        name.removeLast(fileSuffix.count)
        guard let stamp = name.split(separator: "-").last, stamp.count == 16, stamp.hasSuffix("Z") else { return nil }
        return String(stamp)
    }
}
