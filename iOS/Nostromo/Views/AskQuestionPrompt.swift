// Nostromo iOS — AskQuestionPrompt.swift
//
// SwiftUI view for an askQuestion block. Renders option buttons that send
// the selection back via session_send (same mechanism as a regular user
// message). First tap disables all buttons and fires onAnswer.
//
// Reply format mirrors macOS ReplView.swift:1370-1375:
//   - question empty  → option.label
//   - question present → "<label>\n\n(This answers your question: "<q>" — please proceed.)"

import SwiftUI
import NostromoKit

struct AskQuestionPrompt: View {
    let question:  String
    let header:    String
    let options:   [DaemonAskOption]
    let onAnswer:  (String) -> Void

    @State private var answered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !header.isEmpty {
                Text(header)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !question.isEmpty {
                Text(question)
                    .font(.subheadline)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(options, id: \.label) { option in
                    Button {
                        guard !answered else { return }
                        answered = true
                        let reply: String
                        if question.isEmpty {
                            reply = option.label
                        } else {
                            reply = "\(option.label)\n\n(This answers your question: \"\(question)\" — please proceed.)"
                        }
                        onAnswer(reply)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            if !option.description.isEmpty {
                                Text(option.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(answered ? 0.05 : 0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(answered)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
