# Mosquitto broker setup (Pi Zero)

```bash
sudo apt-get update
sudo apt-get install -y mosquitto mosquitto-clients

sudo cp mosquitto.conf /etc/mosquitto/conf.d/str8zero.conf
sudo cp acl.conf /etc/mosquitto/acl.conf

# Create the two app users referenced in acl.conf (prompts for passwords):
sudo mosquitto_passwd -c /etc/mosquitto/passwd gateway
sudo mosquitto_passwd /etc/mosquitto/passwd iosapp

sudo systemctl restart mosquitto
sudo systemctl enable mosquitto
```

Topic layout:

| Topic                              | Publisher            | Subscriber | Payload                                   |
|-------------------------------------|-----------------------|------------|--------------------------------------------|
| `automotive/tpms/<model>/<id>`      | gateway (sniff/sim)   | iOS app    | decoded TPMS packet (pressure/temp/batt)  |
| `automotive/sniff/<band>`           | gateway (sniff/sim)   | iOS app    | raw pulse-timing summary for that band    |
| `automotive/node/beacon`            | gateway (sim; sniff TBD) | iOS app | gateway health/uptime beacon              |
| `automotive/command/mode`           | iOS app               | gateway    | `{"mode": "sniff" \| "simulate"}`         |

Only ingestion/telemetry topics exist. There is intentionally no
`automotive/command/emulate` or transmit-control topic in this broker
config — see the project README for why the RF replay/emulation path is
out of scope for this build.
