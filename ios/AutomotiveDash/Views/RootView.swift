import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = PersistentMQTTViewModel()

    var body: some View {
        TabView {
            DashboardView(viewModel: viewModel)
                .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent") }

            LiveStreamView(viewModel: viewModel)
                .tabItem { Label("Live", systemImage: "dot.radiowaves.left.and.right") }

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            SettingsView(viewModel: viewModel)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task {
            viewModel.attach(modelContext: modelContext)
            viewModel.connect()
        }
    }
}
