// NostromoKit — MotherCrewPanelModel.swift
//
// Everything the crew panel shows for one job, as a pure value, plus the panel's
// height. The height is a function of the model (fixed row heights, no wrapping), so
// a host that lays the panel out by hand (the Mac's `NSHostingView`) never has to ask
// SwiftUI how tall it is, and a value change that keeps the row structure keeps the
// frame exactly.
//
// No gate output, finding text or claim quotes: the wire carries none, and this model
// has no field for them.

import CoreGraphics
import Foundation

/// Fixed metrics shared by the model's height and the SwiftUI rows.
public enum MotherCrewPanelMetrics {
    /// One single-line row.
    public static let row: CGFloat = 18
    /// A hold option's consequence: two lines, reserved whether or not it needs them.
    public static let consequence: CGFloat = 30
    /// Between sections.
    public static let gap: CGFloat = 8
}

public struct MotherCrewPanelModel: Equatable {
    /// The progress line (`≈60% · gates 2/3 · ETA ~25m`) and what makes the figure up.
    public struct Progress: Equatable {
        public var line: String
        public var accessibility: String
        public var breakdown: [MotherCrewRow]
    }

    public var progress: Progress?
    public var gates: [MotherCrewRow]
    public var lenses: [MotherCrewRow]
    public var badges: [MotherAttentionBadge]
    public var hold: MotherHoldSummary?
    /// The job has a gate run or a review wave, so `mother status <id>` has more to say.
    public var hasDetails: Bool

    public var isEmpty: Bool {
        progress == nil && gates.isEmpty && lenses.isEmpty && badges.isEmpty && hold == nil
    }

    public init(
        progress: Progress? = nil,
        gates: [MotherCrewRow] = [],
        lenses: [MotherCrewRow] = [],
        badges: [MotherAttentionBadge] = [],
        hold: MotherHoldSummary? = nil,
        hasDetails: Bool = false
    ) {
        self.progress = progress
        self.gates = gates
        self.lenses = lenses
        self.badges = badges
        self.hold = hold
        self.hasDetails = hasDetails
    }

    /// Build the model from a job's crew data (nil-safe: a job without any gives an empty model).
    /// `showsHoldOptions: false` keeps the hold's header but not its option list, for a host
    /// that draws the options as controls of its own.
    public static func make(job: MotherJob, showsHoldOptions: Bool = true) -> MotherCrewPanelModel {
        let crew = job.crew
        var progress: Progress?
        if let line = MotherProgressLine.make(progress: crew.progress, gates: crew.gates) {
            progress = Progress(
                line: line.text, accessibility: line.accessibility,
                breakdown: breakdownRows(crew.progress, gates: crew.gates)
            )
        }
        return MotherCrewPanelModel(
            progress: progress,
            gates: MotherGateRows.make(crew.gates),
            lenses: MotherLensRows.make(crew.reviewWave),
            badges: MotherAttentionBadges.make(crew.attention),
            hold: showsHoldOptions ? MotherHoldSummary.make(job) : MotherHoldSummary.make(job)?.withoutOptions(),
            hasDetails: crew.gates != nil || crew.reviewWave != nil
        )
    }

    // MARK: Height

    /// The panel's height. 0 for an empty model.
    public func height(breakdownExpanded: Bool) -> CGFloat {
        var sections: [CGFloat] = []
        let row = MotherCrewPanelMetrics.row
        if let progress {
            sections.append(row * CGFloat(1 + (breakdownExpanded ? progress.breakdown.count : 0)))
        }
        if !gates.isEmpty { sections.append(row * CGFloat(gates.count)) }
        if !lenses.isEmpty { sections.append(row * CGFloat(lenses.count)) }
        if !badges.isEmpty { sections.append(row) }
        if let hold {
            let withConsequence = hold.options.filter { !$0.consequence.isEmpty }.count
            sections.append(
                row * CGFloat(1 + hold.options.count)
                    + MotherCrewPanelMetrics.consequence * CGFloat(withConsequence)
            )
        }
        guard !sections.isEmpty else { return 0 }
        return sections.reduce(0, +) + MotherCrewPanelMetrics.gap * CGFloat(sections.count - 1)
    }

    // MARK: Breakdown

    /// What makes up the progress figure: stage, gates, active time, cost and the ETA's basis.
    static func breakdownRows(_ progress: MotherProgress?, gates: MotherGates?) -> [MotherCrewRow] {
        guard let progress else { return [] }
        var rows: [MotherCrewRow] = []
        func add(_ id: String, _ title: String, _ detail: String) {
            rows.append(MotherCrewRow(
                id: "progress:\(id)", kind: .item, glyph: "·", title: title, detail: detail,
                accessibility: "\(title): \(detail)"
            ))
        }

        if let stage = progress.signals?.stage ?? progress.stage, !stage.isEmpty {
            add("stage", "Stage", stage)
        }
        let signal = progress.signals?.gates
        if let g = signal, g.total > 0 {
            add("gates", "Gates", "\(g.passed) passed, \(g.failed) failed, of \(g.total)")
        } else if let g = gates, !g.results.isEmpty {
            add("gates", "Gates", "\(g.results.filter { $0.result == .passed }.count) passed, "
                + "\(g.results.filter { $0.result == .failed }.count) failed, of \(g.results.count + g.notRun.count)")
        }
        if let s = progress.signals?.elapsedActiveS {
            add("active", "Active time", MotherGateRows.duration(s))
        }
        if let cost = progress.signals?.cost {
            add("cost", "Cost so far", String(format: "$%.2f", cost))
        }
        if let back = progress.movedBack, let reason = back.reason, !reason.isEmpty {
            add("moved_back", "Moved back", reason)
        }
        add("eta", "ETA basis", etaBasisWords(progress.eta?.basis))
        return rows
    }

    static func etaBasisWords(_ basis: String?) -> String {
        switch basis {
        case "repo": return "from this repo's history"
        case "fleet": return "from all repos"
        case nil, "none": return "not enough history"
        case .some(let other): return other
        }
    }
}
