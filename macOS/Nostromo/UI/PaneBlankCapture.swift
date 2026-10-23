import Foundation

/// The files a "transcript pane went blank" capture is written to, and how they are kept.
///
/// `~/.nostromo/logs/pane-blank-<tag hash>-<UTC>[-manual].json`, one per incident (the rate limit lives
/// in `PaneRenderWatch`), the directory 0700 and each file exactly 0600. The newest `keepNewest`
/// automatic captures and, separately, the newest `keepNewest` manual ones are kept over all panes, so
/// pressing the menu item cannot evict the evidence a detector hit wrote. What goes in a file is built
/// by `PaneRenderWatch.report`; it is structure only (numbers, flags, class and kind names), never any
/// text. The pane is named by `tagHash` alone.
enum PaneBlankCapture {

    static let filePrefix = "pane-blank-"
    static let fileSuffix = ".json"
    /// The newest this many automatic captures, and the newest this many manual ones (each over all
    /// panes), are kept.
    static let keepNewest = 8
    private static let manualMarker = "manual"

    static var defaultDirectory: URL {
        NostromoHome.current.appendingPathComponent(".nostromo/logs", isDirectory: true)
    }

    // MARK: - Names

    /// A stable (FNV-1a, not Swift's per-process randomised hash) 8-hex-digit name for a pane tag, so
    /// the same pane gets the same prefix across launches and the tag itself never reaches a file.
    static func tagHash(_ tag: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in tag.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    /// `pane-blank-<tag hash>-<UTC>.json` (`-manual` after the UTC part for a manual capture), the UTC
    /// part sortable (`20261023T073100Z`).
    static func fileName(tagHash: String, at date: Date, manual: Bool = false) -> String {
        "\(filePrefix)\(tagHash)-\(utcStamp(date))\(manual ? "-" + manualMarker : "")\(fileSuffix)"
    }

    // MARK: - Finding

    /// The newest capture (of one pane when `tagHash` is given), or nil when there is none.
    static func latestPath(tagHash: String? = nil, in directory: URL) -> String? {
        captureURLs(in: directory)
            .compactMap { url in parts(of: url).map { (url, $0) } }
            .filter { tagHash == nil || $0.1.hash == tagHash }
            .max { ($0.1.stamp, $0.1.sequence) < ($1.1.stamp, $1.1.sequence) }?
            .0.path
    }

    /// The newest of `paths` by the UTC stamp in its name (names that are not captures are ignored).
    static func newest(of paths: [String]) -> String? {
        paths
            .compactMap { path in parts(of: URL(fileURLWithPath: path)).map { (path, $0) } }
            .max { ($0.1.stamp, $0.1.sequence) < ($1.1.stamp, $1.1.sequence) }?
            .0
    }

    // MARK: - Writing

    /// Writes `report` (which must be valid JSON content), then prunes. Returns the file, or nil when
    /// the write failed. Never overwrites: a second capture in the same second takes a `-2`, `-3` suffix.
    @discardableResult
    static func write(_ report: [String: Any], tagHash: String, directory: URL, now: Date = Date(),
                      manual: Bool = false) -> URL? {
        guard JSONSerialization.isValidJSONObject(report),
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        let base = fileName(tagHash: tagHash, at: now, manual: manual)
        var url = directory.appendingPathComponent(base)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(String(base.dropLast(fileSuffix.count)) + "-\(n)" + fileSuffix)
            n += 1
        }
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
        // `createFile` honours the umask; the contract is exactly 0600.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        prune(directory: directory)
        return url
    }

    /// Keeps the newest `keepNewest` automatic and the newest `keepNewest` manual captures, over every
    /// pane. Touches nothing that is not one of ours.
    static func prune(directory: URL) {
        let ordered = captureURLs(in: directory)
            .compactMap { url in parts(of: url).map { (url, $0) } }
            .sorted { ($0.1.stamp, $0.1.sequence, $0.1.hash) > ($1.1.stamp, $1.1.sequence, $1.1.hash) }
        for manual in [false, true] {
            for (url, _) in ordered.filter({ $0.1.manual == manual }).dropFirst(keepNewest) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Private

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

    /// `<hash>-<UTC>[-manual][-<n>]` from a capture's name; nil for a name that is not one of ours.
    private static func parts(of url: URL) -> (hash: String, stamp: String, manual: Bool, sequence: Int)? {
        var name = url.lastPathComponent
        guard name.hasPrefix(filePrefix), name.hasSuffix(fileSuffix) else { return nil }
        name.removeFirst(filePrefix.count)
        name.removeLast(fileSuffix.count)
        var pieces = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count >= 2, pieces[0].count == 8, pieces[1].count == 16, pieces[1].hasSuffix("Z")
        else { return nil }
        let hash = pieces[0], stamp = pieces[1]
        pieces.removeFirst(2)
        let manual = pieces.first == manualMarker
        if manual { pieces.removeFirst() }
        guard pieces.count <= 1 else { return nil }
        guard let tail = pieces.first else { return (hash, stamp, manual, 1) }
        guard let sequence = Int(tail) else { return nil }
        return (hash, stamp, manual, sequence)
    }
}
