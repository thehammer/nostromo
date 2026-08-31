// Nostromo iOS — PaneSurfaceView.swift
//
// Renders a single non-repl pane's content, keyed by `PaneContentWire`.
//
// Moved out of DynamicFocusView.swift (W2 — ios-curated-view-parity) so the
// tab/region structure in that file and the content-kind switch in this one
// can evolve independently — W4/W5/W7/W8/W9 all touch the switch below.
// DynamicFocusView keeps the TabView/paneIds structure; this file owns the
// content kinds.
//
// Receives `DaemonStore` via `@EnvironmentObject` for `pr_list` action dispatch.
import SwiftUI
import NostromoKit

struct PaneSurfaceView: View {
    let paneId:    String
    let content:   PaneContentWire?
    let freshness: PaneFreshness?
    /// Where to look inside this pane's content, and why (W1/W5 —
    /// curated-agent-views). `pr_list` reads its `queue_row` anchor/emphasis
    /// to mark a row; the other kinds rendered here have no addressing yet.
    let address:   PaneAddress?

    @EnvironmentObject var store: DaemonStore

    /// Staged pending approval — set on first swipe tap; cleared on cancel or after
    /// the confirmation dialog fires. Mirrors the pattern in `PerriView`.
    @State private var pendingApproval: (repo: String, number: Int)?

    private let bucketOrder: [(label: String, key: String)] = [
        ("Requested",    "requested"),
        ("Needs Review", "needs_review"),
        ("Changes Req",  "changes_req"),
        ("Dependabot",   "dependabot"),
    ]

