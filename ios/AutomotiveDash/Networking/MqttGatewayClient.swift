import CocoaMQTT
import Foundation

/// Topic layout, mirrored from mosquitto/README.md / acl.conf.
enum GatewayTopic {
    static let tpmsWildcard = "automotive/tpms/#"
    static let sniffWildcard = "automotive/sniff/#"
    static let beacon = "automotive/node/beacon"
    static let commandMode = "automotive/command/mode"
}

/// A single parsed inbound message, decoupled from CocoaMQTT's own types so
/// the rest of the app (the view model, SwiftData writes) never touches the
/// MQTT library's model directly.
enum GatewayInboundMessage {
    case tpms(TpmsInboundPacket)
    case sniff(SniffInboundSummary)
    case beacon(BeaconInboundPacket)
    case unrecognized(topic: String)
}

struct TpmsInboundPacket: Decodable {
    let id: String
    let position: String?
    let pressureKPa: Double
    let temperatureC: Double
    let batteryV: Double
    let simulated: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case position
        case pressureKPa = "pressure_kPa"
        case temperatureC = "temperature_C"
        case batteryV = "battery_V"
        case simulated
    }
}

struct SniffInboundSummary: Decodable {
    let band: String
    let pulseCount: Int
    let simulated: Bool?

    enum CodingKeys: String, CodingKey {
        case band
        case pulseCount = "pulse_count"
        case simulated
    }
}

struct BeaconInboundPacket: Decodable {
    let nodeId: String
    let uptimeSeconds: Double
    let mode: String
    let cpuTempC: Double
    let supplyVoltageV: Double

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case uptimeSeconds = "uptime_s"
        case mode
        case cpuTempC = "cpu_temp_c"
        case supplyVoltageV = "supply_voltage_v"
    }
}

enum GatewayConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// Thin async wrapper around CocoaMQTT. CocoaMQTT's delegate callbacks fire
/// on CocoaMQTT's own internal queue, not necessarily the main actor, so the
/// delegate shim below is `nonisolated` and immediately hops back onto the
/// client's actor (and, for UI-visible state, onto @MainActor in the view
/// model that owns this client) rather than touching actor-isolated state
/// directly from the callback.
@MainActor
final class MqttGatewayClient: NSObject {
    private(set) var connectionState: GatewayConnectionState = .disconnected
    var onMessage: ((GatewayInboundMessage) -> Void)?
    var onConnectionStateChanged: ((GatewayConnectionState) -> Void)?

    private var mqtt: CocoaMQTT?
    private let decoder = JSONDecoder()

    func connect(settings: GatewayConnectionSettings) {
        disconnect()

        let clientId = "automotive-dash-\(UUID().uuidString.prefix(8))"
        let client = CocoaMQTT(clientID: clientId, host: settings.host, port: settings.port)
        client.username = settings.username
        client.password = settings.password
        client.enableSSL = settings.useTLS
        client.keepAlive = 30
        client.autoReconnect = true
        client.autoReconnectTimeInterval = 5
        client.delegate = self

        self.mqtt = client
        updateState(.connecting)
        _ = client.connect()
    }

    func disconnect() {
        mqtt?.disconnect()
        mqtt = nil
        updateState(.disconnected)
    }

    func publishModeCommand(_ mode: GatewayMode) {
        let payload = #"{"mode": "\#(mode.rawValue)"}"#
        mqtt?.publish(GatewayTopic.commandMode, withString: payload, qos: .qos1)
    }

    private func updateState(_ state: GatewayConnectionState) {
        connectionState = state
        onConnectionStateChanged?(state)
    }

    fileprivate func handleRawMessage(topic: String, payload: Data) {
        if topic.hasPrefix("automotive/tpms/") {
            if let packet = try? decoder.decode(TpmsInboundPacket.self, from: payload) {
                onMessage?(.tpms(packet))
                return
            }
        } else if topic.hasPrefix("automotive/sniff/") {
            if let summary = try? decoder.decode(SniffInboundSummary.self, from: payload) {
                onMessage?(.sniff(summary))
                return
            }
        } else if topic == GatewayTopic.beacon {
            if let beacon = try? decoder.decode(BeaconInboundPacket.self, from: payload) {
                onMessage?(.beacon(beacon))
                return
            }
        }
        onMessage?(.unrecognized(topic: topic))
    }
}

extension MqttGatewayClient: CocoaMQTTDelegate {
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        Task { @MainActor in
            guard ack == .accept else {
                self.updateState(.failed("Broker rejected connection: \(ack)"))
                return
            }
            self.updateState(.connected)
            mqtt.subscribe([
                (GatewayTopic.tpmsWildcard, CocoaMQTTQoS.qos0),
                (GatewayTopic.sniffWildcard, CocoaMQTTQoS.qos0),
                (GatewayTopic.beacon, CocoaMQTTQoS.qos0),
            ])
        }
    }

    nonisolated func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        let topic = message.topic
        let payload = Data(message.payload)
        Task { @MainActor in
            self.handleRawMessage(topic: topic, payload: payload)
        }
    }

    nonisolated func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}

    nonisolated func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}

    nonisolated func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}

    nonisolated func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}

    nonisolated func mqttDidPing(_ mqtt: CocoaMQTT) {}

    nonisolated func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}

    nonisolated func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        Task { @MainActor in
            if let err {
                self.updateState(.failed(err.localizedDescription))
            } else {
                self.updateState(.disconnected)
            }
        }
    }
}
