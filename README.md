# Str8Zero Automotive Wireless Workbench

A personal-use dashboard for passively monitoring your vehicle's sub-GHz RF
environment and TPMS sensors from an iPhone, fed by a Raspberry Pi Zero
gateway over MQTT.

## Scope note

This build covers **sniffing/ingestion** and an **offline simulator**, plus
the full iOS dashboard. It intentionally does **not** include an RF
replay/transmit ("emulate") engine — a raw sub-GHz transmit path is a
general-purpose tool for re-broadcasting captured RF, which is the same
capability used to clone vehicle entry/remote systems without authorization,
and the code can't distinguish a legitimate use from that one. If the actual
goal is diagnosing or re-pairing your own vehicle's TPMS sensors, a
dedicated TPMS tool (Autel/Ateq-style) is the right instrument for that job.

## Layout

```
pi-gateway/        Python 3.10+ async daemons for the Raspberry Pi Zero
  sniff/            rtl_433 + raw envelope ingestion -> MQTT
  simulate/         synthetic telemetry generator -> MQTT (same topics)
  shared/           MQTT publisher used by both daemons
  systemd/          unit file to run the gateway as a service
mosquitto/          broker config, ACLs, and setup README
ios/                SwiftUI/SwiftData iOS app (XcodeGen project)
fastlane/           CI build + signing lanes (match + App Store Connect API key)
.github/workflows/  GitHub Actions: macOS runner builds + signs the ad-hoc IPA
scripts/            PowerShell helpers to run from this Windows machine
```

## Getting the app onto your iPhone (no Mac required)

1. One-time: follow `fastlane/README.md` to create a certificates repo,
   generate an App Store Connect API key, and gather your Team ID + device
   UDID.
2. Run `scripts/setup-github-secrets.ps1` with those values — it pushes
   everything into GitHub Actions secrets and (optionally) kicks off the
   first build.
3. Once the workflow succeeds, run `scripts/download-and-install.ps1` to
   pull the signed `.ipa` and get an OTA install link you open on the
   iPhone itself.

## Running the gateway

See `mosquitto/README.md` for broker setup, and `pi-gateway/.env.example`
for daemon configuration. Start in simulate mode first to verify the full
pipeline end-to-end without any RF hardware attached:

```bash
cd pi-gateway
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
GATEWAY_MODE=simulate MQTT_HOST=localhost python3 run_mode.py
```
