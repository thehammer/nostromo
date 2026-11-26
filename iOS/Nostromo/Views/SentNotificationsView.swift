// Nostromo iOS — SentNotificationsView.swift
//
// Every notification attempted for this device in the last seven days (W13): time, kind, host, the
// exact title and body as sent, and how it came out. Kept on the operator's machines, not in the relay.

import SwiftUI
import NostromoKit

struct SentNotificationsView: View {
    @EnvironmentObject var push: PushModel

    var body: some View {
        List {
            if push.sentLog.isEmpty {
                Text("Nothing has been sent to this device in the last 7 days.").foregroundStyle(.secondary)
            }
            ForEach(push.sentLog.reversed()) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.headline)
                    Text(entry.body)
                    HStack {
                        Text(entry.ts, format: .dateTime.month().day().hour().minute())
                        Spacer()
                        Text(entry.outcome.label)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Sent notifications")
        .onAppear { push.requestSentLog() }
        .refreshable { push.requestSentLog() }
    }
}
