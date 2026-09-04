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

    /// One `PaneFirstPaintAudit.Measurements` value, Codable so it can ride
    /// in a `Report` line. Field-for-field identical to `Measurements` — see
    /// `PaneFirstPaintAudit.swift` — deliberately not made `Encodable`
    /// itself, since that type is intentionally content-free and has no
    /// reason to know about JSON.
    struct PaneMeasurementReport: Encodable {
        let paneId: String
        let hasContent: Bool
        let isLoading: Bool
        let boundsWidth: Double
        let boundsHeight: Double
        let hasWindow: Bool
        let layoutPassCount: Int
    }

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

        // ── launch-layout observability (W1 — launch-smoke-test) ────────────
        // Every field below is `Optional`, so a plain launch — no
        // NOSTROMO_DIAG_PATH override, no smoke check watching — writes
        // exactly the same lines it always has once nothing below has
        // anything to say. See `bin/nostromo-launch-smoke`, which is the
        // actual consumer of these fields.

        /// ISO8601 timestamp of the first `DynamicFocusView.reconcile` that
        /// produced at least one pane with `hasWindow == true` and
        /// `layoutPassCount > 0`, across every live focus. This anchors the
        /// launch-smoke check's observation window. `nil` until that happens.
        let firstLayoutReconcileAt: String?
        /// Split-node count from the most recently reconciled tree, summed
        /// across every live `DynamicFocusView`.
        let splitNodesRendered: Int?
        /// Leaf count from the most recently reconciled tree, summed across
        /// every live `DynamicFocusView`.
        let leavesRendered: Int?
        /// Count of live `RatioSplitView`s that have completed a layout pass
        /// with a non-zero size.
        let splitsLaidOut: Int?
        /// Count of live `RatioSplitView`s whose `applyRatios` call has
        /// returned `true` — the crux observation: positive proof the app
        /// reached `NSSplitView.setPosition` and returned from it, which is
        /// exactly the call that never returned in the 2026-09-03 defect.
        let splitsRatiosApplied: Int?
        /// Verbatim `PaneFirstPaintAudit.Measurements` for every live
        /// agent-authored pane (`PaneContentNSView`), from
        /// `AppStore.currentPaneMeasurements()`. Not re-derived or re-graded
        /// here — the launch-smoke check applies `PaneFirstPaintAudit`'s own
        /// predicate itself.
        let panesMeasured: [PaneMeasurementReport]?
    }

    /// See `firstLayoutReconcileAt` above. Written once, by
    /// `_recordFirstLayoutIfNeeded`, never cleared.
    private static var firstLayoutReconcileAt: String?
    /// tag -> (split-node count, leaf count) from that focus's most recent
    /// reconcile. `snapshot()` sums these for `splitNodesRendered`/
    /// `leavesRendered`.
    private static var renderedTreeShapeByTag: [String: (splits: Int, leaves: Int)] = [:]

    /// Called once per `DynamicFocusView.reconcile`, right after
    /// `renderedTree` is assigned — the documented sole choke point every
    /// structural repair funnels through.
    ///
    /// This is the *hint* path for `firstLayoutReconcileAt`, not the only
    /// one: a `reconcile()` is driven by a `FocusLayout` broadcast, which
    /// typically arrives well before AppKit has actually run a layout pass
    /// on the freshly built views (a real layout pass is scheduled
    /// asynchronously on the next display cycle). A fixture that sends
    /// exactly one static tree — as `bin/nostromo-launch-smoke`'s does —
    /// then never calls `reconcile` again, so relying on this path alone
    /// left `firstLayoutReconcileAt` unset for tens of seconds until some
    /// unrelated event happened to trigger another reconcile. `snapshot()`
    /// below checks the same condition on every diagnostics-stream tick, so
    /// whichever fires first — another reconcile, or the next tick — records
    /// it.
    static func noteReconcile(tag: String, splitNodes: Int, leaves: Int) {
        renderedTreeShapeByTag[tag] = (splits: splitNodes, leaves: leaves)
        _recordFirstLayoutIfNeeded(using: AppStore.shared.currentPaneMeasurements())
    }

    /// Drop a focus's rendered-shape entry when the focus itself goes away.
    /// `renderedTreeShapeByTag` is strong and keyed by tag, while `splits` is
    /// a weak table that self-prunes — so without this, a removed focus's
    /// splits stay counted in `splitNodesRendered` forever while
    /// `splitsLaidOut`/`splitsRatiosApplied` drop to reflect only live views,
    /// and every subsequent row reports a tree that under-applied its ratios
    /// when nothing of the kind happened. Called from
    /// `AppStore.evictPerFocusState`.
    static func forgetTag(_ tag: String) {
        renderedTreeShapeByTag.removeValue(forKey: tag)
    }

    /// Set `firstLayoutReconcileAt` (and emit a stream line immediately) the
    /// first time any pane measurement shows a real, laid-out size. Safe to
    /// call repeatedly — a no-op once already set.
    private static func _recordFirstLayoutIfNeeded(using measurements: [PaneFirstPaintAudit.Measurements]) {
        guard firstLayoutReconcileAt == nil else { return }
        let anyPaneLaidOut = measurements.contains {
            $0.hasWindow && $0.layoutPassCount > 0 && $0.boundsWidth > 0 && $0.boundsHeight > 0
        }
        guard anyPaneLaidOut else { return }
        firstLayoutReconcileAt = ISO8601DateFormatter().string(from: Date())
        emitStreamLineNow()
    }

    /// Anything a live `RatioSplitView` can report about itself — see
    /// `RatioSplitView`'s conformance in `DynamicFocusView.swift`.
    protocol SplitReporting: AnyObject {
        var hasLaidOut: Bool { get }
        var ratiosApplied: Bool { get }
        var splitBoundsWidth: Double { get }
        var splitBoundsHeight: Double { get }
    }

    private static var splits = NSHashTable<AnyObject>.weakObjects()

    /// Registered by `DynamicFocusView.makeSplitView` right after
    /// construction. Weakly held, like `panes` above — registration must
    /// never be what keeps a split alive, and a rebuilt-away split simply
    /// drops out once deallocated; no explicit unregister needed.
    static func registerSplit(_ split: SplitReporting) { splits.add(split) }

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
        let splitReports = splits.allObjects.compactMap { $0 as? SplitReporting }
        let splitsLaidOutCount = splitReports.filter {
            $0.hasLaidOut && $0.splitBoundsWidth > 0 && $0.splitBoundsHeight > 0
        }.count
        let splitsRatiosAppliedCount = splitReports.filter { $0.ratiosApplied }.count
        let rawMeasurements = AppStore.shared.currentPaneMeasurements()
        // Catch-up path for `firstLayoutReconcileAt` — see `noteReconcile`'s
        // doc comment: a fixture (or a real launch) that never triggers a
        // second `reconcile()` still gets this recorded within one
        // diagnostics-stream tick of AppKit actually completing a layout
        // pass, rather than waiting on an unrelated later reconcile.
        _recordFirstLayoutIfNeeded(using: rawMeasurements)
        let paneMeasurements = rawMeasurements.map {
            PaneMeasurementReport(paneId: $0.paneId, hasContent: $0.hasContent,
                                  isLoading: $0.isLoading, boundsWidth: $0.boundsWidth,
                                  boundsHeight: $0.boundsHeight, hasWindow: $0.hasWindow,
                                  layoutPassCount: $0.layoutPassCount)
        }
        let treeShape = renderedTreeShapeByTag.values.reduce((splits: 0, leaves: 0)) {
            (splits: $0.splits + $1.splits, leaves: $0.leaves + $1.leaves)
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
                      harnessRequestedFocuses: TranscriptLoadHarness.shared?.requestedFocusCount,
                      firstLayoutReconcileAt: firstLayoutReconcileAt,
                      splitNodesRendered: renderedTreeShapeByTag.isEmpty ? nil : treeShape.splits,
                      leavesRendered: renderedTreeShapeByTag.isEmpty ? nil : treeShape.leaves,
                      splitsLaidOut: splitReports.isEmpty ? nil : splitsLaidOutCount,
                      splitsRatiosApplied: splitReports.isEmpty ? nil : splitsRatiosAppliedCount,
                      panesMeasured: paneMeasurements.isEmpty ? nil : paneMeasurements)
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

    /// `NOSTROMO_DIAG_PATH`, resolved once, overrides the default path
    /// entirely — this is what lets `bin/nostromo-launch-smoke` point a
    /// launch at its own per-run temp file instead of appending to the
    /// operator's `diagnostics.jsonl`. Falls back to the existing path when
    /// unset, so default behaviour (no `NOSTROMO_*` variables) is unchanged.
    static var streamURL: URL {
        if let override = ProcessInfo.processInfo.environment["NOSTROMO_DIAG_PATH"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
