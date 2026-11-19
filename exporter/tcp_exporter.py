"""Prometheus exporter that measures how long TCP connections take to open.

Every few seconds it tries to open a TCP connection to each target in
targets.yml and records whether it worked and how long the handshake took.
Prometheus scrapes the results from /metrics on port 9105 by default.

Settings come from environment variables:
    TARGETS_FILE    path to the targets file (default: targets.yml)
    PROBE_INTERVAL  seconds between rounds of probes (default: 15)
    PROBE_TIMEOUT   seconds to wait for each connection (default: 3)
    EXPORTER_PORT   port to serve /metrics on (default: 9105)
"""
import logging
import os
import socket
import time

import yaml
from prometheus_client import Counter, Gauge, start_http_server

log = logging.getLogger("tcp_exporter")

PROBE_UP = Gauge(
    "tcp_probe_up",
    "1 if the last TCP connection to the target worked, 0 if it failed",
    ["target"],
)
CONNECT_SECONDS = Gauge(
    "tcp_probe_connect_seconds",
    "Time taken to open the last successful TCP connection",
    ["target"],
)
PROBES_TOTAL = Counter(
    "tcp_probe_checks_total",
    "Number of probes run, split by result",
    ["target", "result"],
)


def load_targets(path):
    """Read the targets file and return a list of (name, host, port) tuples."""
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}

    targets = []
    for entry in data.get("targets", []):
        name = entry.get("name")
        host = entry.get("host")
        port = entry.get("port")
        if not name or not host or not isinstance(port, int):
            raise ValueError(f"target needs a name, host and whole-number port: {entry}")
        if not 0 < port < 65536:
            raise ValueError(f"port out of range for {name}: {port}")
        targets.append((name, host, port))

    if not targets:
        raise ValueError(f"no targets found in {path}")
    return targets


def probe(host, port, timeout):
    """Try one TCP connection. Returns (worked, seconds taken)."""
    start = time.perf_counter()
    try:
        # create_connection also does the DNS lookup, so a name that won't
        # resolve counts as a failed probe rather than crashing the loop
        with socket.create_connection((host, port), timeout=timeout):
            pass
    except OSError as error:
        log.info("probe to %s:%s failed: %s", host, port, error)
        return False, time.perf_counter() - start
    return True, time.perf_counter() - start


def run_once(targets, timeout):
    """Probe every target once and update the metrics."""
    for name, host, port in targets:
        worked, seconds = probe(host, port, timeout)
        PROBE_UP.labels(target=name).set(1 if worked else 0)
        PROBES_TOTAL.labels(target=name, result="success" if worked else "failure").inc()
        # Only record the time for connections that opened. A failed probe's
        # time is usually just the timeout and would make the graph misleading.
        if worked:
            CONNECT_SECONDS.labels(target=name).set(seconds)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    targets_file = os.environ.get("TARGETS_FILE", "targets.yml")
    interval = float(os.environ.get("PROBE_INTERVAL", "15"))
    timeout = float(os.environ.get("PROBE_TIMEOUT", "3"))
    port = int(os.environ.get("EXPORTER_PORT", "9105"))

    targets = load_targets(targets_file)
    start_http_server(port)
    log.info("serving metrics on :%s for %d targets", port, len(targets))

    while True:
        run_once(targets, timeout)
        time.sleep(interval)


if __name__ == "__main__":
    main()
