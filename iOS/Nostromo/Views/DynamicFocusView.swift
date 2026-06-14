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
private struct PaneTab: View {
    let paneId:  String
    let content: PaneContentWire?

    var body: some View {
        ScrollView {
            switch content {
            case nil:
                waitingView
            case .text(let text):
                textView(text)
            case .jsonSnapshot(let value):
                jsonView(value)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Renderers

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
