import SwiftData
import SwiftUI

@main
struct AutomotiveDashApp: App {
    let modelContainer: ModelContainer

    init() {
        do {
            let schema = Schema([
                TelemetryRecord.self,
                TpmsReading.self,
                NodeBeacon.self,
            ])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create SwiftData ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }
}