    var body: some View {
        Group {
            switch content {
            case nil:
                ScrollView { waitingView }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text(let text):
                ScrollView { textView(text) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .jsonSnapshot(let value):
                ScrollView { jsonView(value) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .prList(let items):
                prListView(items)
            case .loading:
                ScrollView {
                    VStack(spacing: 8) {
                        Spacer(minLength: 60)
                        ProgressView()
                        Text("Refreshing…")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }.frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let msg):
                ScrollView {
                    VStack(spacing: 8) {
                        Spacer(minLength: 60)
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(msg)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                    }.frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unknown(let raw):
                ScrollView { jsonView(raw) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            // `.code`/`.diff` are out of scope for iOS rendering in this wedge
            // (the PRD is explicit: no tabs, code views, or modals on iOS in
            // v1) — these exist only so this switch stays exhaustive against
            // the shared wire type. `.code` at least has a plain `text` field
            // worth showing as-is; `.diff`'s structured per-file model has no
            // simple text equivalent, so it gets a placeholder instead of a
            // half-built rendering nobody asked for.
            case .code(let payload):
                ScrollView { textView(payload.text) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .diff:
                ScrollView {
                    VStack(spacing: 8) {
                        Spacer(minLength: 60)
                        Text("Diff view isn't available on iOS yet.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                    }.frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            // `.prConversation` (W3) is likewise out of scope for iOS
            // rendering in v1 — its server-parsed markdown blocks have no
            // simple text equivalent, so it gets the same placeholder
            // treatment as `.diff` rather than a half-built rendering.
            case .prConversation:
                ScrollView {
                    VStack(spacing: 8) {
                        Spacer(minLength: 60)
                        Text("PR conversation isn't available on iOS yet.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                    }.frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            // `.ticket` (W4) is likewise out of scope for iOS rendering in
            // v1 — its server-parsed markdown sections have no simple text
            // equivalent, so it gets the same placeholder treatment as
            // `.diff`/`.prConversation`.
            case .ticket:
                ScrollView {
                    VStack(spacing: 8) {
                        Spacer(minLength: 60)
                        Text("Ticket view isn't available on iOS yet.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                    }.frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // D11: a quiet as-of footnote when this pane's data hasn't refreshed in
        // a while. Never shown for a normal transient miss — only `badlyStale`
        // (never `stale`) is rendered, and it disappears on the next push with
        // no agent action.
        .overlay(alignment: .bottomTrailing) {
            if let freshness, freshness.badlyStale {
                Text(staleLabelText(freshness))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
            }
        }
        // Confirmation gate — nothing reaches GitHub until the user taps "Approve" here.
        // This mirrors the existing PerriView swipe-to-approve + pendingApproval pattern.
        .confirmationDialog(
            pendingApproval.map { "Approve PR #\($0.number) in \($0.repo)?" } ?? "",
            isPresented: Binding(
                get:  { pendingApproval != nil },
                set:  { if !$0 { pendingApproval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let item = pendingApproval {
                Button("Approve") {
                    store.perriApprove(number: item.number, repo: item.repo)
                    pendingApproval = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingApproval = nil }
        } message: {
            Text("The approval will be posted to GitHub. The PR will leave the queue once the index catches up.")
        }
    }

    // MARK: - pr_list renderer

    @ViewBuilder
    private func prListView(_ items: [PrListItemModel]) -> some View {
        if items.isEmpty {
            ScrollView {
                VStack {
                    Spacer(minLength: 60)
                    Text("No PRs in queue")
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            List {
                ForEach(bucketOrder, id: \.key) { bucket in
                    let group = items.filter { $0.bucket == bucket.key }
                    if !group.isEmpty {
                        Section(bucket.label) {
                            ForEach(group) { item in
                                NostromoKit.PerriPRRow(
                                    model:  item.toRowModel(marked: address?.marks(repo: item.repo, number: item.number) ?? false),
                                    onLoad: { store.perriLoadPr(number: item.number, repo: item.repo) },
                                    onClear: {}
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        // First tap only stages the approval — confirmation
                                        // dialog fires before anything is sent to GitHub.
                                        pendingApproval = (repo: item.repo, number: item.number)
                                    } label: {
                                        Label("Approve", systemImage: "checkmark.seal.fill")
                                    }
                                    .tint(.green)
                                }
                            }
                        }
                    }
                }
                // Overflow — items with unrecognised bucket strings
                let knownBuckets = Set(bucketOrder.map(\.key))
                let overflow = items.filter { !knownBuckets.contains($0.bucket) }
                if !overflow.isEmpty {
                    Section("Other") {
                        ForEach(overflow) { item in
                            NostromoKit.PerriPRRow(
                                model:  item.toRowModel(marked: address?.marks(repo: item.repo, number: item.number) ?? false),
                                onLoad: { store.perriLoadPr(number: item.number, repo: item.repo) },
                                onClear: {}
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    pendingApproval = (repo: item.repo, number: item.number)
                                } label: {
                                    Label("Approve", systemImage: "checkmark.seal.fill")
                                }
                                .tint(.green)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - Staleness footnote

    private func staleLabelText(_ freshness: PaneFreshness) -> String {
        guard let asOf = freshness.asOf else { return "stale" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "stale · as of \(formatter.string(from: asOf))"
    }

    // MARK: - Text / JSON renderers

    private var waitingView: some View {
        VStack {
            Spacer(minLength: 60)
            Text("waiting for content…")
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func textView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .regular, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .textSelection(.enabled)
    }

    private func jsonView(_ value: Any) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(jsonRows(from: value)) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.key)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 80, alignment: .trailing)
                    Text(row.value)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 12)
            }
        }
    }

    // MARK: - JSON helpers

    private struct JsonRow: Identifiable {
        let key: String
        let value: String
        var id: String { key }
    }

    private func jsonRows(from value: Any) -> [JsonRow] {
        if let dict = value as? [String: Any] {
            return dict.map { k, v in JsonRow(key: k, value: jsonString(v)) }
                       .sorted { $0.key < $1.key }
        }
        if let arr = value as? [Any] {
            return arr.enumerated().map { i, v in JsonRow(key: "\(i)", value: jsonString(v)) }
        }
        return [JsonRow(key: "value", value: jsonString(value))]
    }

    private func jsonString(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let b = value as? Bool   { return b ? "true" : "false" }
        if let i = value as? Int    { return "\(i)" }
        if let d = value as? Double { return "\(d)" }
        if let arr = value as? [Any] {
            return "[\(arr.map { jsonString($0) }.joined(separator: ", "))]"
        }
        if let dict = value as? [String: Any] {
            let pairs = dict.map { "\($0.key): \(jsonString($0.value))" }.joined(separator: ", ")
            return "{\(pairs)}"
        }
        return "\(value)"
    }
}
