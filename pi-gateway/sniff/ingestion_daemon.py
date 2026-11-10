"""
Pi Zero sniffing/ingestion daemon.

Two data paths feed MQTT:

1. rtl_433 subprocess (JSON-lines mode) decodes standards-based sub-GHz
   protocols directly -- this is the practical path for TPMS packets, since
   rtl_433 already ships correct decoders for the common TPMS chipsets
   (Schrader, Continental/VDO, etc). Its JSON lines are parsed and
   republished verbatim onto automotive/tpms/<vehicle_or_sensor_id>.

2. A raw envelope path (ook_pulse_parser) is kept for generic sub-GHz
   spectrum awareness -- passive RSSI/pulse-timing visibility into the
   environment, published onto automotive/sniff/<band_mhz>. This path is
   receive-only: it reports pulse timing and power, not decoded protocol
   semantics, and is never connected to anything that transmits.

This module intentionally does not expose any replay/retransmit path --
only ingestion and publication. See project README for scope rationale.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import signal as signal_module
import sys
from dataclasses import dataclass

from shared.mqtt_client import MqttConfig, ResilientMqttPublisher
from sniff.signal_processing import process_envelope_to_pulses

logger = logging.getLogger(__name__)

RTL_433_TOPIC_PREFIX = "automotive/tpms"
RAW_SNIFF_TOPIC_PREFIX = "automotive/sniff"


@dataclass(slots=True)
class IngestionConfig:
    mqtt: MqttConfig
    rtl433_binary: str = "rtl_433"
    rtl433_frequency_hz: int = 433_920_000  # common TPMS/sub-GHz ISM band
    rtl433_sample_rate_hz: int = 250_000
    raw_sniff_enabled: bool = True
    raw_sniff_band_label: str = "433.92MHz"


class RtlFourThreeThreeReader:
    """Spawns rtl_433 in JSON-lines mode and republishes each decoded
    packet onto MQTT. rtl_433 already implements the Butterworth-style
    envelope filtering, Otsu-like adaptive slicing, and protocol-specific
    pulse decoding internally for its supported devices (TPMS included);
    this reader's job is process lifecycle + JSON passthrough + MQTT."""

    def __init__(self, config: IngestionConfig, publisher: ResilientMqttPublisher) -> None:
        self._config = config
        self._publisher = publisher
        self._process: asyncio.subprocess.Process | None = None
        self._stopping = False

    async def run_forever(self) -> None:
        backoff = 2.0
        while not self._stopping:
            try:
                await self._run_once()
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001
                logger.warning("rtl_433 process error: %s; restarting in %.1fs", exc, backoff)
            if self._stopping:
                break
            await asyncio.sleep(backoff)
            backoff = min(backoff * 1.5, 20.0)

    async def _run_once(self) -> None:
        args = [
            self._config.rtl433_binary,
            "-f", str(self._config.rtl433_frequency_hz),
            "-s", str(self._config.rtl433_sample_rate_hz),
            "-F", "json",
            "-M", "time:unix",
        ]
        logger.info("Starting rtl_433: %s", " ".join(args))
        self._process = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        assert self._process.stdout is not None

        stderr_task = asyncio.create_task(self._drain_stderr())
        try:
            async for line in self._process.stdout:
                decoded = line.decode("utf-8", errors="replace").strip()
                if not decoded:
                    continue
                await self._handle_json_line(decoded)
        finally:
            stderr_task.cancel()
            if self._process.returncode is None:
                self._process.terminate()
                try:
                    await asyncio.wait_for(self._process.wait(), timeout=5.0)
                except asyncio.TimeoutError:
                    self._process.kill()

    async def _drain_stderr(self) -> None:
        if self._process is None or self._process.stderr is None:
            return
        async for line in self._process.stderr:
            text = line.decode("utf-8", errors="replace").strip()
            if text:
                logger.debug("rtl_433 stderr: %s", text)

    async def _handle_json_line(self, line: str) -> None:
        try:
            packet = json.loads(line)
        except json.JSONDecodeError:
            logger.debug("Non-JSON line from rtl_433 ignored: %s", line[:200])
            return

        model = str(packet.get("model", "unknown")).replace("/", "_")
        sensor_id = packet.get("id", packet.get("sensor_id", "unknown"))
        topic = f"{RTL_433_TOPIC_PREFIX}/{model}/{sensor_id}"
        await self._publisher.publish_json(topic, packet)

    async def stop(self) -> None:
        self._stopping = True
        if self._process is not None and self._process.returncode is None:
            self._process.terminate()


