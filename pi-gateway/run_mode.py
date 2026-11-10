"""
Single entry point for the Pi Zero gateway, so systemd (or a manual SSH
session) runs one unit and picks the mode via GATEWAY_MODE env var or CLI
arg, matching the iOS app's .sniff / .simulate mode switch.

Usage:
    python3 run_mode.py sniff
    python3 run_mode.py simulate
or:
    GATEWAY_MODE=simulate python3 run_mode.py
"""
from __future__ import annotations

import os
import sys


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("GATEWAY_MODE", "sniff")
    mode = mode.strip().lower()

    if mode == "sniff":
        from sniff.ingestion_daemon import main as sniff_main

        sniff_main()
    elif mode == "simulate":
        from simulate.simulator_node import main as simulate_main

        simulate_main()
    else:
        print(f"Unknown GATEWAY_MODE/mode '{mode}'. Expected 'sniff' or 'simulate'.", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
