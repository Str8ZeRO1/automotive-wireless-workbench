import Foundation
import SwiftData

/// Operating mode of the gateway the app is currently pointed at.
/// Mirrors GATEWAY_MODE on the Pi Zero side (run_mode.py).
enum GatewayMode: String, Codable, CaseIterable, Identifiable {
    case sniff
    case simulate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sniff: return "Sniff"
        case .simulate: return "Simulate"
        }
    }
}

/// Generic raw sub-GHz pulse-timing summary, persisted for the offline
/// historical log view. One row per MQTT message on automotive/sniff/#.
@Model
final class TelemetryRecord {
    @Attribute(.unique) var id: UUID
    var band: String
    var pulseCount: Int
    var receivedAt: Date
    var isSimulated: Bool

    init(id: UUID = UUID(), band: String, pulseCount: Int, receivedAt: Date, isSimulated: Bool) {
        self.id = id
        self.band = band
        self.pulseCount = pulseCount
        self.receivedAt = receivedAt
        self.isSimulated = isSimulated
    }
}

/// Decoded TPMS reading, persisted for the gauge clusters and historical
/// queries. One row per MQTT message on automotive/tpms/#.
@Model
final class TpmsReading {
    @Attribute(.unique) var id: UUID
    var sensorId: String
    var position: String
    var pressureKPa: Double
    var temperatureC: Double
    var batteryV: Double
    var receivedAt: Date
    var isSimulated: Bool

    init(
        id: UUID = UUID(),
        sensorId: String,
        position: String,
        pressureKPa: Double,
        temperatureC: Double,
        batteryV: Double,
        receivedAt: Date,
        isSimulated: Bool
    ) {
        self.id = id
        self.sensorId = sensorId
        self.position = position
        self.pressureKPa = pressureKPa
        self.temperatureC = temperatureC
        self.batteryV = batteryV
        self.receivedAt = receivedAt
        self.isSimulated = isSimulated
    }

    var pressurePsi: Double { pressureKPa * 0.145038 }
}

/// Gateway health beacon, persisted so the dashboard can show "last seen"
/// and basic node vitals even across app restarts.
@Model
final class NodeBeacon {
    @Attribute(.unique) var id: UUID
    var nodeId: String
    var uptimeSeconds: Double
    var mode: String
    var cpuTempC: Double
    var supplyVoltageV: Double
    var receivedAt: Date

    init(
        id: UUID = UUID(),
        nodeId: String,
        uptimeSeconds: Double,
        mode: String,
        cpuTempC: Double,
        supplyVoltageV: Double,
        receivedAt: Date
    ) {
        self.id = id
        self.nodeId = nodeId
        self.uptimeSeconds = uptimeSeconds
        self.mode = mode
        self.cpuTempC = cpuTempC
        self.supplyVoltageV = supplyVoltageV
        self.receivedAt = receivedAt
    }
}