class RawSpectrumSniffer:
    """
    Generic receive-only sub-GHz spectrum visibility: reads a raw envelope
    stream (e.g. from an rtl_sdr power/magnitude FIFO, or injected by a test
    harness) and runs it through the Butterworth/Otsu/pulse-width pipeline,
    publishing pulse-timing summaries. This gives passive RF-activity
    awareness (how busy the band is, roughly what timing pattern is present)
    without decoding or replaying anything.
    """

    def __init__(
        self,
        config: IngestionConfig,
        publisher: ResilientMqttPublisher,
        envelope_source: "EnvelopeSource",
    ) -> None:
        self._config = config
        self._publisher = publisher
        self._envelope_source = envelope_source
        self._stopping = False

    async def run_forever(self) -> None:
        if not self._config.raw_sniff_enabled:
            return
        async for envelope_chunk, sample_rate_hz in self._envelope_source.chunks():
            if self._stopping:
                break
            pulses = process_envelope_to_pulses(envelope_chunk, sample_rate_hz)
            if not pulses:
                continue
            summary = {
                "band": self._config.raw_sniff_band_label,
                "pulse_count": len(pulses),
                "pulses_us": [p.duration_us for p in pulses[:512]],  # cap payload size
                "levels": [p.level for p in pulses[:512]],
            }
            topic = f"{RAW_SNIFF_TOPIC_PREFIX}/{self._config.raw_sniff_band_label}"
            await self._publisher.publish_json(topic, summary)

    async def stop(self) -> None:
        self._stopping = True


class EnvelopeSource:
    """Abstract source of (envelope_samples, sample_rate_hz) chunks. The
    production implementation reads from a FIFO fed by rtl_sdr/rtl_power;
    this base class exists so simulator_node.py can substitute a synthetic
    generator without the sniffer caring which it's talking to."""

    async def chunks(self):  # pragma: no cover - interface
        raise NotImplementedError
        yield  # noqa - makes this an async generator for subclasses


class FifoEnvelopeSource(EnvelopeSource):
    """Reads raw float32 magnitude samples from a named pipe/FIFO, in
    fixed-size chunks, at a configured sample rate."""

    def __init__(self, fifo_path: str, sample_rate_hz: float, chunk_samples: int = 4096) -> None:
        self._fifo_path = fifo_path
        self._sample_rate_hz = sample_rate_hz
        self._chunk_samples = chunk_samples

    async def chunks(self):
        import struct

        bytes_per_chunk = self._chunk_samples * 4  # float32
        loop = asyncio.get_running_loop()
        fd = os.open(self._fifo_path, os.O_RDONLY | os.O_NONBLOCK)
        try:
            while True:
                data = await loop.run_in_executor(None, _blocking_read, fd, bytes_per_chunk)
                if not data:
                    await asyncio.sleep(0.05)
                    continue
                count = len(data) // 4
                values = list(struct.unpack(f"<{count}f", data[: count * 4]))
                yield values, self._sample_rate_hz
        finally:
            os.close(fd)


def _blocking_read(fd: int, size: int) -> bytes:
    try:
        return os.read(fd, size)
    except BlockingIOError:
        return b""


async def main_async(config: IngestionConfig, envelope_source: EnvelopeSource | None) -> None:
    publisher = ResilientMqttPublisher(config.mqtt)
    await publisher.start()

    rtl433_reader = RtlFourThreeThreeReader(config, publisher)
    tasks = [asyncio.create_task(rtl433_reader.run_forever(), name="rtl433-reader")]

    raw_sniffer: RawSpectrumSniffer | None = None
    if config.raw_sniff_enabled and envelope_source is not None:
        raw_sniffer = RawSpectrumSniffer(config, publisher, envelope_source)
        tasks.append(asyncio.create_task(raw_sniffer.run_forever(), name="raw-sniffer"))

    stop_event = asyncio.Event()

    def _handle_signal() -> None:
        stop_event.set()

    loop = asyncio.get_running_loop()
    for sig in (signal_module.SIGINT, signal_module.SIGTERM):
        loop.add_signal_handler(sig, _handle_signal) if hasattr(loop, "add_signal_handler") else None

    await stop_event.wait()

    logger.info("Shutting down ingestion daemon")
    await rtl433_reader.stop()
    if raw_sniffer is not None:
        await raw_sniffer.stop()
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)
    await publisher.stop()


def load_config_from_env() -> IngestionConfig:
    mqtt = MqttConfig(
        host=os.environ.get("MQTT_HOST", "localhost"),
        port=int(os.environ.get("MQTT_PORT", "1883")),
        client_id=os.environ.get("MQTT_CLIENT_ID", "pi-zero-sniff"),
        username=os.environ.get("MQTT_USERNAME") or None,
        password=os.environ.get("MQTT_PASSWORD") or None,
    )
    return IngestionConfig(
        mqtt=mqtt,
        rtl433_binary=os.environ.get("RTL433_BINARY", "rtl_433"),
        rtl433_frequency_hz=int(os.environ.get("RTL433_FREQ_HZ", "433920000")),
        rtl433_sample_rate_hz=int(os.environ.get("RTL433_SAMPLE_RATE_HZ", "250000")),
        raw_sniff_enabled=os.environ.get("RAW_SNIFF_ENABLED", "1") == "1",
        raw_sniff_band_label=os.environ.get("RAW_SNIFF_BAND_LABEL", "433.92MHz"),
    )


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    config = load_config_from_env()

    envelope_source: EnvelopeSource | None = None
    fifo_path = os.environ.get("RAW_SNIFF_FIFO_PATH")
    if fifo_path:
        envelope_source = FifoEnvelopeSource(
            fifo_path=fifo_path,
            sample_rate_hz=float(os.environ.get("RAW_SNIFF_SAMPLE_RATE_HZ", "250000")),
        )

    try:
        asyncio.run(main_async(config, envelope_source))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main() or 0)
