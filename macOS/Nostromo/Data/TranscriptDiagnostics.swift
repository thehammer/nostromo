import AppKit
import Foundation
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "diagnostics")

/// Reports what the transcript is actually costing, without a debugger.
///
/// The incident's real harm was not the leak — it was three hundred unnoticed
/// minutes ending in a system-wide kill. Several of this work's acceptance
/// criteria are numeric (retained turns, materialized views, resident memory,
/// slope over a run), and a criterion that can only be checked by reading the
/// implementation is not really a criterion. Two surfaces:
///
///   - **Debug ▸ Copy transcript diagnostics** puts the JSON report on the
///     clipboard. This is the "on demand, without attaching a debugger" path.
///   - Setting `NOSTROMO_DIAG_INTERVAL=<seconds>` appends one JSON line per
///     interval to `~/Library/Application Support/Nostromo/diagnostics.jsonl`.
///     This is what `macOS/scripts/transcript-load-test.sh` reads.
enum TranscriptDiagnostics {

    /// Anything a `ReplView` can answer about its own cost.
    protocol Reporting: AnyObject {
        var diagnosticsTag: String { get }
        var retainedTurnCount: Int { get }
        var materializedViewCount: Int { get }
        var hotPayloadTurnCount: Int { get }
        var compressedPayloadBytes: Int { get }
        var estimatedDocumentHeight: Double { get }
        var transcriptClearCount: Int { get }
    }

    // MARK: - Registry

    private static var panes = NSHashTable<AnyObject>.weakObjects()

    static func register(_ pane: Reporting) { panes.add(pane) }
    static func unregister(_ pane: Reporting) { panes.remove(pane) }

    /// Tags of every live transcript pane, distinct and ordered.
    ///
    /// The load harness drives these rather than a hard-coded list: traffic sent
    /// to a tag with no pane attached would exercise `ChatSession` but never
    /// materialize a view, which is precisely the half of the system under test.
    static var registeredTags: [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for object in panes.allObjects {
            guard let pane = object as? Reporting else { continue }
            if seen.insert(pane.diagnosticsTag).inserted { tags.append(pane.diagnosticsTag) }
        }
        return tags.sorted()
    }

    // MARK: - Resident memory

