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
    }

    // MARK: - Registry

    private static var panes = NSHashTable<AnyObject>.weakObjects()

    static func register(_ pane: Reporting) { panes.add(pane) }
    static func unregister(_ pane: Reporting) { panes.remove(pane) }

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
    }

    struct Report: Encodable {
        let timestamp: String
        let physFootprintBytes: Int
        let physFootprintMB: Double
        let maxMaterializedPerPane: Int
        let panes: [PaneReport]
        /// Total turns delivered by the load harness, when one is running.
        let turnsProcessed: Int?
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
                              estimatedDocHeight: pane.estimatedDocumentHeight)
        }
        return Report(timestamp: ISO8601DateFormatter().string(from: Date()),
                      physFootprintBytes: footprint,
                      physFootprintMB: (Double(footprint) / 1_048_576 * 10).rounded() / 10,
                      maxMaterializedPerPane: TurnListVirtualizer.maxMaterialized,
                      panes: reports.sorted { $0.tag < $1.tag },
                      turnsProcessed: TranscriptLoadHarness.shared?.turnsDelivered)
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

    private static func appendStreamLine() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(snapshot()) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: streamURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: streamURL)
        }
    }
}
