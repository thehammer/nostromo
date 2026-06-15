// Nostromo iOS — DynamicFocusView.swift
//
// Renders a focus's agent-authored pane tree on iOS.
//
// On iOS, real split views are impractical on a small screen.  This view
// renders panes "by meaning not geometry": the `repl` pane is always the
// primary tab (backed by TranscriptView), and additional agent-created panes
// become extra tabs whose content is rendered from the `PaneContentWire`
// pushed by `set_pane_content`.
//
// When there is only a single `repl` pane (the initial state), the TabView
// chrome is suppressed entirely so the layout is identical to the previous
// direct-to-TranscriptView navigation.

import SwiftUI
import NostromoKit

struct DynamicFocusView: View {
    let tag:         String
    let displayName: String
    let agentName:   String
    let viewName:    String
    let client:      NetworkClient

    @EnvironmentObject var store: DaemonStore
    @State private var selectedTab: String = "repl"

    var body: some View {
        let layout  = store.focusLayouts[tag] ?? FocusLayoutModel.initial
        let paneIds = layout.tree.paneIds

        if paneIds.count <= 1 {
            // Single pane: no tab chrome; identical to the previous TranscriptView experience.
            transcriptView
        } else {
            // Multiple panes: TabView with repl first, then agent-created panes.
            TabView(selection: $selectedTab) {
                transcriptView
                    .tag("repl")
                    .tabItem { Label("Repl", systemImage: "terminal") }

                ForEach(paneIds.filter { $0 != "repl" }, id: \.self) { paneId in
                    PaneTab(paneId: paneId, content: layout.paneContent[paneId])
                        .environmentObject(store)
                        .navigationTitle(paneId.capitalized)
                        .navigationBarTitleDisplayMode(.inline)
                        .tag(paneId)
                        .tabItem {
                            Label(paneId.capitalized, systemImage: "rectangle.split.2x1")
                        }
                }
            }
            .navigationTitle(selectedTab == "repl" ? displayName : selectedTab.capitalized)
            .navigationBarTitleDisplayMode(.inline)
            // Reset to repl if the selected pane is removed by reset_panes.
            .onChange(of: paneIds) { _, newIds in
                if !newIds.contains(selectedTab) { selectedTab = "repl" }
            }
        }
    }

    // MARK: - Sub-views

    private var transcriptView: some View {
        TranscriptView(
            tag:         tag,
            displayName: displayName,
            agentName:   agentName,
            viewName:    viewName,
            client:      client
        )
    }
}

// MARK: - PaneTab

/// A single non-repl pane rendered from `PaneContentWire` content.
/// Receives `DaemonStore` via `@EnvironmentObject` for `pr_list` action dispatch.
private struct PaneTab: View {
    let paneId:  String
    let content: PaneContentWire?

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
                                    model:  item.toRowModel(),
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
                                model:  item.toRowModel(),
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