    /// The process's `phys_footprint`, in bytes.
    ///
    /// This is the figure macOS memory pressure and Activity Monitor actually
    /// use — and the one the Force Quit dialog reported as 123.75 GB. Resident
    /// size from `TASK_BASIC_INFO` is a different and less relevant number.
    static func physicalFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint)
    }

    // MARK: - Report

    struct PaneReport: Encodable {
        let tag: String
        let retainedTurns: Int
        let materializedViews: Int
        let hotPayloadTurns: Int
        let compressedPayloadBytes: Int
        let estimatedDocHeight: Double
        let transcriptClears: Int
    }

    /// Identity for every line this process writes, generated once per launch.
    ///
    /// `diagnostics.jsonl` is append-only across app launches, and two Nostromo
    /// instances — a normal GUI plus a harness build — write to the same path
    /// within one run. Without this the report had no way to tell where the
    /// current run starts: it read every row ever written, so the footprint delta
    /// straddled two runs and a fresh run of three samples could be graded
    /// entirely on a previous run's numbers and print PASS on the headline memory
    /// figure. `transcript-load-report.py` groups on this field and grades only
    /// the newest run, and fails a criterion outright when the stream carries no
    /// identity at all.
    private static let runID = UUID().uuidString

    struct Report: Encodable {
        let timestamp: String
        /// Which run wrote this line. See `TranscriptDiagnostics.runID`.
        let runID: String
        /// Which process wrote it, so two concurrent instances are
        /// distinguishable by eye in the raw file and not only by run id.
        let pid: Int
        let physFootprintBytes: Int
        let physFootprintMB: Double
        let maxMaterializedPerPane: Int
        let panes: [PaneReport]
        /// Total turns delivered by the load harness, when one is running.
        let turnsProcessed: Int?
        /// Panes the load harness actually drove. A run that measured no view
        /// layer at all must be visible in the report rather than passing every
        /// view-layer criterion by vacuum. Optional so Debug ▸ Copy transcript
        /// diagnostics is unchanged outside a harness run.
        let harnessTargetedPanes: Int?
        /// Focuses the run asked for, so a run that drove 1 of 8 fails a
        /// criterion instead of reading as a clean 1-focus run.
        let harnessRequestedFocuses: Int?
    }

    static func snapshot() -> Report {
        let footprint = physicalFootprint()
        let reports: [PaneReport] = panes.allObjects.compactMap { object in
            guard let pane = object as? Reporting else { return nil }
            return PaneReport(tag: pane.diagnosticsTag,
                              retainedTurns: pane.retainedTurnCount,
                              materializedViews: pane.materializedViewCount,
                              hotPayloadTurns: pane.hotPayloadTurnCount,
                              compressedPayloadBytes: pane.compressedPayloadBytes,
                              estimatedDocHeight: pane.estimatedDocumentHeight,
                              transcriptClears: pane.transcriptClearCount)
        }
        return Report(timestamp: ISO8601DateFormatter().string(from: Date()),
                      runID: runID,
                      pid: Int(ProcessInfo.processInfo.processIdentifier),
                      physFootprintBytes: footprint,
                      physFootprintMB: (Double(footprint) / 1_048_576 * 10).rounded() / 10,
                      maxMaterializedPerPane: TurnListVirtualizer.maxMaterialized,
                      panes: reports.sorted { $0.tag < $1.tag },
                      turnsProcessed: TranscriptLoadHarness.shared?.turnsDelivered,
                      harnessTargetedPanes: TranscriptLoadHarness.shared?.targetedPaneCount,
                      harnessRequestedFocuses: TranscriptLoadHarness.shared?.requestedFocusCount)
    }

    static func reportJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot()),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Debug ▸ Copy transcript diagnostics.
    static func copyReportToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(reportJSON(), forType: .string)
        log.info("transcript diagnostics copied to pasteboard")
    }

    // MARK: - JSONL stream

    private static var timer: DispatchSourceTimer?

    static var streamURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nostromo/diagnostics.jsonl")
    }

    /// Start the JSONL stream if `NOSTROMO_DIAG_INTERVAL` is set.
    static func startStreamingIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["NOSTROMO_DIAG_INTERVAL"],
              let seconds = Double(raw), seconds > 0
        else { return }

        try? FileManager.default.createDirectory(
            at: streamURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + seconds, repeating: seconds)
        source.setEventHandler { appendStreamLine() }
        source.resume()
        timer = source
        log.info("diagnostics stream every \(seconds, privacy: .public)s → \(streamURL.path, privacy: .public)")
    }

    /// Write one stream line right now, regardless of the timer.
    ///
    /// The harness's abort path uses this: a run that targeted no pane must leave
    /// the report a row to fail on rather than an empty file it can only shrug at.
    static func emitStreamLineNow() {
        try? FileManager.default.createDirectory(
            at: streamURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        appendStreamLine()
    }

    /// Append one line. **Never** shortens the file, on any path.
    ///
    /// This function had two ways to destroy a whole run's evidence in four
    /// lines. `FileHandle(forWritingTo:)` fails when the file does not exist, so
    /// the fallback existed to create it — but it was `try? data.write(to:)`,
    /// which *truncates*, so any other cause of a failed open on an existing file
    /// (permissions, a lock, an exhausted descriptor table) replaced the entire
    /// run with a single line. And `_ = try? handle.seekToEnd()` discarded its
    /// error, so a failed seek left the handle at offset 0 and the following
    /// write overwrote the start of the file.
    ///
    /// An error path must never destroy previously-written evidence. A dropped
    /// sample costs one data point and shows up as a criterion reading
    /// INCONCLUSIVE; a truncated file makes every criterion in the report grade
    /// somebody else's numbers, and says nothing.
    private static func appendStreamLine() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(snapshot()) else { return }
        data.append(0x0A)

        let fm = FileManager.default
        if !fm.fileExists(atPath: streamURL.path) {
            fm.createFile(atPath: streamURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: streamURL) else {
            log.error("""
                diagnostics stream: cannot open \(streamURL.path, privacy: .public) \
                — sample dropped, prior evidence intact
                """)
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            log.error("diagnostics stream: append failed — sample dropped, prior evidence intact")
        }
    }
}
