import SwiftUI

struct LiveStreamView: View {
    var viewModel: PersistentMQTTViewModel

    var body: some View {
        NavigationStack {
            List(viewModel.liveLog) { entry in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.summary)
                            .font(.callout)
                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.isSimulated {
                        Text("SIM")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Live Stream")
            .overlay {
                if viewModel.liveLog.isEmpty {
                    ContentUnavailableView(
                        "Waiting for telemetry",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Messages from the gateway will appear here as they arrive.")
                    )
                }
            }
        }
    }
}
