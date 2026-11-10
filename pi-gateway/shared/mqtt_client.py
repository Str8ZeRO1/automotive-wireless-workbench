"""
Shared async MQTT publisher used by every Pi Zero daemon in this project.

Wraps asyncio-mqtt (aiomqtt) with reconnect-with-backoff and a simple
publish_json helper so each daemon doesn't reimplement connection handling.
"""
from __future__ import annotations

import asyncio
import json
import logging
import random
from dataclasses import dataclass
from typing import Any

import aiomqtt

logger = logging.getLogger(__name__)


@dataclass(slots=True)
class MqttConfig:
    host: str = "localhost"
    port: int = 1883
    client_id: str = "pi-zero-gateway"
    keepalive: int = 30
    username: str | None = None
    password: str | None = None
    tls: bool = False


class ResilientMqttPublisher:
    """
    Async context-managed MQTT publisher that keeps a single connection
    alive for the life of the daemon and transparently reconnects with
    exponential backoff + jitter on failure. Callers just `await pub.publish(...)`
    and never see the connection churn.
    """

    def __init__(self, config: MqttConfig) -> None:
        self._config = config
        self._client: aiomqtt.Client | None = None
        self._lock = asyncio.Lock()
        self._connected = asyncio.Event()
        self._closing = False
        self._task: asyncio.Task[None] | None = None

    async def start(self) -> None:
        self._closing = False
        self._task = asyncio.create_task(self._run(), name="mqtt-connection-loop")

    async def stop(self) -> None:
        self._closing = True
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    async def _run(self) -> None:
        backoff = 1.0
        max_backoff = 30.0
        while not self._closing:
            try:
                async with aiomqtt.Client(
                    hostname=self._config.host,
                    port=self._config.port,
                    identifier=self._config.client_id,
                    keepalive=self._config.keepalive,
                    username=self._config.username,
                    password=self._config.password,
                ) as client:
                    async with self._lock:
                        self._client = client
                        self._connected.set()
                    logger.info(
                        "MQTT connected host=%s port=%d client_id=%s",
                        self._config.host,
                        self._config.port,
                        self._config.client_id,
                    )
                    backoff = 1.0
                    # Block here until the connection drops; aiomqtt raises
                    # on disconnect, which sends us back to the retry loop.
                    while not self._closing:
                        await asyncio.sleep(3600)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 - daemon must never crash on MQTT errors
                self._connected.clear()
                async with self._lock:
                    self._client = None
                jitter = random.uniform(0, backoff * 0.25)
                wait_s = min(backoff + jitter, max_backoff)
                logger.warning(
                    "MQTT connection lost/failed (%s); retrying in %.1fs", exc, wait_s
                )
                await asyncio.sleep(wait_s)
                backoff = min(backoff * 2, max_backoff)

    async def publish_json(self, topic: str, payload: dict[str, Any], qos: int = 0) -> bool:
        """Publish a dict as JSON. Returns False (and logs) instead of raising
        if the client is currently disconnected, so callers in a tight sensor
        loop never need their own try/except around every publish."""
        async with self._lock:
            client = self._client
        if client is None:
            logger.debug("Dropped publish to %s: MQTT not connected", topic)
            return False
        try:
            await client.publish(topic, payload=json.dumps(payload), qos=qos)
            return True
        except Exception as exc:  # noqa: BLE001
            logger.warning("Publish to %s failed: %s", topic, exc)
            return False
