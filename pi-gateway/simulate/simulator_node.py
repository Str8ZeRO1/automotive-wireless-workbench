"""
simulator_node.py

Offline test-mode daemon. Generates synthetic TPMS readings, supply-voltage
telemetry, and periodic node beacons, publishing them on the exact same MQTT
topics the real sniffing daemon uses (automotive/tpms/#, automotive/sniff/#,
plus automotive/node/beacon). This lets the iOS app and its SwiftData layer
be developed and demoed with zero hardware attached: flip the app's mode to
`.simulate` and point it at a broker running this daemon instead of
ingestion_daemon.py.

Values are randomized within realistic ranges and drift slowly over time
(a random walk) rather than jumping, so a live dashboard looks believable
rather than obviously fake.
"""
from __future__ import annotations

import asyncio
import logging
import os
import random
import sys
import time
from dataclasses import dataclass, field

from shared.mqtt_client import MqttConfig, ResilientMqttPublisher

logger = logging.getLogger(__name__)

TPMS_TOPIC_PREFIX = "automotive/tpms"
SNIFF_TOPIC_PREFIX = "automotive/sniff"
BEACON_TOPIC = "automotive/node/beacon"


@dataclass(slots=True)
class SimulatedTireState:
    sensor_id: str
    position: str  # "FL", "FR", "RL", "RR"
    pressure_kpa: float = 220.0
    temperature_c: float = 25.0
    battery_v: float = 3.0

    def step(self, rng: random.Random) -> None:
        self.pressure_kpa = _clamp(self.pressure_kpa + rng.uniform(-1.5, 1.5), 150.0, 320.0)
        self.temperature_c = _clamp(self.temperature_c + rng.uniform(-0.8, 0.8), -10.0, 85.0)
        self.battery_v = _clamp(self.battery_v + rng.uniform(-0.01, 0.005), 2.4, 3.2)


def _clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


@dataclass(slots=True)
class SimulatorConfig:
    mqtt: MqttConfig
    tpms_interval_s: float = 4.0
    sniff_interval_s: float = 2.0
    beacon_interval_s: float = 10.0
    vehicle_id: str = "sim-vehicle-01"
    tires: list[SimulatedTireState] = field(default_factory=list)

    def __post_init__(self) -> None:
        if not self.tires:
            self.tires = [
                SimulatedTireState(sensor_id="sim-fl-0001", position="FL"),
                SimulatedTireState(sensor_id="sim-fr-0002", position="FR"),
                SimulatedTireState(sensor_id="sim-rl-0003", position="RL"),
                SimulatedTireState(sensor_id="sim-rr-0004", position="RR"),
            ]


class SimulatorNode:
    def __init__(self, config: SimulatorConfig, publisher: ResilientMqttPublisher) -> None:
        self._config = config
        self._publisher = publisher
        self._rng = random.Random()
        self._stopping = False

    async def run_forever(self) -> None:
        tasks = [
            asyncio.create_task(self._tpms_loop(), name="sim-tpms-loop"),
            asyncio.create_task(self._sniff_loop(), name="sim-sniff-loop"),
            asyncio.create_task(self._beacon_loop(), name="sim-beacon-loop"),
        ]
        await asyncio.gather(*tasks)

    async def stop(self) -> None:
        self._stopping = True

    async def _tpms_loop(self) -> None:
        while not self._stopping:
            for tire in self._config.tires:
                tire.step(self._rng)
                packet = {
                    "model": "Simulated-TPMS",
                    "id": tire.sensor_id,
                    "position": tire.position,
                    "vehicle_id": self._config.vehicle_id,
                    "pressure_kPa": round(tire.pressure_kpa, 1),
                    "temperature_C": round(tire.temperature_c, 1),
                    "battery_V": round(tire.battery_v, 2),
                    "time": time.time(),
                    "simulated": True,
                }
                topic = f"{TPMS_TOPIC_PREFIX}/Simulated-TPMS/{tire.sensor_id}"
                await self._publisher.publish_json(topic, packet)
            await asyncio.sleep(self._config.tpms_interval_s)

    async def _sniff_loop(self) -> None:
        bands = ["315MHz", "433.92MHz", "868MHz"]
        while not self._stopping:
            band = self._rng.choice(bands)
            pulse_count = self._rng.randint(8, 64)
            pulses_us = [round(self._rng.uniform(150, 900), 1) for _ in range(pulse_count)]
            levels = [bool(self._rng.getrandbits(1)) for _ in range(pulse_count)]
            summary = {
                "band": band,
                "pulse_count": pulse_count,
                "pulses_us": pulses_us,
                "levels": levels,
                "time": time.time(),
                "simulated": True,
            }
            topic = f"{SNIFF_TOPIC_PREFIX}/{band}"
            await self._publisher.publish_json(topic, summary)
            await asyncio.sleep(self._config.sniff_interval_s)

    async def _beacon_loop(self) -> None:
        start = time.time()
        while not self._stopping:
            beacon = {
                "node_id": "pi-zero-simulator",
                "uptime_s": round(time.time() - start, 1),
                "mode": "simulate",
                "cpu_temp_c": round(45.0 + self._rng.uniform(-3.0, 5.0), 1),
                "supply_voltage_v": round(5.05 + self._rng.uniform(-0.1, 0.05), 2),
                "time": time.time(),
                "simulated": True,
            }
            await self._publisher.publish_json(BEACON_TOPIC, beacon)
            await asyncio.sleep(self._config.beacon_interval_s)


def load_config_from_env() -> SimulatorConfig:
    mqtt = MqttConfig(
        host=os.environ.get("MQTT_HOST", "localhost"),
        port=int(os.environ.get("MQTT_PORT", "1883")),
        client_id=os.environ.get("MQTT_CLIENT_ID", "pi-zero-simulator"),
        username=os.environ.get("MQTT_USERNAME") or None,
        password=os.environ.get("MQTT_PASSWORD") or None,
    )
    return SimulatorConfig(
        mqtt=mqtt,
        tpms_interval_s=float(os.environ.get("SIM_TPMS_INTERVAL_S", "4.0")),
        sniff_interval_s=float(os.environ.get("SIM_SNIFF_INTERVAL_S", "2.0")),
        beacon_interval_s=float(os.environ.get("SIM_BEACON_INTERVAL_S", "10.0")),
        vehicle_id=os.environ.get("SIM_VEHICLE_ID", "sim-vehicle-01"),
    )


async def main_async(config: SimulatorConfig) -> None:
    publisher = ResilientMqttPublisher(config.mqtt)
    await publisher.start()
    node = SimulatorNode(config, publisher)
    try:
        await node.run_forever()
    finally:
        await node.stop()
        await publisher.stop()


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    try:
        asyncio.run(main_async(load_config_from_env()))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main() or 0)
