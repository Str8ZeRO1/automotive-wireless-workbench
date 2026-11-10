import Foundation

/// User-editable connection settings for the Pi Zero's Mosquitto broker.
/// Persisted to UserDefaults (not SwiftData -- this is app configuration,
/// not telemetry history).
struct GatewayConnectionSettings: Codable, Equatable {
    var host: String
    var port: UInt16
    var username: String
    var password: String
    var useTLS: Bool

    static let `default` = GatewayConnectionSettings(
        host: "str8zero-gateway.local",
        port: 1883,
        username: "iosapp",
        password: "",
        useTLS: false
    )

    private static let storageKey = "gatewayConnectionSettings.v1"

    static func load() -> GatewayConnectionSettings {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(GatewayConnectionSettings.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
