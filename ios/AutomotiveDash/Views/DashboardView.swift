import SwiftUI

struct DashboardView: View {
    var viewModel: PersistentMQTTViewModel

    private let positionOrder = ["FL", "FR", "RL", "RR"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ConnectionBanner(state: viewModel.connectionState, mode: viewModel.mode)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        ForEach(positionOrder, id: \.self) { position in
                            TireGaugeCard(gauge: viewModel.tireGauges[position], position: position)
                        }
                    }
                    .padding(.horizontal)

                    if let beacon = viewModel.lastBeacon, let at = viewModel.lastBeaconAt {
                        NodeBeaconCard(beacon: beacon, receivedAt: at)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Dashboard")
        }
    }
}

private struct ConnectionBanner: View {
    let state: GatewayConnectionState
    let mode: GatewayMode

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(mode.displayName.uppercased())
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(mode == .simulate ? Color.orange.opacity(0.2) : Color.green.opacity(0.2))
                .foregroundStyle(mode == .simulate ? .orange : .green)
                .clipShape(Capsule())
        }
        .padding(.horizontal)
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private var label: String {
        switch state {
        case .connected: return "Connected to gateway"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        case .failed(let reason): return "Connection failed: \(reason)"
        }
    }
}

private struct TireGaugeCard: View {
    let gauge: LiveTireGauge?
    let position: String

    private var pressurePsi: Double? {
        guard let gauge else { return nil }
        return gauge.pressureKPa * 0.145038
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(position)
                .font(.headline)

            Gauge(value: pressurePsi ?? 0, in: 0...45) {
                Text("PSI")
            } currentValueLabel: {
                Text(pressurePsi.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.title2.weight(.bold))
            }
            .gaugeStyle(.accessoryCircular)
            .tint(tintColor)

            if let gauge {
                VStack(spacing: 2) {
                    Text(String(format: "%.1f°C", gauge.temperatureC))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "Batt %.2fV", gauge.batteryV))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("No data yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var tintColor: Color {
        guard let psi = pressurePsi else { return .gray }
        if psi < 26 || psi > 38 { return .red }
        if psi < 30 || psi > 35 { return .orange }
        return .green
    }
}

private struct NodeBeaconCard: View {
    let beacon: BeaconInboundPacket
    let receivedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Gateway: \(beacon.nodeId)")
                .font(.headline)
            HStack {
                Label(String(format: "%.1f°C CPU", beacon.cpuTempC), systemImage: "thermometer")
                Spacer()
                Label(String(format: "%.2fV supply", beacon.supplyVoltageV), systemImage: "bolt.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Uptime \(formattedUptime(beacon.uptimeSeconds)) · last seen \(receivedAt.formatted(date: .omitted, time: .standard))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func formattedUptime(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "\(Int(seconds))s"
    }
}
