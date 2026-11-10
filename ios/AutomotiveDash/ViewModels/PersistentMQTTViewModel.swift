import Foundation
import Observation
import SwiftData

/// Lightweight in-memory projection of "latest reading per tire position",
/// for the gauge clusters -- recomputed from inbound messages, not a
/// SwiftData query, so the gauges update instantly without a fetch.
struct LiveTireGauge: Identifiable, Equatable {
    var id: String { position }
    let position: String
    var pressureKPa: Double
    var temperatureC: Double
    var batteryV: Double
    var lastUpdated: Date
}

struct LiveStreamLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let summary: String
    let isSimulated: Bool
}

/// The app's central view model: owns the MQTT connection, writes every
/// inbound telemetry message into SwiftData via its injected ModelContext,
/// and exposes @Observable live state for the dashboard views.
///
/// Runs entirely on the main actor: SwiftData's ModelContext is not
/// Sendable across actors, and UI state needs to be main-actor anyway, so
/// there's no benefit to splitting ingestion onto a background actor here
/// -- the work per message (JSON already decoded by MqttGatewayClient,
/// just a model insert) is cheap enough to do inline.
@MainActor
@Observable
final class PersistentMQTTViewModel {
    private(set) var mode: GatewayMode = .simulate
    private(set) var connectionState: GatewayConnectionState = .disconnected
    private(set) var tireGauges: [String: LiveTireGauge] = [:]
    private(set) var liveLog: [LiveStreamLogEntry] = []
    private(set) var lastBeacon: BeaconInboundPacket?
    private(set) var lastBeaconAt: Date?

    var connectionSettings: GatewayConnectionSettings

    private let maxLiveLogEntries = 200
    private let client = MqttGatewayClient()
    private var modelContext: ModelContext?

    init(connectionSettings: GatewayConnectionSettings = .load()) {
        self.connectionSettings = connectionSettings

        client.onConnectionStateChanged = { [weak self] state in
            self?.connectionState = state
        }
        client.onMessage = { [weak self] message in
            self?.handle(message)
        }
    }

    /// Call once, from a SwiftUI `.task` with the environment's modelContext,
    /// so every subsequent inbound message can be persisted.
    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func connect() {
        client.connect(settings: connectionSettings)
    }

    func disconnect() {
        client.disconnect()
    }

    func reconnectWithCurrentSettings() {
        connectionSettings.save()
        connect()
    }

    /// Mode switching publishes a command topic the gateway's run_mode.py
    /// listens for (future enhancement on the Pi side) and immediately
    /// reflects the chosen mode in the UI so gauges/log clearly indicate
    /// whether data is live RF or synthetic.
    func setMode(_ newMode: GatewayMode) {
        mode = newMode
        client.publishModeCommand(newMode)
    }

    private func handle(_ message: GatewayInboundMessage) {
        switch message {
        case .tpms(let packet):
            handleTpms(packet)
        case .sniff(let summary):
            handleSniff(summary)
        case .beacon(let beacon):
            handleBeacon(beacon)
        case .unrecognized(let topic):
            appendLog("Unrecognized message on \(topic)", isSimulated: false)
        }
    }

    private func handleTpms(_ packet: TpmsInboundPacket) {
        let now = Date()
        let position = packet.position ?? "?"
        let isSimulated = packet.simulated ?? false

        tireGauges[position] = LiveTireGauge(
            position: position,
            pressureKPa: packet.pressureKPa,
            temperatureC: packet.temperatureC,
            batteryV: packet.batteryV,
            lastUpdated: now
        )

        let reading = TpmsReading(
            sensorId: packet.id,
            position: position,
            pressureKPa: packet.pressureKPa,
            temperatureC: packet.temperatureC,
            batteryV: packet.batteryV,
            receivedAt: now,
            isSimulated: isSimulated
        )
        modelContext?.insert(reading)
        persistIfNeeded()

        let psi = reading.pressurePsi
        appendLog(
            String(format: "TPMS %@: %.1f psi, %.1f°C", position, psi, packet.temperatureC),
            isSimulated: isSimulated
        )
    }

    private func handleSniff(_ summary: SniffInboundSummary) {
        let now = Date()
        let isSimulated = summary.simulated ?? false

        let record = TelemetryRecord(
            band: summary.band,
            pulseCount: summary.pulseCount,
            receivedAt: now,
            isSimulated: isSimulated
        )
        modelContext?.insert(record)
        persistIfNeeded()

        appendLog("Sniff \(summary.band): \(summary.pulseCount) pulses", isSimulated: isSimulated)
    }

    private func handleBeacon(_ beacon: BeaconInboundPacket) {
        let now = Date()
        lastBeacon = beacon
        lastBeaconAt = now

        let record = NodeBeacon(
            nodeId: beacon.nodeId,
            uptimeSeconds: beacon.uptimeSeconds,
            mode: beacon.mode,
            cpuTempC: beacon.cpuTempC,
            supplyVoltageV: beacon.supplyVoltageV,
            receivedAt: now
        )
        modelContext?.insert(record)
        persistIfNeeded()

        appendLog("Beacon from \(beacon.nodeId): mode=\(beacon.mode)", isSimulated: beacon.mode == "simulate")
    }

    private func appendLog(_ summary: String, isSimulated: Bool) {
        liveLog.insert(LiveStreamLogEntry(timestamp: Date(), summary: summary, isSimulated: isSimulated), at: 0)
        if liveLog.count > maxLiveLogEntries {
            liveLog.removeLast(liveLog.count - maxLiveLogEntries)
        }
    }

    private func persistIfNeeded() {
        guard let modelContext, modelContext.hasChanges else { return }
        do {
            try modelContext.save()
        } catch {
            appendLog("SwiftData save failed: \(error.localizedDescription)", isSimulated: false)
        }
    }
}
