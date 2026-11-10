import SwiftUI

struct SettingsView: View {
    var viewModel: PersistentMQTTViewModel
    @State private var host: String = ""
    @State private var port: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var useTLS: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway Mode") {
                    Picker("Mode", selection: Binding(
                        get: { viewModel.mode },
                        set: { viewModel.setMode($0) }
                    )) {
                        ForEach(GatewayMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Sniff uses live RF hardware on the Pi Zero. Simulate generates synthetic telemetry for development/demo without hardware attached.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Mosquitto Broker") {
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Toggle("Use TLS", isOn: $useTLS)
                }

                Section {
                    Button("Save & Reconnect") {
                        applyAndReconnect()
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear(perform: loadFromViewModel)
        }
    }

    private func loadFromViewModel() {
        let settings = viewModel.connectionSettings
        host = settings.host
        port = String(settings.port)
        username = settings.username
        password = settings.password
        useTLS = settings.useTLS
    }

    private func applyAndReconnect() {
        guard let portValue = UInt16(port) else { return }
        viewModel.connectionSettings = GatewayConnectionSettings(
            host: host,
            port: portValue,
            username: username,
            password: password,
            useTLS: useTLS
        )
        viewModel.reconnectWithCurrentSettings()
    }
}
