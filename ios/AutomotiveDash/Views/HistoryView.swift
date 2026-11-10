import SwiftData
import SwiftUI

struct HistoryView: View {
    @Query(sort: \TpmsReading.receivedAt, order: .reverse)
    private var tpmsReadings: [TpmsReading]

    @Query(sort: \TelemetryRecord.receivedAt, order: .reverse)
    private var sniffRecords: [TelemetryRecord]

    @State private var selectedTab: HistoryTab = .tpms

    enum HistoryTab: String, CaseIterable, Identifiable {
        case tpms = "TPMS"
        case sniff = "Sniff"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack {
                Picker("History", selection: $selectedTab) {
                    ForEach(HistoryTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                switch selectedTab {
                case .tpms:
                    tpmsList
                case .sniff:
                    sniffList
                }
            }
            .navigationTitle("History")
        }
    }

    private var tpmsList: some View {
        List(tpmsReadings) { reading in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(reading.position) · \(reading.sensorId)")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if reading.isSimulated {
                        Text("SIM").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Text(String(format: "%.1f psi · %.1f°C · %.2fV", reading.pressurePsi, reading.temperatureC, reading.batteryV))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(reading.receivedAt.formatted())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .listStyle(.plain)
        .overlay {
            if tpmsReadings.isEmpty {
                ContentUnavailableView("No TPMS history yet", systemImage: "gauge.with.dots.needle.67percent")
            }
        }
    }

    private var sniffList: some View {
        List(sniffRecords) { record in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(record.band)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if record.isSimulated {
                        Text("SIM").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Text("\(record.pulseCount) pulses")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(record.receivedAt.formatted())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .listStyle(.plain)
        .overlay {
            if sniffRecords.isEmpty {
                ContentUnavailableView("No sniff history yet", systemImage: "dot.radiowaves.left.and.right")
            }
        }
    }
}
